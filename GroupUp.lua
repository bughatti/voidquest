----------------------------------------------------------------------
-- VoidQuest — GroupUp: ask other VoidQuest players on the same quest to group (WoW Forever)
--
-- The user, 2026-11-11: "a person can click, it send a whisper to the first 4 other people in
-- that zone on the same quest saying something like Voidquest player is on same quest as you,
-- would you like to group with a accept button". Decided the same day: the pop-up shows the
-- asker's name, level and class; it's on unless turned off; the closest 4 are asked first and
-- a second Ctrl-click asks the next ones. And (same day): "if someone clicks deny we dont ask again
-- for that quest, if we ask and they dont accept within 5 min, we dont ask again": No thanks or
-- no answer in 5 minutes = that player is never asked about that quest again.
--
-- Ctrl-click a quest line (or /vq group for the tracked quest):
--   1. GQ:1:qid:zone:x:y:nonce  to the VoidQuest players of your faction online (up to ASK_MAX):
--      "anyone on this quest in this zone?" x/y = where you are, 0..999 of the zone map.
--   2. GH:1:nonce:yards         back from each one who has it in their log, unfinished, is in
--                               that zone, solo, outside instances (yards from you, -1 unknown)
--   3. GA:1:nonce:qid:level:CLASS  to the closest ROUND of them (4, or fewer free group spots):
--                               they get a pop-up with Accept / No thanks (5 minutes to answer)
--   4. GY:1:nonce (accept) -> you invite them; their VoidQuest accepts that invite by itself.
--      GN:1:nonce (no) · GX:1:nonce (your group filled up first)
-- Ctrl-click again within 5 minutes: the next closest who haven't been asked.
--
-- /vq group test: the same, with YOU as the other player (your own whispers come back, as
-- /vq net proves): real messages, real checks, the real pop-up. Only the invite is skipped (you
-- can't invite yourself; it's the same call as VoidLayer's hops), and nothing is remembered.
--
-- Rides ForeverShare's addon whispers (same prefix, rate limits, faction channel). Every
-- message is untrusted: a pop-up only comes from a player who first asked about a quest
-- YOU have and got your answer (GA must match a GQ you answered), at most one pop-up every
-- POPUP_GAP, never in combat, an instance or a group, never from someone you ignore.
-- Names live in memory only (the pop-up and chat lines show them). A quest you said no to (or
-- let the pop-up run out on) is saved by quest ID in VoidQuestCharDB.groupNo: you never answer
-- a search for it again, so no asker can reach you about it. The asker also skips you for the
-- rest of the session (refused, in memory).
----------------------------------------------------------------------
local VQ = VoidQuest
if not VQ.ForeverQuests then return end   -- WoW Forever only

local G = {}
VQ.GroupUp = G

local ASK_MAX    = 15     -- players asked "are you on it?" per search
local ROUND      = 4      -- pop-ups per round (the user: "the first 4")
local KEEP       = 300    -- a search's answers stay usable this long (Ctrl-click = ask more)
local SEARCH_CD  = 300    -- a new search for the same quest at most this often
local ANSWER_FOR = 300    -- seconds the asked have to answer the pop-up (the user: 5 min)
local POPUP_GAP  = 180    -- at most one pop-up per this
local HEARD_FOR  = 300    -- a GA must follow our GH within this
local INVITE_FOR = 90     -- after Accept, the asker's invite is taken within this
local REPLY_GAP  = 20     -- one GH per asker per this

local function safe(fn, ...)
    if not fn then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
end
local function S() return VQ.Share end
local function on() return VQ:Get("groupAsks") ~= false end
local function say(msg) VQ:Print(msg) end

local function title(qid)
    return safe(C_QuestLog.GetTitleForQuestID, qid)
        or (VQ.ForeverQuests[qid] and VQ.ForeverQuests[qid].title) or ("quest " .. qid)
end

-- the zone a map belongs to (towns, caves and floors roll up)
local function zoneOf(mapID)
    local ZONE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
    local info, hops = mapID and safe(C_Map.GetMapInfo, mapID), 0
    while info and info.mapType and info.mapType > ZONE and info.parentMapID and hops < 6 do
        info, hops = safe(C_Map.GetMapInfo, info.parentMapID), hops + 1
    end
    return info and info.mapType == ZONE and info.mapID or nil
end
local function hereZone() return zoneOf(safe(C_Map.GetBestMapForUnit, "player")) end
local function zoneName(z) local i = z and safe(C_Map.GetMapInfo, z); return i and i.name or "this zone" end

-- where you are in a zone, 0..999 (nil = unknown)
local function posIn(zone)
    local p = safe(C_Map.GetPlayerMapPosition, zone, "player")
    if not (p and p.GetXY) then return nil end
    local x, y = p:GetXY()
    if not (x and y) or (issecretvalue and (issecretvalue(x) or issecretvalue(y))) then return nil end
    return math.floor(x * 999 + 0.5), math.floor(y * 999 + 0.5)
end

local function onQuest(qid)   -- in your log and not finished yet
    return safe(C_QuestLog.GetLogIndexForQuestID, qid) and not safe(C_QuestLog.IsComplete, qid)
end
local function freeSlots()   -- how many you can still invite (nil + why when you can't)
    if IsInRaid() then return nil, "you're in a raid group" end
    if IsInGroup() and not UnitIsGroupLeader("player") then return nil, "only your group's leader can invite" end
    local n = IsInGroup() and GetNumGroupMembers() or 1
    if n >= 5 then return nil, "your group is full" end
    return 5 - n
end
local function nonce()
    local c, s = "abcdefghjkmnpqrstuvwxyz23456789", {}
    for i = 1, 6 do local k = math.random(#c); s[i] = c:sub(k, k) end
    return table.concat(s)
end
local function ignored(name)
    return C_FriendList and C_FriendList.IsIgnored and safe(C_FriendList.IsIgnored, name) and true or false
end
local function charDB()
    VoidQuestCharDB = VoidQuestCharDB or {}
    VoidQuestCharDB.groupNo = VoidQuestCharDB.groupNo or {}
    return VoidQuestCharDB.groupNo
end

----------------------------------------------------------------------
-- Asking
----------------------------------------------------------------------
local refused = {}    -- [qid] = { [name] = true }: said no or never answered (this session)
local searches = {}   -- [qid] = { nonce, t, zone, found = { [name] = { to, yd } }, asked = {}, answered = {} }
local byNonce = {}    -- [nonce] = qid

-- Can this quest offer "Ctrl-click: group up"? (tooltip hint)
function G:CanOffer(qid)
    return qid and S() and S():On() and VQ.ForeverQuests[qid] and onQuest(qid) and freeSlots() and not IsInInstance() and true or false
end

local function finishRound(qid, st, round)
    if searches[qid] ~= st then return end
    if G.testing then G.testing = nil; say("Group up test: the pop-up ran out (a real player would never be asked about this quest again; not saved in a test)."); return end
    local waiting, left = 0, 0
    for _, name in ipairs(round) do
        if not st.answered[name] then
            waiting = waiting + 1
            refused[qid] = refused[qid] or {}; refused[qid][name] = true
        end
    end
    for name in pairs(st.found) do if not st.asked[name] and not (refused[qid] and refused[qid][name]) then left = left + 1 end end
    local bits = {}
    if waiting > 0 then bits[#bits + 1] = ("%d didn't answer (they won't be asked about it again)"):format(waiting) end
    if left > 0 then bits[#bits + 1] = ("Ctrl-click the quest again to ask %d more"):format(left) end
    if #bits > 0 then say(("Group up, %s: %s."):format(title(qid), table.concat(bits, ". "))) end
end

local function askRound(qid, st)
    local slots, why = freeSlots()
    if not slots then say("Group up: " .. why .. "."); return end
    local list = {}
    local no = refused[qid] or {}
    for name, f in pairs(st.found) do if not st.asked[name] and not no[name] then list[#list + 1] = { name = name, to = f.to, yd = f.yd } end end
    table.sort(list, function(a, b)
        local ay, by = a.yd < 0 and 1e9 or a.yd, b.yd < 0 and 1e9 or b.yd
        if ay ~= by then return ay < by end
        return a.name < b.name
    end)
    local n = math.min(ROUND, slots, #list)
    if n == 0 then return false end
    local lvl, cls = UnitLevel("player") or 0, select(2, UnitClass("player")) or "?"
    local round, near = {}, nil
    for i = 1, n do
        local c = list[i]
        st.asked[c.name] = true
        round[#round + 1] = c.name
        if c.yd >= 0 and (not near or c.yd < near) then near = c.yd end
        S():SendNow(("GA:1:%s:%d:%d:%s"):format(st.nonce, qid, lvl, cls), c.to)
    end
    say(("Group up: asked %d player%s on %s%s. They have a minute to answer."):format(n, n == 1 and "" or "s",
        title(qid), near and (" (closest %d yd away)"):format(near) or ""))
    C_Timer.After(ANSWER_FOR + n * S().SEND_EVERY + 5, function() finishRound(qid, st, round) end)
    return true
end

function G:Ask(qid)
    if not qid then return end
    if not (S() and S():On()) then say("Group up needs quest sharing on (VoidQuest settings)."); return end
    if not VQ.ForeverQuests[qid] then return end
    if not onQuest(qid) then say(("Group up: %s is finished or not in your log."):format(title(qid))); return end
    if IsInInstance() then say("Group up works outside instances."); return end
    local slots, why = freeSlots()
    if not slots then say("Group up: " .. why .. "."); return end
    local zone = hereZone()
    if not zone then return end
    local now, st = time(), searches[qid]
    if st and now - st.t < KEEP and st.zone == zone then
        if askRound(qid, st) then return end
        if now - st.t < SEARCH_CD then
            say(("Group up: nobody else on %s answered. You can look again in %d min."):format(title(qid),
                math.ceil((SEARCH_CD - (now - st.t)) / 60)))
            return
        end
    end
    local members = G.testing and { S():Me() } or S():Members(ASK_MAX)
    if #members == 0 then say("Group up: no other VoidQuest players of your faction are online right now."); return end
    local x, y = posIn(zone)
    if searches[qid] then byNonce[searches[qid].nonce] = nil end
    st = { nonce = nonce(), t = now, zone = zone, found = {}, asked = {}, answered = {} }
    searches[qid], byNonce[st.nonce] = st, qid
    for _, name in ipairs(members) do
        S():SendNow(("GQ:1:%d:%d:%d:%d:%s"):format(qid, zone, x or 0, y or 0, st.nonce), name)
    end
    say(("Group up: looking for VoidQuest players in %s on %s..."):format(zoneName(zone), title(qid)))
    -- answers come back within a few seconds of each question going out
    C_Timer.After(#members * S().SEND_EVERY + 8, function()
        if searches[qid] ~= st then return end
        if next(st.found) == nil then
            say(("Group up: nobody else in %s is on %s right now (asked %d player%s)."):format(zoneName(zone),
                title(qid), #members, #members == 1 and "" or "s"))
            return
        end
        askRound(qid, st)
    end)
end

-- the quest you're tracking (/vq group)
function G:AskTracked()
    local qid = C_SuperTrack and safe(C_SuperTrack.GetSuperTrackedQuestID)
    if not qid or qid == 0 then say("Group up: track a quest first, or Ctrl-click one in the VoidQuest panel."); return end
    G:Ask(qid)
end

-- /vq group test: you play the other player too (see the top of this file)
function G:SelfTest()
    local qid = C_SuperTrack and safe(C_SuperTrack.GetSuperTrackedQuestID)
    -- the tracked quest, else any unfinished quest in your log
    if not (qid and qid ~= 0 and onQuest(qid) and VQ.ForeverQuests[qid]) then
        qid = nil
        for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
            local info = safe(C_QuestLog.GetInfo, i)
            if info and not info.isHeader and info.questID and VQ.ForeverQuests[info.questID] and onQuest(info.questID) then
                qid = info.questID
                break
            end
        end
    end
    if not qid then say("Group up test: no unfinished quest in your log to test with."); return end
    local why
    if not (S() and S():On()) then why = "quest sharing is off (VoidQuest settings)"
    elseif not on() then why = "\"Let VoidQuest players on your quest ask you to group\" is off in settings"
    elseif charDB()[qid] then why = "you said no to group asks for this quest before"
    elseif not onQuest(qid) then why = "the quest is finished or not in your log"
    elseif IsInGroup() then why = "you're in a group (only solo players are asked)"
    elseif IsInInstance() then why = "you're in an instance"
    elseif InCombatLockdown() then why = "you're in combat" end
    if why then say("Group up test can't run: " .. why .. "."); return end
    if searches[qid] then byNonce[searches[qid].nonce] = nil; searches[qid] = nil end
    G.testing = true
    C_Timer.After(ANSWER_FOR + 60, function() G.testing = nil end)   -- never left on
    say(("Group up test on %s: you play the other player. Watch for the pop-up."):format(title(qid)))
    G:Ask(qid)
end

----------------------------------------------------------------------
-- Being asked
----------------------------------------------------------------------
local heard = {}      -- [nonce] = { from, to, qid, t }: questions we answered "yes, me too"
local lastReply = {}  -- [from] = time()
local lastPopup = 0
local popup           -- the open pop-up's { nonce, from, to, qid }
local expect          -- after Accept: { from, untilT }

local function reply(to, msg) S():SendNow(msg, to) end

StaticPopupDialogs["VOIDQUEST_GROUPUP"] = {
    text = "%s",
    button1 = ACCEPT or "Accept",
    button2 = "No thanks",
    timeout = ANSWER_FOR,
    whileDead = false,
    hideOnEscape = true,
    OnAccept = function(_, data)
        if not data then return end
        reply(data.to, "GY:1:" .. data.nonce)
        expect = { from = data.from, untilT = time() + INVITE_FOR }
        popup = nil
        say(("Group up: waiting for %s's invite."):format(data.from))
    end,
    -- No thanks (or Escape: reason "clicked"): never asked about this quest again (the user, 11-11);
    -- no answer in 5 minutes (reason "timeout") the same. Blizzard also calls this with NO reason when
    -- the pop-up couldn't be shown at all (every pop-up slot in use): that's not an answer (Codex 11-12).
    OnCancel = function(_, data, reason)
        data = data or popup
        if not data then return end
        if reason == "timeout" then
            popup = nil
            if not G.testing then charDB()[data.qid] = true end
            return
        end
        if reason ~= "clicked" then return end
        popup = nil
        reply(data.to, "GN:1:" .. data.nonce)
        if G.testing then say("Group up test: No thanks works (a real player would never be asked about this quest again; not saved in a test)."); return end
        charDB()[data.qid] = true
        say(("Group up: you won't be asked about %s again."):format(title(data.qid)))
    end,
    -- Hidden any other way: not an answer, unless its countdown ran out (a client whose timeout
    -- doesn't come through OnCancel)
    OnHide = function(dialog)
        if popup and not G.testing and dialog and dialog.timeleft and dialog.timeleft <= 0 then
            charDB()[popup.qid] = true
        end
        popup = nil
    end,
}

local function onQuestion(sender, to, qid, zone, x, y, n)
    if not on() or charDB()[qid] or not VQ.ForeverQuests[qid] then return end
    if not onQuest(qid) or IsInInstance() or IsInGroup() or ignored(sender) then return end
    if hereZone() ~= zone then return end
    local now = time()
    if not G.testing and lastReply[sender] and now - lastReply[sender] < REPLY_GAP then return end
    lastReply[sender] = now
    -- how far from the asker, in yards (-1 when the map has no size)
    local yd = -1
    local mx, my = posIn(zone)
    local w, h = safe(C_Map.GetMapWorldSize, zone)
    if mx and w and h and w > 0 and (x > 0 or y > 0) then
        local dx, dy = (mx - x) / 999 * w, (my - y) / 999 * h
        yd = math.floor(math.sqrt(dx * dx + dy * dy) / 10 + 0.5) * 10
    end
    heard[n] = { from = sender, to = to, qid = qid, t = now }
    C_Timer.After(0.2 + math.random() * 1.3, function() reply(to, ("GH:1:%s:%d"):format(n, yd)) end)
end

local function onInvite(sender, to, n, qid, lvl, cls)
    local h = heard[n]
    if not (h and h.from == sender and h.qid == qid and time() - h.t < HEARD_FOR) then return end
    heard[n] = nil
    if not on() or charDB()[qid] or not onQuest(qid) then reply(to, "GN:1:" .. n); return end
    if InCombatLockdown() or IsInInstance() or IsInGroup() or popup or (not G.testing and time() - lastPopup < POPUP_GAP) then
        reply(to, "GN:1:" .. n); return
    end
    lastPopup = time()
    local className = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls]) or cls:sub(1, 1) .. cls:sub(2):lower()
    local text = ("|cff00c7ffVoidQuest|r\n\n%s (%d %s) is on |cffffd200%s|r in %s too.\nGroup up?"):format(
        sender, lvl, className, title(qid), zoneName(hereZone()))
    popup = { nonce = n, from = sender, to = to, qid = qid }
    local dlg = StaticPopup_Show("VOIDQUEST_GROUPUP", text, nil, popup)
    if not dlg then popup = nil; reply(to, "GN:1:" .. n); return end
    if SOUNDKIT and SOUNDKIT.IG_PLAYER_INVITE then pcall(PlaySound, SOUNDKIT.IG_PLAYER_INVITE) end
end

----------------------------------------------------------------------
-- Who's on your quests here (the user, 2026-11-11: "3 other players on this quest, 7 other
-- players on this other quest ... find a way to not make that information super annoying").
-- No pop-up: a grey number at the end of each quest line in the panel, a tooltip line, and
-- one chat line when you arrive in a zone (on by default, at most once per zone per 30 min).
--   GZ:1:zone:nonce   "who's here, on which quests?" to the VoidQuest players online, on
--                     arriving in a zone and every CENSUS_EVERY while you stay
--   GL:1:nonce:q,q,q  back from each one IN THAT ZONE: their unfinished quest IDs
-- GZ carries only your zone; your quests go only to someone in your zone who asked. Counts
-- only, never names on screen; the names stay in memory. The "let VoidQuest players on your
-- quest ask you to group" setting turns answering (and being counted) off too.
----------------------------------------------------------------------
local CENSUS_EVERY = 300   -- re-ask while you stay in a zone
local CENSUS_ASK   = 12    -- players asked each time
local CENSUS_STALE = 900   -- an answer counts this long
local CENSUS_IDS   = 38    -- quest IDs per answer (38 x "12345," + header fits one 255-byte whisper)
local ARRIVE_GAP   = 1800  -- the arrival line, once per zone per this
local census = {}          -- [name] = { zone, q = { [qid] = true }, t }
local censusNonce, censusAt, censusZone = nil, 0, nil
local arrived = {}         -- [zone] = time() of the arrival line
local lastList = {}        -- [asker] = time(): one answer per asker per minute
local redraw

local function myQuestIDs()
    local out = {}
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        local q = info and not info.isHeader and info.questID
        if q and VQ.ForeverQuests[q] and not safe(C_QuestLog.IsComplete, q) then
            out[#out + 1] = q
            if #out >= CENSUS_IDS then break end
        end
    end
    return out
end

local function changed()
    if redraw then return end
    redraw = true
    C_Timer.After(2, function()
        redraw = nil
        if VQ.Guide and VQ.Guide.Refresh then pcall(VQ.Guide.Refresh, VQ.Guide) end
    end)
end

-- Other VoidQuest players in your zone on this quest (0 when none, off, or unknown).
function G:Here(qid)
    if not qid or not on() then return 0 end
    local zone, now, n = hereZone(), time(), 0
    if not zone then return 0 end
    for _, c in pairs(census) do
        if c.zone == zone and c.q[qid] and now - c.t < CENSUS_STALE then n = n + 1 end
    end
    return n
end

local function arrivalLine(zone)
    if VQ:Get("groupArrival") == false or hereZone() ~= zone then return end
    if arrived[zone] and time() - arrived[zone] < ARRIVE_GAP then return end
    local players, shared, now = {}, 0, time()
    for _, q in ipairs(myQuestIDs()) do
        local any = false
        for name, c in pairs(census) do
            -- only fresh answers (Codex 11-12: old ones were counted as players here now)
            if c.zone == zone and c.q[q] and now - c.t < CENSUS_STALE then players[name] = true; any = true end
        end
        if any then shared = shared + 1 end
    end
    local np = 0
    for _ in pairs(players) do np = np + 1 end
    if np == 0 then return end
    arrived[zone] = time()
    say(("%d VoidQuest player%s in %s %s on %d of your quests (hover a quest's grey number, Ctrl-click it to group up)."):format(
        np, np == 1 and "" or "s", zoneName(zone), np == 1 and "is" or "are", shared))
end

function G:Census(arriving)
    if not (S() and S():On() and on()) or IsInInstance() then return end
    local zone = hereZone()
    if not zone then return end
    local members = S():Members(CENSUS_ASK)
    if #members == 0 then return end
    censusNonce, censusAt, censusZone = nonce(), time(), zone
    for _, name in ipairs(members) do S():SendNow(("GZ:1:%d:%s"):format(zone, censusNonce), name) end
    if arriving then
        C_Timer.After(#members * S().SEND_EVERY + 8, function() arrivalLine(zone) end)
    end
end

local function onCensusAsk(sender, to, zone, n)
    if not on() or IsInInstance() or hereZone() ~= zone or ignored(sender) then return end
    local now = time()
    if lastList[sender] and now - lastList[sender] < 60 then return end
    lastList[sender] = now
    local ids = myQuestIDs()
    if #ids == 0 then return end
    local s = {}
    for i, q in ipairs(ids) do s[i] = tostring(q) end
    C_Timer.After(0.2 + math.random() * 2, function() S():SendNow(("GL:1:%s:%s"):format(n, table.concat(s, ",")), to) end)
end

local function onCensusList(sender, n, body)
    if n ~= censusNonce or time() - censusAt > 120 or hereZone() ~= censusZone then return end
    local q, count = {}, 0
    for id in body:gmatch("%d+") do
        id = tonumber(id)
        if id and VQ.ForeverQuests[id] and not q[id] then q[id] = true; count = count + 1 end
        if count >= CENSUS_IDS then break end
    end
    -- old answers make room first (Codex 11-12: they were never removed, so after 200 players in a
    -- session nobody new was counted)
    local size, now = 0, time()
    for name, c in pairs(census) do
        if now - c.t >= CENSUS_STALE then census[name] = nil else size = size + 1 end
    end
    if not census[sender] and size >= 200 then return end
    census[sender] = { zone = censusZone, q = q, t = time() }
    changed()
end

-- arriving in a zone asks once things settle; staying re-asks every CENSUS_EVERY
local lastZone
local zf = CreateFrame("Frame")
zf:RegisterEvent("ZONE_CHANGED_NEW_AREA")
zf:RegisterEvent("PLAYER_ENTERING_WORLD")
zf:SetScript("OnEvent", function()
    C_Timer.After(12, function()
        local z = hereZone()
        if z and z ~= lastZone then lastZone = z; pcall(G.Census, G, true) end
        changed()
    end)
end)
C_Timer.NewTicker(CENSUS_EVERY, function()
    local z = hereZone()
    if z and z == lastZone then pcall(G.Census, G, false) end
end)

----------------------------------------------------------------------
-- Messages (from ForeverShare:OnMessage; sender = canonical name, replyTo = as received)
----------------------------------------------------------------------
function G:OnMessage(msg, sender, replyTo)
    if type(msg) ~= "string" or #msg > 255 then return end
    local to = replyTo or sender
    local cz, cn = msg:match("^GZ:1:(%d+):(%w+)$")
    if cz then
        if #cn <= 8 then onCensusAsk(sender, to, tonumber(cz), cn) end
        return
    end
    local ln, lbody = msg:match("^GL:1:(%w+):([%d,]+)$")
    if ln then onCensusList(sender, ln, lbody); return end
    if #msg > 120 then return end
    local q, z, x, y, n = msg:match("^GQ:1:(%d+):(%d+):(%d+):(%d+):(%w+)$")
    if q then
        if #n > 8 then return end
        onQuestion(sender, to, tonumber(q), tonumber(z), math.min(999, tonumber(x)), math.min(999, tonumber(y)), n)
        return
    end
    local hn, yd = msg:match("^GH:1:(%w+):(%-?%d+)$")
    if hn then
        local qid = byNonce[hn]
        local st = qid and searches[qid]
        if st and st.nonce == hn and time() - st.t < KEEP and not st.found[sender] then
            local count = 0
            for _ in pairs(st.found) do count = count + 1 end
            if count < ASK_MAX then st.found[sender] = { to = to, yd = math.max(-1, math.min(99999, tonumber(yd) or -1)) } end
        end
        return
    end
    local an, aq, al, ac = msg:match("^GA:1:(%w+):(%d+):(%d+):(%u+)$")
    if an then
        if #ac > 12 then return end
        onInvite(sender, to, an, tonumber(aq), math.min(99, tonumber(al) or 0), ac)
        return
    end
    local kind, rn = msg:match("^G([YNX]):1:(%w+)$")
    if not kind then return end
    if kind == "X" then
        if expect and expect.from == sender then
            expect = nil
            say(("Group up: %s's group filled up before your invite."):format(sender))
        end
        return
    end
    local qid = byNonce[rn]
    local st = qid and searches[qid]
    if not (st and st.nonce == rn and st.asked[sender] and not st.answered[sender]) then return end
    st.answered[sender] = kind
    if kind == "N" then
        if not G.testing then refused[qid] = refused[qid] or {}; refused[qid][sender] = true end
        say(("Group up: %s said no thanks."):format(sender))
        if G.testing then G.testing = nil; say("Group up test done: everything went over the wire.") end
        return
    end
    local slots, why = freeSlots()
    if not slots or InCombatLockdown() then
        reply(st.found[sender] and st.found[sender].to or to, "GX:1:" .. rn)
        say(("Group up: %s said yes, but %s."):format(sender, why or "you're in combat"))
        return
    end
    if G.testing then
        expect = nil
        G.testing = nil
        say(("Group up test: %s said yes. A real player would get your invite now and join by themselves. Test done: everything went over the wire."):format(sender))
        return
    end
    -- the plain name, as VoidLayer's hop invites do (proven on Forever 11-10)
    if C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(sender) elseif InviteUnit then InviteUnit(sender) end
    say(("Group up: %s said yes, invite sent."):format(sender))
end

----------------------------------------------------------------------
-- The asker's invite after Accept: taken by itself (no second "join group?" box)
----------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PARTY_INVITE_REQUEST")
f:SetScript("OnEvent", function(_, _, inviter)
    if not expect or type(inviter) ~= "string" or (issecretvalue and issecretvalue(inviter)) then return end
    local who = S() and S():Canon(inviter)
    if who ~= expect.from then return end
    local ok = time() < expect.untilT and not IsInGroup() and not InCombatLockdown()
    expect = nil
    if not ok then return end
    AcceptGroup()
    C_Timer.After(0, function() StaticPopup_Hide("PARTY_INVITE") end)
end)
