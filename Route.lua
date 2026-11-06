----------------------------------------------------------------------
-- Route.lua — this addon's own waypoint router (a private copy: every Void addon
-- that pins places ships this same file in its own namespace; there is no shared
-- library and no shared state). Source of truth: wow-addons/_shared/Route.lua —
-- copy changes into each addon (see _shared/README).
--
-- Blizzard's arrow can't point into another WORLD (instance map: Eastern Kingdoms,
-- Kalimdor, Voidstorm, Harandar ...). Route:Go() pins the target if you're in its
-- world; otherwise it finds a way through PORTALS (breadth-first over worlds), pins
-- the first portal, and moves to the next leg on its own after
-- each zone change. A pin clears itself within `arrive` yards, and a pin someone else
-- set is never touched. (User rule, 2026-11-01.)
--
--   ns.Route:Go({ map = uiMapID, x = 0-1, y = 0-1, name = "...", zone = "...",
--                 fallback = <target used when map can't hold a pin> },
--               { arrive = yards, say = function(msg) end, silent = bool })
--     -> true | false, reason
--   ns.Route:Clear()   -- removes the pin only if it's ours
--   ns.Route:Hop(map, x, y)  -- the portal to pin instead (for addons that place their own pins)
--   ns.Route.WorldOf(mapID, x, y)   -- the world (instance) a map point is in
----------------------------------------------------------------------
local _, ns = ...
local Route = {}
ns.Route = Route

local ARRIVE = 20   -- yards

-- Permanent portals between worlds, x, y on 0-100. Silvermoon / Orgrimmar / Stormwind
-- from warcraft.wiki.gg (2026-11-01; full list in _shared/portals-reference.lua);
-- Silvermoon, Voidstorm and Harandar spots are the game's own map markers (area POIs),
-- recorded by VoidDev's scanner in game 2026-11-01 (they confirm the wiki's numbers).
-- Portals inside one world (Stormwind <-> Silvermoon) are skipped automatically.
local PORTALS = {
    { map = 2393, x = 52.17, y = 65.2,  toMap = 85,   faction = "Horde",    name = "Portal Room (Orgrimmar)",   zone = "Silvermoon City" },
    { map = 2393, x = 52.6,  y = 64.6,  toMap = 84,   faction = "Alliance", name = "portal to Stormwind",       zone = "Silvermoon City" },
    { map = 2393, x = 35.29, y = 66.07, toMap = 2405,                       name = "portal to Voidstorm",       zone = "Silvermoon City" },
    { map = 2393, x = 36.74, y = 68.22, toMap = 2413,                       name = "Rootway to Harandar",       zone = "Silvermoon City" },
    { map = 2405, x = 51.62, y = 70.32, toMap = 2393,                       name = "portals to Silvermoon and Harandar", zone = "Voidstorm" },
    { map = 2405, x = 51.62, y = 70.32, toMap = 2413,                       name = "portals to Silvermoon and Harandar", zone = "Voidstorm" },
    { map = 2413, x = 53.34, y = 55.47, toMap = 2395,                       name = "Eversong Rootway",          zone = "Harandar" },
    { map = 2413, x = 52.99, y = 55.74, toMap = 2405,                       name = "portal to Voidstorm",       zone = "Harandar" },
    { map = 85,   x = 56.0,  y = 88.2,  toMap = 2393, faction = "Horde",    name = "portal to Silvermoon City", zone = "Orgrimmar" },
    { map = 84,   x = 48.7,  y = 95.1,  toMap = 2393, faction = "Alliance", name = "portal to Silvermoon City", zone = "Stormwind City" },
    { map = 84,   x = 43.6,  y = 87.2,  toMap = 103,  faction = "Alliance", name = "portal to the Exodar",      zone = "Stormwind City" },
}

-- The world (instance) a map point is in; x, y on 0-1 (the map's middle when omitted).
-- Some maps (cities, micro-maps) don't convert: then the parent maps are tried.
local function worldOf(mapID, x, y)
    if not (mapID and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local m, px, py = mapID, x or 0.5, y or 0.5
    for _ = 1, 6 do
        local ok, w = pcall(C_Map.GetWorldPosFromMapPos, m, CreateVector2D(px, py))
        if ok and w then return w end
        local info = C_Map.GetMapInfo(m)
        m = info and info.parentMapID
        if not m or m <= 0 then return nil end
        px, py = 0.5, 0.5
    end
end
Route.WorldOf = worldOf

local function playerWorld()
    local m = C_Map.GetBestMapForUnit("player")
    local pos = m and C_Map.GetPlayerMapPosition(m, "player")
    if pos then return worldOf(m, pos:GetXY()) end
    return worldOf(m)
end

-- First portal on the way from world `from` to world `to` (breadth-first).
local function firstHop(from, to)
    local faction = UnitFactionGroup("player")
    local edges = {}
    for _, p in ipairs(PORTALS) do
        if not p.faction or p.faction == faction then
            local a, b = worldOf(p.map, p.x / 100, p.y / 100), worldOf(p.toMap)
            if a and b and a ~= b then
                edges[a] = edges[a] or {}
                table.insert(edges[a], { to = b, portal = p })
            end
        end
    end
    local queue, seen, firstOf, i = { from }, { [from] = true }, {}, 1
    while queue[i] do
        local c = queue[i]; i = i + 1
        if c == to then return firstOf[c] end
        for _, e in ipairs(edges[c] or {}) do
            if not seen[e.to] then
                seen[e.to] = true
                firstOf[e.to] = firstOf[c] or e.portal
                queue[#queue + 1] = e.to
            end
        end
    end
end

local state = {}

-- Any waypoint set after ours that we didn't set (the player, another addon, or
-- another Void addon's copy of this file, maybe at the very same portal) takes
-- it over: from then on it isn't ours, even at the same spot.
local settingOurs = false
hooksecurefunc(C_Map, "SetUserWaypoint", function(point)
    if settingOurs then return end
    -- only a call that really set it (the waypoint is now that point) counts
    local wp = C_Map.GetUserWaypoint()
    if wp and point and wp.uiMapID == point.uiMapID and wp.position and point.position
       and math.abs(wp.position.x - point.position.x) < 0.0001
       and math.abs(wp.position.y - point.position.y) < 0.0001 then
        state.lost = true
    end
end)

local function ours()
    if state.lost or not (state.map and C_Map.GetUserWaypoint()) then return false end
    local pos = C_Map.GetUserWaypointPositionForMap(state.map)
    if not pos then return false end
    local x, y = pos:GetXY()
    return math.abs(x - state.x) < 0.001 and math.abs(y - state.y) < 0.001
end

local function stopWatch()
    if state.ticker then state.ticker:Cancel() end
    state.ticker = nil
end

local function watch()
    -- cleared or replaced by someone else: leave it, and give up the route too
    if not ours() then stopWatch(); state.map, state.route = nil, nil; return end
    -- GetDistance() is to the SUPER-tracked target, which may be a quest now
    if C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint
       and not C_SuperTrack.IsSuperTrackingUserWaypoint() then return end
    local d = C_Navigation and C_Navigation.GetDistance and C_Navigation.GetDistance()
    if d and d > 0 and d <= (state.arrive or ARRIVE) then
        C_Map.ClearUserWaypoint()
        stopWatch(); state.map = nil
        if not state.route and state.say then state.say("arrived, waypoint cleared") end
    end
end

local function pin(map, x, y, opts)
    settingOurs = true
    local ok, err = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(map, x, y))
    settingOurs = false
    if not ok then error(err, 2) end
    state.lost = false
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
    stopWatch()
    state.map, state.x, state.y = map, x, y
    state.arrive, state.say = opts.arrive, opts.say
    state.ticker = C_Timer.NewTicker(0.5, watch)
end

function Route:Go(t, opts)
    opts = opts or {}
    if not (t and t.map and t.x and t.y) then return false, "no location" end
    local say = (not opts.silent) and opts.say or nil
    if not opts.leg then state.route = nil end   -- a new target replaces any old route

    local here, there = playerWorld(), worldOf(t.map, t.x, t.y)
    if here and there and here ~= there then
        local hop = firstHop(here, there)
        if hop and C_Map.CanSetUserWaypointOnMap(hop.map) then
            state.route = { target = t, opts = opts }
            pin(hop.map, hop.x / 100, hop.y / 100, { say = opts.say })   -- portals: default distance
            if say then say(("%s is in another part of the world: first the %s (%s), then the arrow moves on."):format(
                t.name or "That", hop.name, hop.zone)) end
            return true
        end
    end

    if not C_Map.CanSetUserWaypointOnMap(t.map) then
        if t.fallback then return self:Go(t.fallback, opts) end
        return false, "that map can't hold a waypoint"
    end
    state.route = nil
    pin(t.map, t.x, t.y, opts)
    if say then
        say(("navigating to %s%s"):format(t.name or "target",
            (here and there and here ~= there) and " (no portal route known from here: travel there first)" or ""))
    end
    return true
end

-- For addons that place their own pins (VoidQuest): the portal to pin INSTEAD of a
-- target in another world, as { map, x = 0-1, y = 0-1, name, zone }, or nil when the
-- target is in this world (or no route is known). x, y (0-1) locate the target.
function Route:Hop(map, x, y)
    local here, there = playerWorld(), worldOf(map, x, y)
    if not (here and there and here ~= there) then return nil end
    local hop = firstHop(here, there)
    if not (hop and C_Map.CanSetUserWaypointOnMap(hop.map)) then return nil end
    return { map = hop.map, x = hop.x / 100, y = hop.y / 100, name = hop.name, zone = hop.zone }
end

function Route:Clear()
    if ours() then C_Map.ClearUserWaypoint() end
    stopWatch(); state.map, state.route = nil, nil
end

-- Next leg after each zone change (taking a portal).
local f = CreateFrame("Frame")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:SetScript("OnEvent", function()
    local r = state.route
    if not r then return end
    C_Timer.After(1, function()   -- let the new zone's map settle
        if state.route ~= r then return end
        -- another pin was set (by the player or another addon): it wins, the route ends.
        -- (No pin = we cleared ours at the portal; our own pin still up = fine.)
        if state.lost or (C_Map.GetUserWaypoint() and not ours()) then state.route = nil; return end
        local o = {}
        for k, v in pairs(r.opts) do o[k] = v end
        o.leg = true
        Route:Go(r.target, o)
    end)
end)
