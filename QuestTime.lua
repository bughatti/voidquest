----------------------------------------------------------------------
-- VoidQuest — QuestTime: how long quests really take, and which ones players give up on
-- (WoW Forever)
--
-- The user, 2026-11-11, approving the "better than Questie" list: "time per quest -> XP/hour"
-- and "quests players give up on". Every VoidQuest player measures the quests they do; the
-- readings are shared as quest facts (ForeverShare: m = minutes, x = gave up), held back
-- 10-20 minutes like every other find, and used once two players agree.
--
-- Effort, not wall time: you work on several quests at once, so the time between two
-- moments of progress (an objective count going up) goes to the quests that moved, split
-- evenly, and a gap is counted up to IDLE_CAP (AFK, a break, a dungeon run in between). The
-- way there counts: it's part of what the quest costs you. Taking or turning in a quest
-- restarts the clock. So the clock never runs from pickup: someone who grabs every quest in a
-- hub and does them in order of what's closest (the user, 2026-11-11) gives each quest only
-- its own leg, the way from the last quest's area plus its own work; a quest waiting in the
-- log collects nothing. Only quests you took while VoidQuest watched, did solo the whole way,
-- that had something to do (not a talk-to quest) AND that you took within LEVEL_NEAR levels of
-- the quest give a reading (the user, 2026-11-11: "a higher level player can get through it
-- quicker, it really should be based on within 1 to 2 levels of the quest level").
--
-- Gave up: abandoned after GIVEUP_MIN of work, unfinished, and not grey for you (grey quests
-- are dropped as clean-up all the time).
--
-- VoidQuestCharDB.qtime[questID] = { e = effort seconds, f = progress seen, s = taken while
-- watched, g = grouped at some point, lv = quest level, pl = your level when you took it }
----------------------------------------------------------------------
local VQ = VoidQuest
if not VQ.ForeverQuests then return end   -- WoW Forever only

local T = {}
VQ.QuestTime = T

local IDLE_CAP   = 600    -- seconds of a gap that count toward the next progress
local MIN_EFFORT = 45     -- shorter readings are noise (a quest finished on the spot)
local GIVEUP_MIN = 600    -- effort before an abandon counts as giving up
local LEVEL_NEAR = 2      -- a time reading only from a player this close to the quest's level

local function safe(fn, ...)
    if not fn then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
end

local function db()
    VoidQuestCharDB = VoidQuestCharDB or {}
    VoidQuestCharDB.qtime = VoidQuestCharDB.qtime or {}
    return VoidQuestCharDB.qtime
end

-- minutes bucket: 2 / 5 / 10 / 15 / 20 / 30 / 45 / 60 (or more)
local function bucket(sec)
    local m = sec / 60
    if m < 3.5 then return "2" elseif m < 7.5 then return "5" elseif m < 12.5 then return "10"
    elseif m < 17.5 then return "15" elseif m < 25 then return "20" elseif m < 37.5 then return "30"
    elseif m < 52.5 then return "45" end
    return "60"
end
T.Bucket = bucket

-- how far a quest has come: objective counts plus finished objectives
local function progress(qid)
    local p = 0
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
        p = p + (tonumber(o.numFulfilled) or 0) + (o.finished and 1 or 0)
    end
    return p
end

local function share(qid, field, value)
    if VQ.Share and VQ.Share.NoteFact then pcall(VQ.Share.NoteFact, VQ.Share, qid, field, value) end
end

----------------------------------------------------------------------
-- Watching
----------------------------------------------------------------------
local lastEvent = time()

local function scan()
    local d, now, moved = db(), time(), {}
    for qid, rec in pairs(d) do
        if safe(C_QuestLog.GetLogIndexForQuestID, qid) then
            local p = progress(qid)
            if p > (rec.f or 0) then moved[#moved + 1] = qid end
            rec.f = math.max(rec.f or 0, p)
        end
    end
    if #moved == 0 then return end
    local each = math.min(now - lastEvent, IDLE_CAP) / #moved
    local grouped = IsInGroup()
    for _, qid in ipairs(moved) do
        local rec = d[qid]
        rec.e = (rec.e or 0) + each
        if grouped then rec.g = true end
    end
    lastEvent = now
end

local function accepted(qid)
    if not (qid and VQ.ForeverQuests[qid]) then return end
    local idx = safe(C_QuestLog.GetLogIndexForQuestID, qid)
    local info = idx and safe(C_QuestLog.GetInfo, idx)
    db()[qid] = { e = 0, f = progress(qid), s = true, g = IsInGroup() or nil, lv = info and info.level, pl = UnitLevel("player") }
    lastEvent = time()
end

local turnedIn = {}   -- [qid] = time(): QUEST_REMOVED after a turn-in isn't an abandon

-- Quest history (the user, 2026-11-11, Questie basics): when and at which level each quest was
-- turned in, per character, shown in the Quest Book. Kept from this version on.
local function remember(qid)
    VoidQuestCharDB = VoidQuestCharDB or {}
    VoidQuestCharDB.history = VoidQuestCharDB.history or {}
    VoidQuestCharDB.history[qid] = { t = time(), lv = UnitLevel("player") }
end
function T:History(qid)
    local h = VoidQuestCharDB and VoidQuestCharDB.history and VoidQuestCharDB.history[qid]
    return h and h.t, h and h.lv
end

local function finished(qid)
    if VQ.ForeverQuests[qid] then remember(qid) end
    local d = db()
    local rec = d[qid]
    d[qid] = nil
    turnedIn[qid] = time()
    lastEvent = time()
    if not (rec and rec.s and not rec.g and (rec.f or 0) > 0 and (rec.e or 0) >= MIN_EFFORT) then return end
    -- at the quest's level: an over-level player clears it faster than it really takes
    if not (rec.lv and rec.lv > 0 and rec.pl and math.abs(rec.pl - rec.lv) <= LEVEL_NEAR) then return end
    share(qid, "m", bucket(rec.e))
end

local function removed(qid)
    C_Timer.After(1, function()
        if turnedIn[qid] and time() - turnedIn[qid] < 10 then return end
        local d = db()
        local rec = d[qid]
        if not rec or safe(C_QuestLog.GetLogIndexForQuestID, qid) then return end
        d[qid] = nil
        if not (rec.s and (rec.e or 0) >= GIVEUP_MIN) then return end
        -- grey for you: dropped as clean-up, not given up on
        local me = UnitLevel("player") or 0
        local green = safe(UnitQuestTrivialLevelRange, "player") or (GetQuestGreenRange and safe(GetQuestGreenRange)) or 5
        if rec.lv and rec.lv > 0 and rec.lv < me - green then return end
        share(qid, "x", "1")
    end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_LOG_UPDATE", "GROUP_ROSTER_UPDATE" }) do
    ev:RegisterEvent(e)
end
local scanQueued
-- In a group at any moment = every quest in the log is no longer a solo reading (Codex 11-12: grouping
-- was only noticed when progress was counted, so join, get help, leave in between still read as solo)
local function markGrouped()
    if not IsInGroup() then return end
    for _, rec in pairs(db()) do rec.g = true end
end
ev:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "GROUP_ROSTER_UPDATE" then
        markGrouped()
    elseif event == "PLAYER_LOGIN" then
        lastEvent = time()   -- the time before a reload / login isn't known
        markGrouped()   -- logged in (or reloaded) while in a group
        -- quests that left the log while we weren't watching
        C_Timer.After(10, function()
            local d = db()
            for qid in pairs(d) do
                if not safe(C_QuestLog.GetLogIndexForQuestID, qid) then d[qid] = nil end
            end
        end)
    elseif event == "QUEST_ACCEPTED" then
        local qid = (type(a2) == "number" and a2) or a1   -- retail-style (questID) or (logIndex, questID)
        if type(qid) == "number" then pcall(accepted, qid) end
    elseif event == "QUEST_TURNED_IN" then
        if type(a1) == "number" then pcall(finished, a1) end
    elseif event == "QUEST_REMOVED" then
        if type(a1) == "number" then removed(a1) end
    elseif event == "QUEST_LOG_UPDATE" then
        if scanQueued then return end
        scanQueued = true
        C_Timer.After(0.5, function() scanQueued = nil; pcall(scan) end)
    end
end)

----------------------------------------------------------------------
-- Reading it back
----------------------------------------------------------------------
-- Minutes the quest takes (your own reading, else what 2+ players agree on), and whether
-- that's your own.
function T:Minutes(qid)
    if not (VQ.Share and VQ.Share.FactValue) then return nil end
    local v, own = VQ.Share:FactValue(qid, "m")   -- both values (an and-chain keeps only the first)
    return v and tonumber(v), own
end

function T:GaveUp(qid)
    local v = VQ.Share and VQ.Share.FactValue and VQ.Share:FactValue(qid, "x")
    return v == "1"
end

-- One line for tooltips and the "worth it" box, or nil when nothing is known yet.
function T:Line(qid)
    local m, own = self:Minutes(qid)
    local parts = {}
    if m then
        local r = VQ.ForeverQuests[qid]
        local xp = r and tonumber(r[4]) or 0
        local t = (m >= 60 and "an hour or more") or ("about %d min"):format(m)
        local per = xp > 0 and (" · ~%s XP/hour"):format(BreakUpLargeNumbers and BreakUpLargeNumbers(math.floor(xp * 60 / m / 50 + 0.5) * 50)
            or tostring(math.floor(xp * 60 / m))) or ""
        parts[#parts + 1] = ("|cffbbbbbbTakes %s solo at its level (%s)%s|r"):format(t, own and "your time" or "players' times", per)
    end
    if self:GaveUp(qid) then
        parts[#parts + 1] = "|cffff9050Players often give up on this one|r"
    end
    return #parts > 0 and table.concat(parts, "\n") or nil
end

function T:AddTooltip(tt, qid)
    local l = qid and self:Line(qid)
    if l then tt:AddLine(l, 1, 1, 1, true) end
end
