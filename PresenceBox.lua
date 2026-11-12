----------------------------------------------------------------------
-- Void "players here" box -- how many other players of each Void addon
-- that shares over a hidden channel (VoidGather, VoidSweep, VoidQuest on WoW
-- Forever) are in your zone (Forever: online).
--
-- The same file is copied into each of those addons (source of truth:
-- wow-addons/_shared/PresenceBox.lua; never a shared library). The first copy
-- that loads builds the box and the global VoidPresence; each addon reports
-- its own line with VoidPresence:Set(). Drag to move, right-click for
-- options. On/off and position are kept in VoidPresenceDB (account-wide; each
-- addon's TOC lists it).
----------------------------------------------------------------------
-- Borders are one screen pixel (tools/cmd/pixelfix, 2026-11-09). WoW snaps each border
-- piece to the pixel grid, and a thin line on a fractional position can snap to 0 px: a side
-- of a box vanishes. VoidPX() asks for one real pixel, and the hook below (installed once, by
-- the first Void addon loaded) turns snapping off on the edges of flat WHITE8X8 borders, like
-- Blizzard's NineSliceUtil.DisableSharpening, so a 1 px line always covers a pixel. It also
-- moves the border 1/8 px up-left: a side sitting exactly on a pixel's middle (a box centred
-- in an odd-width window) covered no pixel and vanished (2026-11-12).
local function VoidPX()
    local s = UIParent and UIParent:GetEffectiveScale()
    if s and s > 0 and PixelUtil and PixelUtil.GetPixelToUIUnitFactor then return PixelUtil.GetPixelToUIUnitFactor() / s end
    return 1
end
if not _G.__VoidBorderHook2 and hooksecurefunc and NineSliceUtil and NineSliceUtil.ApplyLayout then
    _G.__VoidBorderHook2 = true
    local EDGES = { "TopEdge", "BottomEdge", "LeftEdge", "RightEdge",
                    "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner" }
    hooksecurefunc(NineSliceUtil, "ApplyLayout", function(c)
        local i = type(c) == "table" and c.backdropInfo
        local e = i and i.edgeFile
        if type(e) ~= "string" or not e:lower():find("white8x8", 1, true) or (tonumber(i.edgeSize) or 0) > 3 then return end
        for _, k in ipairs(EDGES) do
            local t = c[k]
            if t and t.SetSnapToPixelGrid then
                t:SetSnapToPixelGrid(false)
                t:SetTexelSnappingBias(0)
            end
        end
        -- the corners hold the box's own points; the edges and the background hang off them
        local sc = c.GetEffectiveScale and c:GetEffectiveScale()
        if not (sc and sc > 0 and PixelUtil and PixelUtil.GetPixelToUIUnitFactor) then return end
        local d = PixelUtil.GetPixelToUIUnitFactor() / sc / 8
        for n = 5, 8 do
            local t = c[EDGES[n]]
            if t and t.GetNumPoints and t:GetNumPoints() == 1 then
                local p, rel, rp, x, y = t:GetPoint(1)
                if rel == c then
                    t:ClearAllPoints()
                    t:SetPoint(p, c, rp, (x or 0) - d, (y or 0) + d)
                end
            end
        end
    end)
end
if _G.VoidPresence then return end

local P = { lines = {}, listeners = {} }   -- lines: addon -> { label, count, capped, known }
_G.VoidPresence = P

-- fn() runs when the box is turned on (from any addon), so every addon counts now.
function P:Listen(fn) table.insert(self.listeners, fn) end

local A = { 0, 0.78, 1 }   -- Void cyan
local box

local function db()
    VoidPresenceDB = VoidPresenceDB or {}
    return VoidPresenceDB
end

-- WoW Forever can't count by zone (its channels carry no addon messages), so there the
-- box counts each addon's players online and says so in its title.
local function FOREVER() return RegionalUniqueNamesEnabled ~= nil and RegionalUniqueNamesEnabled() == true end
local function TITLE() return FOREVER() and "Players online" or "Players here" end

-- Every addon that carries this file saves VoidPresenceDB, and each one's copy
-- is restored as it loads, so the last to load would win even if it was
-- disabled last session and holds old settings. Each change is stamped, and as
-- each addon loads the newest copy is kept.
local HOSTS = { VoidGather = true, VoidSweep = true, VoidQuest = true, VoidLayer = true }   -- addons that carry this file
local newest
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
    if not HOSTS[name] then return end
    local cur = _G.VoidPresenceDB
    if type(cur) == "table" and (not newest or (cur.stamp or 0) > (newest.stamp or 0)) then newest = cur end
    _G.VoidPresenceDB = newest
end)

local function changed() db().stamp = time() end

-- count = other players heard in your zone; capped = answers stopped at the
-- cap (busy zone, show "10+"); known = false when it can't count (sharing
-- off, inside an instance); note = a short word shown instead of the count
-- ("blocked": the server won't let you into that addon's channel).
function P:Set(addon, label, count, capped, known, note)
    self.lines[addon] = { label = label, count = count or 0, capped = capped, known = known ~= false, note = note }
    self:Update()
end

function P:IsShown() return db().shown == true end

function P:SetShown(on)
    db().shown = on and true or false
    changed()
    self:Update()
    if on then
        for _, fn in ipairs(self.listeners) do pcall(fn) end
    end
end

local function build()
    local f = CreateFrame("Button", "VoidPresenceBox", UIParent, "BackdropTemplate")
    f:SetSize(150, 40)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = VoidPX() })
    f:SetBackdropColor(0.05, 0.05, 0.08, 0.8)
    f:SetBackdropBorderColor(A[1], A[2], A[3], 0.45)
    local p = db().pos
    if p then f:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else f:SetPoint("TOP", UIParent, "TOP", 0, -205) end
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:RegisterForClicks("RightButtonUp")
    -- the tooltip goes away while dragging (the user, 2026-11-12: "the tooltip completely covers the
    -- box so its hard to see where i am dragging it")
    f:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self.moving = true
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self.moving = nil
        self:StopMovingOrSizing()
        if self.SetUserPlaced then self:SetUserPlaced(false) end
        local pt, _, rel, x, y = self:GetPoint()
        db().pos = { pt, rel, x, y }
        changed()
    end)
    f:SetScript("OnClick", function(self)
        if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
        MenuUtil.CreateContextMenu(self, function(_, root)
            root:CreateTitle(TITLE())
            root:CreateButton("Hide the box", function() P:SetShown(false) end)
        end)
    end)
    f:SetScript("OnEnter", function(self)
        if self.moving then return end
        -- on the side with room: near the bottom of the screen a tooltip below is pushed up over the box
        local _, cy = self:GetCenter()
        local low = cy and UIParent:GetHeight() and cy < UIParent:GetHeight() / 2
        GameTooltip:SetOwner(self, low and "ANCHOR_TOP" or "ANCHOR_BOTTOM")
        GameTooltip:AddLine(TITLE())
        if FOREVER() then
            GameTooltip:AddLine("Other players online running each Void addon, counted from its sharing channel. Updates every 10 minutes. (WoW Forever can't count by zone.)", 0.8, 0.8, 0.8, true)
            GameTooltip:AddLine("Not counted with sharing off.", 0.6, 0.6, 0.6, true)
            GameTooltip:AddLine("\"blocked\": the game won't let you into that addon's sharing channel (its owner banned you, or it has another password). Its /net command says more.", 0.6, 0.6, 0.6, true)
        else
            GameTooltip:AddLine("Other players in your zone running each Void addon, counted over its sharing channel. Updates when people come and go, and every 10 minutes.", 0.8, 0.8, 0.8, true)
            GameTooltip:AddLine("Busy zones show 10+. Not counted in instances or with sharing off.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:AddLine("Drag to move · right-click for options", 0.4, 0.8, 1)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.title:SetPoint("TOPLEFT", 8, -5)
    f.title:SetTextColor(A[1], A[2], A[3])
    f.title:SetText(TITLE())
    f.rows = {}
    f:Hide()
    return f
end

function P:Update()
    if not self:IsShown() or not next(self.lines) then
        if box then box:Hide() end
        return
    end
    box = box or build()
    local names = {}
    for addon in pairs(self.lines) do names[#names + 1] = addon end
    table.sort(names)
    local width = box.title:GetStringWidth() + 16
    for i, addon in ipairs(names) do
        local l = self.lines[addon]
        local row = box.rows[i]
        if not row then
            row = { left = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
                    right = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") }
            box.rows[i] = row
        end
        row.left:SetPoint("TOPLEFT", 8, -6 - i * 13)
        row.right:SetPoint("TOPRIGHT", -8, -6 - i * 13)
        row.left:SetText(l.label)
        if l.note then
            row.right:SetText("|cffff7755" .. l.note .. "|r")
        elseif not l.known then
            row.right:SetText("|cff8c8c9e—|r")
        elseif l.capped and l.count == 0 then
            -- busy zone, and everyone we'd counted has left: others are still there
            row.right:SetText("|cff55ff55some|r")
        elseif l.count == 0 then
            row.right:SetText("|cff8c8c9e0|r")
        else
            row.right:SetText(("|cff55ff55%d%s|r"):format(l.count, l.capped and "+" or ""))
        end
        row.left:Show(); row.right:Show()
        width = math.max(width, row.left:GetStringWidth() + row.right:GetStringWidth() + 28)
    end
    for i = #names + 1, #box.rows do box.rows[i].left:Hide(); box.rows[i].right:Hide() end
    box:SetSize(math.max(130, width), 12 + (#names + 1) * 13)
    box:Show()
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function() P:Update() end)
