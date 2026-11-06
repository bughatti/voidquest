----------------------------------------------------------------------
-- VoidQuest — quest item button
-- Quests that need you to USE an item ("Use the Totem on the corpse") show a
-- clickable item next to the quest in Blizzard's tracker. With that tracker
-- hidden, VoidQuest had no way to use it. This is the same button, next to
-- the guide panel: it shows the item for the guided step (or, in quest-list
-- mode, the super-tracked / first tracked quest that has one).
--
-- Using a quest item is a PROTECTED action: Blizzard's own tracker calls
-- UseQuestLogSpecialItem from secure code, which addons can't. So this is a
-- SecureActionButton (type=item) -- the standard addon pattern. Attributes,
-- Show/Hide and SetPoint are blocked in combat, so changes queue until combat
-- ends; the button you already have keeps working mid-fight.
----------------------------------------------------------------------
local VQ = VoidQuest
local function safe(fn, ...) if not fn then return nil end local ok, a, b, c, d = pcall(fn, ...) if ok then return a, b, c, d end end

local SIZE = 34

-- link, texture, charges for a quest's usable item (nil if it has none / it's done
-- and the item isn't meant to stay up after completion).
local function questItem(qid)
    local idx = qid and safe(C_QuestLog.GetLogIndexForQuestID, qid)
    if not idx then return nil end
    local link, tex, charges, showWhenComplete = safe(GetQuestLogSpecialItemInfo, idx)
    if not link then return nil end
    if safe(C_QuestLog.IsComplete, qid) and not showWhenComplete then return nil end
    return link, tex, charges, idx
end

local btn = CreateFrame("Button", "VoidQuestItemButton", UIParent, "SecureActionButtonTemplate")
btn:SetSize(SIZE, SIZE)
btn:RegisterForClicks("AnyUp", "AnyDown")
-- act on release even with "cast on key down" on -- an Up-only secure button otherwise
-- does nothing (see wow-secure-button-keydown-cvar)
btn:SetAttribute("useOnKeyDown", false)
btn:SetAttribute("type", "item")
btn:Hide()

btn.icon = btn:CreateTexture(nil, "ARTWORK"); btn.icon:SetAllPoints()
btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
btn.border = btn:CreateTexture(nil, "BACKGROUND")
btn.border:SetPoint("TOPLEFT", -2, 2); btn.border:SetPoint("BOTTOMRIGHT", 2, -2)
btn.border:SetColorTexture(0.0, 0.78, 1.0, 0.8)
btn.count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
btn.count:SetPoint("BOTTOMRIGHT", -1, 2)
btn.cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate"); btn.cd:SetAllPoints()
btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

btn:SetScript("OnEnter", function(self)
    if not self.qid then return end
    local idx = safe(C_QuestLog.GetLogIndexForQuestID, self.qid)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    if idx and GameTooltip.SetQuestLogSpecialItem then
        GameTooltip:SetQuestLogSpecialItem(idx)
    elseif self.link then
        GameTooltip:SetHyperlink(self.link)
    end
    GameTooltip:AddLine("Quest: " .. (safe(C_QuestLog.GetTitleForQuestID, self.qid) or "?"), 0.6, 0.8, 1)
    GameTooltip:Show()
end)
btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function updateCooldown()
    if not (btn:IsShown() and btn.qid) then return end
    local idx = safe(C_QuestLog.GetLogIndexForQuestID, btn.qid)
    local start, duration, enable = safe(GetQuestLogSpecialItemCooldown, idx)
    if start and duration and duration > 0 then
        btn.cd:SetCooldown(start, duration)
        btn.icon:SetDesaturated(enable == 0)
    else
        btn.cd:Clear()
        btn.icon:SetDesaturated(false)
    end
end

-- Which quest's item to offer right now.
local function pickQuest()
    local G = VQ.Guide
    if G and G._stepQid and questItem(G._stepQid) then return G._stepQid end
    local st = safe(C_SuperTrack.GetSuperTrackedQuestID)
    if st and st ~= 0 and questItem(st) then return st end
    if G and G.CurrentQuests then
        for _, q in ipairs((G:CurrentQuests()) or {}) do
            if questItem(q) then return q end
        end
    end
end

local pending = false
local function update()
    if InCombatLockdown() then pending = true; return end
    pending = false
    local panel = _G.VoidQuestGuidePanel
    local qid = (panel and panel:IsShown()) and pickQuest() or nil
    local link, tex, charges = questItem(qid)
    if not link then
        btn.qid, btn.link = nil, nil
        btn:SetAttribute("item", nil)
        btn:Hide()
        return
    end
    btn.qid, btn.link = qid, link
    btn:SetAttribute("item", link)
    btn.icon:SetTexture(tex)
    btn.count:SetText((charges and charges > 1) and charges or "")
    btn:ClearAllPoints()
    btn:SetPoint("TOPRIGHT", panel, "TOPLEFT", -4, -4)
    btn:Show()
    updateCooldown()
end

VQ.QuestItem = { Update = update }

-- follow the guide panel's own refreshes, plus anything that changes quest items
if VQ.Guide and VQ.Guide.Refresh then hooksecurefunc(VQ.Guide, "Refresh", update) end
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_REGEN_ENABLED", "QUEST_LOG_UPDATE", "SUPER_TRACKING_CHANGED",
                     "BAG_UPDATE_DELAYED", "BAG_UPDATE_COOLDOWN", "PLAYER_ENTERING_WORLD" }) do
    ev:RegisterEvent(e)
end
ev:SetScript("OnEvent", function(_, e)
    if e == "BAG_UPDATE_COOLDOWN" then updateCooldown(); return end
    if e == "PLAYER_REGEN_ENABLED" and not pending then return end
    update()
end)
