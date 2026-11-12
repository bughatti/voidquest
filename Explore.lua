----------------------------------------------------------------------
-- Explore.lua — which areas you still have to discover (WoW Forever), shared by VoidMap (progress
-- view) and VoidQuest (route plan). The user, 2026-11-11: "do both, progress in voidmap and
-- explore on the route"; Explore Azeroth is a Legacy point ("Have a character with the Explore
-- Azeroth achievement", the in-game challenge list).
--
-- Shared file (_shared/, copied by tools/cmd/sync-libs): the newest VERSION loaded runs as
-- _G.VoidExplore. Needs ForeverAreas.lua (VoidForeverAreas: area centres by zone map).
--
-- The achievements are found by name once (any category): "Explore Azeroth", the continents
-- ("Explore Kalimdor", "Explore Eastern Kingdoms") and one per zone ("Explore Durotar").
-- A zone's criteria are its areas (name + done); each is matched to its centre by name.
--
--   VoidExplore:Overall()          -> { done, conts = { { name, id, done, total, zonesDone } } } or nil
--   VoidExplore:Zone(uiMap)        -> { id, name, done, total, areas = { { name, done, map, x, y } } } or nil
--   VoidExplore:Undiscovered(uiMap)-> { { name, map, x, y }, ... } (only areas with a known centre)
--   VoidExplore:ZoneOf(uiMap)      -> the zone map a map rolls up to
----------------------------------------------------------------------
if (select(4, GetBuildInfo()) or 0) >= 100000 then return end   -- WoW Forever only
local VERSION = 1
if _G.VoidExplore and (_G.VoidExplore.version or 0) >= VERSION then return end

local E = { version = VERSION }
_G.VoidExplore = E

local function safe(fn, ...)
    if not fn then return nil end
    local ok, a, b, c, d, e, f = pcall(fn, ...)
    if ok then return a, b, c, d, e, f end
end

-- achievements by name, found once
local ach   -- { azeroth = id, conts = { [name] = id }, zones = { [zoneName] = id } }
local function find()
    if ach then return ach end
    local found = { conts = {}, zones = {} }
    for _, cat in ipairs(safe(GetCategoryList) or {}) do
        local n = safe(GetCategoryNumAchievements, cat, true) or 0
        for i = 1, n do
            local id, name = safe(GetAchievementInfo, cat, i)
            local what = type(name) == "string" and name:match("^Explore (.+)$")
            if id and what then
                if what == "Azeroth" then found.azeroth = id
                elseif what == "Kalimdor" or what == "Eastern Kingdoms" then found.conts[what] = id
                else found.zones[what] = id end
            end
        end
    end
    -- nothing found yet (achievement data still loading at login): try again next time
    if found.azeroth or next(found.zones) then ach = found end
    return found
end
function E:Reset() ach = nil end

-- the zone a map belongs to (towns, caves and floors roll up)
function E:ZoneOf(mapID)
    local ZONE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
    local info, hops = mapID and safe(C_Map.GetMapInfo, mapID), 0
    while info and info.mapType and info.mapType > ZONE and info.parentMapID and hops < 6 do
        info, hops = safe(C_Map.GetMapInfo, info.parentMapID), hops + 1
    end
    return info and info.mapID or mapID
end

local function zoneName(uiMap)
    local i = uiMap and safe(C_Map.GetMapInfo, uiMap)
    return i and i.name
end

local function centre(uiMap, name)
    local list = VoidForeverAreas and VoidForeverAreas.areas[uiMap]
    if not list or not name then return nil end
    local want = name:lower()
    for _, a in ipairs(list) do
        if a[1]:lower() == want then return a[2], a[3] end
    end
end

-- one zone's areas, from its "Explore <zone>" achievement
function E:Zone(uiMap)
    uiMap = self:ZoneOf(uiMap)
    local name = zoneName(uiMap)
    local id = name and find().zones[name]
    if not id then return nil end
    local out = { id = id, name = name, done = 0, total = 0, areas = {} }
    for i = 1, (safe(GetAchievementNumCriteria, id) or 0) do
        local text, _, completed = safe(GetAchievementCriteriaInfo, id, i)
        if type(text) == "string" and text ~= "" then
            local x, y = centre(uiMap, text)
            out.total = out.total + 1
            if completed then out.done = out.done + 1 end
            out.areas[#out.areas + 1] = { name = text, done = completed and true or false, map = uiMap, x = x, y = y }
        end
    end
    local _, _, _, achDone = safe(GetAchievementInfo, id)
    out.complete = achDone and true or false
    return out
end

function E:Undiscovered(uiMap)
    local z = self:Zone(uiMap)
    local out = {}
    for _, a in ipairs(z and z.areas or {}) do
        if not a.done and a.x then out[#out + 1] = { name = a.name, map = a.map, x = a.x, y = a.y, zone = z.name } end
    end
    return out
end

-- Explore Azeroth and the two continents: zones fully explored out of how many
function E:Overall()
    local a = find()
    if not (a.azeroth or next(a.conts)) then return nil end
    local out = { conts = {} }
    if a.azeroth then
        local _, _, _, done = safe(GetAchievementInfo, a.azeroth)
        out.done = done and true or false
    end
    for _, cname in ipairs({ "Kalimdor", "Eastern Kingdoms" }) do
        local id = a.conts[cname]
        if id then
            local c = { name = cname, id = id, total = 0, zonesDone = 0, zones = {} }
            for i = 1, (safe(GetAchievementNumCriteria, id) or 0) do
                local text, _, completed, _, _, _, _, assetID = safe(GetAchievementCriteriaInfo, id, i)
                if type(text) == "string" and text ~= "" then
                    c.total = c.total + 1
                    if completed then c.zonesDone = c.zonesDone + 1 end
                    local zn = text:match("^Explore (.+)$") or text
                    c.zones[#c.zones + 1] = { name = zn, done = completed and true or false,
                        map = VoidForeverAreas and VoidForeverAreas.zones[zn] }
                end
            end
            out.conts[#out.conts + 1] = c
        end
    end
    return out
end

-- discovering an area updates the achievement criteria: let the views redraw
local listeners = {}
function E:OnChange(fn) listeners[#listeners + 1] = fn end
local ev = CreateFrame("Frame")
ev:RegisterEvent("CRITERIA_UPDATE")
ev:RegisterEvent("ACHIEVEMENT_EARNED")
ev:RegisterEvent("UI_INFO_MESSAGE")
local pending
ev:SetScript("OnEvent", function()
    if pending then return end
    pending = true
    C_Timer.After(1, function()
        pending = nil
        for _, fn in ipairs(listeners) do pcall(fn) end
    end)
end)
