----------------------------------------------------------------------
-- VoidQuest Settings  -- in-depth options (branded frame).
-- Opened via: minimap RIGHT-click, the guide panel's gear button, or /vq config.
--
-- All settings live as flat keys on the account-wide VoidQuestDB (preferences,
-- shared across chars). VQ:Get/Set apply defaults + push changes live so the
-- guide/minimap react immediately -- no /reload needed.
----------------------------------------------------------------------
local VQ = VoidQuest
local mod = VQ:NewModule("Settings")
VQ.Settings = mod

VQ.SettingsDefaults = {
    -- hands-free
    auto = true, autoAccept = true, autoTurnIn = true, autoReward = true, pauseOnChoice = true,
    autoAllQuests = false,   -- extend auto accept/turn-in beyond the campaign to EVERY quest
    -- guidance
    density = "min", foreverDensity = "max", zoneOrder = "nearest", setWaypoint = true, superTrack = true, showRing = true, giverPins = true,
    -- panel
    lockPanel = false, panelScale = 1.0, panelOpacity = 0.9, showObjective = true, showZoneSummary = true,
    panelHeight = 230,   -- fixed guide-panel height; quest lines fill the space the guide leaves
    panelWidth = 300,    -- guide-panel width (drag the corner grip)
    -- general
    minimapShow = true, announceActions = false, blizzTracker = true,
    share = true,   -- WoW Forever: share quest-giver spots with other VoidQuest players (ForeverShare.lua)
}

function VQ:Get(key)
    local v = VoidQuestDB and VoidQuestDB[key]
    if v == nil then return VQ.SettingsDefaults[key] end
    return v
end

function VQ:Set(key, val)
    VoidQuestDB = VoidQuestDB or {}
    VoidQuestDB[key] = val
    if VQ.Settings then VQ.Settings:Apply(key) end
end

-- Push a changed setting into the live UI/behaviour.
function mod:Apply(key)
    if key == "minimapShow" and VQ.Minimap and VQ.Minimap.SetShown then
        VQ.Minimap:SetShown(VQ:Get("minimapShow"))
    end
    if key == "share" and VQ.Share then VQ.Share:Apply() end
    -- WoW Forever's Min / Mid / Max: the map's "!" and the zone list follow it
    if key == "foreverDensity" and VQ.Forever and VQ.Forever.Refresh then VQ.Forever:Refresh() end
    if VQ.Givers then VQ.Givers:Refresh() end   -- density / giverPins change what's highlighted
    if key == "showRing" and VQ.Ring and VQ.Ring.provider and WorldMapFrame:IsShown() then
        VQ.Ring.provider:RefreshAllData()
    end
    if VQ.Guide then
        if VQ.Guide.ApplyPanelStyle then VQ.Guide:ApplyPanelStyle() end
        if VQ.Guide.Refresh then VQ.Guide:Refresh() end
    end
end

----------------------------------------------------------------------
-- widget builders (each registers a sync closure on f._sync so the panel
-- re-reads live values when it's opened -- settings can also change from
-- the guide panel's own Density button).
----------------------------------------------------------------------
local SLIDER_N = 0

local function tip(frame, title, body)
    if not body then return end
    frame:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title)
        GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function makeCheck(f, x, y, label, key, body)
    local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cb:SetSize(24, 24); cb:SetPoint("TOPLEFT", x, y)
    cb.text = cb:CreateFontString(nil, "OVERLAY"); VQ:SetFont(cb.text, 11)
    cb.text:SetPoint("LEFT", cb, "RIGHT", 2, 0); cb.text:SetText(label)
    cb:SetChecked(VQ:Get(key) and true or false)
    cb:SetScript("OnClick", function(s) VQ:Set(key, s:GetChecked() and true or false) end)
    tip(cb, label, body)
    f._sync[#f._sync + 1] = function() cb:SetChecked(VQ:Get(key) and true or false) end
    return cb
end

local function makeSlider(f, x, y, w, label, key, minv, maxv, step, plain)
    SLIDER_N = SLIDER_N + 1
    local name = "VoidQuestSetSlider" .. SLIDER_N
    local s = CreateFrame("Slider", name, f, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", x, y); s:SetWidth(w)
    s:SetMinMaxValues(minv, maxv); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
    local low, high, txt = _G[name .. "Low"], _G[name .. "High"], _G[name .. "Text"]
    if low then low:SetText("") end
    if high then high:SetText("") end
    local function label_of(v)
        if plain then return ("%s: |cff55ff55%.0f|r"):format(label, v) end   -- a size, not a percent
        return ("%s: |cff55ff55%.0f%%|r"):format(label, v * 100)
    end
    local function setLabel(v) if txt then txt:SetText(label_of(v)) end end
    s:SetValue(VQ:Get(key)); setLabel(VQ:Get(key))
    s:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v / step + 0.5) * step
        setLabel(v)
        VQ:Set(key, v)
    end)
    f._sync[#f._sync + 1] = function() s:SetValue(VQ:Get(key)); setLabel(VQ:Get(key)) end
    return s
end

-- A button's text must fit inside it: widen it to the text (+ padding), never below minW.
-- (Fixed widths let "My quests (all, not just campaign)..." spill out both sides, 2026-11-05.)
local function fitButton(b, minW)
    local fs = b:GetFontString()
    local tw = fs and fs:GetStringWidth() or 0
    b:SetWidth(math.max(minW or 0, math.ceil(tw) + 20))
    return b:GetWidth()
end
VQ.FitButton = fitButton

local function makeSegment(f, x, y, label, key, opts)
    local fs = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(fs, 11)
    fs:SetPoint("TOPLEFT", x, y - 2); fs:SetText(label)
    local btns, bx = {}, x + 96
    local function hl()
        for _, b in ipairs(btns) do
            if b.val == VQ:Get(key) then b:LockHighlight() else b:UnlockHighlight() end
        end
    end
    for _, o in ipairs(opts) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetHeight(20); b:SetPoint("TOPLEFT", bx, y)
        b:SetText(o.text); b.val = o.val
        bx = bx + fitButton(b, 52) + 3
        b:SetScript("OnClick", function() VQ:Set(key, o.val); hl() end)
        btns[#btns + 1] = b
    end
    hl()
    f._sync[#f._sync + 1] = hl
    return btns
end

local function header(f, x, y, text)
    local fs = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(fs, 12, "OUTLINE")
    fs:SetPoint("TOPLEFT", x, y); fs:SetText("|cff00c7ff" .. text .. "|r")
    local ln = f:CreateTexture(nil, "ARTWORK"); ln:SetColorTexture(0.3, 0.6, 0.9, 0.4)
    ln:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -2); ln:SetSize(330, 1)
end

----------------------------------------------------------------------
function mod:EnsurePanel()
    if self.frame then return self.frame end
    local f = CreateFrame("Frame", "VoidQuestSettings", UIParent, "BackdropTemplate")
    f._sync = {}
    f:SetSize(372, 820); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG"); f:SetToplevel(true)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    VQ:CreateBackdrop(f, 0.96)

    local title = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(title, 15, "OUTLINE")
    title:SetPoint("TOP", 0, -10); title:SetText("|cff00c7ffVoidQuest|r Settings")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)

    local x, y = 16, -42
    header(f, x, y, "Hands-free (auto)"); y = y - 24
    makeCheck(f, x, y, "Master hands-free", "auto", "Turn all auto actions on/off. When off, VoidQuest only guides -- you accept/turn in yourself."); y = y - 24
    makeCheck(f, x + 16, y, "Auto-accept quests", "autoAccept"); y = y - 24
    makeCheck(f, x + 16, y, "Auto turn-in quests", "autoTurnIn"); y = y - 24
    makeCheck(f, x + 16, y, "Auto-claim single rewards", "autoReward", "Automatically take the reward when there's only one. Choice rewards always pause below."); y = y - 24
    makeCheck(f, x + 16, y, "Pause on reward choice", "pauseOnChoice", "Stop so you pick which reward when a quest offers a choice of items."); y = y - 24
    makeCheck(f, x + 16, y, "Also handle non-campaign quests", "autoAllQuests", "Auto-accept and turn in EVERY quest you talk to an NPC about, not just your campaign. Reward choices still pause. Off by default -- it will also grab dailies and side quests."); y = y - 30

    header(f, x, y, "Guidance"); y = y - 24
    makeCheck(f, x, y, "Set map waypoint", "setWaypoint"); y = y - 24
    makeCheck(f, x, y, "Native objective ring (super-track)", "superTrack", "Use Blizzard's objective-area blob + tracking arrow for in-progress quests."); y = y - 24
    makeCheck(f, x, y, "Objective ring on the world map", "showRing", "Draw a green circle on the world map where the current step happens -- the quest giver, the objective area, or the turn-in."); y = y - 26
    makeCheck(f, x, y, "Highlight needed quest givers", "giverPins", "Light-blue halo on the world map (under Blizzard's !) and minimap for the quest givers in your scope: the Density tier plus the chain the guide follows. Turn Blizzard's Outline Mode off so only these stand out."); y = y - 24
    -- WoW Forever has its own tier (foreverDensity, Chains.lua C:InScope)
    makeSegment(f, x, y, "Density", VQ.ForeverQuests and "foreverDensity" or "density", { { val = "min", text = "Min" }, { val = "mid", text = "Mid" }, { val = "max", text = "Max" } }); y = y - 26
    makeSegment(f, x, y, "Zone order", "zoneOrder", { { val = "nearest", text = "Nearest" }, { val = "grouped", text = "Grouped" } }); y = y - 28
    local csb = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    csb:SetSize(220, 20); csb:SetPoint("TOPLEFT", x, y); csb:SetText("Select campaign to follow..."); fitButton(csb, 220)
    csb:SetScript("OnClick", function() if VQ.Guide and VQ.Guide.ToggleCampaignSelect then VQ.Guide:ToggleCampaignSelect() end end)
    y = y - 26
    local qlb = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    qlb:SetSize(220, 20); qlb:SetPoint("TOPLEFT", x, y); qlb:SetText("My quests (all, not just campaign)..."); fitButton(qlb, 220)
    qlb:SetScript("OnClick", function() if VQ.Guide and VQ.Guide.ToggleQuestLog then VQ.Guide:ToggleQuestLog() end end)
    y = y - 26
    local zgb = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    zgb:SetSize(220, 20); zgb:SetPoint("TOPLEFT", x, y); zgb:SetText("Zone guides (leveling)..."); fitButton(zgb, 220)
    zgb:SetScript("OnClick", function() if VQ.Zones then VQ.Zones:ToggleWindow() end end)
    y = y - 34

    header(f, x, y, "Guide panel"); y = y - 24
    makeCheck(f, x, y, "Show objective text", "showObjective"); y = y - 24
    makeCheck(f, x, y, "Show zone summary line", "showZoneSummary"); y = y - 24
    makeCheck(f, x, y, "Lock panel position", "lockPanel"); y = y - 42   -- room for the slider label above its bar
    makeSlider(f, x, y, 210, "Scale", "panelScale", 0.7, 1.6, 0.05); y = y - 42
    makeSlider(f, x, y, 210, "Opacity", "panelOpacity", 0.1, 1.0, 0.05); y = y - 42
    makeSlider(f, x, y, 210, "Height", "panelHeight", 120, 800, 10, true); y = y - 44

    header(f, x, y, "General"); y = y - 24
    makeCheck(f, x, y, "Show minimap button", "minimapShow"); y = y - 24
    makeCheck(f, x, y, "Announce auto-actions in chat", "announceActions", "Print a line each time VoidQuest auto-accepts or turns in a quest."); y = y - 24
    if VQ.Share then
        makeCheck(f, x, y, "Share quest givers with other players", "share", "WoW Forever has no quest markers on the map. When you find a quest giver, VoidQuest tells a few other VoidQuest players online where it is (by hidden addon whisper), and learns the ones they find. Sent: the quest, the NPC and its spot. Like any whisper, the players who get it can see which character sent it, so your finds go out only after you've left that map (or 10-20 minutes later), never live. A spot is used once two players agree on it."); y = y - 24
        f:SetHeight(850)
    end

    f:Hide()   -- created hidden so the FIRST click opens it (CreateFrame shows by default)
    self.frame = f
    return f
end

function mod:Sync()
    if self.frame then for _, fn in ipairs(self.frame._sync) do fn() end end
end

function mod:Toggle()
    local f = self:EnsurePanel()
    if f:IsShown() then f:Hide() else self:Sync(); f:Show() end
end
