----------------------------------------------------------------------
-- VoidQuest — ForeverShare: share quest-giver spots with other players (WoW Forever)
--
-- Forever has no "!" on the map for its quests and Blizzard's API has no locations, so
-- the only way to know where a quest starts is someone standing at its giver. Every
-- VoidQuest player records that already (QuestStarts.lua); this passes it around, so
-- each player only has to find a giver once for everyone.
--
-- TRANSPORT (measured on live Forever, 2026-11-05): addon messages to a custom channel
-- return 0 but the server refuses them (CHAT_MSG_CHANNEL_NOTICE NOT_ALLOWED_IN_CHANNEL,
-- nothing delivered; it worked on the beta). GUILD sends but never echoes. Addon WHISPERS
-- work, to the bare "First Surname" name (Forever names are unique per region, no realm).
-- So the hidden channel (VoidQuestLink) is only a member list -- who runs VoidQuest right
-- now -- and the messages go by addon whisper to a few random members:
--   N:1:mapID:entries   quest givers you found -> up to FANOUT members (held back, PRIVACY)
--   Q:1:mapID           "any givers for this map?" -> up to ASK_PEERS members (zone change)
--   B:1:mapID:entries   the answer, whispered back to whoever asked: your OWN finds there
--   PING:nonce          /vq net self-test (a whisper to yourself comes back)
-- entry = "questID,npcID,x,y,name" with x/y = 0..9999.
-- Should channel addon messages come back, they're accepted too (same rules).
--
-- PRIVACY: the payload is quest ID, the NPC's ID and name, map and spot -- nothing about
-- you. A whisper shows its receiver who SENT it, so new finds are not sent live (that
-- would show where you are right now): they wait until you've left that map, or 10-20
-- minutes. A Q does show the zone you just entered. Captures where a PLAYER shared the
-- quest are never recorded at all.
--
-- SECURITY: the prefix ships in our code and anyone can whisper, so every inbound message
-- is untrusted. Fields are parsed with strict patterns, names stripped of escape codes and
-- capped, the quest must be a real Forever quest (ForeverQuests.lua, Blizzard's own list),
-- the map must exist, and each sender is rate-limited; a Q from the same player for the
-- same map is answered once per REPLY_CD. A report is only USED once two different
-- players agree on ALL of it (same NPC ID and name, same map, close spots); until then it
-- just waits. Your own finds always win, and only your own finds are passed on, so a
-- forged report can't spread past the people who heard it. Senders are counted by a
-- short one-way hash of their name keyed with a random per-install salt, so no player
-- name is ever saved. (Pseudonymous, not anonymous: someone holding this install's
-- SavedVariables, salt included, could test a list of names against the votes.) A stranger's
-- questions get at most one answer a minute, and turning sharing off drops everything
-- queued or held.
--
-- VoidQuestDB.heard[questID] = { { m, x, y, npc, id, n, v = { [hash] = true } }, ... }
-- (up to 3 candidate spots per quest; n = how many different players reported it).
-- tools/cmd/vq-seed bundles the confirmed ones (n >= 2) into ForeverSeed.lua.
----------------------------------------------------------------------
local VQ = VoidQuest
if not VQ.ForeverQuests then return end   -- WoW Forever only (retail has Blizzard's own pins)

local Share = VQ:NewModule("ForeverShare")
VQ.Share = Share

local PREFIX        = "VQUEST"
local PROTO         = "1"
-- 2026-11-08: the first channel, VoidQuestNet, was open: anyone could /join it, own it once
-- it emptied and /ban players. The author's character got banned; the server then answers
-- the join NOT_ALLOWED_IN_CHANNEL and lists the channel joined but DISABLED, with no member
-- list (so the players box said "—" all day). Now a new channel EVERY DAY, joined with a
-- password, both worked out from the server's date (same scheme as WhisperNet.lua's "Daily
-- channel" in VoidGather / VoidSweep): a /join by hand is refused, and if someone works it
-- out anyway, a ban or a takeover only lasts until 00:00 UTC. Neither is in this file as
-- text. Older versions stay in VoidQuestNet until they update.
local DAILY_TAG, DAILY_SALT = "Vq", 40692
local OLD_CHANNELS  = { "VoidQuestNet", "VoidQuestLink" }
local CODE = "bcdfghjkmnpqrstvwxz23456789"   -- no vowels: no accidental words for the name filter
local function mix(h, n) return (h * 31 + n) % 2147483629 end
local function code(seed, len)
    local h, out = seed, {}
    for i = 1, len do
        h = mix(mix(h, i), 7919)
        local k = h % #CODE + 1
        out[i] = CODE:sub(k, k)
    end
    return table.concat(out)
end
-- One channel PER FACTION (2026-11-10): the channel lists both factions, but whispers don't
-- cross them, so every whisper to an Alliance member bounced (the "2 online" were unreachable,
-- 14 sends found nobody), and the other faction's quest data is no use to you anyway.
-- shared = the old both-factions channel of that day (0.3.19 and older), only to leave it.
local FACTION_SALT = { Horde = 1, Alliance = 2 }
local function dailyChannel(day, shared)
    day = day or math.floor(((GetServerTime and GetServerTime()) or time()) / 86400)
    local s = mix(mix(DAILY_SALT, day), DAILY_SALT % 97)
    if not shared then
        local f = UnitFactionGroup and UnitFactionGroup("player")
        s = mix(s, FACTION_SALT[f] or 3)   -- 3: no faction yet (a new Pandaren)
    end
    return DAILY_TAG .. code(s, 6), code(mix(s, 104729), 8), day
end
local CHANNEL_NAME, CHANNEL_PW = dailyChannel()
local MAX_LEN       = 250    -- SendAddonMessage cap is 255
local SEND_EVERY    = 1.5    -- seconds between our outgoing whispers
local QUEUE_MAX     = 60
local FANOUT        = 6      -- members each new find is whispered to
local ASK_PEERS     = 4      -- members asked on entering a zone
local ROSTER_EVERY  = 300    -- re-read the member list at most this often
local ROSTER_MAX    = 300    -- members read from it
local REPLY_MAX     = 60     -- givers per answer (~8 messages)
local REPLY_CD      = 300    -- answer the same player about the same map at most this often
local QUERY_CD      = 900    -- ask about the same map at most this often
local HOLD_MIN      = 600    -- new finds wait 10-20 min (or until you leave the map)
local HOLD_SPREAD   = 600
local SENDER_WINDOW = 60
local SENDER_MAX    = 40     -- messages accepted per sender per window
local ENTRIES_MAX   = 20     -- entries read per message
local NEAR          = 0.03   -- two reports of the same NPC within this (map 0-1) agree
local CANDIDATES    = 4      -- different spots kept per quest
local FLUSH_MAX     = 14     -- held finds sent per tick: ~2 messages x FANOUT, fits in half the queue
local STALE         = 7 * 86400   -- a spot nobody reported for this long can make room
local ANSWER_EVERY  = 30     -- at most one whispered answer (to anyone) per this
local lastAnyReply
local CONFIRM       = 2      -- players that must agree before a report is used
local VOTES_KEPT    = 5      -- voters remembered per spot (more adds nothing)
local HEARD_FROM_MAX = 500

local queue, sending = {}, nil
local bucket = {}        -- [sender] = { n, start }
local lastReply = {}     -- [sender .. ":" .. mapID] = GetTime()
local lastReplyTo = {}   -- [sender] = GetTime(): one answer per player per REPLY_GAP, any map
local REPLY_GAP = 60
local lastQuery = {}     -- [mapID] = GetTime()
local pending = {}       -- [questID] = GetTime() it may go out (PRIVACY)
local pendingTicker
local roster, rosterAt = {}, -ROSTER_EVERY
local whispered = {}     -- [lower(name)] = GetTime(): hide "No player named ..." for these
local pingNonce, pingGot
local me
local refreshPending
Share.heardMsgs, Share.heardFrom, Share.heardFromN = 0, {}, 0
Share.gen = 0            -- bumped when sharing is turned off; stale scheduled replies check it

local function enabled() return VQ:Get("share") ~= false end

local function netIndex()
    local id = GetChannelName(CHANNEL_NAME)
    if id and id > 0 then return id end
end

-- A channel the game won't let us into (banned / other password; same as WhisperNet.lua's
-- "Refused channels" in VoidGather and VoidSweep). Banned = listed joined but disabled.
local function blocked()
    if not GetChannelList then return false end
    local t, want = { GetChannelList() }, CHANNEL_NAME:lower()
    for i = 1, #t - 2, 3 do   -- id, name, disabled
        if type(t[i + 1]) == "string" and t[i + 1]:lower() == want then return t[i + 2] == true end
    end
    return false
end
local refusedAs   -- "WRONG_PASSWORD" / "BANNED" from the last join's answer
local function blockReason()
    if blocked() or refusedAs == "BANNED" then
        return ("the game won't let you into %s (its owner banned this character). Sharing can't count or reach players until that's lifted."):format(CHANNEL_NAME)
    elseif refusedAs == "WRONG_PASSWORD" then
        return ("%s has a different password (someone else set it). Sharing can't count or reach players there."):format(CHANNEL_NAME)
    end
end

-- Strip anything that could act as an escape code or break the format, and cap the
-- length without cutting a UTF-8 character in half.
local function cleanName(s)
    if type(s) ~= "string" then return nil end
    s = (s:gsub("[%c|;,:]", ""))
    s = (s:gsub("^%s+", ""):gsub("%s+$", ""))
    if #s > 40 then
        s = s:sub(1, 40)
        s = (s:gsub("[\192-\255][\128-\191]*$", ""))
    end
    if s == "" then return nil end
    return s
end

-- One name per player. Forever: "First Surname", unique per region, as the game gives
-- it. Elsewhere: "Name-Realm" (same-realm senders arrive without the realm).
local function canon(name)
    if type(name) ~= "string" or name == "" then return nil end
    if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() then return name end
    if name:find("-", 1, true) then return name end
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    return realm and (name .. "-" .. realm) or name
end

-- One-way 24-bit hash of a sender: tells two reports from the same player apart from
-- two players, without keeping the name. Keyed with a random per-install salt, so nobody
-- can hash a list of names and match them against what's saved here.
local function salt()
    VoidQuestDB.shareSalt = VoidQuestDB.shareSalt
        or ("%06x%06x"):format(math.random(0, 16777215), math.random(0, 16777215))
    return VoidQuestDB.shareSalt
end
local function senderHash(name)
    local h, s = 5381, salt() .. name
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 16777216 end
    return ("%06x"):format(h)
end

-- PRIVACY hold, also across /reload: a find is "fresh" until it went out or HOLD_MAX passed.
local HOLD_MAX = 1200
local function fresh(s)
    return s.t and not s.sent and time() - s.t < HOLD_MAX
end

-- Only quests with a real NPC giver and a spot are shared (never "auto"/object starts).
local function shareable(s)
    return s and s.how == "npc" and s.id and s.npc and s.m and s.x and s.y
        and s.x > 0 and s.x < 1 and s.y > 0 and s.y < 1
end

-- Every player already has the shipped seed (VoidQuest.ForeverSeed, NorgannonDB-backed since
-- 0.3.0): a find it already holds isn't sent. Addon messages are small and throttled, so only
-- gaps and real corrections (the giver somewhere else) go out (the user, 2026-11-06).
local function seedHas(q, s)
    local d = q and VQ.ForeverSeed and VQ.ForeverSeed[q]
    if not (d and d.m and d.x and d.y) or d.m ~= s.m then return false end
    -- same NPC too: a different giver at the same spot is a correction worth sending (Codex review)
    if d.giver and s.npc and d.giver ~= s.npc then return false end
    return math.abs(d.x - s.x) < 0.03 and math.abs(d.y - s.y) < 0.03
end

local function encode(qid, s)
    local name = cleanName(s.npc)
    if not name then return nil end
    return ("%d,%d,%d,%d,%s"):format(qid, s.id,
        math.floor(s.x * 10000 + 0.5), math.floor(s.y * 10000 + 0.5), name)
end

----------------------------------------------------------------------
-- Who's on the network: VoidQuestNet's member list (the channel carries no messages)
----------------------------------------------------------------------
local function displayIndex()
    if not (GetNumDisplayChannels and GetChannelDisplayInfo) then return nil end
    for i = 1, GetNumDisplayChannels() or 0 do
        local name, header = GetChannelDisplayInfo(i)
        if not header and type(name) == "string" and name:lower() == CHANNEL_NAME:lower() then return i end
    end
end

-- Members of VoidQuestNet incl. you (nil = not read yet); shown in the players box.
local memberCount

-- The member list also holds players who can't be whispered right now (logged off, out of
-- reach); the game's connected check answers "unknown" for everyone but you (live 11-05).
-- A whisper that bounces ("No player named X is currently playing") marks X offline. The
-- mark stays until a later whisper to X goes through (no bounce within BOUNCE_WAIT): a
-- timed-out mark made logged-off players count as online again every 30 min, so the
-- players box popped up and down (live 11-07). After UNREACH_FOR, X may be picked again,
-- which is how we find out they're back.
-- Marks were SAVED (VoidQuestDB.netOffline) until 2026-11-09; now this session only (the user:
-- "get rid of the offline list"). They are timed with time(). When they were kept
-- only in memory, every /reload counted logged-off members as online again until their
-- next bounce (live 11-07).
local UNREACH_FOR = 1800   -- a marked player may be whispered again after this
local BOUNCE_WAIT = 5      -- the "No player named" line comes back well within this
local STALE_MARK  = 7200   -- busy channel only: marks older than this stop being counted
local unreach = {}       -- [lower(name)] = time() of the last bounce
local function reachable(name)   -- may be whispered
    local t = unreach[name:lower()]
    return not t or time() - t >= UNREACH_FOR
end

-- The "Players online" box (PresenceBox.lua, shared with VoidGather / VoidSweep).
local function publish()
    if not _G.VoidPresence then return end
    local gone = 0
    if (memberCount or 0) > ROSTER_MAX then
        -- only a window of the list is read: count the recent marks
        local now = time()
        for _, t in pairs(unreach) do if now - t < STALE_MARK then gone = gone + 1 end end
    else
        for _, name in ipairs(roster) do if unreach[name:lower()] then gone = gone + 1 end end
    end
    local others = memberCount and math.max(0, memberCount - 1 - gone)
    local note = enabled() and blockReason() and "blocked" or nil
    VoidPresence:Set("VoidQuest", "VoidQuest online", others or 0, false, enabled() and others ~= nil, note)
end

local function readRoster()
    local i = displayIndex()
    if not (i and C_ChatInfo and C_ChatInfo.GetChannelRosterInfo) then return end
    local _, _, _, _, count = GetChannelDisplayInfo(i)
    count = tonumber(count)
    -- no count = another channel holds the selection (only the selected one has a list,
    -- live 11-07): keep what we had, never wipe the roster on an empty read
    if not count or count < 1 then return end
    memberCount = count
    local list = {}
    -- a busy channel: read a random window of ROSTER_MAX members, so everyone can be picked
    local total = count or 0
    local start = total > ROSTER_MAX and math.random(0, total - ROSTER_MAX) or 0
    local resolved = 0   -- rows that came back with a name (you included)
    for r = start + 1, start + math.min(total, ROSTER_MAX) do
        local ok, name = pcall(C_ChatInfo.GetChannelRosterInfo, i, r)
        name = ok and canon(name)
        if name then resolved = resolved + 1 end
        if name and name ~= me then list[#list + 1] = name end
    end
    if #list > 0 or total <= 1 then
        roster = list
        -- the whole list was read: forget offline marks of players no longer on it (they're
        -- saved across reloads, so this keeps the saved table small). Only when every row
        -- had a name: a name still loading isn't "gone" (Sol review)
        if total <= ROSTER_MAX and resolved == total then
            local on = {}
            for _, n in ipairs(list) do on[n:lower()] = true end
            for k in pairs(unreach) do if not on[k] then unreach[k] = nil end end
        end
    end
    publish()
end

-- Only ONE channel can be selected at a time, and only the selected one has a member list.
-- VoidGather / VoidSweep (WhisperNet.lua Net.Turn) ask at the same moments, so everyone
-- takes turns through the global VoidRosterTurnUntil: whoever selects holds it TURN_HOLD
-- seconds (covers the ~3 s wait for the list), the rest wait for it to run out.
local TURN_HOLD = 4
local function takeTurn(fn)
    local now, busy = GetTime(), _G.VoidRosterTurnUntil or 0
    if now >= busy then
        _G.VoidRosterTurnUntil = now + TURN_HOLD
        fn()
    else
        C_Timer.After(busy - now + 0.1 + math.random() * 0.5, function() takeTurn(fn) end)
    end
end

-- The server sends the member list after the channel is selected (CHANNEL_ROSTER_UPDATE).
-- Left alone while the Channels window is open, so we never change what you're looking at.
local waitingTurn
local function requestRoster()
    if waitingTurn or GetTime() - rosterAt < ROSTER_EVERY then return end
    if not displayIndex() then return end   -- not in the channel yet: try again next time
    waitingTurn = true
    takeTurn(function()
        waitingTurn = nil
        local i = displayIndex()
        if not i then return end
        -- the wait only starts once the list was really asked for (not while the window is open)
        if not (ChannelFrame and ChannelFrame:IsShown()) and SetSelectedDisplayChannel then
            rosterAt = GetTime()
            pcall(SetSelectedDisplayChannel, i)
        end
        readRoster()   -- may already be there
        C_Timer.After(3, readRoster)   -- else it arrives within a few seconds (live 11-05: ~3 s)
    end)
end

-- Up to k random members we can reach.
local function pick(k)
    local live = {}
    for _, name in ipairs(roster) do if reachable(name) then live[#live + 1] = name end end
    local n, out, used = #live, {}, {}
    while #out < math.min(k, n) do
        local j = math.random(n)
        if not used[j] then used[j] = true; out[#out + 1] = live[j] end
    end
    return out
end

----------------------------------------------------------------------
-- Traffic counter (the user, 2026-11-08: "quest should be updating over the wire like
-- gather"; nothing had ever arrived and nothing told us why). Counts by message type
-- (N/Q/B/PING) what went out, what bounced (offline), what came in, and what never went
-- because nobody was online, since `since`, in VoidQuestDB.netStats. /vq net prints it.
----------------------------------------------------------------------
-- Kept small on purpose (incoming messages are counted before they're checked): the type
-- is the message's short uppercase prefix, a short label we pass ourselves, else "other",
-- and each bucket holds at most TALLY_KEYS types (the rest count as "other").
local TALLY_KEYS = 16
local function tally(what, msg)
    if not VoidQuestDB then return end
    local s = VoidQuestDB.netStats
    if not s then s = { since = time() }; VoidQuestDB.netStats = s end
    local kind = type(msg) == "string" and (msg:match("^(%u%u?%u?%u?):") or (#msg <= 12 and not msg:find(":") and msg))
    kind = kind or "other"
    local b = s[what]
    if not b then b = {}; s[what] = b end
    if not b[kind] then
        local n = 0
        for _ in pairs(b) do n = n + 1 end
        if n >= TALLY_KEYS then kind = "other" end
    end
    b[kind] = (b[kind] or 0) + 1
    s["last_" .. what] = time()
end
-- SendAddonMessage's result: accepted (0; older clients nil/true), the player is offline
-- (12 = TargetOffline), or refused for another reason (throttle, lockdown, ...)
local function sendResult(result)
    if result == nil or result == true or result == 0 then return "sent" end
    return result == 12 and "offline" or "refused"
end
Share.Tally = tally

----------------------------------------------------------------------
-- Outgoing: addon whispers, one every SEND_EVERY seconds (the server throttles addon
-- traffic, so we never burst)
----------------------------------------------------------------------
local function pump()
    local item = table.remove(queue, 1)
    if not item then
        if sending then sending:Cancel(); sending = nil end
        return
    end
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        local key, at = item.to:lower(), time()
        whispered[key] = GetTime()   -- bounce matching (HIDE_FOR) runs on GetTime
        local result = C_ChatInfo.SendAddonMessage(PREFIX, item.msg, "WHISPER", item.to)
        tally(sendResult(result), item.msg)
        -- Enum.SendAddonMessageResult: 0 = Success, 12 = TargetOffline (older clients: nil/true).
        -- Only a send the game accepted can prove a marked player is back.
        if result == 12 then
            unreach[key] = at; publish()
        elseif (result == nil or result == true or result == 0) and unreach[key] then
            -- a marked player we whispered again: no bounce = they're back online
            C_Timer.After(BOUNCE_WAIT, function()
                local t = unreach[key]
                if t and t < at then unreach[key] = nil; publish() end
            end)
        end
    end
end

local function send(msg, to)
    if not to or not enabled() or #queue >= QUEUE_MAX then return end
    queue[#queue + 1] = { msg = msg, to = to }
    if not sending then
        pump()
        sending = C_Timer.NewTicker(SEND_EVERY, pump)   -- cancels itself once the queue is empty
    end
end

----------------------------------------------------------------------
-- For GroupUp.lua (asking players on the same quest to group): whispers that go before
-- everything else waiting (a group ask is live, a held find can wait), the member list,
-- and your own name.
----------------------------------------------------------------------
function Share:SendNow(msg, to)
    if not to or not enabled() or #queue >= QUEUE_MAX then return false end
    table.insert(queue, 1, { msg = msg, to = to })
    if not sending then
        pump()
        sending = C_Timer.NewTicker(SEND_EVERY, pump)
    end
    return true
end
function Share:Members(k) requestRoster(); return pick(k) end
function Share:Me() return me end
function Share:Canon(name) return canon(name) end
function Share:On() return enabled() and not blocked() end
Share.SEND_EVERY = SEND_EVERY

-- Pack entries into as few messages as fit under MAX_LEN, each to every target.
local function sendEntries(tag, mapID, entries, targets)
    local head = ("%s:%s:%d:"):format(tag, PROTO, mapID)
    local msgs, parts, len = {}, {}, #head
    for _, e in ipairs(entries) do
        if #parts > 0 and len + 1 + #e > MAX_LEN then
            msgs[#msgs + 1] = head .. table.concat(parts, ";")
            parts, len = {}, #head
        end
        parts[#parts + 1] = e
        len = len + #e + 1
    end
    if #parts > 0 then msgs[#msgs + 1] = head .. table.concat(parts, ";") end
    for _, to in ipairs(targets) do
        for _, m in ipairs(msgs) do send(m, to) end
    end
end

-- Send held finds whose own wait is over, or that are on a map you're no longer on. A find
-- only counts as sent once it really goes out: with nobody to send to yet (member list not
-- read, nobody online) or a busy queue it stays held and the next tick tries again.
local function flush()
    if not enabled() then return end
    local here, now = C_Map.GetBestMapForUnit("player"), GetTime()
    local due = {}
    for q, at in pairs(pending) do
        local s = VoidQuestDB and VoidQuestDB.starts and VoidQuestDB.starts[q]
        if not shareable(s) then
            pending[q] = nil
        elseif ((here and s.m ~= here) or now >= at) and #due < FLUSH_MAX then   -- no map known = not "left"
            due[#due + 1] = q   -- at most FLUSH_MAX a tick, so a batch always fits the queue
        end
    end
    if #due > 0 then
        requestRoster()
        local targets = pick(FANOUT)
        if #targets == 0 then tally("nobody", "N") end
        if #targets > 0 and #queue <= QUEUE_MAX / 2 then
            local byMap = {}
            for _, q in ipairs(due) do
                local s = VoidQuestDB.starts[q]
                local e = encode(q, s)
                pending[q] = nil
                s.sent = true
                if e then
                    byMap[s.m] = byMap[s.m] or {}
                    table.insert(byMap[s.m], e)
                end
            end
            for m, list in pairs(byMap) do sendEntries("N", m, list, targets) end
        end
    end
    if pendingTicker and not next(pending) then pendingTicker:Cancel(); pendingTicker = nil end
end

-- QuestStarts calls this with quests it just learned. Held back (PRIVACY): each one goes
-- out once you've left its map, or 10-20 minutes after you found it.
function Share:Found(qids)
    if not (enabled() and VoidQuestDB and VoidQuestDB.starts) then return end
    for _, q in ipairs(qids) do
        local s = VoidQuestDB.starts[q]
        if shareable(s) and not seedHas(q, s) and not pending[q] then
            pending[q] = GetTime() + HOLD_MIN + math.random() * HOLD_SPREAD
            s.t, s.sent = s.t or time(), nil   -- saved: the hold survives a /reload
        end
    end
    if next(pending) and not pendingTicker then pendingTicker = C_Timer.NewTicker(60, flush) end
end

function Share:Ask(mapID)
    if not (enabled() and mapID) then return end
    if lastQuery[mapID] and GetTime() - lastQuery[mapID] < QUERY_CD then return end
    requestRoster()
    -- nobody to ask yet (none online, or all known to be offline): try again on the next zone change
    local targets = pick(ASK_PEERS)
    if #targets == 0 then tally("nobody", "Q"); return end
    lastQuery[mapID] = GetTime()
    for _, to in ipairs(targets) do send(("Q:%s:%d"):format(PROTO, mapID), to) end
end

local function ownOn(mapID)
    local out = {}
    for q, s in pairs(VoidQuestDB and VoidQuestDB.starts or {}) do
        -- finds still held back (PRIVACY) aren't in answers either
        if type(q) == "number" and shareable(s) and not seedHas(q, s) and s.m == mapID and not pending[q] and not fresh(s) then
            local e = encode(q, s)
            if e then out[#out + 1] = e end
            if #out >= REPLY_MAX then break end
        end
    end
    return out
end

----------------------------------------------------------------------
-- Incoming — untrusted
----------------------------------------------------------------------
local lastSweep = 0
local function rateOK(sender)
    local now = GetTime()
    if now - lastSweep > SENDER_WINDOW then   -- forget senders whose window ran out
        lastSweep = now
        for k, b in pairs(bucket) do
            if now - b.start > SENDER_WINDOW then bucket[k] = nil end
        end
        for k, t in pairs(lastReply) do
            if now - t > REPLY_CD then lastReply[k] = nil end
        end
        for k, t in pairs(lastReplyTo) do
            if now - t > REPLY_GAP then lastReplyTo[k] = nil end
        end
        for k, t in pairs(whispered) do
            if now - t > 30 then whispered[k] = nil end
        end
    end
    local b = bucket[sender]
    if not b or now - b.start > SENDER_WINDOW then
        bucket[sender] = { n = 1, start = now }
        return true
    end
    b.n = b.n + 1
    return b.n <= SENDER_MAX
end

local function validMap(mapID)
    return mapID and mapID > 0 and C_Map.GetMapInfo(mapID) ~= nil
end

local function scheduleRefresh()
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(2, function()
        refreshPending = nil
        if VQ.Forever and VQ.Forever.Refresh then VQ.Forever:Refresh() end
    end)
end

-- Add one report. Returns true when it made a spot confirmed (usable) for the first time.
local function addReport(qid, npcID, mapID, x, y, name, hash)
    VoidQuestDB.heard = VoidQuestDB.heard or {}
    local list = VoidQuestDB.heard[qid]
    if not list then list = {}; VoidQuestDB.heard[qid] = list end
    for _, c in ipairs(list) do
        -- everything must agree, the name too: otherwise a forged name could ride along on
        -- an honest second report
        if c.id == npcID and c.npc == name and c.m == mapID
            and math.abs(c.x - x) <= NEAR and math.abs(c.y - y) <= NEAR then
            c.t = time()                          -- still being reported: keep it
            if c.v[hash] then return false end   -- same player again
            if c.n >= VOTES_KEPT then return false end   -- settled
            c.v[hash] = true
            -- average the spots, so the pin settles on where people actually stand
            c.x = (c.x * c.n + x) / (c.n + 1)
            c.y = (c.y * c.n + y) / (c.n + 1)
            c.n = c.n + 1
            return c.n == CONFIRM
        end
    end
    if #list >= CANDIDATES then
        -- full: make room. First the weakest unconfirmed spot; when every spot is confirmed
        -- (two players can confirm a fake), the one nobody has reported for longest, if it's
        -- older than STALE -- so fakes can't fill a quest's list for good and lock out the
        -- real spot. Otherwise drop the report.
        local victim
        for i, c in ipairs(list) do
            if c.n < CONFIRM and (not victim or c.n < list[victim].n) then victim = i end
        end
        if not victim then
            for i, c in ipairs(list) do
                if time() - (c.t or 0) > STALE and (not victim or (c.t or 0) < (list[victim].t or 0)) then victim = i end
            end
        end
        if not victim then return false end
        table.remove(list, victim)
    end
    list[#list + 1] = { m = mapID, x = x, y = y, npc = name, id = npcID, n = 1, v = { [hash] = true }, t = time() }
    return false
end

local function takeEntries(mapID, body, sender)
    local hash, changed, n = senderHash(sender), false, 0
    for entry in body:gmatch("[^;]+") do
        n = n + 1
        if n > ENTRIES_MAX then break end
        local qs, ids, xs, ys, name = entry:match("^(%d%d?%d?%d?%d?%d?),(%d%d?%d?%d?%d?%d?%d?),(%d%d?%d?%d?),(%d%d?%d?%d?),(.+)$")
        local qid, npcID = tonumber(qs), tonumber(ids)
        name = cleanName(name)
        if qid and npcID and npcID > 0 and name and VQ.ForeverQuests[qid] then
            local x, y = tonumber(xs) / 10000, tonumber(ys) / 10000
            if x > 0 and x < 1 and y > 0 and y < 1 then
                -- your own find for this quest already wins; don't collect votes on it
                local own = VoidQuestDB.starts and VoidQuestDB.starts[qid]
                if not (own and own.how == "npc") and addReport(qid, npcID, mapID, x, y, name, hash) then
                    changed = true
                end
            end
        end
    end
    if changed then scheduleRefresh() end
end

----------------------------------------------------------------------
-- Quest-mob spots (the user, 2026-11-10: "if we see a quest mob in view can that translate to
-- the minimap for a dot and of course over time after 3 or 4 people find it at the same spot
-- its now concrete"). Addons get no mob positions, but a quest mob's nameplate means it's near
-- you, and QuestMobs.lua records where you stood (VoidQuestDB.seenMobs). New spots the shipped
-- data (NorgannonDB, ForeverSpawns) doesn't have go out like givers, held back the same way
-- (PRIVACY: 10-20 min, or once you've left the map):
--   M:1:mapID:npc,x,y,q;...   x/y = 0..999 (0.1% of the map), q = the quest it counted for, or 0
-- ~16-22 bytes an entry, up to FLUSH_MAX entries a tick to FANOUT members. A heard spot is used
-- once MOB_CONFIRM different players reported it within MOB_NEAR (averaged, so the dot settles
-- where mobs really are); a mob's link to a quest the shipped data doesn't know likewise.
-- VoidQuestDB.mobHeard[npc] = { s = { [map] = { { x, y, n, v = { [hash] = true }, t } } },
--                               q = { [questID] = { n, v } } }
-- VoidQuestDB.mobOut = { { npc, m, x, y, q, t, hold, sent }, ... }   your own, until a day after sent
-- tools/cmd/forever-mobs -crowd folds the confirmed spots into ForeverMobs.lua.
----------------------------------------------------------------------
local MOB_CONFIRM = 3      -- players that must agree before a heard spot / link is used
local MOB_NEAR    = 20     -- 0..999 units (2% of the map): reports this close are one spot
local MOB_SPOTS   = 6      -- spots kept per mob per map
local MOB_LINKS   = 3      -- quest links kept per mob
local MOB_MAX     = 2000   -- mobs kept
local MOB_OUT_MAX = 200
local mobTicker, mobCount

local function mobDB()
    VoidQuestDB.mobHeard = VoidQuestDB.mobHeard or {}
    VoidQuestDB.mobOut = VoidQuestDB.mobOut or {}
    if not mobCount then
        mobCount = 0
        for _ in pairs(VoidQuestDB.mobHeard) do mobCount = mobCount + 1 end
    end
    return VoidQuestDB.mobHeard, VoidQuestDB.mobOut
end

local function near(ax, ay, bx, by) return math.abs(ax - bx) <= MOB_NEAR and math.abs(ay - by) <= MOB_NEAR end

-- the shipped data already has this mob close to here
local function seedMobNear(npc, mapID, x, y)
    local s = VQ.ForeverSpawns and VQ.ForeverSpawns["n" .. npc]
    local pts = s and s[mapID]
    for i = 1, #(pts or "") - 5, 6 do
        local px, py = tonumber(pts:sub(i, i + 2)), tonumber(pts:sub(i + 3, i + 5))
        if px and py and near(px, py, x, y) then return true end
    end
    return false
end
local function seedLinks(npc, qid)
    for _, r in ipairs(VQ.ForeverMobs and VQ.ForeverMobs[qid] or {}) do
        if r[2] == "n" .. npc then return true end
    end
    return false
end

local function flushMobs()
    if not (enabled() and VoidQuestDB) then return end
    local _, out = mobDB()
    local here, now = C_Map.GetBestMapForUnit("player"), time()
    local byMap, due, waiting = {}, 0, 0
    for _, o in ipairs(out) do
        if not o.sent then
            if ((here and o.m ~= here) or now >= o.t + o.hold) and due < FLUSH_MAX then
                byMap[o.m] = byMap[o.m] or {}
                table.insert(byMap[o.m], o)
                due = due + 1
            else
                waiting = waiting + 1
            end
        end
    end
    if due == 0 then
        if waiting == 0 and mobTicker then mobTicker:Cancel(); mobTicker = nil end
        return
    end
    requestRoster()
    local targets = pick(FANOUT)
    if #targets == 0 then tally("nobody", "M"); return end   -- stays held: the next tick tries again
    if #queue > QUEUE_MAX / 2 then return end
    for m, list in pairs(byMap) do
        local entries = {}
        for _, o in ipairs(list) do
            entries[#entries + 1] = ("%d,%d,%d,%d"):format(o.npc, o.x, o.y, o.q or 0)
            o.sent = now
        end
        sendEntries("M", m, entries, targets)
    end
    for i = #out, 1, -1 do   -- what went out over a day ago: forget (it only kept us from resending)
        if out[i].sent and now - out[i].sent > 86400 then table.remove(out, i) end
    end
end

-- QuestMobs calls this with a NEW spot you saw a quest mob at (x/y 0..999), or a new quest link
-- at a spot. old = a sighting from before (backfill): not "where you are now", so it's fine
-- inside a dungeon (Sol review: a login in an instance skipped the whole backfill).
-- Returns "queued", "skip" (nothing new / sharing off) or "full" (200 unsent already: nothing
-- unsent is ever pushed out; Sol review: a big backfill dropped its own entries).
function Share:FoundMob(npc, mapID, x, y, qid, old)
    if not (enabled() and VoidQuestDB and npc and mapID and x and y) then return "skip" end
    if not old and IsInInstance() then return "skip" end
    qid = qid or 0
    -- only gaps: a spot the shipped data has, for a quest it links (or no quest), is nothing new
    if (qid == 0 or seedLinks(npc, qid)) and seedMobNear(npc, mapID, x, y) then return "skip" end
    local _, out = mobDB()
    for _, o in ipairs(out) do
        if o.npc == npc and o.m == mapID and (o.q or 0) == qid and near(o.x, o.y, x, y) then return "skip" end
    end
    if #out >= MOB_OUT_MAX then
        local oldest
        for i, o in ipairs(out) do
            if o.sent and (not oldest or o.sent < out[oldest].sent) then oldest = i end
        end
        if not oldest then return "full" end
        table.remove(out, oldest)
    end
    out[#out + 1] = { npc = npc, m = mapID, x = x, y = y, q = qid ~= 0 and qid or nil, t = time(),
                      hold = HOLD_MIN + math.random() * HOLD_SPREAD }
    if not mobTicker then mobTicker = C_Timer.NewTicker(60, flushMobs) end
    return "queued"
end

-- one vote per player; full lists make room by dropping the weakest unconfirmed entry, else one
-- nobody reported for STALE (two players could confirm a fake; it mustn't block the real one)
local function vote(c, hash)
    if c.v[hash] or c.n >= VOTES_KEPT then return false end
    c.v[hash], c.n = true, c.n + 1
    return c.n == MOB_CONFIRM
end
local function makeRoom(list, isArray)
    local victimK
    for k, c in pairs(list) do
        if c.n < MOB_CONFIRM and (not victimK or c.n < list[victimK].n) then victimK = k end
    end
    if not victimK then
        for k, c in pairs(list) do
            if time() - (c.t or 0) > STALE and (not victimK or (c.t or 0) < (list[victimK].t or 0)) then victimK = k end
        end
    end
    if not victimK then return false end
    if isArray then table.remove(list, victimK) else list[victimK] = nil end
    return true
end

-- The store is full: drop a mob nobody confirmed (oldest first), else one nobody reported for
-- STALE. One sender inventing 2,000 mobs could otherwise lock real ones out for good; its fakes
-- never get a second voter, so they're always the ones to go (Sol review).
local function evictMob(heard)
    local victim, victimT
    local function confirmed(mob)
        for _, list in pairs(mob.s or {}) do
            for _, c in ipairs(list) do if c.n >= MOB_CONFIRM then return true end end
        end
        for _, l in pairs(mob.q or {}) do if l.n >= MOB_CONFIRM then return true end end
        return false
    end
    for npc, mob in pairs(heard) do
        if not confirmed(mob) and (not victim or (mob.t or 0) < victimT) then victim, victimT = npc, mob.t or 0 end
    end
    if not victim then
        for npc, mob in pairs(heard) do
            if time() - (mob.t or 0) > STALE and (not victim or (mob.t or 0) < victimT) then victim, victimT = npc, mob.t or 0 end
        end
    end
    if not victim then return false end
    heard[victim] = nil
    mobCount = mobCount - 1
    return true
end

local function takeMobs(mapID, body, sender)
    local heard = mobDB()
    local hash, n, changed = senderHash(sender), 0, false
    for entry in body:gmatch("[^;]+") do
        n = n + 1
        if n > ENTRIES_MAX then break end
        local ns, xs, ys, qs = entry:match("^(%d%d?%d?%d?%d?%d?%d?),(%d%d?%d?),(%d%d?%d?),(%d%d?%d?%d?%d?%d?)$")
        local npc, x, y, q = tonumber(ns), tonumber(xs), tonumber(ys), tonumber(qs)
        if npc and npc > 0 and x and y and x > 0 and y > 0 and x < 1000 and y < 1000 then
            if q == 0 or not VQ.ForeverQuests[q] then q = nil end
            local mob = heard[npc]
            if not mob then
                if mobCount >= MOB_MAX and not evictMob(heard) then tally("dropped", "mobs full"); break end
                mob = { s = {}, q = {} }
                heard[npc] = mob
                mobCount = mobCount + 1
            end
            mob.t = time()   -- last reported (eviction goes by it)
            local list = mob.s[mapID] or {}
            mob.s[mapID] = list
            local hit
            for _, c in ipairs(list) do if near(c.x, c.y, x, y) then hit = c; break end end
            if hit then
                hit.t = time()
                local was = hit.n
                if vote(hit, hash) then changed = true end
                if hit.n > was then   -- average: the dot settles where the mobs are
                    hit.x = math.floor((hit.x * was + x) / hit.n + 0.5)
                    hit.y = math.floor((hit.y * was + y) / hit.n + 0.5)
                end
            elseif #list < MOB_SPOTS or makeRoom(list, true) then
                list[#list + 1] = { x = x, y = y, n = 1, v = { [hash] = true }, t = time() }
            end
            if q and not seedLinks(npc, q) then
                local l = mob.q[q]
                if not l then
                    local count = 0
                    for _ in pairs(mob.q) do count = count + 1 end
                    if count < MOB_LINKS or makeRoom(mob.q, false) then
                        l = { n = 0, v = {}, t = time() }
                        mob.q[q] = l
                    end
                end
                if l then
                    l.t = time()
                    if vote(l, hash) then changed = true end
                end
            end
        end
    end
    if changed and VQ.Mobs and VQ.Mobs.Refresh then VQ.Mobs:Refresh() end
end

-- Confirmed crowd spots for a mob on a map, as "xxxyyy..." (like ForeverSpawns), or "".
function Share:MobPts(npc, mapID)
    local mob = VoidQuestDB and VoidQuestDB.mobHeard and VoidQuestDB.mobHeard[npc]
    local list = mob and mob.s and mob.s[mapID]
    if not list then return "" end
    local out = {}
    for _, c in ipairs(list) do
        if c.n >= MOB_CONFIRM then out[#out + 1] = ("%03d%03d"):format(c.x, c.y) end
    end
    return table.concat(out)
end

-- Mobs players confirmed count for a quest the shipped data doesn't link them to, with
-- confirmed spots on this map: { [npc] = "xxxyyy..." }.
function Share:MobsForQuest(qid, mapID)
    local out = {}
    for npc, mob in pairs(VoidQuestDB and VoidQuestDB.mobHeard or {}) do
        local l = mob.q and mob.q[qid]
        if l and l.n >= MOB_CONFIRM then
            local pts = self:MobPts(npc, mapID)
            if pts ~= "" then out[npc] = pts end
        end
    end
    return out
end

function Share:MobStats()
    local mobs, spots, confirmed, mine, sent = 0, 0, 0, 0, 0
    for _, mob in pairs(VoidQuestDB and VoidQuestDB.mobHeard or {}) do
        mobs = mobs + 1
        for _, list in pairs(mob.s or {}) do
            for _, c in ipairs(list) do
                spots = spots + 1
                if c.n >= MOB_CONFIRM then confirmed = confirmed + 1 end
            end
        end
    end
    for _, o in ipairs(VoidQuestDB and VoidQuestDB.mobOut or {}) do
        mine = mine + 1
        if o.sent then sent = sent + 1 end
    end
    return mobs, spots, confirmed, mine, sent
end

-- Once: sightings recorded before sharing existed (VoidQuestDB.seenMobs) go out like new ones,
-- quest mobs only (a quest's objective said so, or the shipped data lists the mob for a quest),
-- quest titles mapped to IDs by Forever's quest list (unique titles only). FoundMob's own rules
-- apply: only what the shipped data lacks, held back, not twice.
function Share:BackfillMobs()
    if not (enabled() and VoidQuestDB and VoidQuestDB.seenMobs) or VoidQuestDB.mobBackfilled then return end
    local byTitle, dup = {}, {}
    for q, r in pairs(VQ.ForeverQuests) do
        local t = type(r) == "table" and r[1]
        if t then
            if byTitle[t] then dup[t] = true else byTitle[t] = q end
        end
    end
    local quest = {}
    for _, refs in pairs(VQ.ForeverMobs or {}) do
        for _, r in ipairs(refs) do
            local id = tonumber(r[2]:match("^n(%d+)$"))
            if id then quest[id] = true end
        end
    end
    local n, full = 0, false
    VoidQuestDB.mobBackDone = VoidQuestDB.mobBackDone or {}
    local done = VoidQuestDB.mobBackDone
    for npc, s in pairs(VoidQuestDB.seenMobs) do
        local qids = {}
        for title in pairs(type(s) == "table" and s.q or {}) do
            local q = not dup[title] and byTitle[title]
            if q then qids[#qids + 1] = q end
        end
        if type(npc) == "number" and type(s) == "table" and (#qids > 0 or quest[npc]) then
            for map, pts in pairs(s.m or {}) do
                for i = 1, #pts - 5, 6 do
                    local x, y = tonumber(pts:sub(i, i + 2)), tonumber(pts:sub(i + 3, i + 5))
                    if x and y then
                        -- each one handled once, across retries (Sol review: a retry from the top
                        -- could requeue the first batch forever and starve the rest)
                        for _, q in ipairs(#qids == 0 and { 0 } or qids) do
                            local key = npc .. ":" .. map .. ":" .. x .. ":" .. y .. ":" .. q
                            if not done[key] then
                                if self:FoundMob(npc, map, x, y, q, true) == "full" then full = true else done[key] = true end
                            end
                        end
                        n = n + 1
                    end
                end
            end
        end
    end
    -- the queue filled up: try again next login (what went in stays; nothing is queued twice)
    if not full then VoidQuestDB.mobBackfilled, VoidQuestDB.mobBackDone = true, nil end
    return n
end

function Share:RestoreMobs()
    if not (enabled() and VoidQuestDB) then return end
    for _, o in ipairs(VoidQuestDB.mobOut or {}) do
        if not o.sent then
            if not mobTicker then mobTicker = C_Timer.NewTicker(60, flushMobs) end
            return
        end
    end
end

----------------------------------------------------------------------
-- Quest facts (the user, 2026-11-09: "we need to be collecting as much of this data as
-- possible to validate or add to ... this is something that should be sent over the
-- voidquest channel"). What the game itself shows and pays, where it differs from what
-- VoidQuest ships (Blizzard's quest API has no rewards for many quests: A Vengeful Fate
-- offers four, the API lists none):
--   F:1:questID:i=id.id.id   the reward + choice items the quest window shows (sorted)
--   F:1:questID:p=fid.amt.fid.amt   reputation the turn-in really paid (from chat)
-- 20-60 bytes, sent only when it differs from the shipped data, held back like givers
-- (10-20 min: it shows a quest you were just at), whispered to FANOUT members. A fact is
-- used once CONFIRM different players reported the exact same value. Humans aren't asked
-- for reputation (Diplomacy: +10%, it would never agree with anyone else's).
-- VoidQuestDB.facts = { own = { [q] = { i=, p=, t=, sent = { i=, p= } } },
--                       heard = { [q] = { i = { [value] = { n, v = { [hash] = true } } }, p = ... } } }
-- tools/cmd/forever-quests -facts folds the confirmed ones into ForeverQuests.lua.
----------------------------------------------------------------------
local FACT_VALUES = 3     -- different values kept per quest and field
-- i / p: rewards and reputation (above). e / w: escorts (EscortWatch.lua, 2026-11-11, the user:
-- "we also need to collect that data from people actually doing the quests to validate"):
--   e=1   the game showed it's an escort-type quest (a group member's escort-start prompt, or
--         it failed with no time limit)
--   w=N   how long the giver took to show up for someone standing at the spot, in minutes,
--         bucketed 0 (there) / 2 / 5 / 10 / 15 (15 or more)
-- m / x: how players really do the quest (QuestTime.lua, 2026-11-11, the user approving the
-- Questie list: "time per quest -> XP/hour", "quests players give up on"):
--   m=N   minutes it took a solo player within 2 levels of the quest from taking it to finishing it, bucketed 2 / 5 / 10 /
--         15 / 20 / 30 / 45 / 60 (60 or more)
--   x=1   a player gave up on it: abandoned after 10+ minutes of work, unfinished, not grey
-- None of these has a shipped value to differ from, so they're always shared. (Not "t": a
-- quest's own record already uses t, hold and sent for its bookkeeping.)
local FACT_FIELDS = { "i", "p", "e", "w", "m", "x" }
local WAIT_BUCKETS = { ["0"] = true, ["2"] = true, ["5"] = true, ["10"] = true, ["15"] = true }
local TIME_BUCKETS = { ["2"] = true, ["5"] = true, ["10"] = true, ["15"] = true, ["20"] = true, ["30"] = true, ["45"] = true, ["60"] = true }
local function facts()
    VoidQuestDB.facts = VoidQuestDB.facts or { own = {}, heard = {} }
    local f = VoidQuestDB.facts
    f.own, f.heard = f.own or {}, f.heard or {}
    return f
end

-- the shipped value, in the same form, to compare with
local function shippedFact(qid, field)
    local r = VQ.ForeverQuests[qid]
    if not r or (field ~= "i" and field ~= "p") then return nil end
    local out = {}
    if field == "i" then
        for s in (r[11] or ""):gmatch("%d+") do out[#out + 1] = tonumber(s) end
        table.sort(out)
        return table.concat(out, ".")
    end
    local pairsT = {}
    for fid, v in (r[12] or ""):gmatch("(%d+):(%d+)") do pairsT[#pairsT + 1] = { tonumber(fid), tonumber(v) } end
    table.sort(pairsT, function(a, b) return a[1] < b[1] end)
    for _, p in ipairs(pairsT) do out[#out + 1] = p[1] .. "." .. p[2] end
    return table.concat(out, ".")
end

local factTicker
local function anyUnsent(f)
    for _, e in pairs(f.own) do
        local sent = e.sent or {}
        for _, k in ipairs(FACT_FIELDS) do if e[k] and not sent[k] then return true end end
    end
    return false
end
local function flushFacts()
    if not enabled() or not VoidQuestDB then return end
    local f, now, due = facts(), time(), {}
    for q, e in pairs(f.own) do
        e.sent = e.sent or {}
        for _, field in ipairs(FACT_FIELDS) do
            if e[field] and not e.sent[field] and now >= (e.t or 0) + (e.hold or HOLD_MIN) and #due < FLUSH_MAX then
                due[#due + 1] = { q, field, e[field] }
            end
        end
    end
    -- stop only when nothing is left to send (still-held facts keep the ticker: Codex review)
    if #due == 0 then
        if factTicker and not anyUnsent(f) then factTicker:Cancel(); factTicker = nil end
        return
    end
    requestRoster()
    local targets = pick(FANOUT)
    if #targets == 0 then tally("nobody", "F"); return end
    if #queue > QUEUE_MAX / 2 then return end
    for _, d in ipairs(due) do
        local msg = ("F:%s:%d:%s=%s"):format(PROTO, d[1], d[2], d[3])
        if #msg <= MAX_LEN then
            for _, to in ipairs(targets) do send(msg, to) end
        end
        f.own[d[1]].sent[d[2]] = true
    end
end
local function startFactTicker()
    if enabled() and not factTicker then factTicker = C_Timer.NewTicker(60, flushFacts) end
end

-- Note one of your own observations; shared only when it differs from the shipped data.
local function noteFact(qid, field, value)
    if not (qid and VQ.ForeverQuests[qid] and value and value ~= "") then return end
    local f = facts()
    local e = f.own[qid]
    if value == shippedFact(qid, field) then
        -- the game agrees with the shipped data: forget an earlier different reading (Codex review)
        if e and e[field] then
            e[field] = nil
            if e.sent then e.sent[field] = nil end
            local any = false
            for _, k in ipairs(FACT_FIELDS) do if e[k] then any = true end end
            if not any then f.own[qid] = nil end
        end
        return
    end
    e = e or {}
    f.own[qid] = e
    if e[field] == value then startFactTicker(); return end
    e[field], e.t = value, time()
    e.hold = HOLD_MIN + math.random() * HOLD_SPREAD
    e.sent = e.sent or {}
    e.sent[field] = nil
    startFactTicker()
end

-- The quest window's rewards (offer and turn-in). Only a complete list counts: every reward
-- the window has must give its item ID, else try again a little later (Codex review).
local function factWindow(qid, tries)
    if not qid or qid == 0 or (GetQuestID and GetQuestID()) ~= qid then return end   -- window moved on
    local ids, missing = {}, false
    for _, kind in ipairs({ "reward", "choice" }) do
        local n = (kind == "reward" and GetNumQuestRewards and GetNumQuestRewards())
            or (kind == "choice" and GetNumQuestChoices and GetNumQuestChoices()) or 0
        for i = 1, n do
            local link = GetQuestItemLink and GetQuestItemLink(kind, i)
            local id = link and C_Item.GetItemInfoInstant(link)
            if id then ids[#ids + 1] = id else missing = true end
        end
    end
    if missing then
        if (tries or 0) < 4 then C_Timer.After(0.5, function() pcall(factWindow, qid, (tries or 0) + 1) end) end
        return
    end
    if #ids == 0 then return end   -- progress page, or nothing to give: says nothing
    table.sort(ids)
    noteFact(qid, "i", table.concat(ids, "."))
end

-- The reputation a turn-in really paid: its chat lines come right with the turn-in, so only
-- lines in the next second count (a mob kill a few seconds later is not the quest's), and when
-- the shipped data names the quest's factions, only those (Codex review).
local REP_WINDOW = 1.0
local REP_FMT = (FACTION_STANDING_INCREASED or "Reputation with %s increased by %d.")
    :gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
local turnIn   -- { qid, at, got = { [fid] = amount } }
local factionID
local function finishTurnIn(t)
    if not t or t.done then return end
    t.done = true
    local list = {}
    for fid, v in pairs(t.got) do list[#list + 1] = { fid, v } end
    if #list == 0 then return end
    table.sort(list, function(a, b) return a[1] < b[1] end)
    local out = {}
    for _, p in ipairs(list) do out[#out + 1] = p[1] .. "." .. p[2] end
    noteFact(t.qid, "p", table.concat(out, "."))
end
local function repLine(msg)
    if not turnIn or turnIn.done or GetTime() - turnIn.at > REP_WINDOW or type(msg) ~= "string"
        or (issecretvalue and issecretvalue(msg)) then return end
    local name, amt = msg:match("^" .. REP_FMT .. "$")
    if not name then name, amt = msg:match("^Reputation with (.+) increased by (%d+)%.$") end
    if not name then name, amt = msg:match("^Your (.+) reputation has increased by (%d+)%.$") end
    if not (name and amt) then return end
    if not factionID then
        factionID = {}
        for id, n in pairs(VQ.ForeverFactions or {}) do factionID[n] = id end
    end
    local fid = factionID[name]
    if not fid then return end
    local r = VQ.ForeverQuests[turnIn.qid]
    local shipped = r and r[12] or ""
    if shipped:find("%d") and not ("," .. shipped):find("," .. fid .. ":", 1, true) then return end
    turnIn.got[fid] = tonumber(amt)
end
local function onTurnIn(qid)
    local _, race = UnitRace("player")
    if race == "Human" then return end   -- Diplomacy changes every amount
    finishTurnIn(turnIn)   -- a quick second turn-in: keep what the first one got (Codex review)
    local t = { qid = qid, at = GetTime(), got = {} }
    turnIn = t
    C_Timer.After(REP_WINDOW + 0.5, function() finishTurnIn(t) end)
end

-- Someone else's fact (untrusted): strict format, real quest, counted per player. A player
-- gets ONE vote per quest and field, whatever value (Codex review: one sender sending three
-- values could otherwise fill every slot); a full list makes room by dropping a value only
-- one player backs.
local function takeFact(qid, body, sender)
    local field, value = body:match("^([ipewmx])=([%d%.]+)$")
    if not field or #value > 120 or not VQ.ForeverQuests[qid] then tally("dropped", "fact"); return end
    if ((field == "e" or field == "x") and value ~= "1") or (field == "w" and not WAIT_BUCKETS[value])
        or (field == "m" and not TIME_BUCKETS[value]) then tally("dropped", "fact"); return end
    local n = 0
    for _ in value:gmatch("%d+") do n = n + 1 end
    local single = field == "e" or field == "w" or field == "m" or field == "x"
    if n == 0 or n > 16 or (field == "p" and n % 2 ~= 0) or (single and n ~= 1) then tally("dropped", "fact"); return end
    local f = facts()
    local q = f.heard[qid] or {}
    f.heard[qid] = q
    local voters = q[field .. "v"] or {}
    q[field .. "v"] = voters
    local h = senderHash(sender)
    if voters[h] then return end   -- this player already voted on this quest's field
    local byVal = q[field] or {}
    q[field] = byVal
    local c = byVal[value]
    if not c then
        local count, weakest = 0, nil
        for v, cc in pairs(byVal) do
            count = count + 1
            if cc.n < CONFIRM and (not weakest or cc.n < byVal[weakest].n) then weakest = v end
        end
        if count >= FACT_VALUES then
            if not weakest then return end   -- every value is backed by 2+ players: keep them
            byVal[weakest] = nil
        end
        c = { n = 0, v = {} }
        byVal[value] = c
    end
    if c.n >= VOTES_KEPT then return end
    voters[h] = true
    c.v[h], c.n = true, c.n + 1
end

-- EscortWatch's observations go out the same way (held 10-20 min, then to FANOUT members).
function Share:NoteFact(qid, field, value)
    if field ~= "e" and field ~= "w" and field ~= "m" and field ~= "x" then return end
    if (field == "w" and not WAIT_BUCKETS[value]) or (field == "m" and not TIME_BUCKETS[value])
        or ((field == "e" or field == "x") and value ~= "1") then return end
    noteFact(qid, field, value)
end

-- A fact's value: your own observation, else the one most players back (CONFIRM or more).
function Share:FactValue(qid, field)
    local f = VoidQuestDB and VoidQuestDB.facts
    if not f then return nil end
    local own = f.own and f.own[qid]
    if own and own[field] then return own[field], true end
    local q = f.heard and f.heard[qid]
    local best, bestN
    for v, c in pairs(q and q[field] or {}) do
        if type(c) == "table" and c.n and c.n >= CONFIRM and (not bestN or c.n > bestN) then best, bestN = v, c.n end
    end
    return best, false, bestN
end

-- The reward items for a quest: your own observation, else a value CONFIRM players agree on.
function Share:FactItems(qid)
    local f = VoidQuestDB and VoidQuestDB.facts
    if not f then return nil end
    local own = f.own and f.own[qid]
    if own and own.i then return (own.i:gsub("%.", ",")) end
    local q = f.heard and f.heard[qid]
    local best, bestN
    for v, c in pairs(q and q.i or {}) do
        if type(c) == "table" and c.n and c.n >= CONFIRM and (not bestN or c.n > bestN) then best, bestN = v, c.n end
    end
    return best and (best:gsub("%.", ",")) or nil
end

-- sender = canon(name); replyTo = the name to whisper back (as the game gave it)
function Share:OnMessage(msg, sender, replyTo)
    if type(msg) ~= "string" or type(sender) ~= "string" then return end
    local nonce = msg:match("^PING:(.+)$")
    if nonce then
        if sender == me and nonce == pingNonce then pingGot = true end
        return
    end
    -- GroupUp self-test (/vq group test): your own whispers play the other player
    if sender == me and enabled() and VQ.GroupUp and VQ.GroupUp.testing and msg:match("^G%u:") then
        pcall(VQ.GroupUp.OnMessage, VQ.GroupUp, msg, sender, replyTo)
        return
    end
    if not enabled() or sender == me or not VoidQuestDB then return end
    tally("got", msg)
    if not rateOK(sender) then tally("dropped", "rate"); return end
    -- group asks (GroupUp.lua): GQ / GH / GA / GY / GN
    if msg:match("^G%u:") then
        if VQ.GroupUp then pcall(VQ.GroupUp.OnMessage, VQ.GroupUp, msg, sender, replyTo) end
        return
    end
    -- quest facts carry a quest ID where the others carry a map
    local fp, fq, fbody = msg:match("^F:(%d+):(%d+):(.+)$")
    if fp then
        if fp ~= PROTO then tally("dropped", "proto"); return end
        takeFact(tonumber(fq), fbody, sender)
        return
    end
    local tag, proto, mapS, body = msg:match("^(%a):(%d+):(%d+):?(.*)$")
    if proto ~= PROTO then tally("dropped", "proto"); return end
    local mapID = tonumber(mapS)
    if not validMap(mapID) then tally("dropped", "map"); return end
    Share.heardMsgs = Share.heardMsgs + 1
    local h = senderHash(sender)
    if not Share.heardFrom[h] and Share.heardFromN < HEARD_FROM_MAX then
        Share.heardFrom[h] = true
        Share.heardFromN = Share.heardFromN + 1
    end
    if tag == "Q" and body == "" then
        -- answer this player about this map once per REPLY_CD, and only with something to say
        -- and one answer per player per REPLY_GAP across all maps (no amplification)
        local key, now = sender .. ":" .. mapID, GetTime()
        if lastReply[key] and now - lastReply[key] < REPLY_CD then return end
        if lastReplyTo[sender] and now - lastReplyTo[sender] < REPLY_GAP then return end
        -- and one answer to anyone every ANSWER_EVERY seconds, so answers can't fill the
        -- queue and crowd out your own finds
        if lastAnyReply and now - lastAnyReply < ANSWER_EVERY then return end
        local own = ownOn(mapID)
        if #own == 0 or not replyTo then tally("unanswered", "nothing new"); return end
        lastReply[key], lastReplyTo[sender], lastAnyReply = now, now, now
        local gen = Share.gen
        C_Timer.After(1 + math.random() * 3, function()
            -- not if sharing was turned off in the meantime (even if it's back on)
            if enabled() and Share.gen == gen then sendEntries("B", mapID, own, { replyTo }) end
        end)
    elseif tag == "B" or tag == "N" then
        takeEntries(mapID, body, sender)
    elseif tag == "M" then
        takeMobs(mapID, body, sender)
    end
end

----------------------------------------------------------------------
-- Lookups for QuestStarts: the best confirmed spot for a quest, or nil.
----------------------------------------------------------------------
function Share:Best(qid)
    local list = VoidQuestDB and VoidQuestDB.heard and VoidQuestDB.heard[qid]
    local best
    for _, c in ipairs(list or {}) do
        if c.n >= CONFIRM and (not best or c.n > best.n) then best = c end
    end
    return best
end

----------------------------------------------------------------------
-- Channel join (member list only) + zone catch-up
----------------------------------------------------------------------
-- Joining is blocked in combat and during the chat lockdown (encounters): wait, then retry.
local function chatLocked()
    if InCombatLockdown() then return true end
    local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
    if not f then return false end
    local ok, v = pcall(f)
    if not ok then return true end
    if issecretvalue and issecretvalue(v) then return true end
    return v == true
end
local joinRetry = CreateFrame("Frame")
joinRetry:SetScript("OnEvent", function(self)
    if chatLocked() then return end
    self:UnregisterAllEvents()
    Share:JoinNet()
end)

function Share:JoinNet()
    if not enabled() then return end
    -- out of the old channels first, so their slots are free for the new one (Codex review).
    -- A banned one can't be left; it goes at logout.
    if not chatLocked() then
        for _, old in ipairs(OLD_CHANNELS) do
            if (GetChannelName(old) or 0) > 0 then LeaveChannelByName(old) end
        end
    end
    if not netIndex() then
        if chatLocked() then
            joinRetry:RegisterEvent("PLAYER_REGEN_ENABLED")
            joinRetry:RegisterEvent("ZONE_CHANGED_NEW_AREA")
            joinRetry:RegisterEvent("ENCOUNTER_END")
            -- fires when a chat / addon restriction lifts (PvP match end, ...): Codex review
            pcall(joinRetry.RegisterEvent, joinRetry, "ADDON_RESTRICTION_STATE_CHANGED")
            return
        end
        JoinTemporaryChannel(CHANNEL_NAME, CHANNEL_PW)
        C_Timer.After(5, publish)   -- a refused join shows as "blocked"
    end
    if netIndex() and ChatFrame_RemoveChannel then   -- keep it out of the chat tabs
        for i = 1, (NUM_CHAT_WINDOWS or 10) do
            local cf = _G["ChatFrame" .. i]
            if cf then ChatFrame_RemoveChannel(cf, CHANNEL_NAME) end
        end
    end
end

local function askHere()
    if IsInInstance() then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    if mapID then Share:Ask(mapID) end
end

-- Finds still within their hold (found before a /reload, or while sharing was off): hold
-- them for the rest of their time, then send.
function Share:RestoreHeld()
    if not enabled() then return end
    for q, s in pairs(VoidQuestDB and VoidQuestDB.starts or {}) do
        if type(q) == "number" and type(s) == "table" and shareable(s) and fresh(s) and not pending[q] then
            pending[q] = GetTime() + math.max(60, HOLD_MAX - (time() - s.t))
        end
    end
    if next(pending) and not pendingTicker then pendingTicker = C_Timer.NewTicker(60, flush) end
end

function Share:Apply()
    if enabled() then
        self:JoinNet()
        self:RestoreHeld()
        self:RestoreMobs()
        C_Timer.After(3, askHere)
    else
        -- off means off: nothing queued, held or scheduled goes out any more
        Share.gen = Share.gen + 1
        wipe(queue)
        wipe(pending)
        if sending then sending:Cancel(); sending = nil end
        if pendingTicker then pendingTicker:Cancel(); pendingTicker = nil end
        -- held mob spots too: dropped, not sent later
        if mobTicker then mobTicker:Cancel(); mobTicker = nil end
        local out = VoidQuestDB and VoidQuestDB.mobOut
        for i = #(out or {}), 1, -1 do if not out[i].sent then table.remove(out, i) end end
        if netIndex() then LeaveChannelByName(CHANNEL_NAME) end
    end
    publish()
end

-- Players box: count now when it's turned on, and every 10 minutes while it's shown.
local function recount()
    if not (enabled() and _G.VoidPresence and VoidPresence:IsShown()) then return end
    publish()   -- a blocked channel is never read, so say so now
    rosterAt = -ROSTER_EVERY
    requestRoster()
end

-- A member who logged off between the roster read and our whisper makes the game print
-- "No player named X is currently playing." Hide that line for names we just whispered.
-- That line for a name we whispered in the last 30 s: returns the name (lowercased).
local function bouncedName(text)
    -- system lines can arrive as secret text (chat lockdown): never index those
    if type(text) ~= "string" or (issecretvalue and issecretvalue(text)) or not ERR_CHAT_PLAYER_NOT_FOUND_S then return nil end
    for name, t in pairs(whispered) do
        if GetTime() - t < 30 and text:lower() == ERR_CHAT_PLAYER_NOT_FOUND_S:format(name):lower() then
            return name
        end
    end
end
local function hideOfflineNotice(_, _, text) return bouncedName(text) ~= nil end

function Share:Init()
    local today
    CHANNEL_NAME, CHANNEL_PW, today = dailyChannel()   -- again now that the server time is surely in
    -- channels survive a /reload: yesterday's goes too (reload across 00:00 UTC, Codex)
    table.insert(OLD_CHANNELS, (dailyChannel(today - 1)))
    -- and the old both-factions channels (0.3.19 and older), today's and yesterday's
    table.insert(OLD_CHANNELS, (dailyChannel(today, true)))
    table.insert(OLD_CHANNELS, (dailyChannel(today - 1, true)))
    me = canon(GetUnitName and GetUnitName("player") or UnitName("player"))
    -- offline marks: this session only, never saved (the user, 2026-11-09: "get rid of the offline
    -- list"); the old saved list is deleted
    VoidQuestDB = VoidQuestDB or {}
    VoidQuestDB.netOffline = nil
    unreach = {}
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    end
    local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if addFilter then addFilter("CHAT_MSG_SYSTEM", hideOfflineNotice) end
    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:RegisterEvent("CHANNEL_ROSTER_UPDATE")
    f:RegisterEvent("CHAT_MSG_SYSTEM")
    f:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
    f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    f:RegisterEvent("ZONE_CHANGED")
    -- quest facts: the quest window's rewards, and the reputation a turn-in really paid
    f:RegisterEvent("QUEST_DETAIL")
    f:RegisterEvent("QUEST_COMPLETE")
    f:RegisterEvent("QUEST_TURNED_IN")
    f:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
    f:SetScript("OnEvent", function(_, event, prefix, msg, channel, sender, _, _, localID, _, base)
        if event == "QUEST_DETAIL" or event == "QUEST_COMPLETE" then
            local qid = GetQuestID and GetQuestID()   -- snapshot now: the window may move on
            C_Timer.After(0.2, function() pcall(factWindow, qid) end)
            return
        elseif event == "QUEST_TURNED_IN" then
            if type(prefix) == "number" then pcall(onTurnIn, prefix) end   -- arg1 = questID
            return
        elseif event == "CHAT_MSG_COMBAT_FACTION_CHANGE" then
            pcall(repLine, prefix)   -- arg1 = the message text
            return
        end
        if event == "CHAT_MSG_CHANNEL_NOTICE" then
            -- arg1 = notice, arg4 = "6. Name", arg9 = Name. A refused join names the channel
            -- (WRONG_PASSWORD / BANNED); NOT_ALLOWED_IN_CHANNEL doesn't, blocked() sees that one.
            local notice, full = prefix, sender
            if type(notice) ~= "string" or (issecretvalue and (issecretvalue(notice) or issecretvalue(full) or issecretvalue(base))) then return end
            local name = type(base) == "string" and base ~= "" and base
                or type(full) == "string" and full:match("^%d+%.%s*(.+)$") or full
            if type(name) ~= "string" or name:lower() ~= CHANNEL_NAME:lower() then return end
            if notice == "WRONG_PASSWORD" or notice == "BANNED" then
                refusedAs = notice; publish()
            elseif notice == "YOU_JOINED" or notice == "YOU_CHANGED" then
                refusedAs = nil
            end
        elseif event == "CHAT_MSG_SYSTEM" then   -- our whisper bounced: unreachable for a while
            local name = bouncedName(prefix)  -- arg1 = the message text
            -- counted (2026-11-10: the "2 online" were on the channel but every whisper bounced,
            -- likely the other faction; nothing showed it)
            if name then unreach[name] = time(); tally("offline", "whisper"); publish() end
        elseif event == "CHAT_MSG_ADDON" then
            if prefix ~= PREFIX or type(sender) ~= "string" or sender == "" then return end
            -- whispers; or our channel, should Blizzard let channel addon messages through again
            local idx = netIndex()
            if channel == "WHISPER" then
                Share:OnMessage(msg, canon(sender), sender)
            elseif channel == "CHANNEL" and idx and localID == idx then
                Share:OnMessage(msg, canon(sender), sender)
            end
        elseif event == "CHANNEL_ROSTER_UPDATE" then
            if prefix == displayIndex() then readRoster() end   -- arg1 = the channel's display index
        else
            flush()   -- finds from the map you just left go out now
            askHere()
        end
    end)
    if _G.VoidPresence then
        VoidPresence:Listen(recount)
        C_Timer.NewTicker(600, recount)
        publish()   -- "—" until the member list is read
    end
    Share:RestoreHeld()
    Share:RestoreMobs()   -- mob spots still held from before a /reload
    C_Timer.After(30, function() pcall(Share.BackfillMobs, Share) end)   -- once: sightings from before sharing
    -- facts still waiting from before a /reload
    for _, e in pairs(VoidQuestDB.facts and VoidQuestDB.facts.own or {}) do
        if (e.i and not (e.sent and e.sent.i)) or (e.p and not (e.sent and e.sent.p)) then
            startFactTicker()
            break
        end
    end
    -- the chat/channel system needs a few seconds after login
    C_Timer.After(10, function()
        Share:JoinNet()
        C_Timer.After(3, function() requestRoster(); C_Timer.After(3, askHere) end)
    end)
    -- at 00:00 UTC everyone moves to the new day's channel together
    C_Timer.NewTicker(60, function()
        local name, pw = dailyChannel()
        if name == CHANNEL_NAME then return end
        local old = CHANNEL_NAME
        CHANNEL_NAME, CHANNEL_PW = name, pw
        memberCount, roster, rosterAt, refusedAs = nil, {}, -ROSTER_EVERY, nil
        table.insert(OLD_CHANNELS, old)   -- JoinNet leaves it (now, or once chat unlocks)
        publish()   -- "—" until the new list is read
        if not enabled() then
            if (GetChannelName(old) or 0) > 0 and not chatLocked() then LeaveChannelByName(old) end
            return
        end
        C_Timer.After(5 + math.random() * 3, function()   -- after VoidGather / VoidSweep move
            Share:JoinNet()
            C_Timer.After(3, requestRoster)
        end)
    end)
end

----------------------------------------------------------------------
-- /vq net: a whisper to yourself comes back, which proves addon messages get through;
-- also says how many other VoidQuest players are online and how much has come in.
----------------------------------------------------------------------
function Share:Stats()
    local quests, confirmed = 0, 0
    for q in pairs(VoidQuestDB and VoidQuestDB.heard or {}) do
        quests = quests + 1
        if self:Best(q) then confirmed = confirmed + 1 end
    end
    local players = self.heardFromN
    local why = blockReason()
    if why then VQ:Print("|cffff5555" .. why .. "|r") end
    VQ:Print(("%d other VoidQuest player%s online. Shared quest givers: %d quest%s heard about, %d confirmed by 2+ players. This session: %d message%s from %d player%s."):format(
        #roster, #roster == 1 and "" or "s",
        quests, quests == 1 and "" or "s", confirmed, self.heardMsgs, self.heardMsgs == 1 and "" or "s",
        players, players == 1 and "" or "s"))
    -- quest facts: your own observations that differ from the shipped data, and other players'
    local fo, fs, fh, fc = 0, 0, 0, 0
    local fdb = VoidQuestDB and VoidQuestDB.facts
    for _, e in pairs(fdb and fdb.own or {}) do
        fo = fo + 1
        local sent = false
        for _, k in ipairs(FACT_FIELDS) do if e.sent and e.sent[k] then sent = true end end
        if sent then fs = fs + 1 end
    end
    for _, q in pairs(fdb and fdb.heard or {}) do
        fh = fh + 1
        local ok = false
        for _, field in ipairs(FACT_FIELDS) do   -- (q also holds the voter sets "iv" / "pv" / ...)
            for _, c in pairs(q[field] or {}) do if c.n >= CONFIRM then ok = true end end
        end
        if ok then fc = fc + 1 end
    end
    VQ:Print(("Quest facts (rewards / reputation that differ from the shipped data, escorts): %d of your own (%d sent), %d quest%s heard about, %d confirmed by 2+ players."):format(
        fo, fs, fh, fh == 1 and "" or "s", fc))
    local mobs, spots, mconf, mine, msent = self:MobStats()
    VQ:Print(("Quest-mob spots: %d of your own (%d sent), %d heard for %d mob%s, %d confirmed by %d+ players."):format(
        mine, msent, spots, mobs, mobs == 1 and "" or "s", mconf, MOB_CONFIRM))
    -- the traffic counter since it started (all sessions)
    local s = VoidQuestDB and VoidQuestDB.netStats
    if s then
        local function list(t)
            local out = {}
            for k, v in pairs(t or {}) do out[#out + 1] = k .. " " .. v end
            table.sort(out)
            return #out > 0 and table.concat(out, ", ") or "none"
        end
        VQ:Print(("Traffic since %s -- sent: %s | received: %s | not sent, nobody online: %s | offline: %s | refused: %s | dropped: %s | questions with nothing new to answer: %s"):format(
            date("%b %d %H:%M", s.since), list(s.sent), list(s.got), list(s.nobody), list(s.offline), list(s.refused),
            list(s.dropped), list(s.unanswered)))
    end
end

function Share:SelfTest()
    if not enabled() then
        VQ:Print("sharing is |cffff5555off|r: /vq share turns it on.")
        return
    end
    self:JoinNet()
    rosterAt = -ROSTER_EVERY   -- re-read the member list now
    requestRoster()
    VQ:Print("testing sharing (~5s)...")
    pingNonce, pingGot = ("%d"):format(math.floor(GetTime() * 1000)), false
    if me then C_ChatInfo.SendAddonMessage(PREFIX, "PING:" .. pingNonce, "WHISPER", me) end
    C_Timer.After(4, function()
        readRoster()
        VQ:Print(pingGot and "addon whispers |cff33ff33work|r: sharing is live."
            or "addon whispers |cffff5555didn't come back|r: messages aren't getting through here.")
        Share:Stats()
    end)
end
