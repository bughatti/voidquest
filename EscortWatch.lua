----------------------------------------------------------------------
-- VoidQuest — EscortWatch: what players actually see at escort quests (WoW Forever)
--
-- The escort list (ForeverEscort in ForeverRules.lua) is read from NorgannonDB's wording, and
-- "back in a few minutes" is a guess. The user, 2026-11-11: "we also need to collect that data
-- from people actually doing the quests to validate". So every VoidQuest player records:
--   start  a group member started it and the game asked you to join (QUEST_ACCEPT_CONFIRM:
--          the game's own sign of an escort-type quest)
--   accept you took an escort quest          done  you turned it in
--   fail   it failed; with no time limit that's the escort NPC dying (escort-type proof)
--   wait   you stood at the giver's spot: how long until the giver offered it
--   left   you stood at the spot, the giver never offered it, you went away
-- Kept in VoidQuestDB.escort.log (newest 200, no player names: the "start" prompt names the
-- group member, that name is dropped). Shared as quest facts (ForeverShare: e=1, w=minutes),
-- held back 10-20 min like every other find, so the author's install collects other players'
-- readings too. A quest that keeps showing escort proof but isn't on the list shows the note
-- anyway once two players agree.
----------------------------------------------------------------------
local VQ = VoidQuest
if not VQ.ForeverQuests then return end   -- WoW Forever only

local E = {}
VQ.EscortWatch = E

local LOG_MAX  = 200
local NEAR_YD  = 25     -- standing at the giver
local AWAY_YD  = 80     -- gone from it
local AWAY_FOR = 90     -- seconds away before a wait counts as given up
local TICK     = 2

local function safe(fn, ...)
    if not fn then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
end

local function db()
    if not VoidQuestDB then return nil end
    VoidQuestDB.escort = VoidQuestDB.escort or { log = {} }
    local d = VoidQuestDB.escort
    d.log = d.log or {}
    return d
end

local function log(kind, qid, extra)
    local d = db()
    if not d then return end
    local e = { t = time(), k = kind, q = qid, lv = UnitLevel("player") }
    for k, v in pairs(extra or {}) do e[k] = v end
    d.log[#d.log + 1] = e
    while #d.log > LOG_MAX do table.remove(d.log, 1) end
end

local function share(qid, field, value)
    if VQ.Share and VQ.Share.NoteFact then pcall(VQ.Share.NoteFact, VQ.Share, qid, field, value) end
end

-- shipped list, or two players' proof (or your own)
function E:IsEscort(qid)
    if VQ.ForeverEscort and VQ.ForeverEscort[qid] then return true end
    local v = VQ.Share and VQ.Share.FactValue and VQ.Share:FactValue(qid, "e")
    return v == "1"
end

-- minutes bucket for a wait: 0 (there) / 2 / 5 / 10 / 15 (or more)
local function bucket(sec)
    local m = sec / 60
    if m < 1 then return "0" elseif m < 3.5 then return "2" elseif m < 7.5 then return "5"
    elseif m < 12.5 then return "10" end
    return "15"
end

-- The usual wait at this giver: your own reading, else the one most players back.
function E:Wait(qid)
    local v = VQ.Share and VQ.Share.FactValue and VQ.Share:FactValue(qid, "w")
    return v and tonumber(v)
end

----------------------------------------------------------------------
-- Waiting at the giver
----------------------------------------------------------------------
local at = {}   -- [qid] = { first = time we got there, last = time last near }

local function yardsTo(s)
    local here = safe(C_Map.GetBestMapForUnit, "player")
    if not here or here ~= s.m then return nil end
    local pos = safe(C_Map.GetPlayerMapPosition, here, "player")
    if not (pos and pos.GetXY) then return nil end
    local px, py = pos:GetXY()
    local w, h = safe(C_Map.GetMapWorldSize, here)
    if not (px and w and h and w > 0) then return nil end
    local dx, dy = (px - s.x) * w, (py - s.y) * h
    return math.sqrt(dx * dx + dy * dy)
end

-- escort quests you can still take whose giver stands on the map you're on
local function candidates()
    local F = VQ.Forever
    local here = safe(C_Map.GetBestMapForUnit, "player")
    if not (F and here) then return {} end
    local list = {}
    local function consider(qid)
        local s = F:Spot(qid)
        if s and s.m == here and F:Status(qid) == "open" then list[#list + 1] = { q = qid, s = s } end
    end
    for qid in pairs(VQ.ForeverEscort or {}) do consider(qid) end
    local f = VoidQuestDB and VoidQuestDB.facts
    for qid in pairs(f and f.own or {}) do
        if not (VQ.ForeverEscort and VQ.ForeverEscort[qid]) and E:IsEscort(qid) then consider(qid) end
    end
    return list
end

local function tick()
    if not VoidQuestDB or UnitIsDeadOrGhost("player") then return end
    local now = time()
    local list = candidates()
    -- a wait started on another map (you left it): over once you've been gone AWAY_FOR, or coming back
    -- hours later would count the whole absence as waiting at the giver (Codex 11-12)
    local onMap = {}
    for _, c in ipairs(list) do onMap[c.q] = true end
    for q, a in pairs(at) do
        if not onMap[q] and now - a.last > AWAY_FOR then
            local waited = a.last - a.first
            if waited >= 30 then log("left", q, { sec = waited }) end
            at[q] = nil
        end
    end
    for _, c in ipairs(list) do
        local yd = yardsTo(c.s)
        local a = at[c.q]
        if yd and yd <= NEAR_YD then
            if not a then
                local ok = VQ.Forever:Available(c.q)
                if ok then at[c.q] = { first = now, last = now } end
            else
                a.last = now
            end
        elseif a and (not yd or yd > AWAY_YD) and now - a.last > AWAY_FOR then
            local waited = a.last - a.first
            if waited >= 30 then log("left", c.q, { sec = waited }) end
            at[c.q] = nil
        end
    end
end

-- the giver offered it: how long since we got there
local function offered(qid)
    if not E:IsEscort(qid) then return end
    if UnitExists("npc") and UnitIsPlayer("npc") then return end   -- a group member shared it
    local a = at[qid]
    local sec = a and (time() - a.first) or 0
    at[qid] = nil
    local d = db()
    -- one wait per quest per arrival; the same window opened twice doesn't count again
    if d and d.lastOffer and d.lastOffer.q == qid and time() - d.lastOffer.t < 300 then return end
    if d then d.lastOffer = { q = qid, t = time() } end
    log("wait", qid, { sec = sec })
    share(qid, "w", bucket(sec))
end

----------------------------------------------------------------------
-- Taking, failing, finishing
----------------------------------------------------------------------
local taken = {}   -- [qid] = true while in the log this session (failure watch)

local function failed(qid)
    if C_QuestLog.IsFailed then return safe(C_QuestLog.IsFailed, qid) == true end
    local idx = safe(C_QuestLog.GetLogIndexForQuestID, qid)
    local info = idx and safe(C_QuestLog.GetInfo, idx)
    return info and info.isFailed == true or false
end

local function timed(qid)
    local total = C_QuestLog.GetTimeAllowed and safe(C_QuestLog.GetTimeAllowed, qid)
    return type(total) == "number" and total > 0
end

local function checkFailed()
    for qid in pairs(taken) do
        if failed(qid) then
            taken[qid] = nil
            local isTimed = timed(qid)
            log("fail", qid, { timed = isTimed or nil, listed = (VQ.ForeverEscort and VQ.ForeverEscort[qid]) and true or nil })
            if not isTimed then share(qid, "e", "1") end
        elseif not safe(C_QuestLog.GetLogIndexForQuestID, qid) then
            taken[qid] = nil   -- abandoned or turned in
        end
    end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "QUEST_ACCEPT_CONFIRM", "QUEST_ACCEPTED", "QUEST_DETAIL",
    "QUEST_TURNED_IN", "QUEST_LOG_UPDATE" }) do
    ev:RegisterEvent(e)
end
ev:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if event == "PLAYER_LOGIN" then
        C_Timer.NewTicker(TICK, function() pcall(tick) end)
        -- escorts already in the log (a /reload mid-escort) are watched too
        C_Timer.After(5, function()
            for qid in pairs(VQ.ForeverQuests) do
                if E:IsEscort(qid) and safe(C_QuestLog.GetLogIndexForQuestID, qid) then taken[qid] = true end
            end
        end)
    elseif event == "QUEST_ACCEPT_CONFIRM" then
        -- arg1 = the group member's name (not kept), arg2 = title, arg3 = questID
        local qid = tonumber(a3)
        if qid and VQ.ForeverQuests[qid] then
            log("start", qid, { listed = (VQ.ForeverEscort and VQ.ForeverEscort[qid]) and true or nil })
            share(qid, "e", "1")
        end
    elseif event == "QUEST_ACCEPTED" then
        -- retail-style (questID) or older (logIndex, questID)
        local qid = (type(a2) == "number" and a2) or a1
        if type(qid) == "number" then
            taken[qid] = true   -- any quest can fail; escorts are what fail without a timer
            if E:IsEscort(qid) then log("accept", qid) end
        end
    elseif event == "QUEST_DETAIL" then
        local qid = GetQuestID and GetQuestID()
        if qid and qid > 0 then pcall(offered, qid) end
    elseif event == "QUEST_TURNED_IN" then
        local qid = a1
        if type(qid) == "number" then
            taken[qid] = nil
            if E:IsEscort(qid) then log("done", qid) end
        end
    elseif event == "QUEST_LOG_UPDATE" then
        if next(taken) then pcall(checkFailed) end
    end
end)
