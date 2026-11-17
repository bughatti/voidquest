----------------------------------------------------------------------
-- Void Layer: which layer you're on (WoW Forever)
--
-- Forever has no layer API. Every NPC's GUID carries it (measured 2026-11-08 with
-- VoidDev's LayerProbe): Creature-0-<server>-<map>-<n>-<npcID>-<spawn>. The server
-- number is the layer (<n> and <spawn> are per player: see L.Canon); it changes when a
-- group invite moves you (7075 -> 7054) or you walk into another area (Barrens 6831,
-- Orgrimmar 7073). Now and then a single NPC from another layer shows up, so the layer
-- is the one MOST nearby NPCs share. Ids are "<server>-0" (the old two-number shape).
--
--   ns.Layer:Current(zone)   id for that zone ("6831-0"), or nil while unknown
--   ns.Layer:Here()          pair, zone for where you stand
--   ns.Layer:Compare(pair, zone)  "same" / "other" / nil (unknown either side)
--   ns.Layer:Zone(mapID)     the zone a map rolls up to (caves, floors -> zone)
--   ns.Layer:OnChange(fn)    fn(pair, zone) when your layer changes
--
-- Read from nameplates, your target and your mouseover; players and their pets,
-- totems and summons are skipped. Readings reset when your group changes, you
-- change zone, or the game's "world refresh" moves you (SHARD_TRANSFER, measured
-- 2026-11-14: Stonetalon 6831-95 -> 7051-96 solo, no zone change; without the reset
-- the old pair kept the majority and VoidLayer showed it). Nothing is saved or sent. Forever only.
--
-- Copied as-is into each addon that uses it (source of truth: wow-addons/_shared/Layer.lua).
----------------------------------------------------------------------
local _, ns = ...
local L = {}
ns.Layer = L

-- ONLY THE SERVER NUMBER IS THE LAYER (proven 2026-11-14 with two players in one group at one spot,
-- each seeing the other, targeting the SAME grunt: user Creature-0-6832-1-125-5953-13B91CA0CC, son
-- Creature-0-6832-1-3-5953-7053364CB3). The number after the map and the spawn part differ per
-- player (that number counts up per player: 88, 95 ... 125 over a day; 2, 3 for a fresh login),
-- and every layer change ever logged changed the server number. So the layer id is "<server>-0":
-- the "-0" keeps the old "<server>-<n>" shape every message and saved table uses, and Canon turns
-- an id from an older version ("6832-125") into the same "6832-0".
function L.Canon(p)
    local s = type(p) == "string" and p:match("^(%d+)%-%d+$")
    return s and (s .. "-0") or p
end

local WINDOW  = 180   -- seconds a reading counts
local MAX     = 60    -- readings kept
local FRESH   = 600   -- a zone's layer is trusted this long after its last reading

local function secret(v) return issecretvalue and issecretvalue(v) end
local function active() return RegionalUniqueNamesEnabled ~= nil and RegionalUniqueNamesEnabled() == true end

local readings = {}   -- { pair, zone, t }
local known = {}      -- [zone] = { pair, t }
local listeners = {}

function L:Zone(mapID)
    local info = mapID and C_Map.GetMapInfo(mapID)
    local zoneType = Enum.UIMapType and Enum.UIMapType.Zone or 3
    while info and info.mapType and info.mapType > zoneType and info.parentMapID and info.parentMapID > 0 do
        mapID = info.parentMapID
        info = C_Map.GetMapInfo(mapID)
    end
    return mapID
end

local function here() return L:Zone(C_Map.GetBestMapForUnit("player")) end

local function recompute(zone)
    local now, count, best, bestN = GetTime(), {}, nil, 0
    for _, r in ipairs(readings) do
        if r.zone == zone and now - r.t <= WINDOW then
            local n = (count[r.pair] or 0) + 1
            count[r.pair] = n
            if n > bestN then best, bestN = r.pair, n end
        end
    end
    if not best then return end
    local old = known[zone] and known[zone].pair
    known[zone] = { pair = best, t = now }
    if best ~= old then
        for _, fn in ipairs(listeners) do pcall(fn, best, zone) end
    end
end

local function note(unit)
    if not active() or not UnitExists(unit) then return end
    if UnitPlayerControlled(unit) then return end   -- players, pets, totems, summons
    -- companion pets aren't player-controlled, but their GUID says another server (live 11-14: a
    -- player's Mini Diablo read 7054-120 in a camp that was 6807-111)
    for _, fn in ipairs({ UnitIsBattlePetCompanion, UnitIsOtherPlayersPet }) do
        local ok, v = pcall(fn, unit)
        if ok and not secret(v) and v then return end
    end
    local g = UnitGUID(unit)
    if not g or secret(g) then return end
    local kind, _, server, _, shard = strsplit("-", g)
    if kind ~= "Creature" or not (server and shard) then return end
    local zone = here()
    if not zone then return end
    -- one vote per NPC: pointing at the same odd one again doesn't outvote the rest (Codex)
    for i = #readings, 1, -1 do
        if readings[i].guid == g then table.remove(readings, i) end
    end
    table.insert(readings, { pair = L.Canon(server .. "-" .. shard), zone = zone, t = GetTime(), guid = g })
    while #readings > MAX do table.remove(readings, 1) end
    recompute(zone)
end

-- The nameplates already on screen. NAME_PLATE_UNIT_ADDED only fires when a plate appears,
-- so standing among NPCs after a login, a reload or a hop read nothing (live 11-09: "not
-- known yet" in a camp full of plates). Units by name: plate.namePlateUnitToken errors on Forever.
local function scanPlates()
    if not active() then return end
    for i = 1, 40 do
        local u = "nameplate" .. i
        if UnitExists(u) then pcall(note, u) end
    end
end

-- A group change or a new zone can move you: start over, answers included (Codex: a
-- kept answer said the old layer for up to FRESH seconds after a hop). Then read the plates
-- around you again (twice: the new ones load in over a few seconds).
local function reset()
    wipe(readings); wipe(known)
    C_Timer.After(1, scanPlates)
    C_Timer.After(4, scanPlates)
end
-- and every 15 s, so a layer you're standing in never goes stale
C_Timer.NewTicker(15, scanPlates)

function L:Current(zone)
    local k = zone and known[zone]
    if k and GetTime() - k.t <= FRESH then return k.pair end
end

function L:Here()
    local zone = here()
    return self:Current(zone), zone
end

function L:Compare(pair, zone)
    if type(pair) ~= "string" or pair == "" or pair == "0" then return nil end
    local mine = self:Current(zone)
    if not mine then return nil end
    return mine == L.Canon(pair) and "same" or "other"
end

function L:OnChange(fn) listeners[#listeners + 1] = fn end

local f = CreateFrame("Frame")
for _, ev in ipairs({ "NAME_PLATE_UNIT_ADDED", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT",
                      "GROUP_ROSTER_UPDATE", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "SHARD_TRANSFER" }) do
    pcall(f.RegisterEvent, f, ev)
end
local lastGroup
f:SetScript("OnEvent", function(_, ev, a1)
    if ev == "NAME_PLATE_UNIT_ADDED" then pcall(note, a1)
    elseif ev == "PLAYER_TARGET_CHANGED" then pcall(note, "target")
    elseif ev == "UPDATE_MOUSEOVER_UNIT" then pcall(note, "mouseover")
    elseif ev == "GROUP_ROSTER_UPDATE" then
        local n = GetNumGroupMembers and GetNumGroupMembers() or 0
        local inGroup = n > 0
        if inGroup ~= lastGroup then lastGroup = inGroup; reset() end   -- joined or left, not every roster tick
    else
        reset()
    end
end)
