----------------------------------------------------------------------
-- VoidQuest — the mob atlas: every mob you see and kill (WoW Forever)
--
-- The user, 2026-11-16: "track every mob we see and kill in voidquest, this is for data but also
-- validation for quests". For every NPC whose nameplate (or target) you see in the open world:
--   name, level range, classification (normal / elite / rare), creature type, hostile or not,
--   how often seen, where seen per map (the spot you were CLOSEST to it: QuestMobs' range checks,
--   ~10 yd when you ride past), and the mobs you or your group KILLED and where.
-- A kill is a mob that was fighting you or your group (threat on it) and dies, not tagged by
-- someone else. No combat log (not read by Void addons); WoW Forever gives addons no mob position,
-- so a spot is where you stood near it.
-- Not in dungeons / raids: mob identity is secret to addons there (measured 2026-11-14).
-- Kept in VoidQuestDB.mobAtlas (SavedVariables) for /vq atlas and tools/cmd/vq-atlas-report, which
-- checks it against the shipped quest data (new mobs, new spots, quest mobs seen elsewhere).
-- Settings > Guidance > "Record the mobs you see" turns it off.
----------------------------------------------------------------------
local VQ = VoidQuest
if not VQ then return end
if (select(4, GetBuildInfo()) or 0) >= 100000 then return end   -- WoW Forever only

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c, d = pcall(fn, ...) if ok then return a, b, c, d end end
local function secret(v) return issecretvalue and issecretvalue(v) end

local SPOTS_MAX = 40      -- spots kept per mob per map (oldest out)
local GRID = 15           -- 1.5% of the map: closer than this to a kept spot = the same spot
local NEAR_FOR = 30       -- s: a mob in view this long is settled (its closest spot kept)
local SKIP_TYPE = { Critter = true, Totem = true, ["Not specified"] = true, ["Gas Cloud"] = true, ["Wild Pet"] = true }

local A = {}
VQ.MobAtlas = A

local function On() return VQ:Get("mobAtlas") ~= false end

local function DB()
    VoidQuestDB = VoidQuestDB or {}
    local db = VoidQuestDB.mobAtlas
    if type(db) ~= "table" then db = { v = 1, mobs = {} }; VoidQuestDB.mobAtlas = db end
    db.mobs = db.mobs or {}
    return db
end

local function inInstance()
    local inside, kind = IsInInstance()
    return inside and kind ~= "none"
end

local function npcOf(guid)
    if type(guid) ~= "string" or secret(guid) then return nil end
    local kind, npc = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind ~= "Creature" and kind ~= "Vehicle" then return nil end   -- not players, pets, objects
    return tonumber(npc)
end

local function here()
    local map = safe(C_Map.GetBestMapForUnit, "player")
    local pos = map and safe(C_Map.GetPlayerMapPosition, map, "player")
    if not pos then return nil end
    local x, y = pos:GetXY()
    if not (x and y) or secret(x) or secret(y) then return nil end
    x, y = math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5)
    if x <= 0 or y <= 0 or x > 999 or y > 999 then return nil end
    return map, x, y
end

-- add a spot to "xxxyyy..." unless one within GRID is there already; oldest out past SPOTS_MAX
local function addSpot(pts, x, y)
    pts = pts or ""
    for i = 1, #pts - 5, 6 do
        local px, py = tonumber(pts:sub(i, i + 2)), tonumber(pts:sub(i + 3, i + 5))
        if px and py and math.abs(px - x) < GRID and math.abs(py - y) < GRID then return pts, false end
    end
    if #pts >= SPOTS_MAX * 6 then pts = pts:sub(7) end
    return pts .. ("%03d%03d"):format(x, y), true
end

-- what a unit is, read once per sighting: nil for players, pets, critters, secret units
local function describe(unit)
    if safe(UnitIsPlayer, unit) then return nil end
    local guid = safe(UnitGUID, unit)
    local npc = npcOf(guid)
    if not npc then return nil end
    local name = safe(UnitName, unit)
    if not name or secret(name) then return nil end
    local ctype = safe(UnitCreatureType, unit)
    if secret(ctype) then ctype = nil end
    if ctype and SKIP_TYPE[ctype] then return nil end
    local lvl = safe(UnitLevel, unit)
    if secret(lvl) then lvl = nil end
    local cls = safe(UnitClassification, unit)
    if secret(cls) then cls = nil end
    local react = safe(UnitReaction, unit, "player")
    if secret(react) then react = nil end
    return { guid = guid, npc = npc, name = name, lvl = lvl, cls = cls, ctype = ctype,
             r = react and ((react <= 3 and "h") or (react == 4 and "n") or "f") or nil }
end

-- the record for one NPC, updated with what we just read about it
local function record(d)
    local db = DB()
    local m = db.mobs[d.npc]
    local now = (GetServerTime and GetServerTime()) or 0
    if not m then
        m = { n = d.name, s = 0, k = 0, m = {}, t1 = now }
        db.mobs[d.npc] = m
    end
    m.n = d.name
    if d.lvl and d.lvl > 0 then
        if not m.lo or d.lvl < m.lo then m.lo = d.lvl end
        if not m.hi or d.lvl > m.hi then m.hi = d.lvl end
    elseif d.lvl == -1 then
        m.boss = true   -- "??": a skull-level mob
    end
    if d.cls and d.cls ~= "normal" and d.cls ~= "" then m.c = d.cls end
    if d.ctype then m.t = d.ctype end
    if d.r then m.r = d.r end
    m.t2 = now
    return m
end

-- In view: keep the spot where you got closest (like QuestMobs); settled when it leaves view, dies,
-- or after NEAR_FOR seconds.
local near = {}   -- [guid] = { d = desc, map, x, y, dist, t0, seen }

local function settle(guid)
    local s = near[guid]
    if not s then return end
    near[guid] = nil
    if not (s.map and s.x) then return end
    local m = record(s.d)
    m.s = (m.s or 0) + 1
    local pts, added = addSpot(m.m[s.map], s.x, s.y)
    if added then m.m[s.map] = pts end
end

local function look(unit)
    if not On() or inInstance() then return end
    local d = describe(unit)
    if not d then return end
    local map, x, y = here()
    if not map then return end
    local HowNear = VQ.Mobs and VQ.Mobs.HowNear
    local dist = (HowNear and HowNear(unit)) or 60
    local s = near[d.guid]
    if s and (s.map ~= map or GetTime() - s.t0 > NEAR_FOR) then settle(d.guid); s = nil end
    if not s then
        near[d.guid] = { d = d, map = map, x = x, y = y, dist = dist, t0 = GetTime() }
    elseif dist < s.dist then
        s.map, s.x, s.y, s.dist, s.d = map, x, y, dist, d
    end
end

-- Kills: was it fighting you or your group (threat on it), and isn't it someone else's tag?
local engaged = {}   -- [guid] = GetTime() of the last threat seen
local function threatFrom(who, unit)
    local t = safe(UnitThreatSituation, who, unit)
    return t ~= nil and not secret(t)
end
-- you, your pet, and your group and their pets (a pet-only kill counts too, Sol)
local function ourThreat(unit)
    if threatFrom("player", unit) or threatFrom("pet", unit) then return true end
    if IsInGroup() then
        local raid = IsInRaid()
        for i = 1, (raid and 40 or 4) do
            local u = (raid and "raid" or "party") .. i
            if safe(UnitExists, u) then
                if threatFrom(u, unit) then return true end
                local p = (raid and "raidpet" or "partypet") .. i
                if safe(UnitExists, p) and threatFrom(p, unit) then return true end
            end
        end
    end
    return false
end
local lastScan = {}   -- [guid] = GetTime(): a threat scan per mob at most every 0.5 s (Sol)
local function noteThreat(unit)
    if not On() or inInstance() then return end
    local guid = safe(UnitGUID, unit)
    if not guid or secret(guid) or not npcOf(guid) then return end
    local now = GetTime()
    if lastScan[guid] and now - lastScan[guid] < 0.5 then return end
    lastScan[guid] = now
    if ourThreat(unit) then
        engaged[guid] = now
    elseif engaged[guid] then
        -- it reset (evaded, out of combat, alive): no longer yours; a guard killing it later
        -- mustn't count as your kill (Sol). Not on death: the threat list empties as it dies.
        local dead = safe(UnitIsDead, unit)
        local fighting = safe(UnitAffectingCombat, unit)
        if not secret(dead) and not dead and not secret(fighting) and not fighting then engaged[guid] = nil end
    end
end

local counted = {}   -- [guid] = GetTime(): a kill is counted once (nameplate + target both see it)
local function checkDeath(unit)
    if not On() or inInstance() then return end
    local dead = safe(UnitIsDead, unit)
    if secret(dead) or not dead then return end
    local guid = safe(UnitGUID, unit)
    if not guid or secret(guid) or counted[guid] then return end
    local t = engaged[guid]
    if not t or GetTime() - t > 120 then return end   -- not one you were fighting
    local denied = safe(UnitIsTapDenied, unit)
    if secret(denied) or denied then return end        -- someone else's
    local d = describe(unit)
    if not d then return end
    counted[guid] = GetTime()
    engaged[guid] = nil
    settle(guid)                                        -- keep its sighting first
    local m = record(d)
    m.k = (m.k or 0) + 1
    local map, x, y = here()
    if map then
        m.km = m.km or {}
        local pts, added = addSpot(m.km[map], x, y)
        if added then m.km[map] = pts end
    end
    A.lastKill = { npc = d.npc, name = d.name }
end
A.CheckDeath = checkDeath   -- (for the offline test)
A.Look = look
A.NoteThreat = noteThreat
A.Settle = settle

local ev = CreateFrame("Frame")
for _, e in ipairs({ "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED",
    "UPDATE_MOUSEOVER_UNIT", "UNIT_THREAT_LIST_UPDATE", "UNIT_HEALTH", "PLAYER_LOGOUT" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, e, unit)
    if e == "PLAYER_LOGOUT" then
        -- keep what's still in view (a /reload or logout dropped the last half minute, Sol)
        if On() then for guid in pairs(near) do pcall(settle, guid) end end
    elseif e == "NAME_PLATE_UNIT_ADDED" then
        pcall(look, unit)
    elseif e == "NAME_PLATE_UNIT_REMOVED" then
        pcall(checkDeath, unit)   -- a mob's plate goes when it dies: count it while the unit still reads
        local guid = safe(UnitGUID, unit)
        if guid and not secret(guid) then pcall(settle, guid) end
    elseif e == "PLAYER_TARGET_CHANGED" then
        pcall(look, "target")
    elseif e == "UPDATE_MOUSEOVER_UNIT" then
        pcall(look, "mouseover")
    elseif e == "UNIT_THREAT_LIST_UPDATE" then
        if unit then pcall(noteThreat, unit) end
    elseif e == "UNIT_HEALTH" then
        -- only what can die in view: target, mouseover and nameplates (enemy plates may be off)
        if unit == "target" or unit == "mouseover" or (type(unit) == "string" and unit:find("^nameplate")) then
            pcall(checkDeath, unit)
        end
    end
end)
C_Timer.NewTicker(10, function()
    local now = GetTime()
    if On() then
        for guid, s in pairs(near) do if now - s.t0 > NEAR_FOR then settle(guid) end end
    else
        wipe(near)   -- switched off: what was pending isn't saved (Sol)
    end
    for guid, t in pairs(engaged) do if now - t > 300 then engaged[guid] = nil end end
    -- a corpse's GUID can't die twice: forget counted kills and old scans (bounded, Sol)
    for guid, t in pairs(counted) do if now - t > 600 then counted[guid] = nil end end
    for guid, t in pairs(lastScan) do if now - t > 60 then lastScan[guid] = nil end end
end)

-- /vq atlas: what's recorded, this map's mobs, and your kills
function A:Report()
    local db = DB()
    local p = "|cff00c7ffVoidQuest|r "
    local mobs, kills, spots = 0, 0, 0
    for _, m in pairs(db.mobs) do
        mobs = mobs + 1
        kills = kills + (m.k or 0)
        for _, s in pairs(m.m or {}) do spots = spots + #s / 6 end
    end
    print(p .. ("mob atlas: %d mobs, %d spots, %d kills recorded%s"):format(mobs, spots, kills,
        On() and "" or " |cffff6060(recording is off: Settings > Guidance)|r"))
    local map = safe(C_Map.GetBestMapForUnit, "player")
    if not map then return end
    local here = {}
    for npc, m in pairs(db.mobs) do
        local s = m.m and m.m[map]
        local k = m.km and m.km[map]
        if s or k then here[#here + 1] = { npc = npc, m = m, n = (s and #s / 6 or 0), k = k and #k / 6 or 0 } end
    end
    table.sort(here, function(a, b) return (a.m.k or 0) > (b.m.k or 0) end)
    local info = safe(C_Map.GetMapInfo, map)
    print(p .. ("%s: %d mobs seen here"):format(info and info.name or ("map " .. map), #here))
    for i = 1, math.min(12, #here) do
        local h, m = here[i], here[i].m
        local lvl = m.lo and ((m.lo == m.hi) and tostring(m.lo) or (m.lo .. "-" .. m.hi)) or "?"
        local tag = (m.c and m.c ~= "normal") and (" " .. m.c) or ""
        local inData = VQ.ForeverMobNames and VQ.ForeverMobNames["n" .. h.npc]
        print(("  %s [%s]%s - %d spot%s, %d kill%s%s"):format(m.n or "?", lvl, tag, h.n, h.n == 1 and "" or "s",
            m.k or 0, (m.k or 0) == 1 and "" or "s", inData and "" or " |cffaaaaaa(not a quest mob in our data)|r"))
    end
end
