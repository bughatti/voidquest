----------------------------------------------------------------------
-- VoidLayerCore: the WoW Forever layer network (2026-11-09)
--
-- Copied as-is into every addon that carries it (VoidLayer, VoidSweep; source of truth:
-- wow-addons/_shared/VoidLayerCore.lua). Needs WhisperNet.lua and Layer.lua loaded before it
-- in the same addon. Like VoidHubBundle / PresenceBox: every copy registers, and at
-- PLAYER_LOGIN ONE copy runs (the newest CORE_VERSION), so two addons never answer, host or
-- invite twice. Settings come from the addon with the highest priority (VoidLayer 2,
-- VoidSweep 1): each addon calls ns.LayerCoreSettings(prio, label, getSettingsTable).
-- The running core is _G.VoidLayerCore (nil on retail, or before PLAYER_LOGIN).
--
-- The game has no layer API and no "go to layer X". Your layer is read from nearby NPC GUIDs
-- (Layer.lua), and you move to another one by joining a group whose leader is on it
-- (measured 2026-11-08). So the network does three things, all by addon whisper (Forever
-- refuses addon messages in custom channels; the channel is only a member list):
--   1. Who's on which layer:  Q:1:ttl:zone:nonce:asker   relayed once (ttl 1) to a few more
--                             A:1:zone:pair:h            straight back to the asker; h=1 hosts
--                             S:1:zone:pair:n            right after it: n players seen on that layer (6)
--   2. Rares:                 R:1:ttl:zone:pair:npc:hp:x:y:origin:name   relayed twice (ttl 2);
--                             hp 0 = dead. Shown in the window; a rare on ANOTHER layer of your
--                             zone pops up "Hop there?" (one click).
--   3. The hop:               HR:1:zone:pair:nonce   "please invite me"  (to a host)
--                             HA:1:nonce:ok|no:why   then the host invites you
--                             HS:1:nonce             "I'm staying grouped"
--   4. One layer, many zones:  L:1:0:zoneA:pairA:zoneB:pairB:age   never relayed; a solo zone
--                             crossing showed both ids are one layer, age s ago (section 4)
--   5. Fresh camp:            C:1:zone:pair:cx:cy:age   never relayed; a pack died around a Void
--                             player at that grid cell on that layer, age s ago (section 5)
--     You accept only the invite from the host you asked, while asking; check your layer
--     changed; leave (or stay, if leaving sent you back once). One hop every 5 minutes.
-- Hosting is ON unless turned off (the user, 11-09: a hop only works when someone hosts).
-- A host only invites while solo, alive, out of combat, outside instances, on the asked
-- layer and zone, at most once every 2 minutes and 8 times an hour, and only channel members.
--
-- Channel: a new one every UTC day and per faction, with a password, both worked out from the date
-- (WhisperNet.DailyChannel), so nobody can /join it by hand, own it and /ban players, and a
-- takeover lasts a day at most. The password is in the addon's code, so it stops casual
-- griefing, not a determined one: EVERY message is treated as hostile. A message can only
-- add a short-lived census line or rare line, or ask for an invite the host checks itself.
-- Names stay in memory, never saved or shown (the host's name shows only in its invite).
----------------------------------------------------------------------
local ADDON, ns = ...
-- 2: a hop counts any move off your layer; the hop group is always left (2026-11-10)
-- 3: one channel per faction, so this core must win over an older copy's both-factions one (2026-11-10)
-- 4: layer names from the layer's own number, the same for every player (2026-11-14)
local CORE_VERSION = 9   -- 9 (2026-11-17): VoidNet, the one channel + Help switch in every Void addon; 5 (2026-11-14): layer = server number only (canon); 6: S, players seen per layer; 7: group rejoin (GQ/GL/RJ/RA); 8: hosting from a Group Finder listing

local reg = _G.VoidLayerCoreReg or { list = {} }
_G.VoidLayerCoreReg = reg
local mine = { v = CORE_VERSION, addon = ADDON, ns = ns, prio = 0 }
table.insert(reg.list, mine)

-- The embedding addon says where the settings live (a table it saves) and what to call itself.
function ns.LayerCoreSettings(prio, label, get)
    mine.prio, mine.label, mine.settings = prio, label, get
end

local function forever() return RegionalUniqueNamesEnabled ~= nil and RegionalUniqueNamesEnabled() == true end

----------------------------------------------------------------------
-- The core (built once, by the elected copy)
----------------------------------------------------------------------
function ns.LayerCoreBuild(owner)
    local Net, Layer = ns.WhisperNet, ns.Layer
    local C = { version = CORE_VERSION, owner = owner.addon }
    local LABEL = owner.label or owner.addon

    local PREFIX        = "VLAYER"
    local DAILY_TAG, DAILY_SALT = "Vl", 58313
    -- 1.1 s (was 0.6): the game allows ~10 addon messages at once, then ~1 a second per prefix; at 0.6 s a
    -- busy queue had sends refused (vnet-sim 2026-11-16: ~2,600 refused an hour at 2,000 players per addon)
    local SEND_EVERY    = 1.1
    local QUEUE_MAX     = 60
    local SENDER_MAX    = 20      -- messages accepted per player per minute
    -- census
    local ASK_PEERS     = 10
    local RELAY_FANOUT  = 4
    local ASK_CD        = 120     -- one question per zone per this
    local ANSWER_WINDOW = 60      -- answers count this long after our question
    local LIVE          = 600     -- an answer counts this long
    local HOST_LIVE     = 300     -- ...and says "hosts" this long
    local REPLY_GAP     = 60      -- one answer per asker per this
    -- rares
    local RARE_FANOUT   = 8
    local RARE_RESEND   = 180     -- the finder re-sends the same rare at most this often
    local RARE_LIVE     = 600     -- a rare line stays this long (dead: DEAD_LIVE)
    local DEAD_LIVE     = 120
    local OFFER_GAP     = 600     -- "hop there?" once per rare per this
    local POPUP_GAP     = 60      -- ...and at most one "hop there?" per this, any rare
    local RARE_MAX      = 200     -- rare lines kept
    -- hop
    local ASK_WAIT      = 12
    local MOVE_WAIT     = 45
    local REVERT_WATCH  = 40
    local COOLDOWN      = 300
    local FIND_WAIT     = 6
    local HOST_GAP      = 120
    local HOUR_CAP      = 8
    local HOST_STAY     = 180
    local STAY_MAX      = 900
    local JOIN_WAIT     = 65      -- the game's invite lasts about a minute
    local LATE_JOIN     = 120     -- a guest who accepts after that is still looked after

    local function S() local t = owner.settings and owner.settings(); return type(t) == "table" and t or {} end
    local function say(msg) print(("|cff00c7ff%s|r: %s"):format(LABEL, msg)) end
    local function now() return GetTime() end
    local function secret(v) return issecretvalue and issecretvalue(v) end
    local function validPair(p) return type(p) == "string" and #p <= 20 and p:match("^%d+%-%d+$") ~= nil end
    -- only the server number is the layer (Layer.lua L.Canon, 2026-11-14): "6832-125" -> "6832-0"
    local function canon(p) local s = type(p) == "string" and p:match("^(%d+)%-%d+$"); return s and (s .. "-0") or p end
    local function validName(n) return type(n) == "string" and n ~= "" and #n <= 48 and not n:find("[|:]") end
    local function validZone(z) z = tonumber(z); return z and z > 0 and C_Map.GetMapInfo(z) and z or nil end

    local listeners = {}
    local function changed() for _, fn in ipairs(listeners) do pcall(fn) end end
    function C:OnChange(fn) listeners[#listeners + 1] = fn end

    -- Hop health (2026-11-16, the user: "start on 5"): how hops end, how long they take, how hosting goes.
    -- Saved per character, never any names: totals + the last 50. /vl stats. A table field, not a local:
    -- LayerCoreBuild is at Lua 5.1's local/register limit.
    function C.hlog(result, st, extra)
        if st and st.test then return end
        local s = S()
        s.hopStats = type(s.hopStats) == "table" and s.hopStats or {}
        s.hopStats[result] = (tonumber(s.hopStats[result]) or 0) + 1
        if result == "start" then return end   -- a total only; the log keeps how hops ended
        s.hopLog =type(s.hopLog) == "table" and s.hopLog or {}
        local e = { t = time(), r = result }
        if st then
            e.z = st.zone
            if st.t0 then e.s = math.floor(GetTime() - st.t0 + 0.5) end
            if st.idx and st.idx > 0 then e.a = st.idx end
        end
        if extra then e.x = extra end
        table.insert(s.hopLog, e)
        while #s.hopLog > 50 do table.remove(s.hopLog, 1) end
    end
    function C.hunlog(result)
        local t = S().hopStats
        if type(t) == "table" and (tonumber(t[result]) or 0) > 0 then t[result] = t[result] - 1 end
    end
    -- An invite from a player listed in the Group Finder shows LFGInvitePopup (role icons), not PARTY_INVITE:
    -- live 11-16 it stayed on screen after AcceptGroup(). Close it too when we accept or decline ourselves.
    function C.hideLfgPopup()
        local p = _G.LFGInvitePopup
        if p and p.IsShown and p:IsShown() and StaticPopupSpecial_Hide then pcall(StaticPopupSpecial_Hide, p) end
    end
    function C:HopStats()
        local s = S()
        return type(s.hopStats) == "table" and s.hopStats or {}, type(s.hopLog) == "table" and s.hopLog or {}
    end

    ------------------------------------------------------------------
    -- Channel + whisper transport
    ------------------------------------------------------------------
    -- ONE channel since 2026-11-17 (VoidNet.lua, the user: "build the one channel move starting with
    -- voidlayer and voidsweep"): the swarm's daily per-faction channel is the member list for every Void
    -- addon; the old layer channel ("Vl") stays while players on an old version are on it, and goes 30
    -- days after the last one. Messages are unchanged, so old and new versions keep hopping together.
    -- Offline marks (bounced whispers) stay session only (the user, 2026-11-09: no names saved).
    -- Members seen in any read of the list this session: a busy channel (over 300) is read a
    -- random window at a time, so one read isn't everyone (Sol review).
    local everPeer, everN = {}, 0
    local net
    -- The Void players box (PresenceBox.lua): "VoidNet" (everyone on the one channel; the user 11-17: "VoidNet" then "Layer helpers" under it) and
    -- "Layer helpers" (players running the layer engine, less the ones who said Help others is off).
    -- Only when VoidLayer runs the core: VoidSweep has its own line.
    C.offNames = {}   -- name -> GetTime() of their "no:off" answer (a table field: locals are at the limit)
    local function publish()
        -- every Void addon carries the engine now (2026-11-17): the two lines show whichever one runs it
        if not _G.VoidPresence or not net then return end
        local note = Net.BlockNote(net:Channel())
        local void = net:Void()
        _G.VoidPresence:Set("VoidNet", "VoidNet", void or 0, false, void ~= nil, note)
        local helpers = net:Others()
        if helpers then
            for name, t in pairs(C.offNames) do
                if GetTime() - t > 3600 then C.offNames[name] = nil else helpers = helpers - 1 end
            end
            helpers = math.max(0, helpers)
        end
        _G.VoidPresence:Set("VoidLayer", "Layer helpers", helpers or 0, false, helpers ~= nil, note)
    end
    net = ns.VoidNet.New({ prefix = PREFIX, legacy = { tag = DAILY_TAG, salt = DAILY_SALT }, db = S(),
        onRoster = function()
            for _, n in ipairs(net and net.roster or {}) do
                if not everPeer[n] and everN < 3000 then everPeer[n] = true; everN = everN + 1 end
            end
            publish()
            changed()
        end })
    if _G.VoidPresence and _G.VoidPresence.Listen then
        _G.VoidPresence:Listen(function() net:RequestRoster(true); publish() end)
    end
    -- the member list is re-read at most every 5 minutes (WhisperNet); ask now and then so the count stays current
    C_Timer.NewTicker(60, function() net:RequestRoster(); publish() end)
    local me = Net.Me()

    local function chatLocked()
        if InCombatLockdown() then return true end
        local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
        if not f then return false end
        local ok, v = pcall(f)
        if not ok or secret(v) then return true end
        return v == true
    end
    -- joining (the one channel, plus the old one while it's needed) lives in VoidNet; it waits out a fight
    local function join() net:Join() end

    -- traffic this session, for /vl net: whispers the game took, refused as offline (result 12),
    -- or refused otherwise. Bounces ("No player named X") are net.bounces.
    local traffic = { sent = 0, offline = 0, refused = 0 }
    -- Sending (2026-11-17, live): the game lets ~10 addon messages go at once per prefix, then ~1 a second.
    -- One message every SEND_EVERY took a 10-player question 11 s to send, longer than the 6 s report,
    -- so answers came in after "only your layer" (0.6 s before VoidNet: 6 s). Now a burst of up to
    -- C.burst goes at once and refills at one per SEND_EVERY: same rate over time, under the game's limit.
    -- (Table fields, not locals: this function is at Lua 5.1's 200-locals limit.)
    local queue, pumping = {}, nil
    C.burst, C.tokens, C.filled = 8, 8, now()
    local function pump()
        -- one run at a time (Sol 2026-11-17): net:Sent can call back into this file (counts, windows); a send
        -- made from there only queues, so an answer and its players-seen count keep their order
        if C.pumpBusy then return end
        C.pumpBusy = true
        local ok, err = pcall(function()
            local t = now()
            C.tokens = math.min(C.burst, C.tokens + (t - C.filled) / SEND_EVERY)
            C.filled = t
            while C.tokens >= 1 and queue[1] do
                local item = table.remove(queue, 1)
                C.tokens = C.tokens - 1
                net:Noted(item.to)
                local result = C_ChatInfo.SendAddonMessage(PREFIX, item.msg, "WHISPER", item.to)
                local k = (result == nil or result == true or result == 0) and "sent" or result == 12 and "offline" or "refused"
                traffic[k] = traffic[k] + 1
                net:Sent(item.to, result)
            end
        end)
        C.pumpBusy = false
        if not ok and geterrorhandler then geterrorhandler()(err) end   -- shown like any Lua error (Sol), never stuck
        if not queue[1] and pumping then pumping:Cancel(); pumping = nil end
    end
    -- runs the queue now, then keeps a short ticker going only while something waits for a token
    function C._kick()
        if pumping then return end
        pump()
        if queue[1] and not pumping then pumping = C_Timer.NewTicker(0.25, pump) end
    end
    local function send(msg, to, urgent)
        if not to or to == me or #queue >= QUEUE_MAX then return end
        local item = { msg = msg, to = to }
        if urgent then table.insert(queue, 1, item) else queue[#queue + 1] = item end
        C._kick()
    end
    local function sendAll(msg, list, urgent) for _, n in ipairs(list) do send(msg, n, urgent) end end
    -- urgent messages that must arrive in THIS order (a census answer, then its players-seen count):
    -- send() puts each urgent one first, which would flip them (Sol review 2026-11-14)
    local function sendFirst(msgs, to)
        if not to or to == me or #queue + #msgs > QUEUE_MAX then return end
        for i = #msgs, 1, -1 do table.insert(queue, 1, { msg = msgs[i], to = to }) end
        C._kick()
    end

    local function isPeer(name)
        if everPeer[name] then return true end
        -- a Void player VoidNet trusted (a channel member heard within the hour, kept over a /reload, never
        -- hostile): we may be asking them while shut out of the channel, so their answers count (Sol, 2026-11-17)
        if net.core and net.core.Fresh and net.core:Fresh(name) then return true end
        for _, n in ipairs(net.roster or {}) do if n == name then return true end end
        return false
    end

    -- k targets: players we know are in this zone first, then random members.
    local census = {}   -- [zone] = { [name] = { pair, host, t } }
    -- a player's id as THEY sent it (older versions: "<server>-<their own number>"): a hop request
    -- to them must carry it, or they answer "not my layer" (Sol review 2026-11-14). [name] = raw id
    local rawOf = {}
    local function noteRaw(name, raw)
        if type(raw) == "string" and validName(name) and (not raw:match("%-0$") or not rawOf[name]) then rawOf[name] = raw end
    end
    local function targets(k, zone, skip)
        net:RequestRoster()
        local out, used = {}, { [me or ""] = true }
        if skip then for _, n in ipairs(skip) do used[n] = true end end
        if zone and census[zone] then
            for name, a in pairs(census[zone]) do
                if #out >= k then break end
                if not used[name] and now() - a.t <= LIVE and net:Reachable(name) then out[#out + 1] = name; used[name] = true end
            end
        end
        for _, name in ipairs(net:Pick(k + #out + 2)) do
            if #out >= k then break end
            if not used[name] then out[#out + 1] = name; used[name] = true end
        end
        return out
    end

    function C:Online() return net:Others() end
    function C:Channel() return net:Channel() end
    function C:BlockReason() return Net.BlockReason(net:Channel()) end
    function C:Void() return net:Void() end
    function C:LegacyInfo() return net:LegacyInfo() end

    -- /vl net: who's reachable and what our whispers did this session (bounces were invisible
    -- before 2026-11-10, when the channel still mixed factions)
    function C:NetReport()
        net:RequestRoster(true)
        C_Timer.After(3.5, function()
            local why, others, void = Net.BlockReason(net:Channel()), net:Others(), net:Void()
            if why then say("|cffff5555" .. why .. "|r")
            elseif not others then say("couldn't read the member list yet, try again in a few seconds.")
            else say(("%d other Void player%s of your faction online, %d running the layer engine."):format(void or 0, (void or 0) == 1 and "" or "s", others)) end
            local li = net:LegacyInfo()
            if li then
                say(li.kept and ("old layer channel kept for older versions (%s on it now; dropped %d days after the last one)."):format(
                        li.old and tostring(li.old) .. " old" or "count not read yet", li.daysLeft)
                    or "old layer channel no longer needed: nobody on an old version for 30 days.")
            end
            say(("this session: %d whisper%s sent, %d bounced (not reachable), %d refused as offline, %d refused otherwise.")
                :format(traffic.sent, traffic.sent == 1 and "" or "s", net.bounces, traffic.offline, traffic.refused))
        end)
    end

    ------------------------------------------------------------------
    -- Layer names, the same for every player. Until 2026-11-14 they were letters in the order YOU
    -- met them (the user "B", a guildie on the same layer "G"), then the number after the dash
    -- ("6829-98" -> "Layer 98"). That number turned out PER PLAYER (2026-11-14, two players on one
    -- layer, same grunt: the user 125, his son 3); only the server number is the layer. Names are
    -- now that number ("6832-0" -> "Layer 6832"), the same for everyone on it (Layer.lua, L.Canon).
    ------------------------------------------------------------------
    function C:Label(zone, pair)
        pair = canon(pair)
        if not validPair(pair) then return pair or "?" end
        local n = tonumber(pair:match("^(%d+)"))
        -- names since 2026-11-24 (Layer.lua v2) are 6 random digits: 3 are enough to tell a zone's few apart
        if n and n >= 100000 then n = n % 900 + 100 end
        return "Layer " .. tostring(n)
    end
    function C:Here() return Layer:Here() end
    function C:Current(zone) return Layer:Current(zone) end
    function C:Zone(mapID) return Layer:Zone(mapID) end

    -- Section 4 (one layer, many zones) fills these in; the census, rares and messages call them.
    local noteSeen = function() end   -- (zone, pair): a Void player saw this layer in this zone
    local onGroupMsg                  -- section 6: GQ / GL / RJ / RA between group members
    local onLink, shareLinks          -- a link from a message; links to hand an asker
    local onCamp                      -- section 5: a camp cleared, from a message
    local linkSharedTo = {}           -- [asker] = GetTime() we last handed them links

    ------------------------------------------------------------------
    -- 1. Who's on which layer
    ------------------------------------------------------------------
    local lastAsk, asked, seenQ, lastReplyTo = {}, {}, {}, {}

    function C:Ask(zone)
        if not zone or not forever() then return false end
        if lastAsk[zone] and now() - lastAsk[zone] < ASK_CD then return false end
        local to = targets(ASK_PEERS, zone)
        if #to == 0 then return false end
        lastAsk[zone], asked[zone] = now(), now()
        local nonce = tostring(math.random(100000, 999999))
        seenQ[nonce .. me] = now()
        sendAll(("Q:1:1:%d:%s:%s"):format(zone, nonce, me), to, true)
        return true
    end

    function C:AskLeft(zone)
        local t = zone and lastAsk[zone]
        local l = t and (ASK_CD - (now() - t)) or 0
        return l > 0 and l or 0
    end

    function C:Counts(zone)
        local out = {}
        for _, a in pairs(census[zone] or {}) do
            if now() - a.t <= LIVE then out[a.pair] = (out[a.pair] or 0) + 1 end
        end
        return out
    end

    -- [pair] = the most players any Void player there says it has seen on that layer (each count is
    -- a minimum, only what that player saw, so the highest is the best guess). Layers nobody counted
    -- aren't in it: unknown, never 0.
    function C:SeenCounts(zone)
        local out = {}
        for _, a in pairs(census[zone] or {}) do
            if a.seen and now() - a.t <= LIVE and (not out[a.pair] or a.seen > out[a.pair]) then out[a.pair] = a.seen end
        end
        return out
    end

    function C:Hosts(zone, pair)
        local out = {}
        for name, a in pairs(census[zone] or {}) do
            if a.pair == pair and a.host and now() - a.t <= HOST_LIVE then out[#out + 1] = name end
        end
        return out
    end

    ------------------------------------------------------------------
    -- 2. Rares
    ------------------------------------------------------------------
    local rares = {}     -- [origin..":"..npc] = { zone, pair, npc, name, hp, x, y, origin, t }
    local sentRare = {}  -- [npc] = { t, dead }
    local offered = {}   -- [name] = GetTime()
    local RARE_CLASS = { rare = true, rareelite = true, worldboss = true }

    local rareCount = 0
    local function pruneRares()
        local n, count, oldestK, oldestT = now(), 0, nil, nil
        for k, r in pairs(rares) do
            if n - r.t > ((r.hp == 0) and DEAD_LIVE or RARE_LIVE) then
                rares[k] = nil
            else
                count = count + 1
                if not oldestT or r.t < oldestT then oldestK, oldestT = k, r.t end
            end
        end
        if count > RARE_MAX and oldestK then rares[oldestK] = nil; count = count - 1 end
        rareCount = count
    end

    -- Rares known, newest first: { npc, name, zone, pair, hp, x, y, age, origin, mineLayer }
    function C:Rares(zone)
        pruneRares()
        local out = {}
        for _, r in pairs(rares) do
            if not zone or r.zone == zone then
                local cur = Layer:Current(r.zone)
                out[#out + 1] = { npc = r.npc, name = r.name, zone = r.zone, pair = r.pair, hp = r.hp, x = r.x, y = r.y,
                                  age = now() - r.t, origin = not r.test and r.origin or nil, same = cur ~= nil and cur == r.pair }
            end
        end
        table.sort(out, function(a, b) return a.age < b.age end)
        return out
    end

    local offerRare   -- defined with the hop

    local function storeRare(zone, pair, npc, hp, x, y, origin, name, test)
        noteSeen(zone, pair)
        local key = origin .. ":" .. npc
        local old = rares[key]
        -- dead stays dead: a late "alive" (relayed slower) doesn't bring it back (Sol review)
        if old and old.hp == 0 and hp > 0 and now() - old.t < DEAD_LIVE then return false end
        if not old and rareCount >= RARE_MAX then pruneRares() end
        local fresh = not old or (old.hp == 0) ~= (hp == 0) or now() - old.t > 60
        if not old then rareCount = rareCount + 1 end
        rares[key] = { zone = zone, pair = pair, npc = npc, name = name, hp = hp, x = x, y = y, origin = origin, t = now(), test = test }
        -- a newer report of the same rare from someone else replaces nothing: both lines age out
        if fresh then changed() end
        return fresh
    end

    local function myPos(zone)
        local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(zone, "player")
        if not pos then return 0, 0 end
        local x, y = pos:GetXY()
        if not x or secret(x) then return 0, 0 end
        return math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5)
    end

    local function seeUnit(unit)
        if not UnitExists(unit) or UnitPlayerControlled(unit) or IsInInstance() then return end
        local cls = UnitClassification(unit)
        if secret(cls) or not RARE_CLASS[cls] then return end
        local g = UnitGUID(unit)
        if not g or secret(g) then return end
        local kind, _, server, _, shard, npc = strsplit("-", g)
        if kind ~= "Creature" then return end
        npc = tonumber(npc)
        local name = UnitName(unit)
        if not npc or secret(name) or not validName(name) then return end
        local zone = Layer:Zone(C_Map.GetBestMapForUnit("player"))
        if not zone then return end
        local pair = Layer:Current(zone) or (Layer:Here())
        if not validPair(pair) then return end
        local dead = UnitIsDead(unit) and true or false
        local hp = 0
        if not dead then
            local h, m = UnitHealth(unit), UnitHealthMax(unit)
            hp = (not secret(h) and not secret(m) and m and m > 0) and math.max(1, math.floor(h / m * 100)) or 100
        end
        -- per rare AND layer: the same rare seen again after a hop is a new report (Sol review)
        local sk = npc .. "@" .. pair
        local s = sentRare[sk]
        if s and s.dead == dead and now() - s.t < RARE_RESEND then return end
        sentRare[sk] = { t = now(), dead = dead }
        local x, y = myPos(zone)
        storeRare(zone, pair, npc, hp, x, y, me, name)
        sendAll(("R:1:2:%d:%s:%d:%d:%d:%d:%s:%s"):format(zone, pair, npc, hp, x, y, me, name), targets(RARE_FANOUT, zone), true)
    end

    ------------------------------------------------------------------
    -- 3. The hop
    ------------------------------------------------------------------
    local state, lastHop, lastHosted, hosting, finding
    local hostedTimes = {}

    local function inGroupWith(name)
        if not (name and IsInGroup()) then return false end
        local raid = IsInRaid()
        local n = GetNumGroupMembers() or 0
        for i = 1, raid and n or n - 1 do
            local u = (raid and "raid" or "party") .. i
            local un, sur = UnitName(u)
            if type(un) == "string" and not secret(un) then
                if Net.Canon(un) == name then return true end
                -- Forever names have two parts ("Ana Brightwood"; Sol review 2026-11-16)
                if type(sur) == "string" and not secret(sur) and sur ~= "" and Net.Canon(un .. " " .. sur) == name then return true end
            end
            local g = GetUnitName and GetUnitName(u, true)
            if type(g) == "string" and not secret(g) and Net.Canon(g) == name then return true end
        end
        return false
    end
    -- hopGroupUntil: a group you accepted for a hop (you were solo: the hop requires it) is yours to
    -- leave for a few minutes, even when the host's name doesn't match the party member's (first real
    -- hop, 2026-11-10: the user stayed grouped after VoidLayer gave up, most likely a name-format mismatch)
    local hopGroupUntil, hopGroupSeen = 0, false
    local function leaveHopGroup(other)
        local two = (GetNumGroupMembers() or 0) <= 2 and not IsInRaid()
        if two and (inGroupWith(other) or now() < hopGroupUntil) and C_PartyInfo and C_PartyInfo.LeaveParty then
            hopGroupUntil = 0
            C_PartyInfo.LeaveParty()
            return true
        end
        return false
    end

    function C:HostingOn() return S().hostHops ~= false end
    function C:SetHosting(on)
        S().hostHops = on and true or false
        -- ONE switch for every Void addon (LayerHelp.lua, 2026-11-17): every addon's settings get the same
        -- value, so it stays the same whichever addon runs the engine next time
        for _, c in ipairs(reg.list) do
            local ok, t = pcall(function() return c.settings and c.settings() end)
            if ok and type(t) == "table" then t.hostHops = on and true or false end
        end
        say(("helping others change layer %s."):format(on and "|cff33ff33on|r: Void players on your layer can ask you for a quick group invite (only while you're solo and out of combat; the group ends on its own)" or "|cffff5555off|r"))
        changed()
    end
    function C:StayOn() return S().hopStay == true end
    function C:SetStay(on) S().hopStay = on and true or false; changed() end
    function C:PopupsOn() return S().rarePopups ~= false end
    function C:SetPopups(on) S().rarePopups = on and true or false; changed() end

    local function hostedLastHour()
        local n = 0
        for i = #hostedTimes, 1, -1 do
            if now() - hostedTimes[i] > 3600 then table.remove(hostedTimes, i) else n = n + 1 end
        end
        return n
    end
    function C:CanHost()
        -- never while your own hop is under way: two invites at once (Sol review)
        -- nor while you wait for your own leader's re-invite: a hop guest's group would make you
        -- refuse it (Sol release review)
        return self:HostingOn() and not hosting and not state and not finding
            and not (self.Rejoining and self:Rejoining())
            and not IsInGroup() and not InCombatLockdown() and not IsInInstance()
            and not UnitIsDeadOrGhost("player")
            and not (lastHosted and now() - lastHosted < HOST_GAP)
            and hostedLastHour() < HOUR_CAP
    end
    function C:CooldownLeft()
        local l = lastHop and (COOLDOWN - (now() - lastHop)) or 0
        return l > 0 and l or 0
    end
    function C:Busy() return state ~= nil or finding == true end
    -- Why you can't hop right now (nil = you can).
    function C:Blocked()
        if not forever() then return "Layers are a WoW Forever thing." end
        if state or finding then return "A hop is under way." end
        if hosting then return "Bringing another Void player over right now; a moment." end
        if InCombatLockdown() then return "In combat." end
        if IsInInstance() then return "Not inside a dungeon or raid." end
        if IsInGroup() then return "In a group: leave it to hop." end
        local cd = self:CooldownLeft()
        if cd > 0 then return ("Next hop in %d:%02d (one every 5 minutes)."):format(math.floor(cd / 60), math.floor(cd % 60)) end
    end

    function C:Status()
        if finding then return "Looking for a Void player on that layer..." end
        if not state then return nil end
        local p = self:Label(state.zone, state.pair)
        if state.phase == "asking" then return ("Asking a Void player on %s to invite you..."):format(p) end
        if state.phase == "joined" then return ("In their group: checking you moved to %s..."):format(p) end
        if state.phase == "retrying" then return "That didn't move you: trying another player..." end
        if state.phase == "left" then return ("On %s. Left the group; making sure you stay."):format(p) end
        return "Hopping..."
    end

    local function stop(msg)
        if msg then say(msg) end
        if state and state.timer then state.timer:Cancel() end
        state = nil
        changed()
    end
    local function setTimer(sec, fn)
        if state.timer then state.timer:Cancel() end
        state.timer = C_Timer.NewTimer(sec, fn)
    end

    local nextHost
    local function moved()
        lastHop = now()
        -- the host is on the layer you landed on, whatever they reported before (2026-11-10: host said
        -- B, you landed on C, and the window kept listing them on B)
        local c = census[state.zone] and census[state.zone][state.host]
        if c then
            -- its players-seen count was for the layer it reported, not this one (Sol review)
            if c.pair ~= state.pair then c.seen = nil end
            c.pair = state.pair
        end
        say(("you're on |cffffd200%s|r now."):format(C:Label(state.zone, state.pair)))
        C.hlog("moved", state)
        if C:StayOn() and not state.test then   -- a test always leaves (Sol review)
            send(("HS:1:%s"):format(state.nonce), state.host, true)
            stop("staying in the group so you keep this layer (it lasts up to 15 minutes); leave it when you're done.")
            return
        end
        state.phase = "left"
        local host = state.host
        C_Timer.After(3, function() leaveHopGroup(host) end)
        setTimer(REVERT_WATCH, function() stop() end)
        changed()
    end

    Layer:OnChange(function(pair, zone, how)
        C:Label(zone, pair)
        if how == "moved" or how == "hop" then C.movedAtS = C.movedAtS or {}; C.movedAtS[zone] = GetServerTime() end
        -- a merge (the game placed you with someone) or a restore is a new NAME for the same layer, not a move
        if state and zone == state.zone and (how == "merged" or how == "kept" or how == "hop" or how == "entered") then
            if state.phase == "left" then state.pair = pair else state.from = pair end
            changed()
            return
        end
        if state and zone == state.zone then
            -- In the host's group, ANY move off the layer you came from is the hop: joining puts you on
            -- the group's layer, and the layer the host reported can be stale. First real hop (the user,
            -- 2026-11-10, The Barrens): A 7054-28 -> joined -> 7054-29 at once, but the host had reported
            -- another id ("Layer B"), so the check waited for B, never finished and never left the group.
            if state.phase == "joined" and pair ~= state.from then
                -- the game moved you while in the host's group: you're on the host's layer, so take its
                -- name (the one it just sent with HP, else the one it reported) instead of a new one
                local hostPair = state.hostPair or state.pair
                state.pair = hostPair
                moved()
                Layer:Adopt(zone, hostPair, "hop")
            elseif state.phase == "left" and pair ~= state.pair then
                S().hopStay = true
                C.hlog("reverted", state)
                stop("leaving the group sent you back, so from now on a hop keeps you in the group (Stay grouped, in the window).")
            end
        end
        changed()
    end)

    -- What the game says about other players (Layer.lua v2, 2026-11-24): a Void player you can see, or a group
    -- member the game puts on your layer, holds your layer's name from now on (both take the lower one); one the
    -- game puts on another layer is proven different. Census and rares follow every merge.
    if Layer.OnPlayer then
        C.lq = {}   -- [name] = { zone, t }: we asked that player its layer's name (LQ) and wait for LA
        Layer:OnPlayer(function(name, zone, same)
            local who = Net.Canon(name)
            if not who or secret(who) or who == me then return end
            local a = census[zone] and census[zone][who]
            if same then
                -- the game says this player is on your layer NOW, but a census name may be the layer it left
                -- (Sol review): ask its current name (LQ, a Void player only); both then take the lower one
                if not isPeer(who) then return end
                local cur = Layer:Current(zone)
                if not cur then return end
                C.lq[who] = { zone = zone, t = now(), gen = Layer:Gen(zone) }
                send(("LQ:1:%d:%s:%d"):format(zone, cur, GetServerTime()), who, true)
            elseif a and now() - a.t <= 120 then
                Layer:Different(zone, a.pair)
                changed()
            end
        end)
        Layer:OnMerge(function(zone, old, new)
            for _, a in pairs(census[zone] or {}) do if a.pair == old then a.pair = new end end
            for _, r in pairs(rares) do if r.zone == zone and r.pair == old then r.pair = new end end
            changed()
        end)
    end

    local function checkMove()
        if not (state and state.phase == "joined") then return end
        local cur = Layer:Current(state.zone)
        if cur and cur ~= state.from then
            -- moved off your layer: that's the hop; take the host's name (Layer.lua v2)
            local zone, hostPair = state.zone, state.hostPair or state.pair
            state.pair = hostPair
            moved()
            Layer:Adopt(zone, hostPair, "hop")
        elseif state.anyPair and cur then
            local host = state.host
            stop(("test: you joined but stayed on %s, so %s was on your layer already. Leaving the group."):format(C:Label(state.zone, cur), host))
            leaveHopGroup(host)
        elseif cur then
            say(("joined, but you're still on %s. Trying another player."):format(C:Label(state.zone, cur)))
            C.hlog("joinedNoMove", state)
            state.phase = "retrying"
            leaveHopGroup(state.host)
            C_Timer.After(2, function() if state and state.phase == "retrying" then nextHost() end end)
        elseif not state.extended then
            state.extended = true
            say("point at or target any NPC so your new layer can be read.")
            setTimer(MOVE_WAIT, checkMove)
        else
            local host = state.host
            C.hlog("unconfirmed", state)
            stop("couldn't confirm the move (no NPC seen), so you're leaving the group.")
            leaveHopGroup(host)
        end
    end

    nextHost = function()
        if not state then return end
        state.idx = state.idx + 1
        local h = state.hosts[state.idx]
        -- a helper since found on YOUR layer (a same-layer invite, or the game placing you together): skip
        while h and Layer:Alias(state.zone, h.pair) == Layer:Current(state.zone) do
            state.idx = state.idx + 1
            h = state.hosts[state.idx]
        end
        if not h then
            -- say why, else a failed Hop looks broken (the user, 2026-11-15, Durotar: two Hops to a
            -- rare's layer, both "nobody could bring you over", no reason)
            local n, parts = 0, {}
            for _, k in ipairs({ "busy", "layer", "off", "none" }) do
                local c = state.why and state.why[k] or 0
                n = n + c
                if c > 0 then
                    parts[#parts + 1] = ("%d %s"):format(c, k == "busy" and "in a group, in combat or just helped someone"
                        or k == "layer" and "no longer on that layer" or k == "off" and "has Help others off"
                        or "didn't answer (offline or out of reach)")
                end
            end
            C.hlog("nobody", state, n > 0 and ("busy %d layer %d off %d none %d"):format(state.why.busy or 0, state.why.layer or 0,
                state.why.off or 0, state.why.none or 0) or nil)
            stop(n > 0 and ("nobody on that layer could bring you over right now. Asked %d: %s. Try again in a bit."):format(n, table.concat(parts, ", "))
                or "nobody on that layer could bring you over right now. Try again in a bit.")
            return
        end
        state.host, state.pair, state.phase, state.extended, state.seenHost, state.hostPair = h.name, h.pair, "asking", nil, nil, nil
        state.nonce = tostring(math.random(100000, 999999))
        send(("HR:1:%d:%s:%s"):format(state.zone, (rawOf[h.name] and canon(rawOf[h.name]) == state.pair) and rawOf[h.name] or state.pair, state.nonce), h.name, true)
        local asked1 = h.name
        setTimer(ASK_WAIT, function()
            if state and state.phase == "asking" and state.host == asked1 then
                state.why = state.why or {}
                state.why.none = (state.why.none or 0) + 1
                -- no answer: not offered as a helper again until they report in (the user, 2026-11-21: "if that
                -- player is no longer reachable, it should go away")
                local a = census[state.zone] and census[state.zone][asked1]
                if a then a.host = false; changed() end
                nextHost()
            end
        end)
        changed()
    end

    -- Hop to a layer in your zone. pair nil = any other layer. prefer = a player to ask first
    -- (the one who saw the rare). isRetry: internal (after asking around). rank(pair) -> number
    -- (lower first) or nil to skip that layer: fresh camp's choice (section 5).
    function C:Start(pair, expectZone, prefer, isRetry, rank)
        if finding and not isRetry then say("still looking for a Void player there; one moment.") return end
        local why = self:Blocked()
        if why then
            if not isRetry then say(why) end   -- a retry that can't go ahead (combat since) stays quiet
            changed()
            return
        end
        local cur, zone = Layer:Here()
        if not zone then say("no zone here.") return end
        if expectZone and zone ~= expectZone then say("you've left that zone, so that hop no longer applies.") return end
        if not cur then say("your layer isn't known yet: point at or target any NPC, then try again.") return end
        if pair == cur then say("you're already on that layer.") return end
        local hosts, used = {}, {}
        local function add(name, p)
            if name and name ~= me and not used[name] and p ~= cur and (not pair or p == pair) then
                local score = 0
                if rank then score = rank(p); if not score then return end end
                used[name] = true
                hosts[#hosts + 1] = { name = name, pair = p, score = score, n = #hosts }
            end
        end
        -- the rare's finder first, then players who said they host, then other rare finders there
        if prefer and pair then add(prefer, pair) end
        local known = {}
        for p in pairs(self:Counts(zone)) do
            for _, n in ipairs(self:Hosts(zone, p)) do known[#known + 1] = { n, p } end
        end
        for i = #known, 2, -1 do local j = math.random(i); known[i], known[j] = known[j], known[i] end
        for _, k in ipairs(known) do add(k[1], k[2]) end
        pruneRares()
        for _, r in pairs(rares) do if r.zone == zone and r.hp > 0 and not r.test then add(r.origin, r.pair) end end
        -- ranked (fresh camp): best layers first, the order found within a layer kept
        if rank then table.sort(hosts, function(a, b) if a.score ~= b.score then return a.score < b.score end return a.n < b.n end) end
        if #hosts == 0 then
            if not isRetry and self:Ask(zone) then
                finding = true
                changed()
                C_Timer.After(FIND_WAIT, function()
                    finding = nil
                    C:Start(pair, zone, prefer, true, rank)
                end)
                return
            end
            C.hlog(rank and "noFresh" or "noHelper", { zone = zone })
            if rank then
                say("no Void player who can bring you over is on another layer here, apart from ones where you cleared this spot yourself in the last 10 minutes. Try again in a few minutes.")
                changed()
                return
            end
            -- Known players there who answered "can't host" (in a group, in combat, dead, just hosted, or Help
            -- others off): say so, else "Hop" looks broken (the user, 2026-11-10, Orgrimmar: Refresh showed
            -- 1 player on another layer, Hop said nobody was there).
            local busy = 0
            for p, n in pairs(self:Counts(zone)) do
                if p ~= cur and (not pair or p == pair) then busy = busy + n end
            end
            if busy > 0 then
                say(("the Void player%s on %s can't bring anyone over right now (in a group, in combat, or Help others is off). Refresh in a few minutes and try again.")
                    :format(busy == 1 and "" or "s", pair and "that layer" or "the other layer"))
            else
                say(("no Void player who can bring you over is on %s in this zone right now. Try again in a few minutes.")
                    :format(pair and "that layer" or "another layer"))
            end
            changed()
            return
        end
        state = { zone = zone, from = cur, hosts = hosts, idx = 0, t0 = now(), want = pair }
        C.hlog("start", { zone = zone })   -- one per hop, however many helpers it asks (Sol review)
        say(("asking a Void player on %s to bring you over..."):format(pair and self:Label(zone, pair) or "another layer"))
        nextHost()
    end

    local lateGuest   -- { name, nonce, t }: invited but didn't come in time (the invite may still be open)
    local function endHosting(leave)
        if not hosting then return end
        local guest = hosting.guest
        C.hlog(hosting.joined and (hosting.finder and "hostFinderCame" or "hostCame")
            or (hosting.finder and "hostFinderNoShow" or "hostNoShow"))
        -- a guest who accepted late was counted as a no-show first: take that back (Sol review)
        if hosting.joined and hosting.late then C.hunlog(hosting.finder and "hostFinderNoShow" or "hostNoShow") end
        if not hosting.joined then lateGuest ={ name = guest, nonce = hosting.nonce, finder = hosting.finder, t = now() } end
        hosting = nil
        StaticPopup_Hide("VOIDLAYER_REMOVE")   -- the guest is gone: no stale Remove prompt (Sol review)
        if leave and leaveHopGroup(guest) then say("left the layer-hop group.") end
    end

    ------------------------------------------------------------------
    -- Incoming messages
    ------------------------------------------------------------------
    local bucket = {}
    local function rateOK(who)
        local b = bucket[who]
        if not b or now() - b.start > 60 then b = { n = 0, start = now() }; bucket[who] = b end
        b.n = b.n + 1
        return b.n <= SENDER_MAX
    end

    local function relay(msg, ttl, who, extraSkip, k)
        if ttl < 1 then return end
        sendAll(msg, targets(k or RELAY_FANOUT, nil, { who, extraSkip }), false)
    end

    local function onMessage(msg, who)
        local tag = msg:match("^(%u%u?):1:")
        if tag == "Q" then
            local ttl, zoneS, nonce, asker = msg:match("^Q:1:(%d):(%d+):(%d+):(.+)$")
            local zone = validZone(zoneS)
            ttl = tonumber(ttl)
            if not (zone and ttl and ttl <= 1 and validName(asker)) or asker == me then return end
            if not isPeer(who) then return end
            -- a first-hand question is from the asker itself; a relayed one names a channel member
            -- (Sol review: else anyone could make us whisper any name)
            if ttl == 1 and asker ~= who then return end
            if ttl == 0 and not isPeer(asker) then return end
            local key = nonce .. asker
            if seenQ[key] then return end
            seenQ[key] = now()
            if ttl > 0 then relay(("Q:1:%d:%d:%s:%s"):format(ttl - 1, zone, nonce, asker), ttl, who, asker) end
            -- the layer links we know for that zone, wherever we stand (section 4), once per asker per ASK_CD
            if shareLinks and not (linkSharedTo[asker] and now() - linkSharedTo[asker] < ASK_CD) then
                linkSharedTo[asker] = now()
                shareLinks(asker, zone)
            end
            if IsInInstance() then return end
            local cur, here = Layer:Here()
            if not cur or here ~= zone then return end
            if lastReplyTo[asker] and now() - lastReplyTo[asker] < REPLY_GAP then return end
            lastReplyTo[asker] = now()
            local out = { ("A:1:%d:%s:%d"):format(zone, cur, C:CanHost() and 1 or 0) }
            -- how many players we've seen on our layer (VoidLayer's count, the last 15 min), so the
            -- asker can tell which layer is quietest (the user, 2026-11-14). Its own message: an older
            -- core's A pattern is anchored and would drop an A with an extra field. Right after the
            -- A, never before it (the asker only takes a count for an answer it already has).
            local seenFn = _G.VoidLayerSeenCount
            local okS, sc = pcall(function() return seenFn and seenFn() end)
            sc = okS and tonumber(sc)
            if sc and sc >= 1 then out[2] = ("S:1:%d:%s:%d"):format(zone, cur, math.min(math.floor(sc), 999)) end
            sendFirst(out, asker)
        elseif tag == "A" then
            local zoneS, pair, h = msg:match("^A:1:(%d+):(%d+%-%d+):([01])$")
            local rawA = pair
            pair = canon(pair)   -- an older version sends "<server>-<its own number>"
            local zone = validZone(zoneS)
            if not (zone and validPair(pair)) then return end
            pair = Layer:Alias(zone, pair)   -- a name we merged away since
            if not (asked[zone] and now() - asked[zone] <= ANSWER_WINDOW) or not isPeer(who) then return end
            census[zone] = census[zone] or {}
            census[zone][who] = { pair = pair, host = h == "1", t = now() }
            noteRaw(who, rawA)
            C:Label(zone, pair)
            noteSeen(zone, pair)
            changed()
        elseif tag == "S" then
            -- the players a census answerer has seen on its layer: only for an answer it just gave
            -- us (same zone and layer, while we're asking), a sane number
            local zoneS, pair, n = msg:match("^S:1:(%d+):(%d+%-%d+):(%d+)$")
            pair = canon(pair)
            local zone = validZone(zoneS)
            n = tonumber(n)
            if not (zone and validPair(pair) and n and n >= 1 and n <= 999) then return end
            if not (asked[zone] and now() - asked[zone] <= ANSWER_WINDOW) or not isPeer(who) then return end
            local a = census[zone] and census[zone][who]
            if not (a and a.pair == Layer:Alias(zone, pair)) then return end
            a.seen = n
            changed()
        elseif tag == "R" then
            local ttl, zoneS, pair, npc, hp, x, y, origin, name =
                msg:match("^R:1:(%d):(%d+):(%d+%-%d+):(%d+):(%d+):(%d+):(%d+):([^:]+):(.+)$")
            local rawR = pair
            pair = canon(pair)
            local zone = validZone(zoneS)
            ttl, npc, hp, x, y = tonumber(ttl), tonumber(npc), tonumber(hp), tonumber(x), tonumber(y)
            if not (zone and ttl and ttl <= 2 and validPair(pair) and npc and npc < 10000000 and hp and hp <= 100
                    and x and x <= 1000 and y and y <= 1000 and validName(origin) and validName(name)) then return end
            if origin == me or not isPeer(who) then return end
            pair = Layer:Alias(zone, pair)
            noteRaw(origin, rawR)
            if storeRare(zone, pair, npc, hp, x, y, origin, name) then
                if ttl > 0 then
                    relay(("R:1:%d:%d:%s:%d:%d:%d:%d:%s:%s"):format(ttl - 1, zone, rawR, npc, hp, x, y, origin, name), ttl, who, origin)
                end
                C:Label(zone, pair)
                if hp > 0 then offerRare(name, zone, pair, origin, x, y, npc) end
            end
        elseif tag == "L" then
            -- one layer's ids in two zones (section 4): the sender vouches for it, seen `age` s ago;
            -- never relayed (a griefer's word reaches only who they whisper)
            local za, pa, zb, pb, age = msg:match("^L:1:0:(%d+):(%d+%-%d+):(%d+):(%d+%-%d+):(%d+)$")
            za, zb, age = validZone(za), validZone(zb), tonumber(age)
            pa, pb = canon(pa), canon(pb)
            if not (za and zb and za ~= zb and validPair(pa) and validPair(pb) and age and age <= 3 * 3600) then return end
            if not isPeer(who) or not onLink then return end
            pa, pb = Layer:Alias(za, pa), Layer:Alias(zb, pb)   -- names merged away since (Sol review)
            onLink(za, pa, zb, pb, who, now() - age)
        elseif tag == "C" then
            -- a camp cleared (section 5): zone, layer, grid cell, seconds ago; never relayed
            local zoneS, pair, cx, cy, age = msg:match("^C:1:(%d+):(%d+%-%d+):(%d+):(%d+):(%d+)$")
            pair = canon(pair)
            local zone = validZone(zoneS)
            if zone and validPair(pair) then pair = Layer:Alias(zone, pair) end   -- a merged-away name (Sol review)
            if zone and validPair(pair) and isPeer(who) and onCamp then onCamp(zone, pair, tonumber(cx), tonumber(cy), tonumber(age)) end
        elseif tag == "HR" then
            local zoneS, pair, nonce = msg:match("^HR:1:(%d+):(%d+%-%d+):(%d+)$")
            pair = canon(pair)
            if not (nonce and validPair(pair)) or not isPeer(who) then return end
            local function reply(txt) send(("HA:1:%s:%s"):format(nonce, txt), who, true) end
            if not C:HostingOn() then reply("no:off") return end
            if not C:CanHost() then reply("no:busy") return end
            local cur, zone = Layer:Here()
            if zone ~= tonumber(zoneS) or Layer:Alias(zone, pair) ~= cur then reply("no:layer") return end
            lastHosted = now()
            hostedTimes[#hostedTimes + 1] = lastHosted
            hosting = { guest = who, nonce = nonce, invited = now(), deadline = now() + HOST_STAY }
            C_PartyInfo.InviteUnit(who)
            reply("ok")
            -- our layer's name, so a guest who moves takes it (an older guest ignores HP)
            send(("HP:1:%s:%s"):format(nonce, cur), who, true)
            say(("inviting %s to bring them to your layer (a layer hop; the group ends on its own)."):format(who))
        elseif tag == "LQ" then
            -- a Void player whose game just put us on one layer (it sees us, or we're grouped): one name for it,
            -- the lower; the answer tells it which (2026-11-24, Layer.lua v2)
            local zoneS, pair, sentS = msg:match("^LQ:1:(%d+):(%d+%-%d+):(%d+)$")
            local zone = validZone(zoneS)
            pair, sentS = canon(pair), tonumber(sentS)
            if not (zone and validPair(pair) and sentS) or not isPeer(who) then return end
            local _, here = Layer:Here()
            if here ~= zone then return end
            -- the asker's game saw us together at sentS (server time, the same clock for both): too old, or we
            -- moved since (or just before), and it's about a layer we left (Sol reviews 2 and 3)
            local nowS = GetServerTime()
            if math.abs(nowS - sentS) > 10 then return end
            C.movedAtS = C.movedAtS or {}
            if C.movedAtS[zone] and C.movedAtS[zone] >= sentS - 2 then return end
            local lo = Layer:Merge(zone, pair)
            if not lo then return end
            local a = census[zone] and census[zone][who]
            if a then a.pair = lo end
            send(("LA:1:%d:%s"):format(zone, lo), who, true)
            changed()
        elseif tag == "LA" then
            local zoneS, pair = msg:match("^LA:1:(%d+):(%d+%-%d+)$")
            local zone = validZone(zoneS)
            pair = canon(pair)
            local q = C.lq and C.lq[who]
            if not (zone and validPair(pair) and q and q.zone == zone and now() - q.t <= 15) then return end
            C.lq[who] = nil
            -- moved since we asked: the answer is about the layer we left (Sol review)
            if q.gen ~= Layer:Gen(zone) then return end
            local lo = Layer:Merge(zone, pair)
            local a = census[zone] and census[zone][who]
            if a and lo then a.pair = lo end
            changed()
        elseif tag == "HP" then
            -- the host's layer name, sent with its ok (2026-11-24)
            local nonce, pair = msg:match("^HP:1:(%d+):(%d+%-%d+)$")
            if state and nonce == state.nonce and who == state.host and validPair(canon(pair)) then state.hostPair = canon(pair) end
        elseif tag == "HN" then
            -- the guest's game said our invite was "same layer": it declined, and we're on one layer
            local nonce, pair = msg:match("^HN:1:(%d+):(%d+%-%d+)$")
            if hosting and hosting.guest == who and nonce == hosting.nonce then
                local _, zone = Layer:Here()
                if zone and validPair(canon(pair)) then Layer:Merge(zone, canon(pair)) end
                C.hlog("hostSame")
                hosting = nil
                changed()
            end
        elseif tag == "HS" then
            local nonce = msg:match("^HS:1:(%d+)$")
            -- a nonce is required, and a Group Finder guest never extends its stay (Sol review 2026-11-16)
            if nonce and hosting and not hosting.finder and hosting.guest == who and nonce == hosting.nonce and inGroupWith(who) then
                hosting.deadline = hosting.invited + STAY_MAX
                say(("%s stays in the group to keep your layer (up to 15 minutes); leave any time."):format(who))
            end
        elseif tag == "HA" then
            local nonce, answer = msg:match("^HA:1:(%d+):(.+)$")
            if not (state and state.phase == "asking" and who == state.host and nonce == state.nonce) then return end
            if answer ~= "ok" then
                local k = answer:match("^no:(%a+)$")
                k = (k == "busy" or k == "layer" or k == "off") and k or "busy"
                if k == "off" then C.offNames[who] = GetTime() end   -- not counted as a Layer helper for an hour
                -- busy / off: not offered as a helper on that layer until their next report says they can (2026-11-21)
                local a = census[state.zone] and census[state.zone][who]
                if a and (k == "busy" or k == "off") then a.host = false end
                state.why = state.why or {}
                state.why[k] = (state.why[k] or 0) + 1
                -- moved off that layer: what they told us before is stale, so they stop being offered
                local c = census[state.zone] and census[state.zone][who]
                if k == "layer" and c and c.pair == state.pair then census[state.zone][who] = nil; changed() end
                nextHost()
            end
        elseif tag == "GQ" or tag == "GL" or tag == "RJ" or tag == "RA" then
            if onGroupMsg then onGroupMsg(tag, msg, who) end
        end
    end

    ------------------------------------------------------------------
    -- "Hop there?" for a rare on another layer of your zone; a line in chat for one on yours
    -- (only when VoidLayer itself runs the core: VoidSweep shows its own rare alerts).
    ------------------------------------------------------------------
    -- section 7: a Group Finder guest still in your group; removing needs your click (UninviteUnit is restricted)
    StaticPopupDialogs.VOIDLAYER_REMOVE = {
        text = "VoidLayer: %s is still in your group (on your layer by now). Remove them? Your Group Finder listing stays.",
        button1 = "Remove", button2 = "Not now",
        OnAccept = function(_, name)
            -- still this hosting session and still in our group, or a stale prompt could remove them later (Sol review)
            if type(name) ~= "string" or not (hosting and hosting.finder and hosting.guest == name and inGroupWith(name)) then return end
            if C_PartyInfo and C_PartyInfo.UninviteUnit then pcall(C_PartyInfo.UninviteUnit, name)
            elseif UninviteUnit then pcall(UninviteUnit, name) end
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
    StaticPopupDialogs.VOIDLAYER_HOP = {
        text = "%s",
        button1 = "Hop there", button2 = CANCEL,
        OnAccept = function(_, d) if d then C:Start(d.pair, d.zone, d.prefer) end end,
        timeout = 60, whileDead = false, hideOnEscape = true, preferredIndex = 3,
    }
    local function canOffer()
        return C:PopupsOn() and not C:Blocked()
    end
    local lastPopup
    offerRare = function(name, zone, pair, origin, x, y, npc)
        local cur, here = Layer:Here()
        if not cur then return end
        -- once per rare (by NPC id when known: a name is whatever the message says, Sol review)
        local okey = tostring(npc or name) .. "@" .. zone
        if offered[okey] and now() - offered[okey] < OFFER_GAP then return end
        if here ~= zone then
            -- another zone, but YOUR layer there (section 4's links): walk over, no hop
            if owner.addon == "VoidLayer" and C:PopupsOn() and C.OnMyLayer and C:OnMyLayer(zone, pair) == true then
                offered[okey] = now()
                local info = C_Map.GetMapInfo(zone)
                local at = (x > 0 or y > 0) and (" near %.0f, %.0f"):format(x / 10, y / 10) or ""
                say(("|cffffd200%s|r is up in %s%s, on your layer: walk over, no hop needed."):format(name, info and info.name or "the next zone", at))
            end
            return
        end
        if cur == pair then
            if owner.addon == "VoidLayer" and C:PopupsOn() then
                offered[okey] = now()
                local at = (x > 0 or y > 0) and (" near %.0f, %.0f"):format(x / 10, y / 10) or ""
                say(("|cffffd200%s|r is up on your layer%s."):format(name, at))
            end
            return
        end
        -- only when someone there can bring you over right now: the popup says so (2026-11-21: Hops to rare layers
        -- failed with the one Void player there busy)
        if #C:Hosts(zone, pair) == 0 then return end
        if not canOffer() then return end
        if lastPopup and now() - lastPopup < POPUP_GAP then return end
        lastPopup = now()
        offered[okey] = now()
        StaticPopup_Show("VOIDLAYER_HOP",
            ("%s: |cffffd200%s|r is up on %s.\nA Void player there can bring you over. Hop there?"):format(LABEL, name, C:Label(zone, pair)),
            nil, { pair = pair, zone = zone, prefer = origin })
    end
    -- Other addons (VoidSweep sightings): offer the hop if anyone there can host.
    function C:Offer(name, zone, pair)
        if not (name and zone and validPair(pair)) then return end
        if #self:Hosts(zone, pair) == 0 then
            local found
            for _, r in pairs(rares) do if r.zone == zone and r.pair == pair and r.hp > 0 then found = true break end end
            if not found then return end
        end
        offerRare(name, zone, pair, nil, 0, 0)
    end

    ------------------------------------------------------------------
    -- 4. Your layer, zone to zone (2026-11-14). Each zone gives you its own id: five solo crossings
    -- Barrens <-> Ashenvale were ALWAYS Barrens 6831-88 / Ashenvale 6829-98 (VoidDev's log), and
    -- a world refresh changes only the zone you're in (Ashenvale 98 -> 100, the Barrens stayed 88).
    -- So the game keeps YOUR id per zone: a SOLO crossing with no refresh, no loading screen and no
    -- hop links your two ids:
    --   L:1:0:zoneA:pairA:zoneB:pairB:age    age = seconds since the crossing that showed it
    -- Sent to a few Void players, never relayed. Every message is hostile (Sol review, 11-14), so:
    --   * only your own crossings are sure ("your layer, walk over"); another player's link is true
    --     for THEM, so it's a hint, however many send it; only your own links are passed on (to a
    --     census asker, with their age)
    --   * a link keeps the time it was SEEN, not received, so passing it around doesn't renew it;
    --     it ages out after LINK_LIVE (ids get reused)
    --   * a layer has one id per zone: your own crossing replaces a different id in that zone, and
    --     a zone the links give two ids for is left out (contradiction = say nothing)
    -- What you get: your layer's ids in other zones, a rare next door on YOUR layer ("walk over"),
    -- and the layers Void players have seen in a zone lately (readings, answers, rares, links).
    ------------------------------------------------------------------
    local LINK_LIVE    = 3 * 3600   -- a link counts this long after the crossing that showed it
    local LINK_FANOUT  = 6
    local LINK_SHARE   = 4          -- links handed to an asker
    local LINK_MAX     = 400        -- ids kept
    local BY_MAX       = 8          -- reporters kept per link
    local CROSS_GAP    = 90         -- the old zone's layer was read at most this long before the new one
    local LINK_CONFIRM = 10         -- the new zone's id has to hold this long (a border NPC can be read first)
    local SEEN_WINDOW  = 1800       -- "layers seen in this zone": the last 30 minutes

    -- [node][node] = { own = t, by = { [player] = t } }, both ways; node = "zone:pair"; t = when seen
    local links = {}
    local seenIds = {}   -- [zone][pair] = t
    local function node(zone, pair) return zone .. ":" .. pair end
    local function unnode(k) local z, p = k:match("^(%d+):(%d+%-%d+)$"); return tonumber(z), p end
    -- a merge renames a layer (Layer.lua v2): its links move to the new name, both directions (Sol review)
    if Layer.OnMerge then
        Layer:OnMerge(function(zone, old, new)
            local ok, nk = node(zone, old), node(zone, new)
            local from = links[ok]
            if not from then return end
            -- one edge from two: the newest own crossing and the newest word of each sender (Sol review 3)
            local function join(dst, src)
                if not dst then return src end
                if src.own and (not dst.own or src.own > dst.own) then dst.own = src.own end
                dst.by = dst.by or {}
                for name, t in pairs(src.by or {}) do if not dst.by[name] or t > dst.by[name] then dst.by[name] = t end end
                return dst
            end
            links[nk] = links[nk] or {}
            for o, e in pairs(from) do
                if o ~= nk then
                    links[nk][o] = join(links[nk][o], e)
                    local back = links[o]
                    if back then
                        if back[ok] then back[nk] = join(back[nk], back[ok]) end
                        back[ok] = nil
                    end
                end
            end
            links[ok] = nil
        end)
    end

    local function edgeTime(e)
        -- not 0: GetTime() is seconds since the game started, so a link seen before that is negative
        local t = e.own or -math.huge
        for _, bt in pairs(e.by) do if bt > t then t = bt end end
        return t
    end
    local function alive(e) return now() - edgeTime(e) <= LINK_LIVE end
    -- the time of your own crossing: what gets passed on (only your own links are), so passing a
    -- link around never renews it (Sol review)
    local function sureTime(e) return e.own or -math.huge end
    -- Sure = YOUR OWN crossing only (live 11-14: a refresh moved Ashenvale 98 -> 100 while the
    -- Barrens stayed 88, so the game keeps each player's id per zone; another player's crossing is
    -- true for them, not necessarily for you, however many agree). Others' links are hints.
    local function sure(e)
        return e.own ~= nil and now() - e.own <= LINK_LIVE
    end

    -- t = when it was seen (a link's crossing time, not when the message came; Sol review)
    noteSeen = function(zone, pair, t)
        if not (zone and validPair(pair)) then return end
        t = math.min(t or now(), now())
        if now() - t > SEEN_WINDOW then return end
        local z = seenIds[zone]
        if not z then z = {}; seenIds[zone] = z end
        z[pair] = math.max(z[pair] or -math.huge, t)
    end

    local function dropNode(k)
        for b in pairs(links[k] or {}) do if links[b] then links[b][k] = nil end end
        links[k] = nil
    end
    local function pruneLinks()
        local n = 0
        for a, t in pairs(links) do
            for b, e in pairs(t) do
                for who, bt in pairs(e.by) do if now() - bt > LINK_LIVE then e.by[who] = nil end end
                if e.own and now() - e.own > LINK_LIVE then e.own = nil end
                if not e.own and not next(e.by) then t[b] = nil end
            end
            if next(t) then n = n + 1 else links[a] = nil end
        end
        -- too many ids (a flood): drop the stalest
        while n > LINK_MAX do
            local oldK, oldT
            for a, t in pairs(links) do
                for _, e in pairs(t) do local et = edgeTime(e); if not oldT or et < oldT then oldK, oldT = a, et end end
            end
            if not oldK then break end
            dropNode(oldK)
            n = n - 1
        end
        for zone, z in pairs(seenIds) do
            for p, t in pairs(z) do if now() - t > SEEN_WINDOW then z[p] = nil end end
            if not next(z) then seenIds[zone] = nil end
        end
    end

    -- A link between a's id in its zone and b's. who = nil: your own crossing (sure, and it replaces
    -- any other id for that zone); else the player who sent it, seen at time t. True when it's new.
    local function addLink(za, pa, zb, pb, who, t)
        if za == zb or not (validPair(pa) and validPair(pb)) then return false end
        t = math.min(t or now(), now())
        local a, b = node(za, pa), node(zb, pb)
        local function put(x, y, zy)
            local tx = links[x]
            if not tx then tx = {}; links[x] = tx end
            if not who then
                -- what you saw yourself wins: another id for that zone is stale or wrong
                for k in pairs(tx) do
                    if k ~= y and unnode(k) == zy then
                        tx[k] = nil
                        if links[k] then links[k][x] = nil end
                    end
                end
            end
            local e = tx[y]
            local was = e ~= nil
            if not e then e = { by = {} }; tx[y] = e end
            if who then
                e.by[who] = math.max(e.by[who] or -math.huge, t)   -- not 0: times can be negative (edgeTime)
                local n, oldW, oldT = 0, nil, nil
                for w, bt in pairs(e.by) do n = n + 1; if not oldT or bt < oldT then oldW, oldT = w, bt end end
                if n > BY_MAX and oldW then e.by[oldW] = nil end
            else
                e.own = t
            end
            return not was
        end
        local fresh = put(a, b, zb)
        put(b, a, za)
        noteSeen(za, pa, t); noteSeen(zb, pb, t)
        if fresh then changed() end
        return fresh
    end
    onLink = function(za, pa, zb, pb, who, t) return addLink(za, pa, zb, pb, who, t) end

    -- ids reachable from start over live links (sure ones only, or all), never through a bad id
    -- (the whole store fits: LINK_MAX ids; cut short = second return true, then nothing is sure)
    local function reach(start, sureOnly, bad)
        local seen, queue, n = { [start] = true }, { start }, 0
        while #queue > 0 and n < LINK_MAX * 2 do
            local k = table.remove(queue, 1)
            for o, e in pairs(links[k] or {}) do
                if not seen[o] and not (bad and bad[o]) and alive(e) and (not sureOnly or sure(e)) then
                    seen[o] = true
                    queue[#queue + 1] = o
                    n = n + 1
                end
            end
        end
        return seen, #queue > 0
    end

    -- This layer's ids in other zones: { { zone, pair, sure }, ... }. sure = every link on the way
    -- is your own crossing (others' links: hints); a zone with two ids is left out.
    function C:SameLayer(zone, pair)
        local out = {}
        if not (zone and validPair(pair)) then return out end
        local start = node(zone, pair)
        -- a zone the links give two ids for (one of them may be your own zone) is a contradiction:
        -- those ids are bad, and nothing is followed THROUGH them either (Sol review: a stale branch
        -- could still certify a zone further on). Repeat until no new contradiction shows up.
        -- One SURE id against unsure ones: the unsure ones go (one griefer can't silence a zone).
        local bad, cut, settled = {}, false, false
        for _ = 1, 5 do
            local allSet, c1 = reach(start, false, bad)
            local sureSet, c2 = reach(start, true, bad)
            cut = cut or c1 or c2
            local perZone, grew = {}, false
            for k in pairs(allSet) do
                local z = unnode(k)
                if z then perZone[z] = perZone[z] or {}; perZone[z][#perZone[z] + 1] = k end
            end
            for z, ks in pairs(perZone) do
                if #ks > 1 or (z == zone and ks[1] ~= start) then
                    local sures = {}
                    for _, k in ipairs(ks) do if sureSet[k] and k ~= start then sures[#sures + 1] = k end end
                    local keep = (z ~= zone and #sures == 1) and sures[1] or nil
                    for _, k in ipairs(ks) do
                        if k ~= start and k ~= keep and not bad[k] then bad[k] = true; grew = true end
                    end
                end
            end
            if not grew then settled = true break end
        end
        local sureSet, c1 = reach(start, true, bad)
        local allSet, c2 = reach(start, false, bad)
        -- cut short (a flood) or still contradicting after 5 rounds: show what's there, none of it sure
        local trust = settled and not (cut or c1 or c2)
        for k in pairs(allSet) do
            local z, p = unnode(k)
            if z and z ~= zone then out[#out + 1] = { zone = z, pair = p, sure = trust and sureSet[k] and true or false } end
        end
        return out
    end

    -- Is that zone's id your layer? true (your own crossing), "maybe" (another player's link), or false
    function C:OnMyLayer(zone, pair)
        local cur, here = Layer:Here()
        if not (cur and here) then return false end
        if here == zone then return cur == pair end
        for _, x in ipairs(self:SameLayer(here, cur)) do
            if x.zone == zone and x.pair == pair then return x.sure and true or "maybe" end
        end
        return false
    end

    -- Rares up in OTHER zones on your layer (your own crossings only), newest first (C:Rares fields + nextDoor)
    function C:RaresNextDoor()
        local cur, here = Layer:Here()
        if not (cur and here) then return {} end
        local mine = {}
        for _, x in ipairs(self:SameLayer(here, cur)) do mine[node(x.zone, x.pair)] = x.sure end
        local out = {}
        if not next(mine) then return out end
        for _, r in ipairs(self:Rares()) do
            local s = mine[node(r.zone, r.pair)]
            if r.zone ~= here and r.hp > 0 and s == true then
                r.nextDoor, r.sure = true, s
                out[#out + 1] = r
            end
        end
        return out
    end

    -- Layers Void players have seen in a zone in the last 30 minutes: count, { pair = t }
    function C:LayersSeen(zone)
        local list, n = {}, 0
        for p, t in pairs(seenIds[zone] or {}) do
            if now() - t <= SEEN_WINDOW then list[p] = t; n = n + 1 end
        end
        return n, list
    end

    -- links to hand an asker in a zone: the freshest SURE ones with an end there, with their age
    shareLinks = function(asker, zone)
        local picks = {}
        for a, t in pairs(links) do
            local za, pa = unnode(a)
            if za == zone then
                for b, e in pairs(t) do
                    local zb, pb = unnode(b)
                    if zb and alive(e) and sure(e) then picks[#picks + 1] = { za, pa, zb, pb, sureTime(e) } end
                end
            end
        end
        table.sort(picks, function(x, y) return x[5] > y[5] end)
        for i = 1, math.min(LINK_SHARE, #picks) do
            local p = picks[i]
            send(("L:1:0:%d:%s:%d:%s:%d"):format(p[1], p[2], p[3], p[4], math.floor(now() - p[5])), asker, false)
        end
    end

    -- Your own crossings. trail = where your layer was last confirmed (every 5 s, solo only); a new
    -- zone's first id within CROSS_GAP of it, with nothing in between that moves you, is the same layer.
    local trail
    local lastGroupT, lastTaintT, lastZoneT, cancelT = 0, 0, 0, 0
    -- A world refresh may move you until refreshUntil (its countdown + a minute): no links before then.
    -- Set from the game's own countdown, so a /reload or a zone change during it keeps it (Sol review).
    local refreshUntil = 0
    -- only ever moves it later: no countdown (or none given) keeps what we had (Sol review);
    -- a cancel ends it, and an expired one simply passes
    local function readCountdown()
        local left = GetEvictionTimeRemaining and GetEvictionTimeRemaining()
        if type(left) == "number" and left > 0 then refreshUntil = math.max(refreshUntil, now() + left + 60) end
    end
    readCountdown()
    C_Timer.NewTicker(5, function()
        pruneLinks()
        if IsInInstance() or IsInGroup() then trail = nil return end
        local cur, zone = Layer:Here()
        if cur and zone then
            trail = { zone = zone, pair = cur, t = now() }
            noteSeen(zone, cur)
        end
    end)
    -- solo only: in a group, a leader change can move you without the group's size changing (Sol review)
    local function clean(since)
        return lastGroupT < since and lastTaintT < since and not state and now() >= refreshUntil and not IsInGroup()
    end
    -- Your id in a zone is `pair` now: your own links to any OTHER id of that zone are stale (a refresh
    -- moved you there: Ashenvale 98 -> 100). They stop being sure; what others sent stays a hint (Sol review).
    local function forgetOwn(zone, pair)
        local keep = node(zone, pair)
        for k, t in pairs(links) do
            if k ~= keep and unnode(k) == zone then
                for o, e in pairs(t) do
                    if e.own then
                        e.own = nil
                        local back = links[o] and links[o][k]
                        if back then back.own = nil end
                        if not next(e.by) then
                            t[o] = nil
                            if links[o] then links[o][k] = nil end
                        end
                    end
                end
            end
        end
    end

    Layer:OnChange(function(pair, zone, how)
        -- a merge or a restore is a new NAME for the same layer (Layer.lua v2): no crossing, and own links
        -- stay (Sol review: forgetOwn dropped them on a rename)
        if how == "merged" or how == "kept" then
            if trail and trail.zone == zone then trail.pair = pair end
            return
        end
        noteSeen(zone, pair)
        if zone and validPair(pair) and not IsInInstance() then forgetOwn(zone, pair) end
        local tr = trail
        if not (tr and zone and validPair(pair)) or zone == tr.zone or IsInInstance() then return end
        trail = { zone = zone, pair = pair, t = now() }
        local since = tr.t - 1
        if now() - tr.t > CROSS_GAP or not clean(since) then return end
        C_Timer.After(LINK_CONFIRM, function()
            if Layer:Current(zone) ~= pair or not clean(since) then return end
            if addLink(tr.zone, tr.pair, zone, pair) then
                sendAll(("L:1:0:%d:%s:%d:%s:0"):format(tr.zone, tr.pair, zone, pair), targets(LINK_FANOUT, zone), false)
            end
        end)
    end)
    local lf = CreateFrame("Frame")
    for _, ev in ipairs({ "SHARD_TRANSFER_IMMINENT", "SHARD_TRANSFER_CANCELLED", "SHARD_TRANSFER",
                          "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED", "PLAYER_ENTERING_WORLD",
                          "PLAYER_LOGOUT" }) do
        pcall(lf.RegisterEvent, lf, ev)
    end
    if Layer.Restore then pcall(Layer.Restore, Layer, S().layerNames) end
    lf:SetScript("OnEvent", function(_, ev)
        if ev == "SHARD_TRANSFER_IMMINENT" then
            readCountdown()
            if refreshUntil < now() then refreshUntil = now() + 660 end   -- no countdown given: the usual 10 min
        elseif ev == "SHARD_TRANSFER_CANCELLED" then
            refreshUntil, cancelT = 0, now()   -- "Refresh Now" cancels the countdown, then moves you
        elseif ev == "SHARD_TRANSFER" then
            -- every zone change fires it too and keeps your layer (live 11-14); a world refresh moves
            -- you: one announced, one just cancelled by Refresh Now, or one far from a zone change
            if now() < refreshUntil or now() - cancelT < 5 or now() - lastZoneT > 15 then lastTaintT = now() end
            if now() - lastZoneT > 15 then
                refreshUntil = 0   -- not a zone change: that WAS the refresh (the move itself is tainted above)
            else
                readCountdown()    -- a zone change during the countdown leaves it running
            end
        elseif ev == "ZONE_CHANGED_NEW_AREA" then
            lastZoneT = now()
        elseif ev == "PLAYER_LOGOUT" then
            if Layer.Snapshot then S().layerNames = Layer:Snapshot() end
        elseif ev == "PLAYER_ENTERING_WORLD" then
            lastTaintT = now()   -- a login, /reload or loading screen (boat, zeppelin, portal)
        else
            lastGroupT = now()   -- any roster or leader change
        end
    end)

    ------------------------------------------------------------------
    -- 5. Fresh camp (2026-11-14). A hop doesn't move you: the world around you swaps to the target
    -- layer's copy. So after you clear a pack, the same spot on another layer can still be full (the
    -- race to 60 in WoW Forever farmed that way, helpers holding spots on other layers). When
    -- CAMP_KILLS mobs die close together around you (any killer: nameplates and your target), the
    -- spot counts as cleared on your layer, on a coarse grid, and the Void players in the zone hear:
    --   C:1:zone:pair:cx:cy:age     never relayed; when, never anyone's position
    -- "Fresh layer here" hops you to a layer with a Void helper where nobody reported clearing your
    -- spot (or a cell next to it) in the last CAMP_FRESH seconds; never-reported layers first.
    ------------------------------------------------------------------
    local CELLS       = 25     -- grid per zone side (one cell ~100-200 yards, zones differ)
    local CAMP_KILLS  = 5      -- deaths in one cell within CAMP_WINDOW = the camp is cleared
    local CAMP_WINDOW = 600
    local CAMP_FRESH  = 600    -- a clear this recent counts against a layer (respawn times not measured yet)
    local CAMP_LIVE   = 1800   -- clears kept this long
    local CAMP_GAP    = 120    -- one message per cleared cell per this
    local CAMP_MAX    = 600    -- clears kept (all zones)
    local OFFER_FRESH = 300    -- "hop to a fresh layer?" at most this often

    local deaths = {}      -- [guid] = { t, zone, pair, cx, cy }: deaths around you, CAMP_WINDOW
    local alive = {}       -- [guid] = t: seen alive (a corpse never seen alive isn't a new death; Sol review)
    local camps = {}       -- [zone][pair][cell] = { t = cleared, own = true when YOU saw it }
    if Layer.OnMerge then
        Layer:OnMerge(function(zone, old, new)
            -- deaths still counting toward a clear stay on the layer's new name (Sol review)
            for _, d in pairs(deaths) do if d.zone == zone and d.pair == old then d.pair = new end end
            local z = camps[zone]
            if not (z and z[old]) then return end
            z[new] = z[new] or {}
            for cell, c in pairs(z[old]) do
                local n = z[new][cell]
                if not n then z[new][cell] = c
                else
                    -- the newest clear, and YOUR newest clear, each kept on its own (Sol review: ownT was lost)
                    local ownT = math.max(n.ownT or -math.huge, c.ownT or -math.huge)
                    if c.t > n.t then z[new][cell] = c; n = c end
                    if ownT > -math.huge then n.ownT = ownT end
                end
            end
            z[old] = nil
        end)
    end
    local campSent = {}    -- [zone:pair:cell] = t
    local lastFreshOffer, pendingOffer
    local function cellKey(cx, cy) return cx .. ":" .. cy end

    local function myCell(zone)
        local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(zone, "player")
        if not pos then return nil end
        local x, y = pos:GetXY()
        if not x or secret(x) or secret(y) or x <= 0 or y <= 0 or x >= 1 or y >= 1 then return nil end
        return math.floor(x * CELLS), math.floor(y * CELLS)
    end

    local function pruneCamps()
        local n = 0
        for zone, zt in pairs(camps) do
            for p, pt in pairs(zt) do
                for k, c in pairs(pt) do if now() - c.t > CAMP_LIVE then pt[k] = nil else n = n + 1 end end
                if not next(pt) then zt[p] = nil end
            end
            if not next(zt) then camps[zone] = nil end
        end
        while n > CAMP_MAX do   -- a flood: drop the oldest
            local oz, op, ok, ot
            for zone, zt in pairs(camps) do
                for p, pt in pairs(zt) do
                    for k, c in pairs(pt) do if not ot or c.t < ot then oz, op, ok, ot = zone, p, k, c.t end end
                end
            end
            if not oz then break end
            camps[oz][op][ok] = nil
            n = n - 1
        end
        for g, d in pairs(deaths) do if now() - d.t > CAMP_WINDOW then deaths[g] = nil end end
        local na = 0
        for g, t in pairs(alive) do if now() - t > CAMP_WINDOW then alive[g] = nil else na = na + 1 end end
        if na > 2000 then wipe(alive) end   -- a city full of plates for an hour: start over
        for k, t in pairs(campSent) do if now() - t > CAMP_GAP then campSent[k] = nil end end
    end

    local function noteCamp(zone, pair, cx, cy, t, own)
        if not (zone and validPair(pair) and cx and cy) or cx < 0 or cy < 0 or cx >= CELLS or cy >= CELLS then return end
        t = math.min(t or now(), now())
        if now() - t > CAMP_LIVE then return end
        camps[zone] = camps[zone] or {}
        camps[zone][pair] = camps[zone][pair] or {}
        local k = cellKey(cx, cy)
        local c = camps[zone][pair][k]
        if not c then c = { t = t }; camps[zone][pair][k] = c end
        if t > c.t then c.t = t end
        if own then c.ownT = math.max(c.ownT or -math.huge, t) end
        noteSeen(zone, pair, t)
        changed()
    end
    onCamp = function(zone, pair, cx, cy, age)
        if not (cx and cy and age) or age > CAMP_LIVE then return end
        noteCamp(zone, pair, cx, cy, now() - age, false)
    end

    -- Seconds since your spot (your cell or one next to it) was reported cleared on that layer, or
    -- nil; second return: seconds since YOU saw it cleared there, or nil
    function C:SpotCleared(zone, pair)
        local cx, cy = myCell(zone)
        local pt = cx and camps[zone] and camps[zone][pair]
        if not pt then return nil end
        local best, bestOwn
        for dx = -1, 1 do
            for dy = -1, 1 do
                local c = pt[cellKey(cx + dx, cy + dy)]
                if c and now() - c.t <= CAMP_LIVE then
                    if not best or c.t > best then best = c.t end
                    if c.ownT and now() - c.ownT <= CAMP_LIVE and (not bestOwn or c.ownT > bestOwn) then bestOwn = c.ownT end
                end
            end
        end
        return best and (now() - best) or nil, bestOwn and (now() - bestOwn) or nil
    end

    -- Fresh camp's ranking for C:Start: never reported first, then reported long ago, then reported
    -- lately by others (advisory: a forged report can't veto a layer; Sol review). Only a clear YOU
    -- saw on that layer within CAMP_FRESH skips it.
    local function freshRank(zone)
        return function(p)
            local age, ownAge = C:SpotCleared(zone, p)
            if ownAge and ownAge < CAMP_FRESH then return nil end
            if not age then return 0 end
            if age >= CAMP_FRESH then return 1 + (CAMP_LIVE - age) / CAMP_LIVE end
            return 3 + (CAMP_FRESH - age) / CAMP_FRESH
        end
    end

    -- Hop to a layer where your spot is fresh (solo, like any hop)
    function C:StartFresh()
        local _, zone = Layer:Here()
        if not zone then say("no zone here.") return end
        self:Start(nil, zone, nil, false, freshRank(zone))
    end

    -- Is there a layer with a helper where no clear of your spot was reported lately? (for the offer)
    local function freshLayerKnown(zone, cur)
        local rank = freshRank(zone)
        for p in pairs(C:Counts(zone)) do
            local r = p ~= cur and #C:Hosts(zone, p) > 0 and rank(p)
            if r and r < 3 then return true end
        end
        return false
    end

    -- "Hop there?" once a camp is cleared; mostly the last mob dies in combat, so then it waits for
    -- combat to end (Sol review) and checks again: same zone and layer, can hop, a layer to go to
    -- still at the cleared camp? same zone and layer, your cell within one of it (Sol review)
    local function atCamp(o)
        local cur, zone = Layer:Here()
        if not (o and zone == o.zone and cur == o.pair) then return false end
        local cx, cy = myCell(zone)
        return cx ~= nil and math.abs(cx - o.cx) <= 1 and math.abs(cy - o.cy) <= 1
    end
    local function offerFresh(zone, cur, cx, cy)
        if owner.addon ~= "VoidLayer" or not C:PopupsOn() then return end
        if lastFreshOffer and now() - lastFreshOffer < OFFER_FRESH then return end
        local o = { zone = zone, pair = cur, cx = cx, cy = cy, t = now() }
        if InCombatLockdown() then pendingOffer = o return end
        if C:Blocked() or not freshLayerKnown(zone, cur) then return end
        lastFreshOffer = now()
        StaticPopup_Show("VOIDLAYER_FRESH",
            ("%s: you cleared this spot on %s.\nA Void player on a layer where nobody reported clearing it lately can bring you over (its mobs may be up). Hop there?"):format(LABEL, C:Label(zone, cur)),
            nil, o)
    end

    StaticPopupDialogs.VOIDLAYER_FRESH = {
        text = "%s",
        button1 = "Hop there", button2 = CANCEL,
        OnAccept = function(_, o)
            if atCamp(o) then C:StartFresh() else say("you've moved on from that camp, so that hop no longer applies.") end
        end,
        timeout = 60, whileDead = false, hideOnEscape = true, preferredIndex = 3,
    }

    -- a mob died near you (nameplate or target): count it toward clearing this spot. Only a mob seen
    -- alive first: targeting old corpses isn't a clear happening now (Sol review)
    local function seeDeath(unit)
        if not UnitExists(unit) or UnitPlayerControlled(unit) or IsInInstance() then return end
        local g = UnitGUID(unit)
        if not g or secret(g) or deaths[g] then return end
        local dead = UnitIsDead(unit)
        if secret(dead) then return end
        if not dead then alive[g] = now() return end
        if not alive[g] then return end
        alive[g] = nil
        local kind = strsplit("-", g)
        if kind ~= "Creature" then return end
        local friend = UnitIsFriend("player", unit)
        if secret(friend) or friend then return end
        local ctype = UnitCreatureType(unit)
        if secret(ctype) or ctype == "Critter" then return end
        local cls = UnitClassification(unit)
        if not secret(cls) and cls == "minus" then return end
        local cur, zone = Layer:Here()
        if not (cur and zone) then return end
        local cx, cy = myCell(zone)
        if not cx then return end
        deaths[g] = { t = now(), zone = zone, pair = cur, cx = cx, cy = cy }
        -- deaths around this cell (it and the 8 next to it: a pack on a cell border) on this layer lately
        local n = 0
        for _, d in pairs(deaths) do
            if d.zone == zone and d.pair == cur and math.abs(d.cx - cx) <= 1 and math.abs(d.cy - cy) <= 1
                    and now() - d.t <= CAMP_WINDOW then n = n + 1 end
        end
        if n < CAMP_KILLS then return end
        noteCamp(zone, cur, cx, cy, now(), true)
        local key = zone .. ":" .. cur .. ":" .. cellKey(cx, cy)
        if not (campSent[key] and now() - campSent[key] < CAMP_GAP) then
            campSent[key] = now()
            sendAll(("C:1:%d:%s:%d:%d:0"):format(zone, cur, cx, cy), targets(LINK_FANOUT, zone), false)
        end
        offerFresh(zone, cur, cx, cy)   -- VoidLayer only, like the rare pop-up
    end

    C_Timer.NewTicker(30, pruneCamps)
    local cf = CreateFrame("Frame")
    for _, ev in ipairs({ "UNIT_HEALTH", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED",
                          "PLAYER_REGEN_ENABLED" }) do pcall(cf.RegisterEvent, cf, ev) end
    cf:SetScript("OnEvent", function(_, ev, unit)
        if ev == "PLAYER_REGEN_ENABLED" then
            -- the camp was cleared in combat: offer now, if you're still at it (within 2 min)
            local p = pendingOffer
            pendingOffer = nil
            if p and now() - p.t < 120 and atCamp(p) then pcall(offerFresh, p.zone, p.pair, p.cx, p.cy) end
            return
        end
        if ev == "PLAYER_TARGET_CHANGED" then unit = "target" end
        if type(unit) == "string" and (unit == "target" or unit:find("^nameplate")) then pcall(seeDeath, unit) end
    end)

    ------------------------------------------------------------------
    -- Tests (/vl test ...): each half of a hop with a player who doesn't run VoidLayer and
    -- sends or accepts the invite by hand (the user, 11-09: "no one will install a zip").
    ------------------------------------------------------------------
    -- You: wait for that player's invite, accept only it, see whether your layer changed, leave.
    function C:TestJoin(name)
        if not validName(name) then say("test join: whose invite? /vl test join First Surname (or target them).") return end
        local why = self:Blocked()
        if why then say(why) return end
        local cur, zone = Layer:Here()
        if not (zone and cur) then say("your layer isn't known yet: point at or target any NPC, then try again.") return end
        state = { zone = zone, from = cur, hosts = {}, idx = 0, host = name, phase = "asking", nonce = "0",
                  anyPair = true, test = true }
        setTimer(120, function()
            if state and state.test and state.phase == "asking" then stop(("test: no invite from %s within 2 minutes."):format(name)) end
        end)
        say(("test: you're on %s. Ask %s to invite you now (within 2 minutes): VoidLayer accepts only that invite, checks your layer and leaves the group."):format(self:Label(zone, cur), name))
        changed()
    end

    -- Host: invite that player as a hop host would; leave the group 60 s after they join.
    function C:TestHost(name)
        if not validName(name) then say("test host: invite whom? /vl test host First Surname (or target them).") return end
        if hosting or state or IsInGroup() or InCombatLockdown() or IsInInstance() then
            say("test host: be solo, out of combat and outside instances, with no hop under way.") return
        end
        lastHosted = now()
        hostedTimes[#hostedTimes + 1] = lastHosted
        hosting = { guest = name, nonce = "0", invited = now(), deadline = now() + JOIN_WAIT + 60, testStay = 60 }
        C_PartyInfo.InviteUnit(name)
        say(("test: invited %s the way a hop host does. Once they accept, you leave the group by yourself within about a minute."):format(name))
    end

    -- A made-up rare on a made-up layer of your zone: the pop-up and the window's rare list.
    function C:TestRare()
        local cur, zone = Layer:Here()
        if not (zone and cur) then say("your layer isn't known yet: point at or target any NPC, then try again.") return end
        local fake = "9999-" .. math.random(10, 99)
        storeRare(zone, fake, 999999, 80, 500, 500, "VoidLayerTest", "Test Rare", true)
        offered["999999@" .. zone], lastPopup = nil, nil
        offerRare("Test Rare", zone, fake, nil, 500, 500, 999999)
        say(("test: a made-up \"Test Rare\" is up on %s. Its Hop finds nobody (that layer doesn't exist)."):format(self:Label(zone, fake)))
    end

    ------------------------------------------------------------------
    -- Chat / summary
    ------------------------------------------------------------------
    function C:Summary(zone)
        local cur = Layer:Current(zone)
        local counts = self:Counts(zone)
        local parts = {}
        if cur then
            local n = counts[cur] or 0
            parts[#parts + 1] = ("|cffffd200%s|r (you%s)"):format(self:Label(zone, cur), n > 0 and (" + " .. n .. " Void") or "")
        end
        for pair, n in pairs(counts) do
            if pair ~= cur then
                parts[#parts + 1] = ("%s: %d Void%s"):format(self:Label(zone, pair), n, #self:Hosts(zone, pair) > 0 and " |cff33ff33(hop)|r" or "")
            end
        end
        return #parts > 0 and table.concat(parts, " · ") or nil
    end

    function C:Report()
        local cur, zone = Layer:Here()
        if not zone then say("no zone here (instances have no layers to compare).") return end
        local info = C_Map.GetMapInfo(zone)
        local zname = info and info.name or "this zone"
        local sent = self:Ask(zone)
        local function show()
            local s = self:Summary(zone)
            say(s and ("layers in %s: %s"):format(zname, s) or ("no layers known in %s yet."):format(zname))
            if not cur then say("your own layer isn't known yet: point at or target any NPC.") end
        end
        if sent then say(("asking the Void players in %s..."):format(zname)); C_Timer.After(FIND_WAIT, show) else show() end
    end

    ------------------------------------------------------------------
    -- 6. In a group, on another layer than the leader (a player's idea, 2026-11-14: "when your in a
    -- group if someone in the group is on a different layer ... so they have to drop group to get a
    -- reinvite"). Joining a group moves you to its leader's layer (measured 11-08), so the fix is
    -- leave + re-invite; this makes it one click.
    --   GQ:1          a member asks the leader which layer it's on
    --   GL:1:zone:pair the leader's answer (to group members only)
    --   RJ:1:nonce    "re-invite me": the leader's core says RA:1:nonce:ok|no:why; on ok you leave and
    --                 its core invites you back once you're out (only someone who was in its group
    --                 and asked, within REJOIN_WAIT), and you accept only that invite from that leader
    -- Without VoidLayer on the leader: the leader is in your zone, close by, yet not visible = another
    -- layer (a guess); the button then whispers the leader in plain chat and leaves.
    ------------------------------------------------------------------
    local REJOIN_WAIT, ASK_EVERY, NEAR_YARDS = 20, 90, 60
    local leaderLayer          -- { name, zone, pair, t } from GL
    local lastGQ = 0
    local rejoin               -- { leader, nonce, phase = "asking" | "left", t }
    local reinvite = {}        -- leader side: [name] = { nonce, t, size (the group then) }

    -- a unit's "First Surname" (UnitName gives the two parts apart on Forever)
    local function fullName(unit)
        local n = GetUnitName and GetUnitName(unit, false)
        if type(n) ~= "string" or secret(n) or n == "" then
            local a, b = UnitName(unit)
            if type(a) ~= "string" or secret(a) then return nil end
            n = (type(b) == "string" and not secret(b) and b ~= "") and (a .. " " .. b) or a
        end
        return Net.Canon(n)
    end
    local function groupUnits()
        local out, raid = {}, IsInRaid()
        local n = GetNumGroupMembers() or 0
        for i = 1, raid and n or n - 1 do out[#out + 1] = (raid and "raid" or "party") .. i end
        return out
    end
    local function unitOf(name)
        for _, u in ipairs(groupUnits()) do if fullName(u) == name then return u end end
    end
    local function isLeader(u)   -- a secret answer counts as no (Sol review)
        local v = UnitIsGroupLeader(u)
        if secret(v) then return false end
        return v and true or false
    end
    local function leaderUnit()
        if not IsInGroup() then return nil end
        if isLeader("player") then return "player" end
        for _, u in ipairs(groupUnits()) do if isLeader(u) then return u end end
    end

    local function askLeader(force)
        local lu = leaderUnit()
        if not lu or lu == "player" or IsInInstance() then return end
        if not force and now() - lastGQ < ASK_EVERY then return end
        local name = fullName(lu)
        if not name then return end
        lastGQ = now()
        send("GQ:1:", name, true)   -- the trailing colon: onMessage only reads "TAG:1:..." (Sol release review)
    end

    -- you vs the leader: nil when it doesn't apply; else { leader, pair (theirs, nil = unknown),
    -- mine, differs, how = "exact" | "guess" }
    function C:GroupLayer()
        local lu = leaderUnit()
        if not lu or lu == "player" or IsInInstance() then return nil end
        local name = fullName(lu)
        local cur, zone = Layer:Here()
        local out = { leader = name, mine = cur }
        -- the game's own answer, when the leader is in your zone (2026-11-24): nil = same layer, Sharding = another
        if UnitPhaseReason and C_Map.GetBestMapForUnit(lu) == C_Map.GetBestMapForUnit("player") then
            local ok, r = pcall(UnitPhaseReason, lu)
            if ok and not secret(r) and (UnitIsConnected == nil or UnitIsConnected(lu)) then
                if r == nil then out.pair, out.how, out.differs = cur, "exact", false; return out end
                local sh = Enum and Enum.PhaseReason and Enum.PhaseReason.Sharding
                if type(sh) ~= "number" then sh = 1 end
                if r == sh then out.how, out.differs = "exact", true; return out end
            end
        end
        if leaderLayer and leaderLayer.name == name and now() - leaderLayer.t <= ASK_EVERY * 2 and leaderLayer.zone == zone and cur then
            out.pair, out.how = leaderLayer.pair, "exact"
            local cmp = Layer:Compare(leaderLayer.pair, zone)   -- names differ until proven (Layer.lua v2)
            if cmp == nil then return out end
            out.differs = cmp == "other"
            return out
        end
        -- no VoidLayer answer: in your zone and close by, yet the game says you can't see them
        local vis = UnitIsVisible(lu)
        if secret(vis) or vis then return out end
        local lm, mm = C_Map.GetBestMapForUnit(lu), C_Map.GetBestMapForUnit("player")
        if not (lm and mm and lm == mm) or secret(lm) then return out end
        local ly, lx = UnitPosition(lu)
        local my, mx = UnitPosition("player")
        if type(lx) ~= "number" or type(mx) ~= "number" or secret(lx) or secret(mx) then return out end
        local d = math.sqrt((lx - mx) ^ 2 + (ly - my) ^ 2)
        if d <= NEAR_YARDS then out.differs, out.how = true, "guess" end
        return out
    end

    -- right before leaving: still the same group with the same leader, no fight, no instance (a
    -- late answer or the 4 s timer must not leave a group you joined since; Sol review)
    local function okToLeave(r)
        if not (r and IsInGroup()) or InCombatLockdown() or IsInInstance() then return false end
        local lu = leaderUnit()
        return lu ~= nil and lu ~= "player" and fullName(lu) == r.leader
    end

    -- the Rejoin button: leave the group and get the leader's invite again (its layer comes with it)
    function C:Rejoin()
        local g = self:GroupLayer()
        if not (g and g.leader) then say("you're not in a group with someone else leading.") return false end
        if InCombatLockdown() then say("not in combat.") return false end
        if IsInInstance() then say("not inside a dungeon or raid: leaving would take you out.") return false end
        rejoin = { leader = g.leader, nonce = tostring(math.random(100000, 999999)), phase = "asking", t = now() }
        send(("RJ:1:%s"):format(rejoin.nonce), g.leader, true)
        say(("asking %s for a re-invite..."):format(g.leader))
        local r = rejoin
        C_Timer.After(4, function()
            if rejoin ~= r or r.phase ~= "asking" then return end
            if not okToLeave(r) then rejoin = nil; changed(); return end
            -- no VoidLayer on the leader: ask in plain words, then leave so they can invite you
            if SendChatMessage then pcall(SendChatMessage, "I'm on another layer than you: please re-invite me (VoidLayer).", "WHISPER", nil, r.leader) end
            r.phase, r.t = "left", now()
            if C_PartyInfo and C_PartyInfo.LeaveParty then C_PartyInfo.LeaveParty() end
            say(("%s doesn't run VoidLayer: whispered them to re-invite you, and left the group."):format(r.leader))
            changed()
        end)
        changed()
        return true
    end
    function C:Rejoining() return rejoin and now() - rejoin.t <= REJOIN_WAIT and rejoin or nil end


    onGroupMsg = function(tag, msg, who)
        if tag == "GQ" then
            -- only for our own group, only when we lead it
            if not (IsInGroup() and isLeader("player") and unitOf(who)) or IsInInstance() then return end
            local cur, zone = Layer:Here()
            if cur and zone then send(("GL:1:%d:%s"):format(zone, cur), who, true) end
        elseif tag == "GL" then
            local zoneS, pair = msg:match("^GL:1:(%d+):(%d+%-%d+)$")
            local zone = validZone(zoneS)
            pair = canon(pair)
            local lu = leaderUnit()
            if not (zone and validPair(pair) and lu and lu ~= "player" and fullName(lu) == who) then return end
            leaderLayer = { name = who, zone = zone, pair = pair, t = now() }
            changed()
        elseif tag == "RJ" then
            local nonce = msg:match("^RJ:1:(%d+)$")
            if not nonce then return end
            local function reply(txt) send(("RA:1:%s:%s"):format(nonce, txt), who, true) end
            if not (IsInGroup() and isLeader("player")) then reply("no:notleader") return end
            if not unitOf(who) then reply("no:notmember") return end
            if IsInInstance() then reply("no:instance") return end
            reinvite[who] = { nonce = nonce, t = now(), size = GetNumGroupMembers() or 0 }
            reply("ok")
        elseif tag == "RA" then
            local nonce, answer = msg:match("^RA:1:(%d+):(.+)$")
            if not (rejoin and rejoin.phase == "asking" and who == rejoin.leader and nonce == rejoin.nonce) then return end
            if answer ~= "ok" then
                rejoin = nil
                say(("%s can't re-invite you right now (%s)."):format(who, answer:gsub("^no:", "")))
                changed()
                return
            end
            if not okToLeave(rejoin) then rejoin = nil; changed(); return end
            rejoin.phase, rejoin.t = "left", now()
            if C_PartyInfo and C_PartyInfo.LeaveParty then C_PartyInfo.LeaveParty() end
            say(("leaving the group: %s re-invites you, and you land on their layer."):format(who))
            changed()
        end
    end

    -- leader side: a member who asked has left: invite them back (once)
    local function reinviteGone()
        -- only for the group we lead (or the two-person one that ended when they left); a request
        -- must not outlive our lead and pull a former member into some other group (Sol review)
        if IsInGroup() and not isLeader("player") then wipe(reinvite) return end
        for name, r in pairs(reinvite) do
            if now() - r.t > REJOIN_WAIT then reinvite[name] = nil
            -- out of our group: still leading it, or solo because it was just the two of us (Sol review)
            elseif not unitOf(name) and (IsInGroup() or r.size == 2) and C_PartyInfo and C_PartyInfo.InviteUnit then
                reinvite[name] = nil
                C_PartyInfo.InviteUnit(name)
                say(("re-inviting %s (onto your layer)."):format(name))
            end
        end
    end
    -- a member we kick didn't "leave to rejoin": drop their request, or a kick could be undone by
    -- asking for a re-invite first (Sol release review). The game's Remove from Group goes through these.
    local function kicked(target)
        if type(target) ~= "string" or secret(target) then return end
        local name = Net.Canon(target)
        if name and reinvite[name] then reinvite[name] = nil return end
        name = UnitExists and UnitExists(target) and fullName(target)
        if name then reinvite[name] = nil end
    end
    if hooksecurefunc then
        if C_PartyInfo and C_PartyInfo.UninviteUnit then hooksecurefunc(C_PartyInfo, "UninviteUnit", kicked) end
        if type(UninviteUnit) == "function" then hooksecurefunc("UninviteUnit", kicked) end
    end

    -- member side: the leader's invite after a rejoin, and only that one
    local function rejoinInvite(from)
        local r = rejoin
        if not (r and r.phase == "left" and now() - r.t <= REJOIN_WAIT) then return false end
        if type(from) ~= "string" or secret(from) or Net.Canon(from) ~= r.leader then return false end
        if IsInGroup() or InCombatLockdown() or IsInInstance() then return false end
        rejoin = nil
        AcceptGroup()
        C_Timer.After(0, function()
            local d = StaticPopup_FindVisible and StaticPopup_FindVisible("PARTY_INVITE")
            if d then d.inviteAccepted = 1 end
            StaticPopup_Hide("PARTY_INVITE")
            C.hideLfgPopup()
        end)
        say("back in the group, on the leader's layer.")
        changed()
        return true
    end
    C_Timer.NewTicker(30, function() pcall(askLeader, false) end)

    ------------------------------------------------------------------
    -- 7. Hosting from a Group Finder listing (core 8, 2026-11-16; the user: "do both").
    -- Forever's Group Finder is the vanilla one (game type camelot): no auto-accept, no "apply", and the
    -- listing note is a secure edit box an addon can't fill. Measured 11-16: 210 listings, none
    -- auto-accept. So the PLAYER posts a listing (Custom, a note with "layer" in it); while it's up and
    -- "Host from my Group Finder listing" is on, VoidLayer brings anyone (no addon needed on their side)
    -- who whispers a swap word, or who clicks Group Invite on the listing. That invite is declined and
    -- sent back the other way: joining THEIR group would move US to THEIR layer.
    ------------------------------------------------------------------
    -- one table field, not locals: LayerCoreBuild is at Lua 5.1's 200-locals limit
    -- Live 11-16: when the HOST leaves the 2-person group, the listing goes with the group to the guest
    -- (a guest inherited "Layer swap - whisper inv"). So for these guests the host never leaves: the
    -- guest is told to leave, and after STAY the host gets a one-click Remove (UninviteUnit needs a click).
    C.fh = { STAY = 60,      -- after this long in the group, offer the host a Remove button
                GAP = 300,     -- one invite per player per this
                BUSY = 60,     -- one "busy" whisper per player per this
                sent = {}, busy = {}, wasListed = false,
                WORDS = { "inv", "invite", "layer", "swap", "hop" } }
    function C.fh.whisper(to, text)
        if SendChatMessage then pcall(SendChatMessage, text, "WHISPER", nil, to) end
    end
    -- listed?, and the note when the game lets us read it
    function C.fh.note()
        if not (C_LFGList and C_LFGList.HasActiveEntryInfo and C_LFGList.GetActiveEntryInfo) then return false end
        local ok, has = pcall(C_LFGList.HasActiveEntryInfo)
        if not ok or secret(has) or has ~= true then return false end
        local ok2, e = pcall(C_LFGList.GetActiveEntryInfo)
        local c = ok2 and type(e) == "table" and e.comment or nil
        if type(c) ~= "string" or secret(c) then return true, nil end
        -- measured live 11-16: your own listing's note comes back as a protected token ("|Ku1|k") that only
        -- displays as the text; it can't be read, so it can't be checked: the switch is the gate
        if c:find("^|K.-|k$") then return true, nil end
        return true, c
    end
    function C:FinderOn() return S().finderHost == true end
    function C:SetFinder(on)
        S().finderHost = on and true or false
        if on then
            S().hostHops = true   -- it hosts through the same guards
            say("hosting from your Group Finder listing |cff33ff33on|r. Post one: Group Finder, Custom, a note with the word \"layer\" (e.g. |cffffd200Layer swap - whisper inv|r), Post. Anyone who whispers you inv, layer or swap, or clicks Group Invite on it, gets an invite onto your layer; they don't need an addon. Same limits as helping: solo, no fight, one every 2 minutes.")
        else
            say("hosting from your Group Finder listing |cffff5555off|r (you can remove the listing in the Group Finder).")
        end
        changed()
    end
    -- switched on, listed, and (when the note can be read) a note about layers: a listing for
    -- "Stromgarde quests" with the switch left on never hands out swaps
    function C:FinderListed()
        if not self:FinderOn() then return false end
        local listed, note = C.fh.note()
        if not listed then return false end
        if note and not note:lower():find("layer", 1, true) then return false end
        return true
    end
    function C.fh.wants(text)
        if type(text) ~= "string" or secret(text) or #text > 200 then return false end
        -- another host's automatic reply ("VoidLayer: inviting you onto my layer...") is no request (Sol review)
        if text:find("^%s*VoidLayer:") then return false end
        local t = " " .. (text:lower():gsub("[^%a]", " ")) .. " "
        for _, w in ipairs(C.fh.WORDS) do if t:find(" " .. w .. " ", 1, true) then return true end end
        return false
    end
    -- a friend's or guildmate's invite is theirs to take, never turned around
    function C.fh.knows(name)
        local short = name:match("^([^%-]+)") or name
        if C_FriendList and C_FriendList.GetFriendInfo then
            local ok, info = pcall(C_FriendList.GetFriendInfo, short)
            if ok and type(info) == "table" then return true end
        end
        if C_GuildInfo and C_GuildInfo.MemberExistsByName then
            local ok, yes = pcall(C_GuildInfo.MemberExistsByName, short)
            if ok and yes == true then return true end
        end
        return false
    end
    function C.fh.bring(who, how)
        if C.fh.sent[who] and now() - C.fh.sent[who] < C.fh.GAP then return end
        if not C:CanHost() then
            if not (C.fh.busy[who] and now() - C.fh.busy[who] < C.fh.BUSY) then
                C.fh.busy[who] = now()
                C.fh.whisper(who, "VoidLayer: busy right now (one layer swap every 2 minutes, never in a fight or a group). Whisper again in a minute.")
            end
            return
        end
        local cur, zone = Layer:Here()
        C.fh.sent[who] = now()
        lastHosted = now()
        hostedTimes[#hostedTimes + 1] = lastHosted
        hosting = { guest = who, finder = true, invited = now(), deadline = now() + HOST_STAY }
        C_PartyInfo.InviteUnit(who)
        -- a group only moves you to the leader's layer inside the same zone (measured 11-09), so say where
        local mi = zone and C_Map.GetMapInfo(zone)
        local zn = mi and type(mi.name) == "string" and mi.name or nil
        C.fh.whisper(who, ("VoidLayer: inviting you onto my layer%s.%s Accept; the game moves you in a few seconds, and the layer stays after the group ends.")
            :format(cur and zone and (" (" .. C:Label(zone, cur) .. (zn and (" in " .. zn) or "") .. ")") or "",
                    zn and (" It only works if you're in " .. zn .. " too.") or ""))
        say(("%s %s from your Group Finder listing: inviting them onto your layer (the group ends on its own)."):format(who, how))
        changed()
    end
    function C.fh.listingChanged()
        local listed = C:FinderOn() and (C.fh.note())
        if C.fh.wasListed and not listed and C:FinderOn() then
            say("your Group Finder listing is gone: post it again to keep hosting from it.")
        end
        C.fh.wasListed = listed and true or false
        changed()
    end

    -- Guest side (2026-11-16, the user: "death bobb has the addon and he still got the popup"): you whispered
    -- someone a swap word (inv / layer / swap ...), and THAT player invites you within a minute -> accept it and
    -- close the role window, like a Hop does. Any host: a Group Finder listing, a Layer-Swap host, a guildie.
    -- Names are compared without realm and case (whisper and invite names can be written differently).
    C.fh.ASK_FOR = 60
    C.fh.asked = {}
    function C.fh.key(n)
        if type(n) ~= "string" or secret(n) then return nil end
        return (n:gsub("%-.*$", "")):lower()
    end
    function C.fh.noteAsk(text, to)
        local k = C.fh.key(to)
        if k and C.fh.wants(text) then C.fh.asked[k] = now() end
    end
    function C.fh.takeAsked(from)
        local k = C.fh.key(from)
        local t = k and C.fh.asked[k]
        if not (t and now() - t <= C.fh.ASK_FOR) then return false end
        if IsInGroup() or InCombatLockdown() or IsInInstance() then return false end
        C.fh.asked[k] = nil
        AcceptGroup()
        C_Timer.After(0, function()
            local d = StaticPopup_FindVisible and StaticPopup_FindVisible("PARTY_INVITE")
            if d then d.inviteAccepted = 1 end
            StaticPopup_Hide("PARTY_INVITE")
            C.hideLfgPopup()
        end)
        say(("accepted %s's invite (you asked them for a layer swap). Leave the group once you've moved; the layer stays."):format(from))
        return true
    end

    ------------------------------------------------------------------
    -- Events
    ------------------------------------------------------------------
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
    local f = CreateFrame("Frame")
    for _, ev in ipairs({ "CHAT_MSG_ADDON", "PARTY_INVITE_REQUEST", "PLAYER_REGEN_DISABLED", "GROUP_ROSTER_UPDATE",
                          "NAME_PLATE_UNIT_ADDED", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "ZONE_CHANGED_NEW_AREA", "PARTY_LEADER_CHANGED" }) do
        pcall(f.RegisterEvent, f, ev)
    end
    -- section 7 (on their own: a longer list above overflows this function's registers in Lua 5.1)
    pcall(f.RegisterEvent, f, "CHAT_MSG_WHISPER")
    pcall(f.RegisterEvent, f, "LFG_LIST_ACTIVE_ENTRY_UPDATE")
    pcall(f.RegisterEvent, f, "CHAT_MSG_WHISPER_INFORM")   -- a whisper you sent: remember swap asks
    f:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, _, a6)
        if event == "CHAT_MSG_ADDON" then
            if a1 ~= PREFIX or a3 ~= "WHISPER" or type(a2) ~= "string" or secret(a2) or #a2 > 255 then return end
            local who = Net.Canon(a4)
            if not who or secret(who) or who == me or not rateOK(who) then return end
            if net:Heard(who) == false then return end   -- a hostile player (VoidNet): dropped; else they run the layer engine
            pcall(onMessage, a2, who)
        elseif event == "NAME_PLATE_UNIT_ADDED" then pcall(seeUnit, a1)
        elseif event == "PLAYER_TARGET_CHANGED" then pcall(seeUnit, "target")
        elseif event == "UPDATE_MOUSEOVER_UNIT" then pcall(seeUnit, "mouseover")
        elseif event == "ZONE_CHANGED_NEW_AREA" then changed()
        elseif event == "CHAT_MSG_WHISPER" then
            -- section 7: a swap word whispered while our layer listing is up
            if type(a2) ~= "string" or secret(a2) or not C.fh.wants(a1) or not C:FinderListed() then return end
            local who = Net.Canon(a2)
            if who and not secret(who) and who ~= me and rateOK(who) then pcall(C.fh.bring, who, "whispered you") end
        elseif event == "LFG_LIST_ACTIVE_ENTRY_UPDATE" then pcall(C.fh.listingChanged)
        elseif event == "CHAT_MSG_WHISPER_INFORM" then pcall(C.fh.noteAsk, a1, a2)
        elseif event == "PLAYER_REGEN_DISABLED" then
            if state and state.phase == "asking" then C.hlog("cancelled", state, "combat"); stop("hop cancelled: you're in combat.") end
        elseif event == "GROUP_ROSTER_UPDATE" then
            -- section 6: re-invite a member who asked and left; ask a (new) leader its layer
            pcall(reinviteGone)
            if rejoin and rejoin.phase == "asking" and not IsInGroup() then rejoin = nil end
            if now() - lastGQ > 10 then C_Timer.After(3, function() pcall(askLeader, true) end) end
            -- the leave-without-name-match window lasts only as long as the hop's own group: once we've
            -- been in it and it's gone, a later two-person group (a friend's) is never left (Sol review)
            if hopGroupUntil > 0 then
                if IsInGroup() then hopGroupSeen = true
                elseif hopGroupSeen then hopGroupUntil, hopGroupSeen = 0, false end
            end
            if state and state.phase == "joined" then
                if inGroupWith(state.host) then state.seenHost = true
                elseif state.seenHost then C.hlog("groupEnded", state); stop("the group ended before the move was confirmed.") end
            end
            if hosting then
                if inGroupWith(hosting.guest) then
                    -- test host: the minute counts from the join (Sol review)
                    if not hosting.joined and hosting.testStay then hosting.deadline = now() + hosting.testStay end
                    -- a Group Finder guest: tell them they can leave; after STAY offer the host a Remove click
                    if not hosting.joined and hosting.finder then
                        hosting.deadline = now() + C.fh.STAY
                        local g = hosting.guest
                        C_Timer.After(8, function()
                            if hosting and hosting.guest == g and inGroupWith(g) then
                                C.fh.whisper(g, "VoidLayer: you're on my layer now. Leave the group whenever you like (type /leave); the layer stays.")
                            end
                        end)
                    end
                    hosting.joined = true
                elseif hosting.joined then endHosting(false) end
            elseif lateGuest and now() - lateGuest.t < LATE_JOIN and inGroupWith(lateGuest.name)
                    and (GetNumGroupMembers() or 0) <= 2 then
                -- they accepted after we stopped waiting: look after the group anyway (Sol review)
                hosting = { guest = lateGuest.name, nonce = lateGuest.nonce, invited = now(), joined = true,
                            finder = lateGuest.finder, late = true,
                            deadline = now() + (lateGuest.finder and C.fh.STAY or HOST_STAY) }
                lateGuest = nil
            end
            changed()
        elseif event == "PARTY_LEADER_CHANGED" then
            leaderLayer = nil
            if rejoin and rejoin.phase == "asking" then rejoin = nil end   -- a request for a group that changed (Sol review)
            if not isLeader("player") then wipe(reinvite) end
            C_Timer.After(2, function() pcall(askLeader, true) end)
            changed()
        elseif event == "PARTY_INVITE_REQUEST" then
            -- the leader's invite back after a rejoin (section 6)
            if rejoinInvite(a1) then return end
            -- the player you just whispered for a swap (guest side of section 7): accept, no role window
            if not (state and state.phase == "asking") then
                local ok, took = pcall(C.fh.takeAsked, a1)
                if ok and took then return end
            end
            -- accept only the invite from the player we asked, while asking
            if not (state and state.phase == "asking") then
                -- section 7: a stranger clicked Group Invite on our layer listing. Joining their group would
                -- move us to their layer, so decline and invite them the other way.
                if type(a1) ~= "string" or secret(a1) or IsInGroup() or hosting or not C:FinderListed() then return end
                local who = Net.Canon(a1)
                if not who or secret(who) or who == me or C.fh.knows(who) then return end
                -- only turn it around when we really can invite back; otherwise the invite stays theirs (Sol review)
                if not C:CanHost() or (C.fh.sent[who] and now() - C.fh.sent[who] < C.fh.GAP) then return end
                if DeclineGroup then DeclineGroup() end
                StaticPopup_Hide("PARTY_INVITE")
                C.hideLfgPopup()
                C_Timer.After(1, function()
                    -- still listed and free a second later (Sol review)
                    if C:FinderListed() and not IsInGroup() then pcall(C.fh.bring, who, "sent you a group invite") end
                end)
                return
            end
            if type(a1) ~= "string" or secret(a1) or Net.Canon(a1) ~= state.host then return end
            -- still the hop you asked for: same zone, solo, no combat, no instance (Sol review)
            local _, zone = Layer:Here()
            if zone ~= state.zone or IsInGroup() or InCombatLockdown() or IsInInstance() then
                C.hlog("cancelled", state, "moved on"); stop("hop cancelled: you've moved on since asking.")
                return
            end
            -- the game says the host is on YOUR layer already (isCrossShard false; 4 of 4 right, 2026-11-24):
            -- joining moves nothing. Decline, both take one name, and ask the next helper.
            if a6 == false and not secret(a6) then
                if DeclineGroup then DeclineGroup() end
                StaticPopup_Hide("PARTY_INVITE")
                C.hideLfgPopup()
                local mine = Layer:Merge(zone, state.hostPair or state.pair)
                if mine then send(("HN:1:%s:%s"):format(state.nonce, mine), state.host, true) end
                C.hlog("sameLayer", state)
                if state.want and Layer:Alias(zone, state.want) == Layer:Current(zone) then
                    stop("you're on that layer already.")
                    return
                end
                say(("%s is on your layer already; asking another player."):format(state.host))
                state.phase = "retrying"
                nextHost()
                return
            end
            AcceptGroup()
            hopGroupUntil, hopGroupSeen = now() + MOVE_WAIT * 2 + REVERT_WATCH + 30, false   -- this group is the hop's
            C_Timer.After(0, function()
                local d = StaticPopup_FindVisible and StaticPopup_FindVisible("PARTY_INVITE")
                if d then d.inviteAccepted = 1 end
                StaticPopup_Hide("PARTY_INVITE")
                C.hideLfgPopup()
            end)
            state.phase = "joined"
            setTimer(MOVE_WAIT, checkMove)
            changed()
        end
    end)

    C_Timer.NewTicker(5, function()
        if hosting then
            local n = now()
            if not hosting.joined and n - hosting.invited > JOIN_WAIT then endHosting(false)
            elseif hosting.joined and n >= hosting.deadline then
                -- a Group Finder guest: never leave (the listing would go to them); ask once for a Remove click
                if hosting.finder then
                    if not hosting.askedRemove and inGroupWith(hosting.guest) then
                        -- only counts as asked when the game really showed it (it can return nil; Sol review)
                        hosting.askedRemove = StaticPopup_Show("VOIDLAYER_REMOVE", hosting.guest, nil, hosting.guest) ~= nil
                    end
                    hosting.deadline = n + (hosting.askedRemove and 600 or 10)   -- shown: no more asks; not shown: try again soon
                else
                    endHosting(true)
                end
            end
        end
        -- forget old question ids, old rares and old offers (Sol review: unbounded otherwise)
        for k, t in pairs(seenQ) do if now() - t > 300 then seenQ[k] = nil end end
        pruneRares()
        for k, t in pairs(offered) do if now() - t > OFFER_GAP then offered[k] = nil end end
        for k, s in pairs(sentRare) do if now() - s.t > RARE_RESEND then sentRare[k] = nil end end
        for k, b in pairs(bucket) do if now() - b.start > 60 then bucket[k] = nil end end
        for k, t in pairs(linkSharedTo) do if now() - t > ASK_CD then linkSharedTo[k] = nil end end
        for k, t in pairs(C.fh.sent) do if now() - t > C.fh.GAP then C.fh.sent[k] = nil end end
        for k, t in pairs(C.fh.busy) do if now() - t > C.fh.BUSY then C.fh.busy[k] = nil end end
        for k, t in pairs(C.fh.asked) do if now() - t > C.fh.ASK_FOR then C.fh.asked[k] = nil end end
    end)

    -- join a little after login (VoidSweep 14 s, VoidGather earlier), then read the members
    C_Timer.After(18, function()
        join()
        C_Timer.After(4, function() net:RequestRoster(true) end)
    end)
    -- new channels at 00:00 UTC, and the old one left once nobody old has been on it for 30 days (VoidNet)
    C_Timer.NewTicker(60, function()
        if net:Day() then publish() end   -- "—" until the new day's list is read
    end)

    -- Players who newly help (no VoidLayer / VoidSweep, 2026-11-17): a short pop-up ONCE PER ACCOUNT (kept in
    -- VoidNet's saved state, which every Void addon's account data holds), with a one-click way out.
    local s = S()
    StaticPopupDialogs.VOIDNET_HELP = {
        text = "Void addons: you can now help other players change layer.\n\nWhen a Void player on your layer asks, you send them a quick group invite (only when you're solo and out of combat). Don't want it? Turn off Help others change layer in %s.",
        button1 = OKAY or "OK", button2 = "Turn it off",
        OnCancel = function(_, _, reason) if reason == "clicked" then C:SetHosting(false) end end,
        -- Escape only closes it (the game would call OnCancel = "Turn it off" on Escape otherwise)
        OnEscape = function() end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
    local vs = net and net.core and net.core.state
    if owner.addon ~= "VoidLayer" and owner.addon ~= "VoidSweep" and vs and not vs.helpPopup and C:HostingOn() then
        vs.helpPopup = true
        s.hostNoticeShown = true
        C_Timer.After(25, function()
            local h = rawget(_G, "VoidLayerHelp")
            local where = h and h.WHERE and h.WHERE[owner.addon] or ("the Void hub (Help Void layer hopping)")
            StaticPopup_Show("VOIDNET_HELP", where)
        end)
    end
    -- once per character (VoidLayer / VoidSweep players): hosting is on, and how to turn it off
    if s.hostHops == nil and not s.hostNoticeShown then
        s.hostNoticeShown = true
        C_Timer.After(25, function()
            local where = owner.addon == "VoidLayer" and "the VoidLayer window (click your layer under the minimap)"
                or "the Void hub's quick switches (Help others change layer)"
            say(("you help other Void players change layer: if one on your layer asks, you send a quick group invite (only while you're solo and out of combat; the group ends on its own). Turn it off in %s."):format(where))
        end)
    end

    return C
end

----------------------------------------------------------------------
-- Election at PLAYER_LOGIN: the newest core runs, with the settings of the highest priority
----------------------------------------------------------------------
local elect = CreateFrame("Frame")
elect:RegisterEvent("PLAYER_LOGIN")
elect:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    if reg.done then return end
    reg.done = true
    if not forever() then return end
    local best, owner
    for _, c in ipairs(reg.list) do
        if not best or c.v > best.v then best = c end
        if c.settings and (not owner or c.prio > owner.prio) then owner = c end
    end
    if not (best and owner and best.ns.LayerCoreBuild) then return end
    local ok, core = pcall(best.ns.LayerCoreBuild, owner)
    if ok then
        _G.VoidLayerCore = core
        for _, fn in ipairs(reg.ready or {}) do pcall(fn, core) end
    else
        print("|cff00c7ffVoid layers|r: couldn't start: " .. tostring(core))
    end
end)

-- Run fn(core) once the core is up (right away if it already is).
function ns.OnLayerCore(fn)
    if _G.VoidLayerCore then pcall(fn, _G.VoidLayerCore) return end
    reg.ready = reg.ready or {}
    table.insert(reg.ready, fn)
end
