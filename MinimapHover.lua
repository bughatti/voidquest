----------------------------------------------------------------------
-- MinimapHover (shared: tools/cmd/sync-libs copies _shared/MinimapHover.lua into every addon
-- that carries a file of the same name: VoidGather, VoidQuest). Edit the _shared copy.
--
-- What the game's own minimap dot says when YOU point at it, and where that dot is on the map.
-- Probed on WoW Forever 2026-11-10 (VoidDev MinimapProbe; memory wow-forever-minimap-readable):
--   * the engine shows a dot's tooltip on GameTooltip, owned by UIParent (not the Minimap), and
--     not through a Lua OnShow we can rely on -> read by polling while the cursor is over the map
--   * the cursor's offset from the minimap center / half its width * C_Minimap.GetViewRadius()
--     (yards from center to edge) = the dot's offset in yards; un-rotated by your facing when
--     the minimap turns; / C_Map.GetMapWorldSize -> map position, about +-10 yd at zoom 0
--   * an addon can't point at the minimap itself (Minimap:UpdateMouseoverAtPoint shows nothing),
--     so this only ever reads dots the player hovers
--   ns.MinimapHover:Listen(fn)   fn(names, mapID, x, y, yards) -- names = the dot's lines without
--                                textures / colours, x/y 0..1, yards from you
--   ns.MinimapHover.Where()      -> mapID, x, y, yards of the cursor's spot (or nil)
----------------------------------------------------------------------
local _, ns = ...
if ns.MinimapHover then return end
local H = { listeners = {} }
ns.MinimapHover = H

function H:Listen(fn) self.listeners[#self.listeners + 1] = fn end

local function secret(v) return issecretvalue and issecretvalue(v) end

-- "|TInterface\Minimap\Minimap-PositionArrows:...|tBruiseweed" -> "Bruiseweed"; colours out
local function clean(s)
    s = s:gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
H.Clean = clean

function H.Where()
    if not (Minimap and C_Minimap and C_Minimap.GetViewRadius) then return nil end
    local cx, cy = GetCursorPosition()
    local s = Minimap:GetEffectiveScale()
    local mx, my = Minimap:GetCenter()
    local half = (Minimap:GetWidth() or 0) / 2
    if not (cx and mx and s and s > 0 and half > 0) then return nil end
    local ok, radius = pcall(C_Minimap.GetViewRadius)
    if not (ok and type(radius) == "number" and radius > 0) then return nil end
    local dx = (cx / s - mx) / half * radius   -- yards right of you on the minimap
    local dy = (cy / s - my) / half * radius   -- yards up
    if GetCVar("rotateMinimap") == "1" then
        -- the minimap turns so you face up: turn it back to north-up
        local f = GetPlayerFacing and GetPlayerFacing()
        if not f or secret(f) then return nil end
        dx, dy = dx * math.cos(f) - dy * math.sin(f), dx * math.sin(f) + dy * math.cos(f)
    end
    local map = C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return nil end
    local px, py = pos:GetXY()
    local okw, w, h = pcall(C_Map.GetMapWorldSize, map)
    if not (okw and w and h and w > 0 and h > 0 and px and py) then return nil end
    local x, y = px + dx / w, py - dy / h      -- map y grows southward
    if x <= 0 or y <= 0 or x >= 1 or y >= 1 then return nil end
    return map, x, y, math.sqrt(dx * dx + dy * dy)
end

-- Poll 5x a second while the cursor is over the minimap and a tooltip is up.
local lastKey, lastAt, acc = nil, 0, 0
local poll = CreateFrame("Frame")
poll:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc < 0.2 then return end
    acc = 0
    if #H.listeners == 0 or not (Minimap and Minimap:IsVisible() and Minimap:IsMouseOver()) or not GameTooltip:IsShown() then
        lastKey = nil
        return
    end
    -- the game's own dots show as UIParent's tooltip; an addon's pin (VoidGather, VoidSweep...)
    -- owns its tooltip and is skipped (its spot is known already)
    local owner = GameTooltip:GetOwner()
    if owner ~= UIParent and owner ~= Minimap then return end
    local names = {}
    for i = 1, math.min(GameTooltip:NumLines() or 0, 12) do
        local fs = _G["GameTooltipTextLeft" .. i]
        local t = fs and fs:GetText()
        if t and not secret(t) then
            for part in t:gmatch("[^\n]+") do   -- dots on top of each other: one per line
                local n = clean(part)
                if n ~= "" then names[#names + 1] = n end
            end
        end
    end
    if #names == 0 then return end
    local map, x, y, yards = H.Where()
    if not map then return end
    -- the same dot again (name + where, ~15 yd), not just the same name: two Peacebloom dots
    -- hovered one after the other are two nodes (Sol review)
    local key = table.concat(names, "|") .. "@" .. map .. ":" .. math.floor(x * 500) .. ":" .. math.floor(y * 500)
    if key == lastKey and GetTime() - lastAt < 5 then return end
    lastKey, lastAt = key, GetTime()
    for _, fn in ipairs(H.listeners) do pcall(fn, names, map, x, y, yards) end
end)
