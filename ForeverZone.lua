----------------------------------------------------------------------
-- VoidQuest — WoW Forever: every quest in a zone, and where the known ones start
--
-- Data: ForeverQuests.lua (generated from Blizzard's Game Data API, namespace
-- static-forever-us: all ~6,850 real Forever quests with zone, faction, class, race,
-- XP, money and rewards). The API has NO locations, and Forever's map shows no "!" for
-- quests that aren't in your log (GetAvailableQuestLines is empty for its Classic
-- zones, checked 2026-11-05). So a quest's spot comes from VoidQuest's own learning
-- (QuestStarts.lua: where you accepted it, or where you saw it offered) and the
-- bundled ForeverSeed.lua (the same, from the author's characters). Quests without a
-- known spot are still listed, so you can see what a zone has left.
--
-- Window: the guide panel's "Zone" button (Forever only) or `/vq fz`.
-- World map: a "!" for every quest you can still do whose start is known.
-- Loaded everywhere; does nothing outside Forever (VoidQuest.ForeverQuests is nil).
----------------------------------------------------------------------
local _, ns = ...
local VQ = VoidQuest
local F = {}
VQ.Forever = F

local ZONE_MAP = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
local DUNGEON_MAP = (Enum and Enum.UIMapType and Enum.UIMapType.Dungeon) or 4
local PIN_TEMPLATE = "VoidQuestForeverPinTemplate"
local FLAG_TEXT = { d = "daily", w = "weekly", r = "repeatable", D = "dungeon", R = "raid", E = "elite", P = "PvP" }

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end end
local function Secret(v) return issecretvalue and issecretvalue(v) end

function F:Active() return VQ.ForeverQuests ~= nil end

----------------------------------------------------------------------
-- Data
----------------------------------------------------------------------
-- One quest as a table. Raw rows are positional (see ForeverQuests.lua's header).
function F:Info(id)
    local r = VQ.ForeverQuests and VQ.ForeverQuests[id]
    if not r then return nil end
    local names = VQ.ForeverNames or {}
    return {
        id = id, title = r[1], zone = names[r[2]], faction = r[3], xp = r[4], money = r[5],
        flags = r[6], classes = r[7], races = r[8], group = names[r[9]], rewards = r[10],
        rewardIDs = r[11], reps = r[12] or "", spell = r[13] or 0, needRep = r[14] or "",
    }
end

local me   -- player faction letter, class token, race name
local function Me()
    if me then return me end
    local fac = UnitFactionGroup("player")
    local _, cls = UnitClass("player")
    local race = UnitRace("player")
    me = { fac = (fac == "Alliance" and "A") or (fac == "Horde" and "H") or "", cls = cls or "", race = race or "" }
    return me
end

-- Plain-text list contains (comma separated, no patterns).
local function inList(list, v)
    if list == "" then return true end
    for item in list:gmatch("[^,]+") do if item == v then return true end end
    return false
end

-- Can this character ever do it? (faction, class, race; level is not in the data)
-- quest ID of a data row (built once): the faction table is keyed by ID, the callers pass rows
local idOfRow
local function IdOf(r)
    if not idOfRow then
        idOfRow = {}
        for id, row in pairs(VQ.ForeverQuests or {}) do idOfRow[row] = id end
    end
    return idOfRow[r]
end

function F:Eligible(r)
    local m = Me()
    -- Blizzard leaves the faction blank on most Forever quests (the user, 2026-11-10, Horde: "i am seeing
    -- quests for ironforge"); NorgannonDB's races fill it in (ForeverFaction.lua), and "X" = hidden
    -- developer quests, for no one
    local fac = r[3]
    if fac == "" and VQ.ForeverFaction then
        local id = IdOf(r)
        local known = id and VQ.ForeverFaction[id]
        if known == "X" then return false end
        fac = known or ""
    elseif VQ.ForeverFaction then
        local id = IdOf(r)
        if id and VQ.ForeverFaction[id] == "X" then return false end
    end
    if fac ~= "" and m.fac ~= "" and fac ~= m.fac then return false end
    if not inList(r[7], m.cls) then return false end
    if not inList(r[8], m.race) then return false end
    -- not for this character at all (another class or race, closed off): F:Rule
    local id = IdOf(r)
    if id and self:Rule(id) == "never" then return false end
    return true
end

-- done / log / open
function F:Status(id)
    if safe(C_QuestLog.IsQuestFlaggedCompleted, id) then return "done" end
    if safe(C_QuestLog.GetLogIndexForQuestID, id) then return "log" end
    return "open"
end

-- Quest level: loads async (RequestLoadQuestByID -> QUEST_DATA_LOAD_RESULT). 0 = unknown.
local levels, asked = {}, {}
function F:Level(id)
    if levels[id] then return levels[id] end
    -- kept across sessions (the Quest Book asks for thousands; a quest's level doesn't change)
    local saved = VoidQuestDB and VoidQuestDB.qlv and VoidQuestDB.qlv[id]
    if saved then levels[id] = saved; return saved end
    local lv = safe(C_QuestLog.GetQuestDifficultyLevel, id)
    if lv and not Secret(lv) and lv > 0 then
        levels[id] = lv
        if VoidQuestDB then VoidQuestDB.qlv = VoidQuestDB.qlv or {}; VoidQuestDB.qlv[id] = lv end
        return lv
    end
    if not asked[id] and C_QuestLog.RequestLoadQuestByID then
        asked[id] = GetTime()
        safe(C_QuestLog.RequestLoadQuestByID, id)
    end
    return 0
end

-- Is the level in, so the "too high" check is real? A map "!" waits for it (the user, 2026-11-10:
-- on a fresh install "a lot of quests that went away after a few sec": every level was still
-- unknown, so every quest showed until the levels came in and the too-high ones dropped). A quest
-- the server never answers for shows after LEVEL_WAIT anyway, rather than never.
local LEVEL_WAIT = 8
function F:LevelSettled(id)
    if self:Level(id) > 0 then return true end
    local t = asked[id]
    return type(t) == "number" and GetTime() - t > LEVEL_WAIT
end

-- The level if it's known already (cache, saved, or the client has it), WITHOUT asking the server:
-- the Quest Book classifies 7,000 quests at once and asks for missing levels a few at a time.
function F:KnownLevel(id)
    if levels[id] then return levels[id] end
    local saved = VoidQuestDB and VoidQuestDB.qlv and VoidQuestDB.qlv[id]
    if saved then levels[id] = saved; return saved end
    local lv = safe(C_QuestLog.GetQuestDifficultyLevel, id)
    if lv and not Secret(lv) and lv > 0 then
        levels[id] = lv
        if VoidQuestDB then VoidQuestDB.qlv = VoidQuestDB.qlv or {}; VoidQuestDB.qlv[id] = lv end
        return lv
    end
    return 0
end

-- Can you take it NOW? The game has no API for a quest's required level, so it's learned:
--   blocked: the last time you talked to its giver it wasn't offered to you (too low a
--            level, or an earlier quest first). Per character; back to "maybe" when you
--            level past it, and checked again the next time you talk to them.
--   red:     its level is 5+ above yours (the game colours it red: too hard anyway).
-- Returns available, reason ("" when available).
local RED = 5

-- Grey (low-level) quests: Blizzard hides their "!" unless Low-Level Quests is on (map
-- Filter, or minimap tracking), and so do we, for the map pins and the guide's pick-up
-- step (the user, 2026-11-07: Derek Swiftdigger had a pin but no "!" in the world).
local function lowLevelHidden(id)
    if C_Minimap and C_Minimap.IsTrackingHiddenQuests and safe(C_Minimap.IsTrackingHiddenQuests) then return false end
    local t = safe(C_QuestLog.IsQuestTrivial, id)
    if t == nil or Secret(t) then return false end
    return t and true or false
end

----------------------------------------------------------------------
-- What a quest needs before its giver offers it (ForeverRules.lua, from NorgannonDB:
-- tools/cmd/vq-rules). The user, 2026-11-11: a "!" for the third "The Swarm Grows" at a
-- giver who only offers it after the first two; "we need to fix anything like this through
-- all the quests". F:Rule(id) -> kind, reason:
--   "never": not for this character (another class or race, past its max level, closed by a
--            quest you did, a lead-in whose quest you already have): no "!", not listed
--   "later": not yet (level, an earlier quest, profession skill, reputation, a holiday)
--   nil:     nothing in the way
----------------------------------------------------------------------
local function bitSet(mask, id)
    if not (mask and id and id > 0) then return true end
    return math.floor(mask / 2 ^ (id - 1)) % 2 == 1
end
-- F.assumeDone: quests the route planner will have you turn in first (RoutePlan.lua asks "could
-- I take this once those are done?" for follow-ups; nil the rest of the time)
local function doneQ(q) return (F.assumeDone and F.assumeDone[q]) or safe(C_QuestLog.IsQuestFlaggedCompleted, q) == true end
local function inLogQ(q) return safe(C_QuestLog.GetLogIndexForQuestID, q) ~= nil end
local function titleQ(q)
    local t = C_QuestLog.GetTitleForQuestID and safe(C_QuestLog.GetTitleForQuestID, q)
    if (not t or t == "") and VQ.ForeverQuests and VQ.ForeverQuests[q] then t = VQ.ForeverQuests[q][1] end
    return t and ("\"" .. t .. "\"") or "an earlier quest"
end
-- the first step still to do back down a chain (1147 -> 1146 -> 1145)
local function undonePrev(rr)
    if not rr then return nil end
    for _, q in ipairs(rr.pa or {}) do if not doneQ(q) then return q end end
    if rr.py then
        for _, q in ipairs(rr.py) do if doneQ(q) then return nil end end
        return rr.py[1]
    end
end
-- the first quest still to do down a chain of earlier quests (1147 -> 1146 -> 1145)
local function firstStep(q)
    local start = q
    for _ = 1, 10 do
        local p = undonePrev(VQ.ForeverRules and VQ.ForeverRules[q])
        if not p or p == start then break end
        q = p
    end
    return q
end
F.FirstStep = function(_, q) return firstStep(q) end
local function needsText(q)
    q = firstStep(q)
    if inLogQ(q) then return ("Finish and turn in %s first (it's in your log)"):format(titleQ(q)) end
    local s = VQ.Starts and VQ.Starts:Get(q)
    local zone = s and s.m and C_Map.GetMapInfo(s.m)
    local giver = VQ.Starts and VQ.Starts.Giver and VQ.Starts:Giver(q)
    local where = {}
    if giver then where[#where + 1] = "from " .. giver end
    if zone and zone.name then where[#where + 1] = "in " .. zone.name end
    return ("Needs %s %sfirst"):format(titleQ(q), #where > 0 and (table.concat(where, " ") .. " ") or "")
end
local SKILL = { [129] = "First Aid", [164] = "Blacksmithing", [165] = "Leatherworking", [171] = "Alchemy",
    [182] = "Herbalism", [185] = "Cooking", [186] = "Mining", [197] = "Tailoring", [202] = "Engineering",
    [333] = "Enchanting", [356] = "Fishing", [393] = "Skinning", [755] = "Jewelcrafting", [773] = "Inscription" }
local function mySkill(line)
    if not (GetProfessions and GetProfessionInfo) then return nil end
    local raw = { pcall(GetProfessions) }   -- up to 6 (Cooking, Fishing, First Aid last): not safe(), which keeps 3
    if not raw[1] then return nil end
    table.remove(raw, 1)
    for i = 1, 6 do
        local idx = raw[i]
        if idx then
            local ok, _, _, rank, _, _, _, l = pcall(GetProfessionInfo, idx)
            if ok and l == line then return rank or 0 end
        end
    end
    return 0   -- not learned
end
local STANDING = { "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted" }
local function standingOfRaw(v)
    if v >= 42000 then return 8 elseif v >= 21000 then return 7 elseif v >= 9000 then return 6
    elseif v >= 3000 then return 5 elseif v >= 0 then return 4 elseif v >= -3000 then return 3
    elseif v >= -6000 then return 2 end
    return 1
end
-- standing tier (1-8), the faction's name, and raw reputation points when the game gives them
-- (Codex 11-11: tiers alone let 3000 rep pass a 5000 requirement, both Friendly)
local function myStanding(fid)
    local d = C_Reputation and C_Reputation.GetFactionDataByID and safe(C_Reputation.GetFactionDataByID, fid)
    local r = d and d.reaction
    if type(r) == "number" and not Secret(r) then
        local raw = d.currentStanding
        if type(raw) ~= "number" or Secret(raw) then raw = nil end
        return r, d.name, raw
    end
end

-- a holiday on the calendar today (Darkmoon Faire, Lunar Festival, ...). Unknown (no calendar data)
-- counts as yes: a holiday quest is only held back when the calendar says nothing is on (Codex 11-11)
local holidayAt, holidayOn = 0, true
local function holidayToday()
    if GetTime() - holidayAt < 60 then return holidayOn end
    holidayAt = GetTime()
    local t = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime and safe(C_DateAndTime.GetCurrentCalendarTime)
    local n = t and C_Calendar and C_Calendar.GetNumDayEvents and safe(C_Calendar.GetNumDayEvents, 0, t.monthDay)
    if type(n) ~= "number" or n == 0 then holidayOn = true; return true end
    holidayOn = false
    for i = 1, n do
        local e = safe(C_Calendar.GetDayEvent, 0, t.monthDay, i)
        -- an event we can't read is unknown: don't hold holiday quests back (Codex 11-11)
        if not e or e.calendarType == "HOLIDAY" then holidayOn = true; break end
    end
    return holidayOn
end

function F:Rule(id)
    local rr = VQ.ForeverRules and VQ.ForeverRules[id]
    if not rr then return nil end
    local _, _, cls = UnitClass("player")
    local _, _, race = UnitRace("player")
    if rr.c and not bitSet(rr.c, cls) then return "never", "For another class" end
    if rr.r and not bitSet(rr.r, race) then return "never", "For other races" end
    local lvl = UnitLevel("player") or 0
    if rr.xl and lvl > rr.xl then return "never", ("Only up to level %d"):format(rr.xl) end
    if rr.db and doneQ(rr.db) then return "never", "Closed: you did " .. titleQ(rr.db) end
    for _, q in ipairs(rr.ex or {}) do
        if doneQ(q) or inLogQ(q) then return "never", "Can't do both: you did or took " .. titleQ(q) end
    end
    if rr.bf and (doneQ(rr.bf) or inLogQ(rr.bf)) then
        return "never", "A lead-in for " .. titleQ(rr.bf) .. ", which you already have"
    end
    if rr.rx then
        local mine, _, raw = myStanding(rr.rx[1])
        local past = (raw and raw > rr.rx[2]) or (not raw and mine and mine > standingOfRaw(rr.rx[2]))
        if past then return "never", "Your reputation is past what it allows" end
    end
    if rr.hol and not holidayToday() then return "later", "A holiday quest: only while its holiday is on" end
    if rr.ml and lvl < rr.ml then return "later", ("Needs level %d"):format(rr.ml) end
    if undonePrev(rr) then return "later", needsText(id), firstStep(id) end   -- 3rd: where to go first
    if rr.sk then
        local have = mySkill(rr.sk[1])
        if have and have < rr.sk[2] then
            return "later", ("Needs %s %d"):format(SKILL[rr.sk[1]] or "a profession", rr.sk[2])
        end
    end
    if rr.rp then
        local mine, name, raw = myStanding(rr.rp[1])
        local need = standingOfRaw(rr.rp[2])
        if (raw and raw < rr.rp[2]) or (not raw and mine and mine < need) then return "later", ("Needs %s with %s"):format(STANDING[need] or "more", name or "a faction") end
    end
    if rr.sp and IsPlayerSpell then
        local known = safe(IsPlayerSpell, math.abs(rr.sp))
        if rr.sp > 0 and known == false then return "later", "Needs a spell you haven't learned yet" end
        if rr.sp < 0 and known == true then return "never", "Not for characters who know that spell" end
    end
    return nil
end

-- An escort's giver walks off with whoever took it and is gone for everyone until that escort
-- ends (the user, 2026-11-11, at Free at Last: "there is no npc here to get it").
-- EscortWatch adds quests players proved are escorts, and how long they waited at the giver.
function F:EscortNote(id)
    local W = VQ.EscortWatch
    local isEscort = (VQ.ForeverEscort and VQ.ForeverEscort[id]) or (W and W:IsEscort(id))
    if not isEscort then return nil end
    local giver = VQ.Starts and VQ.Starts.Giver and VQ.Starts:Giver(id)
    local wait = W and W:Wait(id)
    local back = (wait and wait > 0) and ("Players waited about %d%s minutes."):format(wait, wait >= 15 and "+" or "")
        or "Back in a few minutes."
    return ("Escort quest: if %s isn't here, another player is on the escort. %s"):format(giver or "the giver", back)
end

-- Items a quest needs that ANOTHER quest gives as its reward (the user, 2026-11-12, Catch of the
-- Day: "Talk to Jinar'Zillen ... bring 2 Bloodbelly Fish", and Jinar'Zillen only offers "Fish in a
-- Bucket", which looks like a low-level side quest but is how you get the fish).
-- Reward names come from ForeverQuests (field 10: "A", "A, B" or "choose: A / B").
local rewardIndex   -- lower-case item name -> { quest ids that reward it }
local function RewardIndex()
    if rewardIndex then return rewardIndex end
    rewardIndex = {}
    for id, r in pairs(VQ.ForeverQuests or {}) do
        local s = type(r[10]) == "string" and r[10]:gsub("^choose:%s*", "") or ""
        for name in (s .. ","):gsub("%s*/%s*", ","):gmatch("%s*([^,]-)%s*,") do
            if name ~= "" then
                local k = name:lower()
                local t = rewardIndex[k]
                if not t then t = {}; rewardIndex[k] = t end
                t[#t + 1] = id
            end
        end
    end
    return rewardIndex
end

-- An objective's item name: "Bloodbelly Fish: 0/2" or "0/2 Bloodbelly Fish".
local function objectiveItem(o)
    if type(o) ~= "table" or o.finished or type(o.text) ~= "string" then return nil end
    if issecretvalue and issecretvalue(o.text) then return nil end
    if o.type and o.type ~= "item" then return nil end
    local n = o.text:match("^(.-):%s*%d+%s*/%s*%d+") or o.text:match("^%d+%s*/%s*%d+%s+(.+)$")
    return n and n ~= "" and n or nil
end

-- -> { { item, src, title, giver, spot }, ... } for the unfinished item objectives of a quest in
-- your log that another quest hands out. The source quest whose giver the quest's own text names
-- wins (Catch of the Day names Jinar'Zillen), then one in the same zone. Done ones that can't be
-- repeated are skipped.
function F:ItemSources(qid)
    if not (qid and VQ.ForeverQuests) then return nil end
    local objs = safe(C_QuestLog.GetQuestObjectives, qid)
    if type(objs) ~= "table" or #objs == 0 then return nil end
    local idx, out = RewardIndex(), nil
    local own = VQ.ForeverQuests[qid]
    local text = ""
    local li = safe(C_QuestLog.GetLogIndexForQuestID, qid)
    if li and GetQuestLogQuestText then
        local ok, story, todo = pcall(GetQuestLogQuestText, li)
        if ok then text = ((type(todo) == "string" and todo or "") .. " " .. (type(story) == "string" and story or "")) end
        if issecretvalue and issecretvalue(text) then text = "" end
    end
    for _, o in ipairs(objs) do
        local item = objectiveItem(o)
        local list = item and idx[item:lower()]
        if list then
            local best, bestScore
            for _, src in ipairs(list) do
                local r = VQ.ForeverQuests[src]
                local repeatable = r and type(r[6]) == "string" and r[6]:find("[rdw]") ~= nil
                if src ~= qid and r and (repeatable or self:Status(src) ~= "done") then
                    local giver = VQ.Starts and VQ.Starts:Giver(src)
                    local named = giver and text:find(giver, 1, true) ~= nil
                    local sameZone = own and r[2] == own[2]
                    -- only a real hand-off: the quest names its giver, or it's a no-XP quest in the same
                    -- zone (Fish in a Bucket). Plain rewards (Catch of the Day itself gives Mithril Ore)
                    -- mustn't send someone who needs ore off to a quest.
                    if named or (sameZone and (tonumber(r[4]) or 0) == 0) then
                        local score = (named and 4 or 0) + (sameZone and 2 or 0) + (self:Spot(src) and 1 or 0)
                        if not bestScore or score > bestScore then best, bestScore = src, score end
                    end
                end
            end
            if best then
                -- what the source quest asks for in turn (the user, 2026-11-12: Fish in a Bucket wants 5
                -- Shellfish, from Shellfish Traps by Shadowprey or the Auction House)
                local asks
                for _, m in ipairs(VQ.ForeverMobs and VQ.ForeverMobs[best] or {}) do
                    if m[1] == "d" and (m[3] or 0) ~= 0 then
                        local iname = C_Item and C_Item.GetItemNameByID and safe(C_Item.GetItemNameByID, m[3])
                        local from = VQ.ForeverMobNames and VQ.ForeverMobNames[m[2]]
                        if iname and not (asks and asks:find(iname, 1, true)) then
                            asks = (asks and (asks .. ", ") or "") .. iname .. (from and (" from a " .. from) or "")
                        end
                    end
                end
                out = out or {}
                out[#out + 1] = { item = item, src = best, title = VQ.ForeverQuests[best][1],
                    giver = VQ.Starts and VQ.Starts:Giver(best), spot = self:Spot(best), asks = asks }
            end
        end
    end
    return out
end

-- "Bloodbelly Fish: take 'Fish in a Bucket' from Jinar'Zillen (it gives them)." or nil
function F:ItemSourceNote(qid)
    local list = self:ItemSources(qid)
    if not list then return nil end
    local parts = {}
    for _, s in ipairs(list) do
        parts[#parts + 1] = ("%s: take '%s'%s, it gives them%s."):format(s.item, s.title or "?",
            s.giver and (" from " .. s.giver) or "",
            s.asks and (" (it asks for " .. s.asks .. ", or buy them)") or "")
    end
    return table.concat(parts, " ")
end

function F:Available(id)
    if lowLevelHidden(id) then
        return false, "Low level: Blizzard hides these (map Filter > Low-Level Quests shows them)"
    end
    local lvl = UnitLevel("player") or 0
    local b = not self.assumeDone and VoidQuestCharDB and VoidQuestCharDB.blocked and VoidQuestCharDB.blocked[id]
    if b and lvl <= b then return false, "Not offered to you yet (level or an earlier quest first)" end
    -- a known earlier quest you haven't turned in: no "!" yet, and say which one
    -- what NorgannonDB says the quest needs (F:Rule); only quests it has nothing on fall back to
    -- the earlier quest of a known chain link
    local kind, why, first = self:Rule(id)
    if kind then return false, why, first end
    local prev = not (VQ.ForeverRules and VQ.ForeverRules[id]) and VQ.Chains and VQ.Chains.Earlier and VQ.Chains:Earlier(id)
    if prev then
        -- back to the first step still to do (1147 -> 1146 -> 1145: Korran, not Belgrom)
        for _ = 1, 10 do
            local p = VQ.Chains:Earlier(prev)
            if not p or p == id then break end
            prev = p
        end
        local t = (C_QuestLog.GetTitleForQuestID and safe(C_QuestLog.GetTitleForQuestID, prev)) or (VQ.ForeverQuests and VQ.ForeverQuests[prev] and VQ.ForeverQuests[prev][1])
        local s = VQ.Starts and VQ.Starts:Get(prev)
        local zone = s and s.m and C_Map.GetMapInfo(s.m)
        local where = {}
        local giver = VQ.Starts and VQ.Starts.Giver and VQ.Starts:Giver(prev)
        if giver then where[#where + 1] = "from " .. giver end
        if zone and zone.name then where[#where + 1] = "in " .. zone.name end
        return false, ("Needs %s %sfirst"):format(t and ("\"" .. t .. "\"") or "an earlier quest",
            #where > 0 and (table.concat(where, " ") .. " ") or ""), prev   -- 3rd: the grey pin's first step (Codex 11-11)
    end
    local ql = self:Level(id)
    if ql > 0 and ql >= lvl + RED then return false, ("Level %d: too high for you yet"):format(ql) end
    return true, ""
end

-- Where it starts: learned (this install) or seeded. { m, x, y, how } or nil.
function F:Spot(id)
    local s = VQ.Starts and VQ.Starts:Get(id)
    if s and s.m and s.x and s.y and s.m > 0 and s.x > 0 and s.y > 0 then return s end
end

-- byZone[name] = { ids } (built once)
local byZone
local function Index()
    if byZone then return byZone end
    byZone = {}
    local names = VQ.ForeverNames or {}
    for id, r in pairs(VQ.ForeverQuests or {}) do
        local z = names[r[2]] or names[r[9]] or "Other"
        local t = byZone[z]
        if not t then t = {}; byZone[z] = t end
        t[#t + 1] = id
    end
    return byZone
end

-- The zone the player is in, as the API names it: walk up from micro maps / floors to
-- the Zone (or the Dungeon, inside one).
function F:PlayerZone()
    local m = safe(C_Map.GetBestMapForUnit, "player")
    for _ = 1, 6 do
        local mi = m and safe(C_Map.GetMapInfo, m)
        if not mi then return nil end
        if mi.mapType == ZONE_MAP or mi.mapType == DUNGEON_MAP then return mi.name, m end
        if not mi.parentMapID or mi.parentMapID == 0 then return mi.name, m end
        m = mi.parentMapID
    end
end

-- In the Min / Mid / Max tier (Chains.lua grades; Max = everything).
function F:InScope(id)
    local C = VQ.Chains
    return not C or C:InScope(id)
end

-- Eligible quests of a zone, sorted: in log, open (known spot, then level), open but not
-- for you yet ("later"), then done. e.scope: open and in the Min / Mid / Max tier (what
-- the guide picks and the map pins); e.important: starred in the zone window.
local ORDER = { log = 1, open = 2, later = 3, done = 4 }
function F:ZoneList(zone)
    local out = {}
    local C = VQ.Chains
    for _, id in ipairs(Index()[zone] or {}) do
        local r = VQ.ForeverQuests[id]
        if self:Eligible(r) then
            local st = self:Status(id)
            if st == "open" and not self:Available(id) then st = "later" end
            local live = st == "open" or st == "log"
            out[#out + 1] = { id = id, title = r[1], flags = r[6], status = st,
                spot = self:Spot(id), level = self:Level(id),
                scope = st == "open" and self:InScope(id),
                important = live and C and C:Important(id) or false }
        end
    end
    table.sort(out, function(a, b)
        if a.status ~= b.status then return ORDER[a.status] < ORDER[b.status] end
        if (a.spot ~= nil) ~= (b.spot ~= nil) then return a.spot ~= nil end
        if a.level ~= b.level then
            if a.level == 0 or b.level == 0 then return a.level > b.level end
            return a.level < b.level
        end
        return a.title < b.title
    end)
    return out
end

-- The quest book (the user, 2026-11-10: "i dont see an achievements panel like retail to check if i have
-- completed a quest ... i had to look online for other bag quests i can do at 31"): every zone at once,
-- matched by quest title, zone or reward name; bags = quests that reward a bag (ForeverBags.lua, slot
-- counts from Blizzard's item table). Levels are asked for only once the list is short, so typing one
-- letter doesn't request 7,000 quests from the server.
local LEVEL_ASK_MAX = 300
function F:BagOf(r)
    local B = VQ.ForeverBags
    if not (B and r[11] and r[11] ~= "") then return nil end
    local best, bestID
    for tok in r[11]:gmatch("%d+") do
        local b = B[tonumber(tok)]
        if b and (not best or (b[2] == 0 and best[2] ~= 0) or (b[2] == best[2] and b[1] > best[1])) then
            best, bestID = b, tonumber(tok)
        end
    end
    return best, bestID   -- { slots, family }, itemID; normal bags preferred over quivers / pouches
end

function F:Search(text, bagsOnly)
    text = (text or ""):lower()
    local names = VQ.ForeverNames or {}
    local out = {}
    for id, r in pairs(VQ.ForeverQuests or {}) do
        if self:Eligible(r) then
            local bag = self:BagOf(r)
            local ok = not bagsOnly or bag ~= nil
            if ok and text ~= "" then
                local zone = names[r[2]] or names[r[9]] or ""
                ok = r[1]:lower():find(text, 1, true) or zone:lower():find(text, 1, true)
                    or (r[10] or ""):lower():find(text, 1, true)
            end
            if ok then
                out[#out + 1] = { id = id, title = r[1], flags = r[6], zone = names[r[2]] or names[r[9]], bag = bag }
            end
        end
    end
    local ask = #out <= LEVEL_ASK_MAX
    for _, e in ipairs(out) do
        local st = self:Status(e.id)
        if st == "open" and ask then
            -- grey (low-level) quests still count here: an old bag quest is still a bag
            local avail, why = self:Available(e.id)
            if not avail then
                if (why or ""):find("^Low level") then e.low = true else st = "later" end
            end
        end
        e.status = st
        e.spot = self:Spot(e.id)
        e.level = ask and self:Level(e.id) or 0
    end
    table.sort(out, function(a, b)
        if a.status ~= b.status then return ORDER[a.status] < ORDER[b.status] end
        if a.level ~= b.level then
            if a.level == 0 or b.level == 0 then return a.level > b.level end
            return a.level < b.level
        end
        return a.title < b.title
    end)
    return out, ask
end

-- Bags you can buy (VoidGPS's vendor lists): normal bags biggest first, then reagent / special bags.
-- The user, 2026-11-10: "regeant bags also" (no reagent bag is a quest reward in Forever: vendors sell
-- the Apprentice's Herb Pouch / Mining Pack / Skinning Satchel and the Herb Pouch, the rest is crafted).
F.BAG_KIND = { [1] = "quiver", [2] = "ammo pouch", [4] = "soul bag", [8] = "leatherworking bag", [32] = "herb bag",
    [64] = "enchanting bag", [128] = "engineering bag", [512] = "gem bag", [1024] = "mining bag",
    [33554432] = "skinning bag" }
function F:VendorBags()
    local Goods = VoidGPS and VoidGPS.Goods
    if not (Goods and Goods.Get and VQ.ForeverBags) then return {} end
    local out = {}
    for item, b in pairs(VQ.ForeverBags) do
        local e = Goods:Get(item)
        local v
        for _, x in ipairs(e and e.vendors or {}) do if not x.cost then v = x; break end end
        if v then
            out[#out + 1] = { vendor = true, item = item, name = e.name, slots = b[1], family = b[2],
                buy = e.buy, qty = e.qty or 1, v = v, limited = v.limited }
        end
    end
    table.sort(out, function(a, b)
        if (a.family == 0) ~= (b.family == 0) then return a.family == 0 end
        if a.slots ~= b.slots then return a.slots > b.slots end
        return (a.buy or 0) < (b.buy or 0)
    end)
    return out
end

local function VendorTooltip(owner, e)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(e.item)
    local coin = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or _G.GetCoinTextureString
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("Sold by %s%s"):format(e.v.name, e.v.yards and (" (%d yd)"):format(e.v.yards) or ""), 0.6, 1, 0.6)
    if e.buy and e.buy > 0 then GameTooltip:AddLine(coin and coin(e.buy) or GetMoneyString(e.buy), 1, 1, 1) end
    if e.limited then GameTooltip:AddLine("Limited stock", 1, 0.5, 0.3) end
    GameTooltip:AddLine("Click: the way to the vendor (VoidGPS)", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

-- Zones with at least one quest this character can do, with done / total.
function F:Zones()
    local out = {}
    for z, ids in pairs(Index()) do
        local total, done = 0, 0
        for _, id in ipairs(ids) do
            if self:Eligible(VQ.ForeverQuests[id]) then
                total = total + 1
                if safe(C_QuestLog.IsQuestFlaggedCompleted, id) then done = done + 1 end
            end
        end
        if total > 0 then out[#out + 1] = { zone = z, total = total, done = done } end
    end
    table.sort(out, function(a, b) return a.zone < b.zone end)
    return out
end

----------------------------------------------------------------------
-- Pin / track one quest
----------------------------------------------------------------------
function F:Go(id)
    local info = self:Info(id)
    if not info then return end
    if self:Status(id) == "log" then
        safe(C_SuperTrack.SetSuperTrackedQuestID, id)
        VQ:Print(("tracking %s (it's in your log)."):format(info.title))
        return
    end
    local s = self:Spot(id)
    if not s then
        VQ:Print(("%s: no known start yet. VoidQuest learns it when any of your characters sees it offered or picks it up."):format(info.title))
        return
    end
    local giver = VQ.Starts and VQ.Starts:Giver(id)
    local ok, why = ns.Route:Go({ map = s.m, x = s.x, y = s.y, name = giver or info.title },
        { say = function(msg) VQ:Print(msg) end })
    if not ok then VQ:Print(("%s: %s"):format(info.title, why or "can't pin there")) end
end

local function Tooltip(owner, id, anchor)
    local info = F:Info(id)
    if not info then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:AddLine(info.title, 1, 0.82, 0)
    local lv = F:Level(id)
    local bits = {}
    if lv > 0 then bits[#bits + 1] = "level " .. lv end
    for c in (info.flags or ""):gmatch(".") do if FLAG_TEXT[c] then bits[#bits + 1] = FLAG_TEXT[c] end end
    if info.group and info.group ~= info.zone then bits[#bits + 1] = info.group end
    if #bits > 0 then GameTooltip:AddLine(table.concat(bits, ", "), 0.7, 0.7, 0.7) end
    if info.zone then GameTooltip:AddLine(info.zone, 0.53, 0.8, 1) end
    local st = F:Status(id)
    local doneLine = "Done"
    if st == "done" and VQ.QuestTime then
        local t, lv = VQ.QuestTime:History(id)
        if t then doneLine = ("Done %s%s"):format(date("%b %d, %Y", t), lv and (" at level %d"):format(lv) or "") end
    end
    GameTooltip:AddLine(st == "done" and doneLine or st == "log" and "In your quest log" or "Not done", 1, 1, 1)
    if st == "open" then
        local ok, why = F:Available(id)
        if not ok then GameTooltip:AddLine(why, 1, 0.5, 0.3, true) end
        local seen = VoidQuestDB and VoidQuestDB.offerLevel and VoidQuestDB.offerLevel[id]
        local sd = VQ.ForeverSeed and VQ.ForeverSeed[id]
        if sd and sd.lv and (not seen or sd.lv < seen) then seen = sd.lv end
        if seen then GameTooltip:AddLine(("Offered to a level %d character"):format(seen), 0.7, 0.7, 0.7) end
    end
    if info.xp and info.xp > 0 then GameTooltip:AddLine(("%d XP"):format(info.xp), 1, 1, 1) end
    -- (the quest time comes with VQ.Worth:AddTooltip below; adding it here too doubled it, Codex 11-12)
    if info.money and info.money > 0 then
        -- the global GetCoinTextureString doesn't exist on WoW Forever (C_CurrencyInfo has it)
        local coin = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or _G.GetCoinTextureString
        GameTooltip:AddLine(coin and coin(info.money) or GetMoneyString(info.money), 1, 1, 1)
    end
    if info.rewards and info.rewards ~= "" then GameTooltip:AddLine(info.rewards, 0.8, 0.8, 0.8, true) end
    -- a bag says how big it is (the user, 2026-11-10: "the bags dont say slots")
    local bag, bagID = F:BagOf(VQ.ForeverQuests[id])
    if bag then
        local kind = bag[2] ~= 0 and (F.BAG_KIND and F.BAG_KIND[bag[2]] or "special bag") or "bag"
        local name = bagID and safe(C_Item.GetItemNameByID, bagID)
        GameTooltip:AddLine(("Bag: %d-slot %s%s"):format(bag[1], kind, name and (" (" .. name .. ")") or ""), 0.4, 1, 0.4)
    end
    if VQ.Worth then VQ.Worth:AddTooltip(GameTooltip, id) end
    local giver = VQ.Starts and VQ.Starts:Giver(id)
    if giver then GameTooltip:AddLine("Given by " .. giver, 0.6, 1, 0.6) end
    local esc = st == "open" and F:EscortNote(id)
    if esc then GameTooltip:AddLine(esc, 1, 0.82, 0, true) end
    GameTooltip:AddLine(" ")
    if st == "log" then
        GameTooltip:AddLine("Click: track it", 0.6, 0.6, 0.6)
    elseif F:Spot(id) then
        GameTooltip:AddLine("Click: pin where it starts", 0.6, 0.6, 0.6)
    else
        GameTooltip:AddLine("Start not known yet (learned when you see it offered or pick it up)", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

F.QuestTooltip = Tooltip   -- the Quest Book uses the same tooltip

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local ROW_H, ROWS = 16, 22
local win

local function Build()
    local f = CreateFrame("Frame", "VoidQuestForeverZone", UIParent, "BackdropTemplate")
    f:Hide()
    f:SetSize(380, 74 + ROW_H * ROWS)
    f:SetPoint("CENTER", 260, 40)
    f:SetFrameStrata("HIGH"); f:SetToplevel(true)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    ns.Move(f, { db = function() return VoidQuestDB end, key = "foreverZone" })   -- drag + kept after a restart (VoidMove.lua)
    f:SetClampedToScreen(true)
    VQ:CreateBackdrop(f)
    tinsert(UISpecialFrames, "VoidQuestForeverZone")   -- Esc closes it

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 10, -9); f.title:SetPoint("RIGHT", -30, 0); f.title:SetJustifyH("LEFT")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)

    f.zoneBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.zoneBtn:SetSize(90, 20); f.zoneBtn:SetPoint("TOPLEFT", 8, -28); f.zoneBtn:SetText("Zone...")
    f.zoneBtn:SetScript("OnClick", function(b) F:ZoneMenu(b) end)
    f.hereBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.hereBtn:SetSize(70, 20); f.hereBtn:SetPoint("LEFT", f.zoneBtn, "RIGHT", 4, 0); f.hereBtn:SetText("Here")
    f.hereBtn:SetScript("OnClick", function() F.zone = nil; F:Render() end)

    f.hideDone = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.hideDone:SetSize(22, 22); f.hideDone:SetPoint("LEFT", f.hereBtn, "RIGHT", 8, 0)
    f.hideDone.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.hideDone.label:SetPoint("LEFT", f.hideDone, "RIGHT", 0, 1); f.hideDone.label:SetText("Hide done & later")
    f.hideDone:SetScript("OnClick", function(b) VQ:Set("foreverHideDone", b:GetChecked() and true or false); F:Render() end)

    -- the whole Quest Book (QuestBook.lua): every zone, done / can do, search by reward
    f.bookBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.bookBtn:SetSize(50, 20); f.bookBtn:SetPoint("TOPRIGHT", -8, -28); f.bookBtn:SetText("Book")
    f.bookBtn:SetScript("OnClick", function() if VQ.Book then VQ.Book:Toggle() end end)

    f.scroll = CreateFrame("ScrollFrame", nil, f, "FauxScrollFrameTemplate")
    f.scroll:SetPoint("TOPLEFT", 8, -54); f.scroll:SetPoint("BOTTOMRIGHT", -28, 10)
    f.scroll:SetScript("OnVerticalScroll", function(s, off) FauxScrollFrame_OnVerticalScroll(s, off, ROW_H, function() F:Render() end) end)

    f.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, f)
        row:SetSize(340, ROW_H)
        row:SetPoint("TOPLEFT", 10, -54 - (i - 1) * ROW_H)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 2, 0); row.text:SetPoint("RIGHT", -60, 0); row.text:SetJustifyH("LEFT"); row.text:SetWordWrap(false)
        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.right:SetPoint("RIGHT", -2, 0); row.right:SetWidth(58); row.right:SetJustifyH("RIGHT")
        row:SetScript("OnClick", function(s)
            if s.id then F:Go(s.id)
            elseif s.vend and VoidGPS and VoidGPS.Goods then VoidGPS.Goods:GoVendor(s.vend.v, s.vend.name) end
        end)
        row:SetScript("OnEnter", function(s)
            if s.id then Tooltip(s, s.id) elseif s.vend then VendorTooltip(s, s.vend) end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.rows[i] = row
    end
    f:SetScript("OnShow", function() F:Render() end)
    return f
end

function F:Render()
    if not (win and win:IsShown()) then return end
    local zone = self.zone or self:PlayerZone() or "?"
    local all = self:ZoneList(zone)
    local hide = VQ:Get("foreverHideDone") == true
    win.hideDone:SetChecked(hide)
    local list, done, known = {}, 0, 0
    for _, e in ipairs(all) do
        if e.status == "done" then done = done + 1 end
        if e.spot and e.status == "open" then known = known + 1 end
        if not (hide and (e.status == "done" or e.status == "later")) then list[#list + 1] = e end
    end
    win.title:SetText(("%s  |cffaaaaaa%d / %d done, %d starts known|r"):format(zone, done, #all, known))
    FauxScrollFrame_Update(win.scroll, #list, ROWS, ROW_H)
    local off = FauxScrollFrame_GetOffset(win.scroll)
    for i, row in ipairs(win.rows) do
        local e = list[off + i]
        row.id = e and e.id
        row.vend = nil
        if e then
            local lv = e.level > 0 and ("[" .. e.level .. "] ") or ""
            local tag = ""
            for c in e.flags:gmatch("[dwDRP]") do tag = tag .. " |cff88ccff(" .. FLAG_TEXT[c] .. ")|r" end
            local color = (e.status == "done" or e.status == "later") and "|cff777777"
                or e.status == "log" and "|cffffd200" or "|cffffffff"
            local star = e.important and VQ.Chains.STAR or ""
            row.text:SetText(star .. color .. lv .. e.title .. "|r" .. tag)
            row.right:SetText(e.status == "done" and "done" or e.status == "log" and "in log"
                or e.status == "later" and "later" or e.spot and "|cff88ccffpin|r" or "")
            row:Show()
        else
            row:Hide()
        end
    end
end

function F:ZoneMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        if root.SetScrollMode then root:SetScrollMode(400) end
        for _, z in ipairs(F:Zones()) do
            root:CreateButton(("%s  |cffaaaaaa%d/%d|r"):format(z.zone, z.done, z.total), function()
                F.zone = z.zone; F:Render()
            end)
        end
    end)
end

function F:Toggle()
    if not self:Active() then VQ:Print("the zone quest list is for WoW Forever."); return end
    win = win or Build()
    win:SetShown(not win:IsShown())
end

----------------------------------------------------------------------
-- World map pins: open, eligible quests whose start is known, on the shown map
----------------------------------------------------------------------
VoidQuestForeverPinMixin = CreateFromMixins(MapCanvasPinMixin)

function VoidQuestForeverPinMixin:OnLoad()
    self:SetScalingLimits(1, 0.8, 1.1)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_QUEST_OFFER")
end

-- first: set when an earlier quest has to be done first (a grey "!"; the click routes to it)
function VoidQuestForeverPinMixin:OnAcquired(id, x, y, first)
    self.id, self.first = id, first
    self:SetPosition(x, y)
    if self.icon then
        self.icon:SetDesaturated(first ~= nil)
        if first then self.icon:SetVertexColor(0.75, 0.75, 0.85, 0.85) else self.icon:SetVertexColor(1, 1, 1, 1) end
    end
    self:SetSize(first and 15 or 18, first and 15 or 18)
    self:Show()
end

function VoidQuestForeverPinMixin:OnMouseEnter()
    if not self.id then return end
    if self.first then
        local _, why = F:Available(self.id)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local t = F:Info(self.id)
        GameTooltip:AddLine((t and t.title or "Quest") .. ": not yet", 0.75, 0.75, 0.85)
        GameTooltip:AddLine(((why or ""):gsub("^Needs ", "Go get ")), 1, 0.82, 0, true)
        GameTooltip:AddLine("Click: the way to it", 0.6, 0.6, 0.6)
        GameTooltip:Show()
        return
    end
    Tooltip(self, self.id)
end
function VoidQuestForeverPinMixin:OnMouseLeave() GameTooltip:Hide() end
function VoidQuestForeverPinMixin:OnClick(button)
    if button == "LeftButton" and self.id then F:Go(self.first or self.id) end
end

VoidQuestForeverProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function VoidQuestForeverProviderMixin:RemoveAllData()
    if self:GetMap() then self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE) end
end

function VoidQuestForeverProviderMixin:RefreshAllData()
    self:RemoveAllData()
    if InCombatLockdown() or VQ:Get("foreverPins") == false then return end
    local map = self:GetMap()
    local mapID = map and map:GetMapID()
    if not mapID then return end
    -- starts are saved on the zone map you stood on; this map or its child zones
    local function onThis(m)
        if m == mapID then return true end
        local mi = safe(C_Map.GetMapInfo, m)
        return mi and mi.parentMapID == mapID and mi.mapType ~= ZONE_MAP and true or false
    end
    local waiting = false
    for id, r in pairs(VQ.ForeverQuests or {}) do
        local s = F:Spot(id)
        local here = s and onThis(s.m) and F:Eligible(r) and F:Status(id) == "open" and F:InScope(id)   -- Min / Mid / Max
        local avail, first
        if here then avail, _, first = F:Available(id) end
        local ok = here and avail
        if ok and not F:LevelSettled(id) then ok = false; waiting = true end   -- no "!" before its level is in
        -- held back only by an earlier quest somewhere else: a grey "!" that says go get it
        -- (the user, 2026-11-11: "a different icon for quests ... not available bec the start
        -- quest is somewhere else and to say go get it")
        local later = here and not avail and first and first ~= id and VQ:Get("foreverPinsLater") ~= false
        if ok or later then
            local x, y = s.x, s.y
            if s.m ~= mapID then
                local cont, wp = safe(C_Map.GetWorldPosFromMapPos, s.m, CreateVector2D(x, y))
                local p
                if cont and wp then p = select(2, safe(C_Map.GetMapPosFromWorldPos, cont, wp, mapID)) end
                if p then x, y = p:GetXY() else x = nil end
            end
            if x then map:AcquirePin(PIN_TEMPLATE, id, x, y, (not ok) and first or nil) end
        end
    end
    -- levels still loading: draw again once LEVEL_WAIT is up (answers also redraw as they come in)
    if waiting and not self.levelTimer then
        self.levelTimer = true
        C_Timer.After(LEVEL_WAIT + 1, function() self.levelTimer = nil; F:Refresh() end)
    end
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "QUEST_ACCEPTED",
    "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_DATA_LOAD_RESULT",
    "MINIMAP_UPDATE_TRACKING", "CVAR_UPDATE", "PLAYER_LEVEL_UP" }) do   -- Low-Level Quests on / off; quests turn grey
    pcall(ev.RegisterEvent, ev, e)
end
-- Redraw the window and map pins, once per burst (many QUEST_DATA_LOAD_RESULTs arrive
-- together for levels). Also called by QuestStarts when it learns new starts.
local pending
function F:Refresh()
    if pending or not self:Active() then return end
    pending = true
    C_Timer.After(0.3, function()
        pending = nil
        F:Render()
        if F.provider and WorldMapFrame:IsShown() then F.provider:RefreshAllData() end
    end)
end

ev:SetScript("OnEvent", function(_, e, arg)
    if not F:Active() then ev:UnregisterAllEvents(); return end
    if e == "CVAR_UPDATE" and arg ~= "trivialQuests" then return end
    if e == "PLAYER_LOGIN" then
        if WorldMapFrame and not F.provider then
            F.provider = CreateFromMixins(VoidQuestForeverProviderMixin)
            WorldMapFrame:AddDataProvider(F.provider)
        end
        return
    end
    F:Refresh()
end)

----------------------------------------------------------------------
-- Hover an NPC: the quests it has for you and the ones you can hand in to it (the user,
-- 2026-11-11: "do the questie basics first"). WoW Forever's own tooltips already show quest
-- progress on mobs ("objective 3/8", the same tooltip data QuestMobs.lua reads), but with no
-- "!" anywhere, a giver says nothing about its quests. Givers and turn-ins by name, from the
-- learned / shared / shipped data (QuestStarts.lua).
----------------------------------------------------------------------
local giverIndex, giverIndexAt = nil, 0
local function GiverIndex()
    -- rebuilt now and then: learned and shared givers come in while you play
    if giverIndex and GetTime() - giverIndexAt < 120 then return giverIndex end
    giverIndex, giverIndexAt = {}, GetTime()
    if not VQ.Starts then return giverIndex end
    for qid in pairs(VQ.ForeverQuests or {}) do
        local g = VQ.Starts:Giver(qid)
        if g then
            local l = giverIndex[g]
            if not l then l = {}; giverIndex[g] = l end
            l[#l + 1] = qid
        end
    end
    return giverIndex
end

local NPC_LINES = 4
local function NpcTooltip(tt)
    if tt ~= GameTooltip or not F:Active() then return end
    local _, unit = tt:GetUnit()
    if not unit or UnitIsPlayer(unit) or (UnitCanAttack and UnitCanAttack("player", unit)) then return end
    local name = UnitName(unit)
    if not name or Secret(name) then return end
    local hand, offer = {}, {}
    -- turn-ins first: quests in your log this NPC takes
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        local q = info and not info.isHeader and info.questID
        if q and VQ.Starts and VQ.Starts:Turnin(q) == name then
            local done = safe(C_QuestLog.IsComplete, q)
            hand[#hand + 1] = (done and "|cff55ff55Turn in:|r " or "|cffaaaaaaTurn in later:|r ") .. (info.title or ("quest " .. q))
        end
    end
    for _, q in ipairs(GiverIndex()[name] or {}) do
        if F:Status(q) == "open" and F:Available(q) then
            local info = F:Info(q)
            local lv = F:Level(q)
            local tag = (VQ.Guide and VQ.Guide.LevelTag) and VQ.Guide.LevelTag(q) or ""
            if tag == "" and lv and lv > 0 and VQ:Get("questLevels") ~= false then tag = ("[%d] "):format(lv) end
            offer[#offer + 1] = "|cffffd200Quest:|r " .. tag .. (info and info.title or ("quest " .. q))
        end
    end
    if #hand == 0 and #offer == 0 then return end
    tt:AddLine("|cff00c7ffVoidQuest|r")
    local shown = 0
    for _, l in ipairs(hand) do
        if shown < NPC_LINES then tt:AddLine(l, 1, 1, 1, true); shown = shown + 1 end
    end
    for _, l in ipairs(offer) do
        if shown < NPC_LINES then tt:AddLine(l, 1, 1, 1, true); shown = shown + 1 end
    end
    local more = #hand + #offer - shown
    if more > 0 then tt:AddLine(("and %d more"):format(more), .7, .7, .7) end
    tt:Show()
end
if TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt) pcall(NpcTooltip, tt) end)
elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetUnit", function(tt) pcall(NpcTooltip, tt) end)
end
