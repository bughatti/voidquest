----------------------------------------------------------------------
-- VoidQuest — WoW Forever: every quest in a zone, and where the known ones start
--
-- Data: ForeverQuests.lua (generated from Blizzard's Game Data API, namespace
-- static-forever-us: all ~6,850 real Forever quests with zone, faction, class, race,
-- XP, money and rewards). The API has NO locations, and Forever's map shows no "!" for
-- quests that aren't in your log (GetAvailableQuestLines is empty for its Classic
-- zones, checked 2026-11-05). So a quest's spot comes from VoidQuest's own learning
-- (QuestStarts.lua: where you accepted it, or where you saw it offered) and the
-- bundled ForeverSeed.lua (the same, from the author's characters). Quests without a
-- known spot are still listed, so you can see what a zone has left.
--
-- Window: the guide panel's "Zone" button (Forever only) or `/vq fz`.
-- World map: a "!" for every quest you can still do whose start is known.
-- Loaded everywhere; does nothing outside Forever (VoidQuest.ForeverQuests is nil).
----------------------------------------------------------------------
local _, ns = ...
local VQ = VoidQuest
local F = {}
VQ.Forever = F

local ZONE_MAP = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
local DUNGEON_MAP = (Enum and Enum.UIMapType and Enum.UIMapType.Dungeon) or 4
local PIN_TEMPLATE = "VoidQuestForeverPinTemplate"
local FLAG_TEXT = { d = "daily", w = "weekly", r = "repeatable", D = "dungeon", R = "raid", E = "elite", P = "PvP" }

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end end
local function Secret(v) return issecretvalue and issecretvalue(v) end

function F:Active() return VQ.ForeverQuests ~= nil end

----------------------------------------------------------------------
-- Data
----------------------------------------------------------------------
-- One quest as a table. Raw rows are positional (see ForeverQuests.lua's header).
function F:Info(id)
    local r = VQ.ForeverQuests and VQ.ForeverQuests[id]
    if not r then return nil end
    local names = VQ.ForeverNames or {}
    return {
        id = id, title = r[1], zone = names[r[2]], faction = r[3], xp = r[4], money = r[5],
        flags = r[6], classes = r[7], races = r[8], group = names[r[9]], rewards = r[10],
        rewardIDs = r[11],
    }
end

local me   -- player faction letter, class token, race name
local function Me()
    if me then return me end
    local fac = UnitFactionGroup("player")
    local _, cls = UnitClass("player")
    local race = UnitRace("player")
    me = { fac = (fac == "Alliance" and "A") or (fac == "Horde" and "H") or "", cls = cls or "", race = race or "" }
    return me
end

-- Plain-text list contains (comma separated, no patterns).
local function inList(list, v)
    if list == "" then return true end
    for item in list:gmatch("[^,]+") do if item == v then return true end end
    return false
end

-- Can this character ever do it? (faction, class, race; level is not in the data)
function F:Eligible(r)
    local m = Me()
    if r[3] ~= "" and m.fac ~= "" and r[3] ~= m.fac then return false end
    if not inList(r[7], m.cls) then return false end
    if not inList(r[8], m.race) then return false end
    return true
end

-- done / log / open
function F:Status(id)
    if safe(C_QuestLog.IsQuestFlaggedCompleted, id) then return "done" end
    if safe(C_QuestLog.GetLogIndexForQuestID, id) then return "log" end
    return "open"
end

-- Quest level: loads async (RequestLoadQuestByID -> QUEST_DATA_LOAD_RESULT). 0 = unknown.
local levels, asked = {}, {}
function F:Level(id)
    if levels[id] then return levels[id] end
    local lv = safe(C_QuestLog.GetQuestDifficultyLevel, id)
    if lv and not Secret(lv) and lv > 0 then levels[id] = lv; return lv end
    if not asked[id] and C_QuestLog.RequestLoadQuestByID then
        asked[id] = true
        safe(C_QuestLog.RequestLoadQuestByID, id)
    end
    return 0
end

-- Can you take it NOW? The game has no API for a quest's required level, so it's learned:
--   blocked: the last time you talked to its giver it wasn't offered to you (too low a
--            level, or an earlier quest first). Per character; back to "maybe" when you
--            level past it, and checked again the next time you talk to them.
--   red:     its level is 5+ above yours (the game colours it red: too hard anyway).
-- Returns available, reason ("" when available).
local RED = 5
function F:Available(id)
    local lvl = UnitLevel("player") or 0
    local b = VoidQuestCharDB and VoidQuestCharDB.blocked and VoidQuestCharDB.blocked[id]
    if b and lvl <= b then return false, "Not offered to you yet (level or an earlier quest first)" end
    local ql = self:Level(id)
    if ql > 0 and ql >= lvl + RED then return false, ("Level %d: too high for you yet"):format(ql) end
    return true, ""
end

-- Where it starts: learned (this install) or seeded. { m, x, y, how } or nil.
function F:Spot(id)
    local s = VQ.Starts and VQ.Starts:Get(id)
    if s and s.m and s.x and s.y and s.m > 0 and s.x > 0 and s.y > 0 then return s end
end

-- byZone[name] = { ids } (built once)
local byZone
local function Index()
    if byZone then return byZone end
    byZone = {}
    local names = VQ.ForeverNames or {}
    for id, r in pairs(VQ.ForeverQuests or {}) do
        local z = names[r[2]] or names[r[9]] or "Other"
        local t = byZone[z]
        if not t then t = {}; byZone[z] = t end
        t[#t + 1] = id
    end
    return byZone
end

-- The zone the player is in, as the API names it: walk up from micro maps / floors to
-- the Zone (or the Dungeon, inside one).
function F:PlayerZone()
    local m = safe(C_Map.GetBestMapForUnit, "player")
    for _ = 1, 6 do
        local mi = m and safe(C_Map.GetMapInfo, m)
        if not mi then return nil end
        if mi.mapType == ZONE_MAP or mi.mapType == DUNGEON_MAP then return mi.name, m end
        if not mi.parentMapID or mi.parentMapID == 0 then return mi.name, m end
        m = mi.parentMapID
    end
end

-- In the Min / Mid / Max tier (Chains.lua grades; Max = everything).
function F:InScope(id)
    local C = VQ.Chains
    return not C or C:InScope(id)
end

-- Eligible quests of a zone, sorted: in log, open (known spot, then level), open but not
-- for you yet ("later"), then done. e.scope: open and in the Min / Mid / Max tier (what
-- the guide picks and the map pins); e.important: starred in the zone window.
local ORDER = { log = 1, open = 2, later = 3, done = 4 }
function F:ZoneList(zone)
    local out = {}
    local C = VQ.Chains
    for _, id in ipairs(Index()[zone] or {}) do
        local r = VQ.ForeverQuests[id]
        if self:Eligible(r) then
            local st = self:Status(id)
            if st == "open" and not self:Available(id) then st = "later" end
            local live = st == "open" or st == "log"
            out[#out + 1] = { id = id, title = r[1], flags = r[6], status = st,
                spot = self:Spot(id), level = self:Level(id),
                scope = st == "open" and self:InScope(id),
                important = live and C and C:Important(id) or false }
        end
    end
    table.sort(out, function(a, b)
        if a.status ~= b.status then return ORDER[a.status] < ORDER[b.status] end
        if (a.spot ~= nil) ~= (b.spot ~= nil) then return a.spot ~= nil end
        if a.level ~= b.level then
            if a.level == 0 or b.level == 0 then return a.level > b.level end
            return a.level < b.level
        end
        return a.title < b.title
    end)
    return out
end

-- Zones with at least one quest this character can do, with done / total.
function F:Zones()
    local out = {}
    for z, ids in pairs(Index()) do
        local total, done = 0, 0
        for _, id in ipairs(ids) do
            if self:Eligible(VQ.ForeverQuests[id]) then
                total = total + 1
                if safe(C_QuestLog.IsQuestFlaggedCompleted, id) then done = done + 1 end
            end
        end
        if total > 0 then out[#out + 1] = { zone = z, total = total, done = done } end
    end
    table.sort(out, function(a, b) return a.zone < b.zone end)
    return out
end

----------------------------------------------------------------------
-- Pin / track one quest
----------------------------------------------------------------------
function F:Go(id)
    local info = self:Info(id)
    if not info then return end
    if self:Status(id) == "log" then
        safe(C_SuperTrack.SetSuperTrackedQuestID, id)
        VQ:Print(("tracking %s (it's in your log)."):format(info.title))
        return
    end
    local s = self:Spot(id)
    if not s then
        VQ:Print(("%s: no known start yet. VoidQuest learns it when any of your characters sees it offered or picks it up."):format(info.title))
        return
    end
    local giver = VQ.Starts and VQ.Starts:Giver(id)
    local ok, why = ns.Route:Go({ map = s.m, x = s.x, y = s.y, name = giver or info.title },
        { say = function(msg) VQ:Print(msg) end })
    if not ok then VQ:Print(("%s: %s"):format(info.title, why or "can't pin there")) end
end

local function Tooltip(owner, id, anchor)
    local info = F:Info(id)
    if not info then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:AddLine(info.title, 1, 0.82, 0)
    local lv = F:Level(id)
    local bits = {}
    if lv > 0 then bits[#bits + 1] = "level " .. lv end
    for c in (info.flags or ""):gmatch(".") do if FLAG_TEXT[c] then bits[#bits + 1] = FLAG_TEXT[c] end end
    if info.group and info.group ~= info.zone then bits[#bits + 1] = info.group end
    if #bits > 0 then GameTooltip:AddLine(table.concat(bits, ", "), 0.7, 0.7, 0.7) end
    if info.zone then GameTooltip:AddLine(info.zone, 0.53, 0.8, 1) end
    local st = F:Status(id)
    GameTooltip:AddLine(st == "done" and "Done" or st == "log" and "In your quest log" or "Not done", 1, 1, 1)
    if st == "open" then
        local ok, why = F:Available(id)
        if not ok then GameTooltip:AddLine(why, 1, 0.5, 0.3, true) end
        local seen = VoidQuestDB and VoidQuestDB.offerLevel and VoidQuestDB.offerLevel[id]
        local sd = VQ.ForeverSeed and VQ.ForeverSeed[id]
        if sd and sd.lv and (not seen or sd.lv < seen) then seen = sd.lv end
        if seen then GameTooltip:AddLine(("Offered to a level %d character"):format(seen), 0.7, 0.7, 0.7) end
    end
    if info.xp and info.xp > 0 then GameTooltip:AddLine(("%d XP"):format(info.xp), 1, 1, 1) end
    if info.money and info.money > 0 then
        -- the global GetCoinTextureString doesn't exist on WoW Forever (C_CurrencyInfo has it)
        local coin = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or _G.GetCoinTextureString
        GameTooltip:AddLine(coin and coin(info.money) or GetMoneyString(info.money), 1, 1, 1)
    end
    if info.rewards and info.rewards ~= "" then GameTooltip:AddLine(info.rewards, 0.8, 0.8, 0.8, true) end
    local giver = VQ.Starts and VQ.Starts:Giver(id)
    if giver then GameTooltip:AddLine("Given by " .. giver, 0.6, 1, 0.6) end
    GameTooltip:AddLine(" ")
    if st == "log" then
        GameTooltip:AddLine("Click: track it", 0.6, 0.6, 0.6)
    elseif F:Spot(id) then
        GameTooltip:AddLine("Click: pin where it starts", 0.6, 0.6, 0.6)
    else
        GameTooltip:AddLine("Start not known yet (learned when you see it offered or pick it up)", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local ROW_H, ROWS = 16, 22
local win

local function Build()
    local f = CreateFrame("Frame", "VoidQuestForeverZone", UIParent, "BackdropTemplate")
    f:Hide()
    f:SetSize(380, 74 + ROW_H * ROWS)
    f:SetPoint("CENTER", 260, 40)
    f:SetFrameStrata("HIGH"); f:SetToplevel(true)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    VQ:CreateBackdrop(f)
    tinsert(UISpecialFrames, "VoidQuestForeverZone")   -- Esc closes it

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 10, -9); f.title:SetPoint("RIGHT", -30, 0); f.title:SetJustifyH("LEFT")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)

    f.zoneBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.zoneBtn:SetSize(90, 20); f.zoneBtn:SetPoint("TOPLEFT", 8, -28); f.zoneBtn:SetText("Zone...")
    f.zoneBtn:SetScript("OnClick", function(b) F:ZoneMenu(b) end)
    f.hereBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.hereBtn:SetSize(70, 20); f.hereBtn:SetPoint("LEFT", f.zoneBtn, "RIGHT", 4, 0); f.hereBtn:SetText("Here")
    f.hereBtn:SetScript("OnClick", function() F.zone = nil; F:Render() end)

    f.hideDone = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.hideDone:SetSize(22, 22); f.hideDone:SetPoint("LEFT", f.hereBtn, "RIGHT", 8, 0)
    f.hideDone.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.hideDone.label:SetPoint("LEFT", f.hideDone, "RIGHT", 0, 1); f.hideDone.label:SetText("Hide done & later")
    f.hideDone:SetScript("OnClick", function(b) VQ:Set("foreverHideDone", b:GetChecked() and true or false); F:Render() end)

    f.scroll = CreateFrame("ScrollFrame", nil, f, "FauxScrollFrameTemplate")
    f.scroll:SetPoint("TOPLEFT", 8, -54); f.scroll:SetPoint("BOTTOMRIGHT", -28, 10)
    f.scroll:SetScript("OnVerticalScroll", function(s, off) FauxScrollFrame_OnVerticalScroll(s, off, ROW_H, function() F:Render() end) end)

    f.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, f)
        row:SetSize(340, ROW_H)
        row:SetPoint("TOPLEFT", 10, -54 - (i - 1) * ROW_H)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 2, 0); row.text:SetPoint("RIGHT", -60, 0); row.text:SetJustifyH("LEFT"); row.text:SetWordWrap(false)
        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.right:SetPoint("RIGHT", -2, 0); row.right:SetWidth(58); row.right:SetJustifyH("RIGHT")
        row:SetScript("OnClick", function(s) if s.id then F:Go(s.id) end end)
        row:SetScript("OnEnter", function(s) if s.id then Tooltip(s, s.id) end end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.rows[i] = row
    end
    f:SetScript("OnShow", function() F:Render() end)
    return f
end

function F:Render()
    if not (win and win:IsShown()) then return end
    local zone = self.zone or self:PlayerZone() or "?"
    local all = self:ZoneList(zone)
    local hide = VQ:Get("foreverHideDone") == true
    win.hideDone:SetChecked(hide)
    local list, done, known = {}, 0, 0
    for _, e in ipairs(all) do
        if e.status == "done" then done = done + 1 end
        if e.spot and e.status == "open" then known = known + 1 end
        if not (hide and (e.status == "done" or e.status == "later")) then list[#list + 1] = e end
    end
    win.title:SetText(("%s  |cffaaaaaa%d / %d done, %d starts known|r"):format(zone, done, #all, known))
    FauxScrollFrame_Update(win.scroll, #list, ROWS, ROW_H)
    local off = FauxScrollFrame_GetOffset(win.scroll)
    for i, row in ipairs(win.rows) do
        local e = list[off + i]
        row.id = e and e.id
        if e then
            local lv = e.level > 0 and ("[" .. e.level .. "] ") or ""
            local tag = ""
            for c in e.flags:gmatch("[dwDRP]") do tag = tag .. " |cff88ccff(" .. FLAG_TEXT[c] .. ")|r" end
            local color = (e.status == "done" or e.status == "later") and "|cff777777"
                or e.status == "log" and "|cffffd200" or "|cffffffff"
            local star = e.important and VQ.Chains.STAR or ""
            row.text:SetText(star .. color .. lv .. e.title .. "|r" .. tag)
            row.right:SetText(e.status == "done" and "done" or e.status == "log" and "in log"
                or e.status == "later" and "later" or e.spot and "|cff88ccffpin|r" or "")
            row:Show()
        else
            row:Hide()
        end
    end
end

function F:ZoneMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        if root.SetScrollMode then root:SetScrollMode(400) end
        for _, z in ipairs(F:Zones()) do
            root:CreateButton(("%s  |cffaaaaaa%d/%d|r"):format(z.zone, z.done, z.total), function()
                F.zone = z.zone; F:Render()
            end)
        end
    end)
end

function F:Toggle()
    if not self:Active() then VQ:Print("the zone quest list is for WoW Forever."); return end
    win = win or Build()
    win:SetShown(not win:IsShown())
end

----------------------------------------------------------------------
-- World map pins: open, eligible quests whose start is known, on the shown map
----------------------------------------------------------------------
VoidQuestForeverPinMixin = CreateFromMixins(MapCanvasPinMixin)

function VoidQuestForeverPinMixin:OnLoad()
    self:SetScalingLimits(1, 0.8, 1.1)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_QUEST_OFFER")
end

function VoidQuestForeverPinMixin:OnAcquired(id, x, y)
    self.id = id
    self:SetPosition(x, y)
    self:Show()
end

function VoidQuestForeverPinMixin:OnMouseEnter() if self.id then Tooltip(self, self.id) end end
function VoidQuestForeverPinMixin:OnMouseLeave() GameTooltip:Hide() end
function VoidQuestForeverPinMixin:OnClick(button) if button == "LeftButton" and self.id then F:Go(self.id) end end

VoidQuestForeverProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function VoidQuestForeverProviderMixin:RemoveAllData()
    if self:GetMap() then self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE) end
end

function VoidQuestForeverProviderMixin:RefreshAllData()
    self:RemoveAllData()
    if InCombatLockdown() or VQ:Get("foreverPins") == false then return end
    local map = self:GetMap()
    local mapID = map and map:GetMapID()
    if not mapID then return end
    -- starts are saved on the zone map you stood on; this map or its child zones
    local function onThis(m)
        if m == mapID then return true end
        local mi = safe(C_Map.GetMapInfo, m)
        return mi and mi.parentMapID == mapID and mi.mapType ~= ZONE_MAP and true or false
    end
    for id, r in pairs(VQ.ForeverQuests or {}) do
        local s = F:Spot(id)
        if s and onThis(s.m) and F:Eligible(r) and F:Status(id) == "open" and F:Available(id)
           and F:InScope(id) then   -- Min / Mid / Max
            local x, y = s.x, s.y
            if s.m ~= mapID then
                local cont, wp = safe(C_Map.GetWorldPosFromMapPos, s.m, CreateVector2D(x, y))
                local p
                if cont and wp then p = select(2, safe(C_Map.GetMapPosFromWorldPos, cont, wp, mapID)) end
                if p then x, y = p:GetXY() else x = nil end
            end
            if x then map:AcquirePin(PIN_TEMPLATE, id, x, y) end
        end
    end
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "QUEST_ACCEPTED",
    "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_DATA_LOAD_RESULT" }) do
    pcall(ev.RegisterEvent, ev, e)
end
-- Redraw the window and map pins, once per burst (many QUEST_DATA_LOAD_RESULTs arrive
-- together for levels). Also called by QuestStarts when it learns new starts.
local pending
function F:Refresh()
    if pending or not self:Active() then return end
    pending = true
    C_Timer.After(0.3, function()
        pending = nil
        F:Render()
        if F.provider and WorldMapFrame:IsShown() then F.provider:RefreshAllData() end
    end)
end

ev:SetScript("OnEvent", function(_, e)
    if not F:Active() then ev:UnregisterAllEvents(); return end
    if e == "PLAYER_LOGIN" then
        if WorldMapFrame and not F.provider then
            F.provider = CreateFromMixins(VoidQuestForeverProviderMixin)
            WorldMapFrame:AddDataProvider(F.provider)
        end
        return
    end
    F:Refresh()
end)
