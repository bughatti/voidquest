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
local function dailyChannel(day)
    day = day or math.floor(((GetServerTime and GetServerTime()) or time()) / 86400)
    local s = mix(mix(DAILY_SALT, day), DAILY_SALT % 97)
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
-- Marks are SAVED (VoidQuestDB.netOffline, set in Share:Init) and timed with time(): kept
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

-- sender = canon(name); replyTo = the name to whisper back (as the game gave it)
function Share:OnMessage(msg, sender, replyTo)
    if type(msg) ~= "string" or type(sender) ~= "string" then return end
    local nonce = msg:match("^PING:(.+)$")
    if nonce then
        if sender == me and nonce == pingNonce then pingGot = true end
        return
    end
    if not enabled() or sender == me or not VoidQuestDB then return end
    tally("got", msg)
    if not rateOK(sender) then tally("dropped", "rate"); return end
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
        C_Timer.After(3, askHere)
    else
        -- off means off: nothing queued, held or scheduled goes out any more
        Share.gen = Share.gen + 1
        wipe(queue)
        wipe(pending)
        if sending then sending:Cancel(); sending = nil end
        if pendingTicker then pendingTicker:Cancel(); pendingTicker = nil end
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
    me = canon(GetUnitName and GetUnitName("player") or UnitName("player"))
    -- offline marks saved per account, so a /reload doesn't count logged-off players
    VoidQuestDB = VoidQuestDB or {}
    VoidQuestDB.netOffline = VoidQuestDB.netOffline or {}
    unreach = VoidQuestDB.netOffline
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
    f:SetScript("OnEvent", function(_, event, prefix, msg, channel, sender, _, _, localID, _, base)
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
            if name then unreach[name] = time(); publish() end
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
