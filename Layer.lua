----------------------------------------------------------------------
-- Void Layer: which layer you're on (WoW Forever)
--
-- Forever has no layer API, and since game build 71037 (2026-11-20) a creature's GUID no longer
-- says the layer either: every creature carries a number of its own (VoidDev, 2026-11-21..24:
-- 965 numbers in Orgrimmar; the old "most nearby NPCs share it" reading flipped 215 times in an
-- hour with no move at all). So a layer is now a NAME this addon gives it, kept honest by what
-- the game itself says (all measured 2026-11-24, 4 of 4 hops agreed):
--   * SHARD_TRANSFER away from a zone change = the game moved you: a new layer here.
--   * an invite's isCrossShard (PARTY_INVITE_REQUEST, 6th field) = the inviter is on another layer
--     (false = the same one): the core reads it.
--   * UnitPhaseReason(unit) == Enum.PhaseReason.Sharding = that group member is on another layer;
--     nil = the same one.
--   * a player you can SEE (target, mouseover, nameplate) is on your layer.
-- Names are random ("<6 digits>-0", the old id shape every message and saved table uses). When the
-- game says two players are on one layer, both take the LOWER name (Merge), so names converge as
-- Void players meet; a hop takes the host's name (Adopt).
--
--   ns.Layer:Current(zone)        name for that zone ("482913-0"), or nil
--   ns.Layer:Here()               pair, zone for where you stand (named on first ask)
--   ns.Layer:Compare(pair, zone)  "same" / "other" (proven different) / nil (not known)
--   ns.Layer:Zone(mapID)          the zone a map rolls up to (caves, floors -> zone)
--   ns.Layer:OnChange(fn)         fn(pair, zone, how) when your layer's name changes (how "merged" = same layer, renamed)
--   ns.Layer:Adopt(zone, pair, how)   take that name (a hop to its holder)
--   ns.Layer:Merge(zone, pair)    the holder of pair is on your layer: both names -> the lower one
--   ns.Layer:Different(zone, pair)    the game says the holder of pair is on another layer
--   ns.Layer:Alias(zone, pair)    the name pair became after merges (or pair)
--   ns.Layer:Gen(zone)            changes on every move there (evidence from before it is stale)
--   ns.Layer:OnMerge(fn)          fn(zone, old, new)
--   ns.Layer:OnPlayer(fn)         fn(name, zone, same) a player the game placed on (same=true) or off your layer
--   ns.Layer:Snapshot() / Restore(t)  kept across a /reload or a short logout (the core saves it)
--   ns.Layer.Canon(p)             old ids "<server>-<n>" -> "<server>-0"
--
-- One copy runs for every Void addon (a global singleton), so they all use the same names. Nothing
-- is sent from here. Forever only. Source of truth: wow-addons/_shared/Layer.lua.
----------------------------------------------------------------------
local _, ns = ...
local VERSION = 2
local shared = _G.VoidLayerShared
if shared and shared.v == VERSION and shared.api then ns.Layer = shared.api; return end
local L = {}
ns.Layer = L
_G.VoidLayerShared = { v = VERSION, api = L }

function L.Canon(p)
    local s = type(p) == "string" and p:match("^(%d+)%-%d+$")
    return s and (s .. "-0") or p
end

local KEEP_AWAY  = 1800   -- a zone you left keeps its name this long (a crossing keeps your layer, 11-14)
local ZONE_MOVE  = 15     -- a SHARD_TRANSFER this soon after a zone change is the crossing, not a move
local RESTORE_IN = 180    -- names survive a logout this short (measured 11-16: under ~3.5 min kept the layer)
local PLAYER_GAP = 30     -- one "seen" per player per this many seconds

local function secret(v) return issecretvalue and issecretvalue(v) end
local function active() return RegionalUniqueNamesEnabled ~= nil and RegionalUniqueNamesEnabled() == true end
local function SHARDING()   -- Enum.PhaseReason.Sharding (1 on Forever), only if it really is a number
    local v = Enum and Enum.PhaseReason and Enum.PhaseReason.Sharding
    return type(v) == "number" and v or 1
end
local function num(p) return tonumber(type(p) == "string" and p:match("^(%d+)%-") or nil) end

local names = {}       -- [zone] = { pair, t, how }: t = the last time you were in that zone
local gen = {}         -- [zone] = n, bumped on every move there: evidence from before a move is stale (Sol review)
local alias = {}       -- [zone] = { [old pair] = new pair }
local differ = {}      -- [zone] = { [pair] = true }: proven another layer than ours (until we move)
local listeners, mergers, players = {}, {}, {}
local lastZoneAt, lastSeen = -1000, {}
local crossingOpen = false   -- the one SHARD_TRANSFER a zone crossing fires hasn't come yet

function L:Zone(mapID)
    local info = mapID and C_Map.GetMapInfo(mapID)
    local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
    while info and info.mapType and info.mapType > zoneType and info.parentMapID and info.parentMapID > 0 do
        mapID = info.parentMapID
        info = C_Map.GetMapInfo(mapID)
    end
    return mapID
end
local function here() return L:Zone(C_Map.GetBestMapForUnit("player")) end

-- how: "new" | "moved" (the game moved you) | "hop" (took a host's name) | "merged" (same layer, a new
-- name only: NOT a move) | "kept" (restored after a reload)
local function fire(pair, zone, how) for _, fn in ipairs(listeners) do pcall(fn, pair, zone, how) end end
local function newName()
    -- 100000..999999: never an old server number (those stay under 65536)
    return math.random(100000, 999999) .. "-0"
end
local function set(zone, pair, how)
    if how ~= "merged" and how ~= "kept" and how ~= "entered" then gen[zone] = (gen[zone] or 0) + 1 end
    local old = names[zone] and names[zone].pair
    names[zone] = { pair = pair, t = time(), how = how }
    if pair ~= old then fire(pair, zone, how) end
end

-- to the root, however long the chain (every step goes to a LOWER name, so it ends), then shortened (Sol review)
function L:Alias(zone, pair)
    pair = L.Canon(pair)
    local a = zone and alias[zone]
    if not (a and a[pair]) then return pair end
    local root, seen = pair, {}
    while a[root] and not seen[root] do seen[root] = true; root = a[root] end
    for p in pairs(seen) do if p ~= root then a[p] = root end end
    return root
end

function L:Current(zone)
    local k = zone and names[zone]
    if not k then return nil end
    if zone ~= here() and time() - k.t > KEEP_AWAY then names[zone] = nil; return nil end
    return k.pair
end

-- you're in that zone now: keep its name fresh, or drop it first when you've been away too long (the check
-- comes BEFORE the refresh, whoever touches it first after you return; Sol review)
local function touch(zone)
    local k = names[zone]
    if not k then return nil end
    if time() - k.t > KEEP_AWAY then names[zone] = nil; return nil end
    k.t = time()
    return k
end

function L:Here()
    local zone = here()
    if not zone then return nil, nil end
    if not touch(zone) and active() then set(zone, newName(), "new") end
    return names[zone] and names[zone].pair, zone
end

-- a number that changes whenever the game moves you in that zone (a refresh, a hop)
function L:Gen(zone) return gen[zone] or 0 end

function L:Compare(pair, zone)
    if type(pair) ~= "string" or pair == "" or pair == "0" then return nil end
    local mine = self:Current(zone)
    if not mine then return nil end
    pair = self:Alias(zone, pair)
    if pair == mine then return "same" end
    if differ[zone] and differ[zone][pair] then return "other" end
    return nil
end

function L:Adopt(zone, pair, how)
    pair = self:Alias(zone, pair)   -- a host still using a name merged away since (Sol review)
    if not (zone and num(pair)) then return end
    local old = self:Current(zone)
    if old and old ~= pair then
        alias[zone] = alias[zone] or {}
        alias[zone][old] = nil       -- our old name is NOT the new layer: we moved
    end
    differ[zone] = nil               -- what was "other" was other to the layer we left
    set(zone, pair, how or "hop")
end

function L:Merge(zone, pair)
    pair = self:Alias(zone, pair)
    local mine = self:Current(zone)
    if not (zone and mine and num(pair)) or pair == mine then return mine end
    local lo, hi = mine, pair
    if num(pair) < num(mine) then lo, hi = pair, mine end
    alias[zone] = alias[zone] or {}
    alias[zone][hi] = lo
    if differ[zone] then differ[zone][hi] = nil; differ[zone][lo] = nil end
    if lo ~= mine then set(zone, lo, "merged") else names[zone].t = time() end
    for _, fn in ipairs(mergers) do pcall(fn, zone, hi, lo) end
    return lo
end

function L:Different(zone, pair)
    pair = self:Alias(zone, pair)
    if not (zone and num(pair)) or pair == self:Current(zone) then return end
    differ[zone] = differ[zone] or {}
    differ[zone][pair] = true
end

function L:OnChange(fn) listeners[#listeners + 1] = fn end
function L:OnMerge(fn) mergers[#mergers + 1] = fn end
function L:OnPlayer(fn) players[#players + 1] = fn end

function L:Snapshot()
    local t = { at = time(), names = {} }
    for z, k in pairs(names) do t.names[z] = { pair = k.pair, t = k.t } end
    return t
end
function L:Restore(t)
    if type(t) ~= "table" or type(t.at) ~= "number" or type(t.names) ~= "table" then return end
    if time() - t.at > RESTORE_IN then return end
    for z, k in pairs(t.names) do
        z = tonumber(z)
        if z and type(k) == "table" and num(k.pair) then
            local cur = names[z] and names[z].pair
            names[z] = { pair = k.pair, t = tonumber(k.t) or time(), how = "kept" }
            if cur ~= k.pair then fire(k.pair, z, "kept") end
        end
    end
end

----------------------------------------------------------------------
-- What the game says
----------------------------------------------------------------------
local function tellPlayer(name, same)
    if type(name) ~= "string" or name == "" or secret(name) then return end
    local key = name .. (same and "+" or "-")
    if lastSeen[key] and GetTime() - lastSeen[key] < PLAYER_GAP then return end
    lastSeen[key] = GetTime()
    local zone = here()
    if not zone then return end
    for _, fn in ipairs(players) do pcall(fn, name, zone, same) end
end
-- the same shape the core uses (Forever names are "First Surname"; Sol review): the core canonicalizes it
local function fullName(unit)
    local n = GetUnitName and GetUnitName(unit, false)
    if type(n) == "string" and n ~= "" and not secret(n) then return n end
    local a, b = UnitName(unit)
    if type(a) ~= "string" or a == "" or secret(a) then return nil end
    if type(b) == "string" and b ~= "" and not secret(b) then return a .. " " .. b end
    return a
end
-- a player you can see is on your layer (any other layer's players aren't drawn at all)
local function seePlayer(unit)
    if not active() or not UnitExists(unit) or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return end
    if UnitInParty(unit) or UnitInRaid(unit) then return end   -- group members: the phase check below
    local vis = UnitIsVisible(unit)
    if secret(vis) or not vis then return end
    tellPlayer(fullName(unit), true)
end
-- group members: the game's own answer, every 2 s
C_Timer.NewTicker(2, function()
    if not active() or not UnitPhaseReason then return end
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    if n == 0 then return end
    local raid = IsInRaid and IsInRaid()
    for i = 1, raid and 40 or 4 do
        local u = (raid and "raid" or "party") .. i
        -- only members in YOUR zone: names are per zone (Sol review)
        local zu = UnitExists(u) and L:Zone(C_Map.GetBestMapForUnit(u))
        if zu and not secret(zu) and zu == here() and not UnitIsUnit(u, "player") then
            local ok, r = pcall(UnitPhaseReason, u)
            local on = UnitIsConnected == nil or UnitIsConnected(u)
            if ok and not secret(r) and on then
                if r == nil then tellPlayer(fullName(u), true)
                elseif r == SHARDING() then tellPlayer(fullName(u), false) end
            end
        end
    end
end)

-- standing in a zone keeps its name fresh even when nothing asks for it (an AFK hour isn't "away")
C_Timer.NewTicker(60, function() local z = here(); if z then touch(z) end end)

local f = CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED",
                      "ZONE_CHANGED_NEW_AREA", "SHARD_TRANSFER" }) do
    pcall(f.RegisterEvent, f, ev)
end
f:SetScript("OnEvent", function(_, ev, a1)
    if ev == "PLAYER_TARGET_CHANGED" then pcall(seePlayer, "target")
    elseif ev == "UPDATE_MOUSEOVER_UNIT" then pcall(seePlayer, "mouseover")
    elseif ev == "NAME_PLATE_UNIT_ADDED" then pcall(seePlayer, a1)
    elseif ev == "ZONE_CHANGED_NEW_AREA" then
        lastZoneAt, crossingOpen = GetTime(), true
        -- entering a zone: a name kept from before (a crossing keeps your layer), unless you've been away too
        -- long; listeners hear "entered" either way (the core links zones on it). A second later: the map is set.
        C_Timer.After(1, function()
            local z = here()
            if not z then return end
            local k = touch(z)
            if k then fire(k.pair, z, "entered") else L:Here() end
        end)
    elseif ev == "SHARD_TRANSFER" then
        if not active() then return end
        -- the FIRST transfer right after a zone change is the crossing (keeps your layer); another one is a real
        -- move, even that soon (a hop right after entering; Sol review)
        if crossingOpen and GetTime() - lastZoneAt < ZONE_MOVE then crossingOpen = false; return end
        crossingOpen = false
        -- the game moved you (a world refresh or a hop): a new layer, until the core learns its name
        local zone = here()
        if zone then
            differ[zone] = nil
            set(zone, newName(), "moved")
        end
    end
end)
