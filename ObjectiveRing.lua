----------------------------------------------------------------------
-- VoidQuest — objective ring on the world map
-- A soft translucent disc + center dot marking WHERE the current guide step
-- happens: the quest giver for a pickup, the objective area / turn-in for a
-- quest in your log. Drawn under Blizzard's own quest pins and click-through,
-- so it highlights the spot without getting in the way.
-- Toggle: Settings -> "Objective ring on the world map" (showRing).
----------------------------------------------------------------------
local VQ = VoidQuest
local PIN_TEMPLATE = "VoidQuestRingPinTemplate"
local RING = 44   -- px on the map canvas
local function safe(fn, ...) if not fn then return nil end local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end end

VoidQuestRingPinMixin = CreateFromMixins(MapCanvasPinMixin)

function VoidQuestRingPinMixin:OnLoad()
    self:SetScalingLimits(1, 0.8, 1.4)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_DIG_SITE")   -- below quest/POI pins
    -- round disc: a flat texture through Blizzard's circular portrait mask
    self.disc:SetTexture("Interface\\Buttons\\WHITE8X8")
    self.disc:SetVertexColor(0.33, 1, 0.33, 0.22)
    local mask = self:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(self.disc)
    self.disc:AddMaskTexture(mask)
    self.dot:SetTexture("Interface\\Buttons\\WHITE8X8")
    self.dot:SetVertexColor(0.33, 1, 0.33, 0.9)
    local dmask = self:CreateMaskTexture()
    dmask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    dmask:SetAllPoints(self.dot)
    self.dot:AddMaskTexture(dmask)
end

function VoidQuestRingPinMixin:OnAcquired(x, y)
    self:SetSize(RING, RING)
    self:SetPosition(x, y)
    self:Show()
end

----------------------------------------------------------------------
-- Data provider: where is the current step on the map being VIEWED?
----------------------------------------------------------------------
VoidQuestRingProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function VoidQuestRingProviderMixin:RemoveAllData()
    if self:GetMap() then self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE) end
end

local function stepSpot(mapID)
    local G = VQ.Guide
    local t = G and G._ringTarget
    if not t or not t.qid then return nil end
    if t.status == "pickup" then
        if t.m == mapID and t.x and t.y then return t.x, t.y end
        return nil
    end
    -- in your log: the objective POI (or turn-in) on THIS map, as the game places it
    for _, q in ipairs(safe(C_QuestLog.GetQuestsOnMap, mapID) or {}) do
        if q.questID == t.qid and q.x and q.y then return q.x, q.y end
    end
    local x, y = safe(C_QuestLog.GetNextWaypointForMap, t.qid, mapID)
    if x and y and x > 0 and y > 0 then return x, y end
    return nil
end

function VoidQuestRingProviderMixin:RefreshAllData()
    if InCombatLockdown() then return end   -- acquiring pins touches protected setters
    self:RemoveAllData()
    if VQ:Get("showRing") == false then return end
    local map = self:GetMap()
    local mapID = map and map:GetMapID()
    if not mapID then return end
    local x, y = stepSpot(mapID)
    if x and y then map:AcquirePin(PIN_TEMPLATE, x, y) end
end

VQ.Ring = {}

function VQ.Ring:Init()
    if self.provider or not WorldMapFrame then return end
    self.provider = CreateFromMixins(VoidQuestRingProviderMixin)
    WorldMapFrame:AddDataProvider(self.provider)
end

-- Called by the guide whenever the step (or its location) changes.
function VQ.Ring:Set(step, m, x, y)
    local G = VQ.Guide
    if not G then return end
    if step then
        G._ringTarget = { qid = step.qid, status = step.status, m = m, x = x, y = y }
    else
        G._ringTarget = nil
    end
    if self.provider and WorldMapFrame:IsShown() then self.provider:RefreshAllData() end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, e)
    if e == "PLAYER_LOGIN" then VQ.Ring:Init() end
    if VQ.Ring.provider and WorldMapFrame:IsShown() then VQ.Ring.provider:RefreshAllData() end
end)
