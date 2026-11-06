----------------------------------------------------------------------
-- VoidQuest — highlight the quest givers you actually need
-- Blizzard's outline mode / map "!" show EVERY quest giver. This marks only the
-- ones in VoidQuest's scope -- the density tier (Min = campaign, Mid = + important,
-- Max = all, per-line picks win) plus whatever chain the guide is following -- with
-- a light-blue halo:
--   * world map: a soft light-blue disc UNDER Blizzard's "!" (click-through), so the
--     givers that matter glow and Blizzard's pin keeps its tooltip/click;
--   * minimap: light-blue halo + "!" placed by hand (the minimap isn't a MapCanvas),
--     same math as VoidGather/VoidSweep.
-- Data is live: C_QuestLine.GetAvailableQuestLines(map) -> questID, x, y, flags.
-- Toggle: Settings -> "Highlight needed quest givers" (giverPins).
----------------------------------------------------------------------
local VQ = VoidQuest
local PIN_TEMPLATE = "VoidQuestGiverPinTemplate"
-- light blue (#88ccff, the panel's "Zone" label): gold collided with VoidSweep's yellow
-- treasure dots, and the darker blues / teals are VoidGather's and VoidSweep's (2026-10-26)
local HALO = { 0.53, 0.80, 1.00 }
local function safe(fn, ...) if not fn then return nil end local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end end

VQ.Givers = {}
local G = VQ.Givers

-- Needed givers on a map: { {questID, name, x, y}, ... }. Cached per map; any quest /
-- density / guide change invalidates.
local cache = {}
function G:Invalidate() cache = {} end

function G:For(mapID)
    if not mapID then return {} end
    if cache[mapID] then return cache[mapID] end
    local out = {}
    local Guide = VQ.Guide
    local chain = Guide and Guide.ChainSet and Guide:ChainSet() or {}
    for _, q in ipairs(safe(C_QuestLine.GetAvailableQuestLines, mapID) or {}) do
        -- hidden (low level) givers count when they're on the chain you follow: the War
        -- Within intro is hidden for anyone past 70
        -- only offers Blizzard draws on this map: the neighbors' ones came back too and
        -- left halos with no "!" on them (2026-10-26)
        local onMap = not (Guide and Guide.OfferOnMap) or Guide:OfferOnMap(q, mapID)
        -- the offer list is cached by the game and can still hold quests you've finished or
        -- already picked up: those left dots with no "!" on them (2026-10-26)
        local stale = safe(C_QuestLog.IsQuestFlaggedCompleted, q.questID) or safe(C_QuestLog.GetLogIndexForQuestID, q.questID)
        if onMap and not stale and q.x and q.y and q.x > 0 and q.y > 0 and (not q.isHidden or chain[q.questID]) and not q.inProgress then
            local wanted = chain[q.questID] or (Guide and Guide.InScope and Guide:InScope(q))
            if wanted then
                out[#out + 1] = { questID = q.questID, name = q.questName, x = q.x, y = q.y }
            end
        end
    end
    cache[mapID] = out
    return out
end

----------------------------------------------------------------------
-- World map: halo pins via a MapCanvas data provider
----------------------------------------------------------------------
VoidQuestGiverPinMixin = CreateFromMixins(MapCanvasPinMixin)

function VoidQuestGiverPinMixin:OnLoad()
    -- small: a 26px disc growing to 1.3x covered the map (the player, 2026-10-26)
    self:SetScalingLimits(1, 0.75, 1.0)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_DIG_SITE")   -- below Blizzard's quest pins
    self.halo:SetTexture("Interface\\Buttons\\WHITE8X8")
    self.halo:SetVertexColor(HALO[1], HALO[2], HALO[3], 0.45)
    local mask = self:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(self.halo)
    self.halo:AddMaskTexture(mask)
end

function VoidQuestGiverPinMixin:OnAcquired(x, y)
    self:SetPosition(x, y)
    self:Show()
end

VoidQuestGiverProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function VoidQuestGiverProviderMixin:RemoveAllData()
    if self:GetMap() then self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE) end
end

function VoidQuestGiverProviderMixin:RefreshAllData()
    self:RemoveAllData()   -- always: never leave the previous map's halos behind
    if InCombatLockdown() then return end   -- acquiring pins touches protected setters; redrawn after combat
    if VQ:Get("giverPins") == false then return end
    local map = self:GetMap()
    local mapID = map and map:GetMapID()
    for _, g in ipairs(G:For(mapID)) do map:AcquirePin(PIN_TEMPLATE, g.x, g.y) end
end

----------------------------------------------------------------------
-- Minimap: placed by hand every frame (it scrolls/rotates per frame)
----------------------------------------------------------------------
local pool, nActive = {}, 0

local function acquire()
    nActive = nActive + 1
    local p = pool[nActive]
    if not p then
        p = CreateFrame("Frame", nil, Minimap)
        p:SetFrameLevel(Minimap:GetFrameLevel() + 5)
        p:SetSize(12, 12)
        p.halo = p:CreateTexture(nil, "BACKGROUND")
        p.halo:SetAtlas("WhiteCircle-RaidBlips")
        p.halo:SetVertexColor(HALO[1], HALO[2], HALO[3], 0.55)
        p.halo:SetPoint("CENTER"); p.halo:SetSize(15, 15)
        p.icon = p:CreateTexture(nil, "ARTWORK")
        p.icon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
        p.icon:SetAllPoints()
        p:EnableMouse(true)
        p:SetScript("OnEnter", function(self)
            if not self.name then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(self.name, 1, 0.82, 0)
            GameTooltip:AddLine("VoidQuest: in your quest scope", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end)
        p:SetScript("OnLeave", function() GameTooltip:Hide() end)
        pool[nActive] = p
    end
    p:Show()
    return p
end

local function hideRest()
    for i = nActive + 1, #pool do pool[i]:Hide(); pool[i].name = nil end
end

function G:UpdateMinimap()
    nActive = 0
    if VQ:Get("giverPins") == false then hideRest(); return end
    local mapID = C_Map.GetBestMapForUnit("player")
    local ppos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    local w, h
    if mapID then w, h = C_Map.GetMapWorldSize(mapID) end
    if not (ppos and w and h and w > 0 and h > 0) then hideRest(); return end
    local px, py = ppos:GetXY()
    local radius = (C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()) or 133
    if radius <= 0 then radius = 133 end
    local half = Minimap:GetWidth() / 2
    local scale = half / radius
    local rotate = GetCVar("rotateMinimap") == "1"
        and not (C_Minimap and C_Minimap.IsRotateMinimapIgnored and C_Minimap.IsRotateMinimapIgnored())
    local facing = rotate and (GetPlayerFacing() or 0) or 0
    local sinF, cosF = math.sin(facing), math.cos(facing)
    for _, g in ipairs(self:For(mapID)) do
        local sx = (g.x - px) * w * scale
        local sy = -((g.y - py) * h) * scale
        if rotate then sx, sy = sx * cosF + sy * sinF, -sx * sinF + sy * cosF end
        local d2 = sx * sx + sy * sy
        if d2 <= (half - 6) * (half - 6) then
            local p = acquire()
            p.name = g.name
            p:SetAlpha(d2 > (half * 0.75) ^ 2 and 0.6 or 1)
            p:ClearAllPoints()
            p:SetPoint("CENTER", Minimap, "CENTER", sx, sy)
        end
    end
    hideRest()
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
function G:Refresh()
    self:Invalidate()
    if self.provider and WorldMapFrame:IsShown() then self.provider:RefreshAllData() end
end

local asked = {}   -- quest-line data loads async: ask at most every 30s per map
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "QUEST_ACCEPTED",
    "QUEST_TURNED_IN", "QUEST_REMOVED", "QUESTLINE_UPDATE", "PLAYER_LEVEL_UP" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, e, arg)
    if e == "PLAYER_LOGIN" then
        if WorldMapFrame and not G.provider then
            G.provider = CreateFromMixins(VoidQuestGiverProviderMixin)
            WorldMapFrame:AddDataProvider(G.provider)
        end
        local f = CreateFrame("Frame", nil, Minimap)   -- parented: idle while the minimap is hidden
        f:SetScript("OnUpdate", function() G:UpdateMinimap() end)
    end
    -- QUESTLINE_UPDATE(requestRequired = true): the data needs asking for again
    -- turn-ins / pickups change what's offered (the next quest in a storyline appears)
    if e == "ZONE_CHANGED_NEW_AREA" or e == "PLAYER_LOGIN" or e == "QUEST_TURNED_IN" or e == "QUEST_ACCEPTED"
       or (e == "QUESTLINE_UPDATE" and arg) then
        local m = safe(C_Map.GetBestMapForUnit, "player")
        local wait = (e == "ZONE_CHANGED_NEW_AREA" or e == "PLAYER_LOGIN") and 30 or 5   -- re-ask soon, never in a loop
        if m and (not asked[m] or GetTime() - asked[m] > wait) then
            asked[m] = GetTime()
            safe(C_QuestLine.RequestQuestLinesForMap, m)
        end
    end
    G:Refresh()
end)
