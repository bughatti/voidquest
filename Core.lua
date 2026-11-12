-- VoidSpy hook: enable with /vspy enable VoidQuest  (no-op if VoidSpy missing/disabled)
-- Borders are one screen pixel (tools/cmd/pixelfix, 2026-11-09). WoW snaps each border
-- piece to the pixel grid, and a thin line on a fractional position can snap to 0 px: a side
-- of a box vanishes. VoidPX() asks for one real pixel, and the hook below (installed once, by
-- the first Void addon loaded) turns snapping off on the edges of flat WHITE8X8 borders, like
-- Blizzard's NineSliceUtil.DisableSharpening, so a 1 px line always covers a pixel.
local _, ns = ...   -- ns.Move (VoidMove.lua)
local function VoidPX()
    local s = UIParent and UIParent:GetEffectiveScale()
    if s and s > 0 and PixelUtil and PixelUtil.GetPixelToUIUnitFactor then return PixelUtil.GetPixelToUIUnitFactor() / s end
    return 1
end
if not _G.__VoidBorderHook and hooksecurefunc and NineSliceUtil and NineSliceUtil.ApplyLayout then
    _G.__VoidBorderHook = true
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
    end)
end
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidQuest", fmt, ...) end end

----------------------------------------------------------------------
-- VoidQuest — Core module
-- Achievement/journey/weekly progress tracker for Midnight 12.0.5
----------------------------------------------------------------------

VoidQuest = {}
local VQ = VoidQuest

-- Palette (matches VoidUI cyan accent)
VQ.palette = {
    accent     = { 0.00, 0.78, 1.00 },
    accentDim  = { 0.00, 0.78, 1.00, 0.3 },
    green      = { 0.10, 0.80, 0.35 },
    yellow     = { 1.00, 0.82, 0.00 },
    red        = { 0.85, 0.20, 0.20 },
    text       = { 0.92, 0.92, 0.95 },
    textDim    = { 0.55, 0.55, 0.62 },
    bg         = { 0.06, 0.06, 0.10, 0.95 },
    bgRow      = { 1, 1, 1, 0.04 },
    bgRowAlt   = { 1, 1, 1, 0.02 },
}

VQ.font = "Fonts\\FRIZQT__.TTF"
VQ.texture = "Interface\\Buttons\\WHITE8X8"

----------------------------------------------------------------------
-- Module registry
----------------------------------------------------------------------
VQ.modules = {}

function VQ:NewModule(name)
    local mod = { name = name }
    self.modules[name] = mod
    return mod
end

function VQ:GetModule(name)
    return self.modules[name]
end

----------------------------------------------------------------------
-- Utility helpers
----------------------------------------------------------------------
function VQ:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00c7ff[VoidQuest]|r " .. tostring(msg))
end

function VQ:CreateBackdrop(frame, alpha)
    if not frame then return end
    alpha = alpha or 0.95
    frame:SetBackdrop({
        bgFile   = VQ.texture,
        edgeFile = VQ.texture,
        edgeSize = VoidPX(),
    })
    frame:SetBackdropColor(self.palette.bg[1], self.palette.bg[2], self.palette.bg[3], alpha)
    frame:SetBackdropBorderColor(self.palette.accent[1], self.palette.accent[2], self.palette.accent[3], 0.5)
end

function VQ:SetFont(fontString, size, flags)
    fontString:SetFont(VQ.font, size or 11, flags or "")
end

function VQ:FormatPercent(current, total)
    if not total or total == 0 then return "0%" end
    return string.format("%.0f%%", (current / total) * 100)
end

-- Serialize a table to readable indented text (for pasting diagnostics into chat/me).
function VQ:Dump(t, indent, seen)
    if type(t) ~= "table" then return tostring(t) end
    indent = indent or ""
    seen = seen or {}
    if seen[t] then return indent .. "<cycle>" end
    seen[t] = true
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) == "table" then
            out[#out + 1] = indent .. "[" .. tostring(k) .. "] ="
            out[#out + 1] = VQ:Dump(v, indent .. "  ", seen)
        else
            out[#out + 1] = indent .. "[" .. tostring(k) .. "] = " .. tostring(v)
        end
    end
    return table.concat(out, "\n")
end

-- Copyable popup for diagnostics/debug -- so output goes to a paste-able box, NOT chat.
-- Strips color codes so the pasted text is clean.
function VQ:ShowCopy(title, text)
    text = tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local f = VQ._copyFrame
    if not f then
        f = CreateFrame("Frame", "VoidQuestCopyFrame", UIParent, "BackdropTemplate")
        f:SetSize(600, 440); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG"); f:SetToplevel(true)
        f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
        ns.Move(f, { db = function() return VoidQuestDB end, key = "copy" })   -- drag + kept after a restart (VoidMove.lua)
        VQ:CreateBackdrop(f, 0.97)
        f.titleFS = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(f.titleFS, 13, "OUTLINE")
        f.titleFS:SetPoint("TOP", 0, -10)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)
        local sf = CreateFrame("ScrollFrame", "VoidQuestCopyScroll", f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 12, -32); sf:SetPoint("BOTTOMRIGHT", -32, 42)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true); eb:SetFontObject(ChatFontNormal); eb:SetWidth(540); eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        sf:SetScrollChild(eb); f.eb = eb
        local hint = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(hint, 10)
        hint:SetPoint("BOTTOMRIGHT", -14, 16); hint:SetText("Ctrl+A, Ctrl+C to copy")
        local sel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        sel:SetSize(90, 22); sel:SetPoint("BOTTOMLEFT", 12, 12); sel:SetText("Select All")
        sel:SetScript("OnClick", function() eb:SetFocus(); eb:HighlightText() end)
        VQ._copyFrame = f
    end
    f.titleFS:SetText("|cff00c7ff" .. tostring(title or "VoidQuest") .. "|r")
    f.eb:SetText(text)
    f:Show(); f.eb:SetFocus(); f.eb:HighlightText()
end

----------------------------------------------------------------------
-- Slash command
----------------------------------------------------------------------
SLASH_VOIDQUEST1 = "/vq"
SLASH_VOIDQUEST2 = "/voidquest"
SlashCmdList["VOIDQUEST"] = function(msg)
    dbg("slash: %s", tostring(msg))
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "reload" then
        ReloadUI()
    elseif msg == "reset" then
        if VQ.Guide and VQ.Guide.ResetPos then VQ.Guide:ResetPos() end
    elseif msg == "guide" then
        if VQ.Guide and VQ.Guide.Guide then VQ.Guide:Guide() end
    elseif msg == "auto" then
        VQ:Set("auto", not VQ:Get("auto"))  -- master hands-free toggle
        VQ:Print("Auto turn-in/accept: " .. (VQ:Get("auto") and "|cff55ff55ON|r" or "|cffff5555OFF|r"))
    elseif msg == "config" or msg == "settings" or msg == "options" then
        if VQ.Settings and VQ.Settings.Toggle then VQ.Settings:Toggle() end
    elseif msg == "density" then
        if VQ.Guide and VQ.Guide.CycleDensity then VQ.Guide:CycleDensity() end
    elseif msg == "lines" or msg == "pick" or msg == "focus" then
        if VQ.Guide and VQ.Guide.TogglePicker then VQ.Guide:TogglePicker() end
    elseif msg == "campaign" or msg == "campaigns" or msg == "select" then
        if VQ.Guide and VQ.Guide.ToggleCampaignSelect then VQ.Guide:ToggleCampaignSelect() end
    elseif msg == "quests" or msg == "myquests" or msg == "log" then
        if VQ.Guide and VQ.Guide.ToggleQuestLog then VQ.Guide:ToggleQuestLog() end
    elseif msg == "book" then
        if VQ.Book then VQ.Book:Toggle() else VQ:Print("the Quest Book is for WoW Forever.") end
    elseif msg == "fz" or (VQ.ForeverQuests and (msg == "zone" or msg == "zones")) then
        if VQ.Forever then VQ.Forever:Toggle() end   -- WoW Forever: every quest in the zone
    elseif msg == "zones" or msg == "zone" or msg == "leveling" then
        if VQ.Zones then VQ.Zones:ToggleWindow() end
    elseif VQ.Share and msg == "share" then   -- WoW Forever: quest-giver sharing on/off
        VQ:Set("share", not VQ:Get("share"))
        VQ:Print("Sharing quest givers with other players: " .. (VQ:Get("share") and "|cff55ff55ON|r" or "|cffff5555OFF|r"))
        if VQ.Settings and VQ.Settings.Sync then VQ.Settings:Sync() end
    elseif VQ.Route and msg == "route" then   -- WoW Forever: the best order for your quests
        VQ.Route:Toggle()
    elseif VQ.GroupUp and msg == "group test" then   -- the whole flow with yourself as the other player
        VQ.GroupUp:SelfTest()
    elseif VQ.GroupUp and msg == "group" then   -- WoW Forever: group up on the tracked quest
        VQ.GroupUp:AskTracked()
    elseif VQ.Share and msg == "net" then
        VQ.Share:SelfTest()
    elseif msg == "rewards" and _G.VoidQuestRewardAdvice then   -- marks on quest reward choices
        VoidQuestRewardAdvice.Toggle()
    elseif msg == "items" and VoidQuest.QuestItemDebug then   -- what the quest item buttons see
        VoidQuest.QuestItemDebug()
    elseif msg == "leftovers" and VoidQuest.LeftoversList then   -- quest items nothing needs anymore
        VoidQuest.LeftoversList()
    elseif msg == "dots" and VoidQuest.Mobs then   -- minimap dots for the tracked quest's mobs on / off
        VoidQuest.Mobs:Toggle()
    elseif msg == "drops" and VoidQuest.Drops then   -- where your quests' items have come from
        VoidQuest.Drops:List()
    elseif msg == "chains" and VoidQuest.Chains then   -- grey quests: keep or low value
        VoidQuest.Chains:List()
    elseif msg == "box" and _G.VoidPresence then   -- the "Players online" box (shared with VoidGather / VoidSweep)
        VoidPresence:SetShown(not VoidPresence:IsShown())
    elseif msg == "arrow" then
        if VQ.Guide and VQ.Guide.SetArrow then VQ.Guide:SetArrow(not VQ.Guide:ArrowOn()) end
    elseif msg == "xp" then
        if VQ.Guide and VQ.Guide.XPProbe then VQ.Guide:XPProbe() end
    elseif msg == "zoneprobe" then
        if VQ.Zones then VQ.Zones:Probe() end
    elseif msg == "dumpcampaigns" then
        if VQ.Guide and VQ.Guide.DumpCampaigns then VQ.Guide:DumpCampaigns() end
    elseif msg == "chain" then
        if VQ.Guide and VQ.Guide.DumpChain then VQ.Guide:DumpChain() end
    elseif msg == "stage" then
        if VQ.Coach and VQ.Coach.Diagnose then VQ.Coach:Diagnose() end
    elseif msg == "probe" then
        -- Dynamic-campaign PROBE: dump the LIVE campaign/questline structure (raw API
        -- returns, so we don't guess field names) to build a real guide against current
        -- content (e.g. Glint of History) that static guides can't cover.
        local function pget(fn, ...)
            if not fn then return nil end
            local ok, a, b, c = pcall(fn, ...)
            if ok then return a, b, c end
            return nil
        end
        local P = { at = date("%Y-%m-%d %H:%M:%S"), map = pget(C_Map.GetBestMapForUnit, "player"), log = {}, campaigns = {} }
        local seen = {}
        for i = 1, (pget(C_QuestLog.GetNumQuestLogEntries) or 0) do
            local info = pget(C_QuestLog.GetInfo, i)
            if info and not info.isHeader and info.questID then
                local qid = info.questID
                local campID = pget(C_CampaignInfo.GetCampaignID, qid)
                local mapID, x, y = pget(C_QuestLog.GetNextWaypoint, qid)
                table.insert(P.log, {
                    qid = qid, title = info.title, campaignID = campID,
                    complete = pget(C_QuestLog.IsComplete, qid) and true or false,
                    wpText = pget(C_QuestLog.GetNextWaypointText, qid), wpMap = mapID, wpX = x, wpY = y,
                })
                if campID and campID ~= 0 then seen[campID] = true end
            end
        end
        for campID in pairs(seen) do
            local camp = {
                id = campID, info = pget(C_CampaignInfo.GetCampaignInfo, campID),
                state = pget(C_CampaignInfo.GetState, campID),
                currentChapter = pget(C_CampaignInfo.GetCurrentChapterID, campID),
                chapterIDs = pget(C_CampaignInfo.GetChapterIDs, campID), chapters = {},
            }
            for _, chID in ipairs(camp.chapterIDs or {}) do
                local ch = pget(C_CampaignInfo.GetCampaignChapterInfo, chID)
                local entry = { id = chID, info = ch, quests = {} }
                local qlID = ch and ch.questLineID
                if qlID then
                    for _, qid in ipairs(pget(C_QuestLine.GetQuestLineQuests, qlID) or {}) do
                        table.insert(entry.quests, {
                            qid = qid, title = pget(C_QuestLog.GetTitleForQuestID, qid),
                            done = pget(C_QuestLog.IsQuestFlaggedCompleted, qid) and true or false,
                        })
                    end
                end
                table.insert(camp.chapters, entry)
            end
            table.insert(P.campaigns, camp)
        end
        -- Quest CHAIN: the chapter API has no questLineID, so pull the quest line from the
        -- active campaign quest instead -- this gives the ordered chain (incl. FUTURE quests
        -- not yet in the log), which is exactly what a step-by-step guide needs.
        P.questlines = {}
        for _, lq in ipairs(P.log) do
            if lq.campaignID and lq.campaignID ~= 0 then
                local qlInfo = pget(C_QuestLine.GetQuestLineInfo, lq.qid, P.map)
                local entry = { fromQuest = lq.qid, fromTitle = lq.title, info = qlInfo, quests = {} }
                local qlID = qlInfo and qlInfo.questLineID
                if qlID then
                    for _, qid in ipairs(pget(C_QuestLine.GetQuestLineQuests, qlID) or {}) do
                        entry.quests[#entry.quests + 1] = {
                            qid = qid, title = pget(C_QuestLog.GetTitleForQuestID, qid),
                            done = pget(C_QuestLog.IsQuestFlaggedCompleted, qid) and true or false,
                            inLog = pget(C_QuestLog.GetLogIndexForQuestID, qid) ~= nil,
                        }
                    end
                end
                P.questlines[#P.questlines + 1] = entry
            end
        end
        -- CROSS-CHAPTER diag: for the cached campaign, dump chapter progression + the quest
        -- lines available on the CURRENT map, so we can see how the next chapter is reachable.
        local cc = VoidQuestCharDB and VoidQuestCharDB.chainCache
        if cc and cc.campID then
            local X = { campID = cc.campID, currentChapter = pget(C_CampaignInfo.GetCurrentChapterID, cc.campID), chapters = {}, availableQuestLines = {} }
            for _, chID in ipairs(pget(C_CampaignInfo.GetChapterIDs, cc.campID) or {}) do
                local ci = pget(C_CampaignInfo.GetCampaignChapterInfo, chID)
                X.chapters[#X.chapters + 1] = { id = chID, name = ci and ci.name }
            end
            if P.map then
                pget(C_QuestLine.RequestQuestLinesForMap, P.map)
                for _, q in ipairs(pget(C_QuestLine.GetAvailableQuestLines, P.map) or {}) do
                    X.availableQuestLines[#X.availableQuestLines + 1] = {
                        questLineID = q.questLineID, name = q.questLineName, questID = q.questID,
                        x = q.x, y = q.y, campID = q.questID and pget(C_CampaignInfo.GetCampaignID, q.questID),
                    }
                end
            end
            P.crosschapter = X
        end
        VoidQuestDB.probe = P
        VQ:ShowCopy("VoidQuest — Probe (copy & paste this to me)", VQ:Dump(P))
    elseif VQ.Guide and VQ.Guide.ToggleShown then
        VQ.Guide:ToggleShown()   -- bare /vq toggles the dynamic campaign guide (legacy panel retired)
    end
end

----------------------------------------------------------------------
-- Initialization
----------------------------------------------------------------------
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function()
    VoidQuestDB = VoidQuestDB or {}
    VoidQuestCharDB = VoidQuestCharDB or {}
    VoidQuestDB.chainCache = nil   -- migrated to per-character VoidQuestCharDB (was bleeding across alts)

    -- Init defaults
    VoidQuestDB.config = VoidQuestDB.config or {
        minimapAngle = 220,
    }

    -- Init each module
    for name, mod in pairs(VQ.modules) do
        if mod.Init then mod:Init() end
    end
    -- Enable each module
    for name, mod in pairs(VQ.modules) do
        if mod.Enable then mod:Enable() end
    end

    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local ver = getMeta and getMeta("VoidQuest", "Version")
    VQ:Print("Loaded v" .. (ver or "?") .. " — /vq to open")
end)
