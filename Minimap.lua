----------------------------------------------------------------------
-- VoidQuest Minimap icon (matches Void* convention)
-- 28x28, border 54x54 at TOPLEFT -2, 2, radius (minimap/2)+6
----------------------------------------------------------------------
local VQ = VoidQuest
local mod = VQ:NewModule("Minimap")
VQ.Minimap = mod

local btn

function mod:SetShown(show)
    if btn then btn:SetShown(show and true or false) end
end

local function PositionButton(self)
    local cfg = VoidQuestDB.config
    local angle = math.rad(cfg.minimapAngle or 220)
    local radius = (Minimap:GetWidth() / 2) + 6
    self:ClearAllPoints()
    self:SetPoint("CENTER", Minimap, "CENTER",
        radius * math.cos(angle),
        radius * math.sin(angle))
end

function mod:Init()
    if btn or not Minimap then return end

    btn = CreateFrame("Button", "VoidQuestMinimapBtn", Minimap)
    btn:SetSize(28, 28)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 10)

    -- Icon
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\Achievement_BG_winSOA")  -- trophy/quest icon
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn._icon = icon

    -- Border
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    btn._border = border

    -- Click handler
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if VQ.Settings and VQ.Settings.Toggle then VQ.Settings:Toggle() end   -- right-click = settings
        else
            if VQ.Guide and VQ.Guide.ToggleShown then VQ.Guide:ToggleShown() end  -- left-click = guide
        end
    end)

    -- Tooltip
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("|cff00c7ffVoidQuest|r")
        GameTooltip:AddLine("Dynamic campaign guide", 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-click: toggle guide", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click: settings", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Drag: reposition", 0.55, 0.55, 0.6)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Drag
    btn:SetMovable(true)
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self) self._dragging = true end)
    btn:SetScript("OnDragStop",  function(self) self._dragging = false end)
    btn:SetScript("OnUpdate", function(self)
        if self._dragging then
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local px, py = GetCursorPosition()
            px = px / scale; py = py / scale
            VoidQuestDB.config.minimapAngle = math.deg(math.atan2(py - my, px - mx))
            PositionButton(self)
        end
    end)

    PositionButton(btn)
    btn:SetShown(VQ:Get("minimapShow"))
end
