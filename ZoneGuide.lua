----------------------------------------------------------------------
-- VoidQuest — Zone Guides (zone leveling guides, built LIVE)
--
-- Guide addons ship hand-written guide files per zone. We build the same thing
-- from the game itself, so it covers every zone on day one and never goes
-- stale, and uses no other addon's data:
--   * the ZONE LIST = every zone with a storyline achievement
--     (C_QuestLog.GetZoneStoryInfo -- the "Story: 3/7" bar on the quest map),
--     grouped by expansion from the achievement's own category, with the
--     zone's level range (C_Map.GetMapLevels) and your chapter progress.
--   * a GUIDE = that achievement's chapters in order. The current chapter is
--     the first incomplete criterion; its quest resolves to a questline whose
--     chain we step exactly like the campaign guide (in-log first, else the
--     next quest after the last one you finished, with the giver's location).
--   * if a chapter can't be resolved to a questline, fall back to the nearest
--     available storyline on the zone map, so a guide never dead-ends.
-- Following a zone guide takes over the guide panel (like picking a
-- guide); "Stop" hands it back to the campaign. Per-character.
----------------------------------------------------------------------
local VQ = VoidQuest
local mod = VQ:NewModule("ZoneGuide")
VQ.Zones = mod

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end end
-- every return value (GetAchievementCriteriaInfo returns 11)
local function all(fn, ...)
    if not fn then return end
    return (function(ok, ...) if ok then return ... end end)(pcall(fn, ...))
end

local CRITERIA_QUEST, CRITERIA_ACHIEVEMENT = 27, 8
local COSMIC_MAP = 946

-- Achievement categories under "Quests" are named per expansion / continent.
local EXP_ORDER = {
    "Midnight", "The War Within", "Dragonflight", "Shadowlands", "Battle for Azeroth",
    "Legion", "Draenor", "Pandaria", "Cataclysm", "Northrend", "Outland", "Kalimdor",
    "Eastern Kingdoms",
}
local EXP_LABEL = {
    Draenor = "Warlords of Draenor", Pandaria = "Mists of Pandaria", Northrend = "Wrath of the Lich King",
    Outland = "The Burning Crusade", Kalimdor = "Classic: Kalimdor", ["Eastern Kingdoms"] = "Classic: Eastern Kingdoms",
}
local EXP_RANK = {}
for i, e in ipairs(EXP_ORDER) do EXP_RANK[e] = i end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
-- WoW Forever has no zone storylines to choose (it's the Classic world): the guide is
-- always the zone you're in, so it follows you instead of staying on the zone you
-- started (it said "Zone: Durotar" in the Barrens, 2026-11-05).
function mod:Current()
    local F = VQ.Forever
    if F and F:Active() then
        local name, map = F:PlayerZone()
        return name and map and { name = name, map = map, forever = true } or nil
    end
    return VoidQuestCharDB and VoidQuestCharDB.zoneGuide
end
function mod:Active() return self:Current() ~= nil end

function mod:Follow(entry)
    VoidQuestCharDB = VoidQuestCharDB or {}
    VoidQuestCharDB.zoneGuide = entry and { ach = entry.ach, map = entry.map, name = entry.name } or nil
    local G = VQ.Guide
    if G then G._lastStep = nil; G:Refresh() end
    if VQ.Givers then VQ.Givers:Refresh() end   -- the followed chain's givers light up
    if self.win and self.win:IsShown() then self:RefreshWindow() end
end
function mod:Stop() self:Follow(nil) end

----------------------------------------------------------------------
-- Catalog: every zone with a storyline achievement (static -> cached)
----------------------------------------------------------------------
function mod:ExpansionOf(ach)
    local cat = safe(GetAchievementCategory, ach)
    local title = cat and safe(GetCategoryInfo, cat)
    return (type(title) == "string" and title ~= "") and title or "Other"
end

function mod:Catalog()
    if self._cat then return self._cat end
    local out, seen = {}, {}
    local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
    for _, mi in ipairs(safe(C_Map.GetMapChildrenInfo, COSMIC_MAP, zoneType, true) or {}) do
        local ach, storyMap = safe(C_QuestLog.GetZoneStoryInfo, mi.mapID)
        if ach and ach > 0 and not seen[ach] then
            seen[ach] = true
            local smap = (storyMap and storyMap > 0) and storyMap or mi.mapID
            local smi = safe(C_Map.GetMapInfo, smap)
            out[#out + 1] = { ach = ach, map = smap, name = (smi and smi.name) or mi.name, exp = self:ExpansionOf(ach) }
        end
    end
    table.sort(out, function(a, b)
        local ra, rb = EXP_RANK[a.exp] or 99, EXP_RANK[b.exp] or 99
        if ra ~= rb then return ra < rb end
        return a.name < b.name
    end)
    self._cat = out
    return out
end

-- The storyline for the zone you're standing in (walks up parent maps). Modern zones
-- (BfA's Zandalar onward: Shadowlands, Dragonflight, War Within, Midnight -- verified
-- 2026-10-17) have NO zone-story achievement; Blizzard tells their stories through
-- campaigns + map questlines. For those we return a MAP-MODE guide (ach = nil): follow
-- the zone's available storylines straight off its map.
function mod:ForCurrentZone()
    local start = safe(C_Map.GetBestMapForUnit, "player")
    local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
    local m, zoneMap = start, nil
    for _ = 1, 6 do
        if not m or m <= 0 then break end
        local ach, storyMap = safe(C_QuestLog.GetZoneStoryInfo, m)
        if ach and ach > 0 then
            local smap = (storyMap and storyMap > 0) and storyMap or m
            local smi = safe(C_Map.GetMapInfo, smap)
            return { ach = ach, map = smap, name = (smi and smi.name) or "?" }
        end
        local mi = safe(C_Map.GetMapInfo, m)
        if mi and mi.mapType == zoneType and not zoneMap then zoneMap = m end
        m = mi and mi.parentMapID
    end
    zoneMap = zoneMap or start
    local zi = zoneMap and safe(C_Map.GetMapInfo, zoneMap)
    if zi then return { map = zoneMap, name = zi.name } end   -- map mode
end

-- Modern zones on the player's continent (no story achievement) -> map-mode entries.
function mod:ContinentZones()
    local m = safe(C_Map.GetBestMapForUnit, "player")
    local contType = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
    local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
    local cont
    for _ = 1, 8 do
        local mi = m and safe(C_Map.GetMapInfo, m)
        if not mi then break end
        if mi.mapType == contType then cont = mi; break end
        m = mi.parentMapID
    end
    local out = {}
    if not cont then return out, nil end
    for _, zi in ipairs(safe(C_Map.GetMapChildrenInfo, cont.mapID, zoneType, true) or {}) do
        local ach = safe(C_QuestLog.GetZoneStoryInfo, zi.mapID)
        if not (ach and ach > 0) then out[#out + 1] = { map = zi.mapID, name = zi.name } end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out, cont.name
end

----------------------------------------------------------------------
-- "Where do I level?" -- Chromie Time era + zones that fit your level
----------------------------------------------------------------------
-- Chromie Time era -> its zones: the story-achievement categories (Catalog's z.exp)
-- plus its continents, for modern zones that have no story achievement.
-- Chromie's option names aren't always the expansion's name (Draenor's has been called
-- "The Iron Horde"), so each era matches several keywords against the option's name +
-- description. `label` is the expansion name the capital-board intro quests start with
-- ("Warlords of Draenor: The Dark Portal").
local CHROMIE = {
    { id = "tbc", label = "The Burning Crusade", keys = { "burning crusade", "outland" }, exp = { Outland = true }, conts = { 101 } },
    { id = "wotlk", label = "Wrath of the Lich King", keys = { "lich king", "northrend" }, exp = { Northrend = true }, conts = { 113 } },
    { id = "cata", label = "Cataclysm", keys = { "cataclysm" }, exp = { Cataclysm = true, Kalimdor = true, ["Eastern Kingdoms"] = true }, conts = {} },
    { id = "mop", label = "Mists of Pandaria", keys = { "pandaria" }, exp = { Pandaria = true }, conts = { 424 } },
    { id = "wod", label = "Warlords of Draenor", keys = { "draenor", "iron horde" }, exp = { Draenor = true }, conts = { 572 } },
    { id = "legion", label = "Legion", keys = { "legion", "broken isles" }, exp = { Legion = true }, conts = { 619 } },
    { id = "bfa", label = "Battle for Azeroth", keys = { "battle for azeroth", "zandalar", "kul tiras" }, exp = { ["Battle for Azeroth"] = true }, conts = { 875, 876 } },
    { id = "sl", label = "Shadowlands", keys = { "shadowlands" }, exp = { Shadowlands = true }, conts = { 1550 } },
    { id = "df", label = "Dragonflight", keys = { "dragonflight", "dragon isles" }, exp = { Dragonflight = true }, conts = { 1978 } },
}
local function eraFor(name)
    local n = type(name) == "string" and name:lower() or ""
    for _, e in ipairs(CHROMIE) do
        for _, k in ipairs(e.keys) do
            if n:find(k, 1, true) then return e end
        end
    end
end
mod.EraFor = eraFor   -- shared with the Leveling Coach

-- { can, on, name, recommended }: can you use Chromie Time, are you in it, which era.
function mod:Chromie()
    local c = {}
    c.can = safe(C_PlayerInfo and C_PlayerInfo.CanPlayerEnterChromieTime) and true or false
    c.on = safe(C_PlayerInfo and C_PlayerInfo.IsPlayerInChromieTime) and true or false
    local id = UnitChromieTimeID and safe(UnitChromieTimeID, "player")
    local opt = id and id > 0 and C_ChromieTime and safe(C_ChromieTime.GetChromieTimeExpansionOption, id)
    c.name = opt and opt.name
    c.era = opt and eraFor((opt.name or "") .. " " .. (opt.description or ""))
    for _, o in ipairs((C_ChromieTime and safe(C_ChromieTime.GetChromieTimeExpansionOptions)) or {}) do
        if o.recommended then c.recommended = o.name end
    end
    return c
end

-- Up to `max` unfinished zones whose level range fits you: your Chromie era's zones
-- first, then zones you've started, then lowest level first.
function mod:Suggestions(max)
    local lvl = UnitLevel("player") or 0
    local era = self:Chromie().era
    local list, seenMap = {}, {}
    local function fits(map)
        local lo, hi = self:Levels(map)
        return lo and lvl >= lo and lvl <= (hi or lo), lo, hi
    end
    for _, z in ipairs(self:Catalog()) do
        local d, n = self:Progress(z.ach)
        local ok, lo, hi = fits(z.map)
        if ok and not (n > 0 and d >= n) then
            seenMap[z.map] = true
            list[#list + 1] = { z = z, lo = lo, hi = hi, started = d > 0, inEra = era and era.exp[z.exp] or false,
                progress = ("%d/%d"):format(d, n) }
        end
    end
    -- modern zones (no story achievement) of your era and of the continent you're on:
    -- followed through their map storylines, so only zones that still offer one count
    local function addMapZone(mapID, name, inEra)
        if seenMap[mapID] then return end
        local ach = safe(C_QuestLog.GetZoneStoryInfo, mapID)
        local ok, lo, hi = fits(mapID)
        if ok and not (ach and ach > 0) and #(safe(C_QuestLine.GetAvailableQuestLines, mapID) or {}) > 0 then
            seenMap[mapID] = true
            list[#list + 1] = { z = { map = mapID, name = name }, lo = lo, hi = hi, inEra = inEra }
        end
    end
    local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
    for _, cont in ipairs(era and era.conts or {}) do
        for _, zi in ipairs(safe(C_Map.GetMapChildrenInfo, cont, zoneType, true) or {}) do
            addMapZone(zi.mapID, zi.name, true)
        end
    end
    for _, z in ipairs((self:ContinentZones())) do addMapZone(z.map, z.name, false) end
    table.sort(list, function(a, b)
        if a.inEra ~= b.inEra then return a.inEra end
        if (a.started or false) ~= (b.started or false) then return a.started or false end
        if a.lo ~= b.lo then return a.lo < b.lo end
        return a.z.name < b.z.name
    end)
    for i = #list, (max or 6) + 1, -1 do list[i] = nil end
    return list
end

----------------------------------------------------------------------
-- Live progress + chapters
----------------------------------------------------------------------
-- Chapter "done" is per CHARACTER. Zone-story achievements are account-wide, so their
-- criteria report what any of your characters did (a fresh alt showed Spires of Arak at
-- 9/9). Quest chapters use this character's own quest completion; a nested-achievement
-- chapter is done when this character finished all of its quest chapters.
function mod:Chapters(ach, depth)
    local out = {}
    for i = 1, (safe(GetAchievementNumCriteria, ach) or 0) do
        local name, ctype, done, _, _, _, _, asset = all(GetAchievementCriteriaInfo, ach, i)
        done = done and true or false
        if ctype == CRITERIA_QUEST and asset and asset > 0 then
            done = safe(C_QuestLog.IsQuestFlaggedCompleted, asset) and true or false
        elseif ctype == CRITERIA_ACHIEVEMENT and asset and asset > 0 and (depth or 0) < 1 then
            local subs, quests, all_done = self:Chapters(asset, (depth or 0) + 1), 0, true
            for _, s in ipairs(subs) do
                if s.ctype == CRITERIA_QUEST then
                    quests = quests + 1
                    if not s.done then all_done = false end
                end
            end
            if quests > 0 then done = all_done end
        end
        out[#out + 1] = { name = name or ("Chapter " .. i), ctype = ctype, done = done, asset = asset }
    end
    return out
end

function mod:Progress(ach)
    local d, n = 0, 0
    for _, c in ipairs(self:Chapters(ach)) do
        n = n + 1
        if c.done then d = d + 1 end
    end
    return d, n
end

function mod:Levels(map)
    local lo, hi = safe(C_Map.GetMapLevels, map)
    if lo and lo > 0 then return lo, hi end
end

-- A chapter's quest: the criterion's asset when it's a quest; for a nested
-- achievement, its first incomplete quest criterion.
function mod:ChapterQuest(ch, depth)
    if not ch then return nil end
    if ch.ctype == CRITERIA_QUEST and ch.asset and ch.asset > 0 then return ch.asset end
    if ch.ctype == CRITERIA_ACHIEVEMENT and ch.asset and ch.asset > 0 and (depth or 0) < 2 then
        for _, sub in ipairs(self:Chapters(ch.asset)) do
            if not sub.done then
                local q = self:ChapterQuest(sub, (depth or 0) + 1)
                if q then return q end
            end
        end
    end
    return nil
end

local function done(q) return safe(C_QuestLog.IsQuestFlaggedCompleted, q) end
local function inLog(q) return safe(C_QuestLog.GetLogIndexForQuestID, q) end
local function title(q)
    safe(C_QuestLog.RequestLoadQuestByID, q)
    return safe(C_QuestLog.GetTitleForQuestID, q)
end
local function stepFor(q, idx, total, map)
    if inLog(q) then
        return { qid = q, idx = idx, total = total, title = title(q),
                 status = safe(C_QuestLog.IsComplete, q) and "turnin" or "progress" }
    end
    local st = { qid = q, idx = idx, total = total, status = "pickup", title = title(q) }
    -- giver position as seen on the ZONE map (x/y from GetQuestLineInfo are relative
    -- to the map we pass, so pin on that same map)
    local li = safe(C_QuestLine.GetQuestLineInfo, q, map)
    if li and li.x and li.y and li.x > 0 and li.y > 0 then st.wpMap, st.wpX, st.wpY = map, li.x, li.y end
    -- offered on the zone map right now = game-confirmed obtainable
    for _, a in ipairs(safe(C_QuestLine.GetAvailableQuestLines, map) or {}) do
        if a.questID == q then
            st.confirmed = true
            if not st.wpX and a.x and a.y and a.x > 0 then st.wpMap, st.wpX, st.wpY = map, a.x, a.y end
            break
        end
    end
    return st
end

-- Same rules as the campaign stepper: a chain quest IN YOUR LOG is the step; else the
-- first not-done quest AFTER the last one finished (skips never-flagged variants).
function mod:ChainStep(chain, map)
    local lastDone = 0
    for i, q in ipairs(chain) do
        if done(q) then lastDone = i
        elseif inLog(q) then return stepFor(q, i, #chain, map) end
    end
    for i = lastDone + 1, #chain do
        local q = chain[i]
        if q and not done(q) then return stepFor(q, i, #chain, map) end
    end
end

-- Fallback when a chapter doesn't resolve to a questline: the nearest available
-- storyline on the zone map (important lines first).
function mod:NearestOnMap(map)
    safe(C_QuestLine.RequestQuestLinesForMap, map)
    local px, py = 0.5, 0.5
    local pos = safe(C_Map.GetPlayerMapPosition, map, "player")
    if pos and pos.GetXY then local a, b = pos:GetXY(); if a then px, py = a, b end end
    local best, bestScore
    for _, q in ipairs(safe(C_QuestLine.GetAvailableQuestLines, map) or {}) do
        if q.questID and not done(q.questID) and not inLog(q.questID) then
            local dx, dy = (q.x or px) - px, (q.y or py) - py
            local score = math.sqrt(dx * dx + dy * dy) - (q.isImportant and 1 or 0)
            if not bestScore or score < bestScore then best, bestScore = q, score end
        end
    end
    if best then
        return { qid = best.questID, idx = 0, total = 0, status = "pickup", confirmed = true,
                 title = (best.questName ~= "" and best.questName) or best.questLineName,
                 wpMap = map, wpX = best.x, wpY = best.y }
    end
end

-- The zone storyline that IS this chapter: an available questline on the zone map whose
-- name matches the chapter name ("Defenders of Daelin's Gate"). Verified 2026-10-17 on
-- Tiragarde Sound: story criteria point at a chapter's FINAL quest (type 27), which the
-- game won't resolve to a questline until you're on it -- the name match finds the
-- obtainable first quest instead.
function mod:MatchLine(map, chapterName)
    if not (map and chapterName) then return nil end
    safe(C_QuestLine.RequestQuestLinesForMap, map)
    local want = chapterName:lower()
    for _, q in ipairs(safe(C_QuestLine.GetAvailableQuestLines, map) or {}) do
        local n = (q.questLineName or ""):lower()
        if q.questID and n ~= "" and (n == want or n:find(want, 1, true) or want:find(n, 1, true))
           and not done(q.questID) then
            return q
        end
    end
end

-- The guide's current state, in the shape the panel already renders:
-- g = { campName, chapter, ql, chain }, step = { qid, status, title, idx, total, wp* }.
-- Map mode: in-log quests located on this zone's map first (objective, then turn-in),
-- else the nearest storyline you can pick up here.
-- Map mode's chain = the storyline of the quest being guided (plus that quest). Without
-- it ChainSet was empty, so hands-free accept / turn-in never fired for zone storylines --
-- only campaign quests were handled (Waking Shores, 2026-10-24).
local function withLine(g, st, map)
    if not st then return g, st end
    local chain = {}
    local li = safe(C_QuestLine.GetQuestLineInfo, st.qid, map)
    if li and li.questLineID then
        for _, q in ipairs(safe(C_QuestLine.GetQuestLineQuests, li.questLineID) or {}) do chain[#chain + 1] = q end
    end
    local has = false
    for _, q in ipairs(chain) do if q == st.qid then has = true; break end end
    if not has then chain[#chain + 1] = st.qid end
    g.chain = chain
    return g, st
end

local SWITCH = 0.7   -- another quest must be 30% closer than the one shown to take over

-- Your log quests on this map: the one whose objective / turn-in is NEAREST to you, so the
-- panel changes as you move ("smart enough to change when you're closer to quests you're
-- on", 2026-11-05). It only switches when another one is clearly closer (SWITCH), so two
-- quests about as far away don't flicker back and forth. Without your position: the first
-- one still in progress, else the first turn-in (as before). peek = don't remember the
-- pick (the movement check below asks without changing anything).
function mod:NearestLogQuest(map, peek)
    local pos = safe(C_Map.GetPlayerMapPosition, map, "player")
    local px, py
    if pos and pos.GetXY then px, py = pos:GetXY() end
    if px and (px <= 0 or py <= 0) then px = nil end
    -- map x/y are 0-1 across a map that's rarely square: scale to yards so east and north
    -- count the same (1:1 if the size is unknown)
    local w, h = safe(C_Map.GetMapWorldSize, map)
    if not (w and h and w > 0 and h > 0) then w, h = 1, 1 end
    local dist, first, turnin = {}, nil, nil
    -- dungeon quests have their own group in the quest lines; outside an instance the guide
    -- doesn't jump to one just because you walk past its dungeon
    local G = VQ.Guide
    local outside = not (IsInInstance and IsInInstance())
    for _, q in ipairs(safe(C_QuestLog.GetQuestsOnMap, map) or {}) do
        local qid = q.questID
        if qid and inLog(qid) and not safe(C_QuestLog.IsWorldQuest, qid)
           and not (outside and G and G.IsDungeonQuest and G:IsDungeonQuest(qid)) then
            if safe(C_QuestLog.IsComplete, qid) then turnin = turnin or qid else first = first or qid end
            if px and q.x and q.y then
                local dx, dy = (q.x - px) * w, (q.y - py) * h
                local d = math.sqrt(dx * dx + dy * dy)
                if not dist[qid] or d < dist[qid] then dist[qid] = d end
            end
        end
    end
    local pick
    if px then
        for qid, d in pairs(dist) do
            if not pick or d < dist[pick] then pick = qid end
        end
        local last = self.nearQuest
        if pick and last and last ~= pick and dist[last] and dist[pick] > dist[last] * SWITCH then
            pick = last   -- the one you were on is still about as close: stay on it
        end
        if not peek then self.nearQuest = pick end
    end
    -- second value: picked by distance (false = no position, fell back to log order)
    if pick then return pick, true end
    return first or turnin, false
end

-- The panel refreshes on quest events, not as you walk: every few seconds, if the nearest
-- log quest is now a different one, refresh it. Cheap (one map query); never in combat or
-- instances, and only while the guide is in map mode (always on WoW Forever).
C_Timer.NewTicker(4, function()
    if InCombatLockdown() or (IsInInstance and IsInInstance()) then return end
    local zg = mod:Active() and mod:Current()
    if not (zg and zg.map and not zg.ach) or not (VQ.Guide and VQ.Guide.Refresh) then return end
    local want, byDistance = mod:NearestLogQuest(zg.map, true)
    if byDistance and want ~= mod.nearQuest then VQ.Guide:Refresh() end
end)

function mod:MapStep(zg)
    local g = { campName = "Zone: " .. (zg.name or "?"), zoneGuide = true,
                chapter = zg.forever and "Your quests here first" or "Zone storylines (nearest first)" }
    local pick = self:NearestLogQuest(zg.map)
    if pick then return withLine(g, stepFor(pick, 0, 0, zg.map), zg.map) end
    local st = self:NearestOnMap(zg.map)
    -- Forever: the map offers no storylines; the next quest you can pick up here whose
    -- giver is known (ForeverZone's list: lowest level first, too-high ones left out)
    if not st and zg.forever and VQ.Forever then
        g.chapter = "Quests here first"
        -- only quests in the Min / Mid / Max tier (Chains.lua: Min = important ones)
        local skipped = false
        for _, e in ipairs(VQ.Forever:ZoneList(zg.name)) do
            if e.status == "open" and e.spot then
                if e.scope then
                    st = { qid = e.id, idx = 0, total = 0, status = "pickup", title = e.title,
                           wpMap = e.spot.m, wpX = e.spot.x, wpY = e.spot.y }
                    break
                end
                skipped = true
            end
        end
        if not st then
            g.chapter = skipped
                and "|cff55ff55Nothing to pick up here at this density|r (Max shows every quest)"
                or "|cff55ff55No known quest to pick up here|r (zone list: /vq fz)"
        end
        return withLine(g, st, zg.map)
    end
    if not st then g.chapter = "|cff55ff55No more storylines offered here right now|r" end
    return withLine(g, st, zg.map)
end

function mod:Step()
    local zg = self:Current()
    if not zg then return nil end
    if not zg.ach then return self:MapStep(zg) end
    local chs = self:Chapters(zg.ach)
    local cur, idx
    for i, c in ipairs(chs) do if not c.done then cur, idx = c, i; break end end
    local g = { campName = "Zone: " .. (zg.name or "?"), zoneGuide = true }
    if not cur then
        g.chapter = ("|cff55ff55Storyline complete|r (%d/%d)"):format(#chs, #chs)
        return g, nil
    end
    g.chapter = ("Chapter %d/%d: %s"):format(idx, #chs, cur.name)
    local step
    -- (1) the chapter's own quest resolves to a questline (you're on it) -> step its chain
    local q = self:ChapterQuest(cur)
    local ql = q and safe(C_QuestLine.GetQuestLineInfo, q, zg.map)
    -- (2) else the zone storyline named like the chapter (its obtainable first quest)
    if not (ql and ql.questLineID) then
        local line = self:MatchLine(zg.map, cur.name)
        if line then ql = { questLineID = line.questLineID, questLineName = line.questLineName, startMapID = zg.map } end
    end
    if ql and ql.questLineID then
        local chain = safe(C_QuestLine.GetQuestLineQuests, ql.questLineID) or {}
        g.ql, g.chain = ql, chain
        step = self:ChainStep(chain, zg.map)
    end
    -- (3) the chapter quest itself only if you actually have it
    if not step and q and inLog(q) then step = stepFor(q, 0, 0, zg.map) end
    -- (4) never dead-end: nearest storyline offered in the zone
    if not step then step = self:NearestOnMap(zg.map) end
    return g, step
end

-- Quest IDs the auto engine may handle while a zone guide is followed.
function mod:ChainSet()
    local g = self:Active() and select(1, self:Step())
    local set = {}
    if g and g.chain then for _, q in ipairs(g.chain) do set[q] = true end end
    return set
end

----------------------------------------------------------------------
-- Zone Guides window (a guide list: expansion -> zone, progress, levels)
----------------------------------------------------------------------
local VISIBLE = 18

function mod:EnsureWindow()
    if self.win then return self.win end
    local p = CreateFrame("Frame", "VoidQuestZoneGuides", UIParent, "BackdropTemplate")
    p:SetSize(360, 500); p:SetPoint("CENTER", UIParent, "CENTER", 160, 0); p:SetClampedToScreen(true)
    p:SetFrameStrata("FULLSCREEN_DIALOG"); p:SetToplevel(true)
    p:SetMovable(true); p:EnableMouse(true); p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving); p:SetScript("OnDragStop", p.StopMovingOrSizing)
    VQ:CreateBackdrop(p, 0.96)
    p.title = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.title, 13, "OUTLINE")
    p.title:SetPoint("TOP", 0, -8); p.title:SetText("Zone Guides")
    local close = CreateFrame("Button", nil, p, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)
    p.sub = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.sub, 10)
    p.sub:SetPoint("TOPLEFT", 12, -28); p.sub:SetWidth(336); p.sub:SetJustifyH("LEFT"); p.sub:SetTextColor(.8, .8, .8)

    p.here = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    p.here:SetSize(160, 20); p.here:SetPoint("TOPLEFT", 12, -46); p.here:SetText("Follow this zone")
    p.here:SetScript("OnClick", function()
        local z = mod:ForCurrentZone()
        if z then mod:Follow(z) else VQ:Print("This zone has no storyline to follow.") end
    end)
    p.stop = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    p.stop:SetSize(160, 20); p.stop:SetPoint("TOPRIGHT", -12, -46); p.stop:SetText("Stop (back to campaign)")
    if VQ.FitButton then VQ.FitButton(p.stop, 160) end   -- text fits its button
    p.stop:SetScript("OnClick", function() mod:Stop() end)

    p.showDone = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
    p.showDone:SetSize(20, 20); p.showDone:SetPoint("TOPLEFT", 10, -70)
    p.showDone.text = p.showDone:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.showDone.text, 10)
    p.showDone.text:SetPoint("LEFT", p.showDone, "RIGHT", 2, 0); p.showDone.text:SetText("Show completed zones")
    p.showDone:SetScript("OnClick", function(s)
        VoidQuestDB.zoneShowDone = s:GetChecked() and true or false
        p.scrollOffset = 0; mod:RefreshWindow()
    end)

    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(_, delta)
        p.scrollOffset = (p.scrollOffset or 0) - delta * 3; mod:RefreshWindow(true)   -- scroll: reuse the list
    end)
    p.rows = {}
    p:Hide()
    self.win = p
    return p
end

-- keep = true (scrolling): re-render the list built last time instead of rebuilding it.
-- Rebuilding walks every zone's chapters and the map storylines, and that data trickles
-- in, so rebuilding per scroll tick made the list reshuffle and hitch.
function mod:RefreshWindow(keep)
    local p = self:EnsureWindow()
    local showDone = VoidQuestDB and VoidQuestDB.zoneShowDone
    p.showDone:SetChecked(showDone and true or false)
    local cur = self:Current()
    p.sub:SetText(("Following: |cff55ff55%s|r  \226\128\148  click a zone to follow its storyline"):format(
        cur and cur.name or "campaign (no zone guide)"))
    p.stop:SetEnabled(cur ~= nil)
    if keep and p.entries then return self:RenderRows(p.entries) end

    local entries, lastExp = {}, nil
    -- "where do I go?": your Chromie Time era + zones that fit your level, on top
    local lvl = UnitLevel("player") or 0
    local ct = self:Chromie()
    entries[#entries + 1] = { header = true, text = ("Suggested for you (level %d)"):format(lvl) }
    if ct.on and ct.name then
        entries[#entries + 1] = { info = true, text = ("Chromie Time: |cffffd200%s|r (its zones scale to you)"):format(ct.name) }
    elseif ct.can then
        entries[#entries + 1] = { info = true, text = ("Not in Chromie Time -- pick an era with Chromie%s"):format(
            ct.recommended and (" (try |cffffd200" .. ct.recommended .. "|r)") or " in Orgrimmar/Stormwind") }
    end
    local sugg = self:Suggestions(6)
    for _, s in ipairs(sugg) do
        local lv = (s.lo == s.hi) and (" |cff888888lvl %d|r"):format(s.lo) or (" |cff888888lvl %d-%d|r"):format(s.lo, s.hi)
        local mark = (cur and ((s.z.ach and cur.ach == s.z.ach) or (not s.z.ach and not cur.ach and cur.map == s.z.map))) and "> " or ""
        entries[#entries + 1] = { z = s.z, text = ("%s|cff55ff55%s|r%s%s"):format(mark, s.z.name,
            s.progress and ("  " .. s.progress) or "", lv) }
    end
    if #sugg == 0 then
        entries[#entries + 1] = { info = true, text = "No unfinished zone storylines fit your level here." }
    end
    -- modern zones on your continent first (map mode -- no story achievement)
    local cz, contName = self:ContinentZones()
    if #cz > 0 then
        entries[#entries + 1] = { header = true, text = (contName or "This continent") .. " (storylines on map)" }
        for _, z in ipairs(cz) do
            local lo, hi = self:Levels(z.map)
            local lv = lo and ((lo == hi) and (" |cff888888lvl %d|r"):format(lo) or (" |cff888888lvl %d-%d|r"):format(lo, hi)) or ""
            local mark = (cur and not cur.ach and cur.map == z.map) and "> " or ""
            entries[#entries + 1] = { z = z, text = mark .. z.name .. lv }
        end
    end
    for _, z in ipairs(self:Catalog()) do
        local d, n = self:Progress(z.ach)
        local complete = n > 0 and d >= n
        if showDone or not complete then
            if z.exp ~= lastExp then
                entries[#entries + 1] = { header = true, text = EXP_LABEL[z.exp] or z.exp }
                lastExp = z.exp
            end
            local lo, hi = self:Levels(z.map)
            local lv = lo and ((lo == hi) and (" |cff888888lvl %d|r"):format(lo) or (" |cff888888lvl %d-%d|r"):format(lo, hi)) or ""
            local col = complete and "|cff888888" or (d > 0 and "|cffffd200" or "|cffffffff")
            local mark = (cur and cur.ach == z.ach) and "> " or ""
            entries[#entries + 1] = { z = z, text = ("%s%s%s|r  %d/%d%s"):format(mark, col, z.name, d, n, lv) }
        end
    end
    p.entries = entries
    self:RenderRows(entries)
end

function mod:RenderRows(entries)
    local p = self:EnsureWindow()
    local maxOff = math.max(0, #entries - VISIBLE)
    p.scrollOffset = math.max(0, math.min(p.scrollOffset or 0, maxOff))
    for i = 1, VISIBLE do
        local row = p.rows[i]
        if not row then
            row = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
            row:SetSize(336, 20); row:SetPoint("TOPLEFT", 12, -96 - (i - 1) * 21)
            row:SetScript("OnClick", function(s) if s.z then mod:Follow(s.z) end end)
            p.rows[i] = row
        end
        local e = entries[i + p.scrollOffset]
        if e then
            row:SetText(e.header and ("|cff00c7ff%s|r"):format(e.text) or e.text)
            row.z = e.z
            row:SetEnabled(not (e.header or e.info))
            row:Show()
        else
            row:Hide()
        end
    end
    p:SetHeight(96 + VISIBLE * 21 + 12)
end

function mod:ToggleWindow()
    local p = self:EnsureWindow()
    if p:IsShown() then p:Hide() else p.scrollOffset = 0; self:RefreshWindow(); p:Show() end
end

-- Diagnostic: the current (or followed) zone's storyline criteria, raw -> copy popup.
function mod:Probe()
    local z = self:Current() or self:ForCurrentZone()
    if not z then VQ:ShowCopy("VoidQuest — Zone probe", "no zone found"); return end
    if not z.ach then
        local _, st = self:MapStep(z)
        VQ:ShowCopy("VoidQuest — Zone probe", ("MAP MODE zone %s map %d\nstep: %s"):format(z.name or "?", z.map or 0,
            st and ("%s %s %s"):format(st.status, st.qid, st.title or "?") or "none"))
        return
    end
    local lines = { ("zone %s  map %d  ach %d  exp %s"):format(z.name or "?", z.map or 0, z.ach, self:ExpansionOf(z.ach)) }
    for i, c in ipairs(self:Chapters(z.ach)) do
        local q = self:ChapterQuest(c)
        local ql = q and safe(C_QuestLine.GetQuestLineInfo, q, z.map)
        local m = (not c.done) and self:MatchLine(z.map, c.name)
        lines[#lines + 1] = ("%2d %s  type=%s asset=%s done=%s -> quest %s ql %s | nameMatch %s"):format(
            i, c.name, tostring(c.ctype), tostring(c.asset), tostring(c.done), tostring(q), tostring(ql and ql.questLineID),
            m and (("%s (q%s)"):format(m.questLineName, m.questID)) or "-")
    end
    local g, st = self:Step()
    lines[#lines + 1] = ("step: %s"):format(st and (("%s %s %s"):format(st.status, st.qid, st.title or "?")) or "none")
    VQ:ShowCopy("VoidQuest — Zone probe (copy & paste this to me)", table.concat(lines, "\n"))
end

-- Story chapters complete via achievement criteria -> refresh the guide when they move.
do
    local ev, pending = CreateFrame("Frame"), false
    ev:RegisterEvent("CRITERIA_UPDATE")
    ev:RegisterEvent("ACHIEVEMENT_EARNED")
    ev:SetScript("OnEvent", function()
        if not mod:Active() or pending then return end
        pending = true
        C_Timer.After(0.5, function()
            pending = false
            if VQ.Guide then VQ.Guide:Refresh() end
            if mod.win and mod.win:IsShown() then mod:RefreshWindow() end
        end)
    end)
end
