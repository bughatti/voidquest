-- VoidQuest reward advice: when a quest offers a choice of rewards, mark which one is an
-- upgrade for you (green arrow on its icon) and which is worth the most gold (gold coin);
-- the reason is in the reward's tooltip. Marks only: you still pick, and
-- hands-free turn-in keeps pausing on choices.
--
-- Gold = what you'd get for it. Most quest rewards are soulbound, so that's the vendor
-- price (from the reward's own link). A reward that isn't bound can also be worth its AH
-- price after the AH's cut (VoidAH's scan data, when VoidAH is installed); the better one
-- counts and the badge says "(AH)".
-- Upgrade = better than what you wear in that slot: VoidGear's stat score for your class
-- and spec when VoidGear is installed ("Upgrade"); otherwise a higher item level ("Higher
-- item level"). Items the game marks unusable for you (red) are never an upgrade.
--
-- Only at a quest giver (QuestFrame); the quest log's reward list is left alone.
-- /vq rewards turns it on or off.

local function Enabled()
    return not (VoidQuestDB and VoidQuestDB.rewardAdvice == false)
end

local function Money(c)
    if VoidUI and VoidUI.FormatMoney then return VoidUI:FormatMoney(c) end
    return GetCoinTextureString and GetCoinTextureString(c) or tostring(c)
end

-- Equipment slots each kind of item can go in, for this character and client.
local rangedSlot
do
    local ok, id = pcall(GetInventorySlotInfo, "RANGEDSLOT")
    if ok and type(id) == "number" then rangedSlot = id end
end

local function SlotsFor(equipLoc)
    local dual = CanDualWield and CanDualWield()
    local map = {
        INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
        INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
        INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 },
        INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
        INVTYPE_WEAPON = dual and { 16, 17 } or { 16 },
        INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 },
        INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
        INVTYPE_RANGED = { rangedSlot or 16 }, INVTYPE_RANGEDRIGHT = { rangedSlot or 16 },
        INVTYPE_THROWN = { rangedSlot or 16 }, INVTYPE_RELIC = rangedSlot and { rangedSlot } or nil,
    }
    return map[equipLoc]
end

-- Score of an item for you, and how it was scored ("stats" or "ilvl").
local function Score(link)
    local VG = _G.VoidGear
    local Sc = VG and VG.Scorer
    if Sc and Sc.ScoreLink and Sc.GetActiveContext then
        local ok, w, primary = pcall(Sc.GetActiveContext, Sc)
        if ok and w then
            local ok2, s = pcall(Sc.ScoreLink, Sc, link, w, primary)
            if ok2 and type(s) == "number" and s > 0 then return s, "stats" end
        end
    end
    local ilvl = C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link)
    return ilvl or 0, "ilvl"
end

-- An equipped item's score on the same scale as the candidate's.
local function ScoreAs(link, how)
    if not link then return 0 end
    local s, h = Score(link)
    if h == how then return s end
    return (how == "ilvl") and (C_Item.GetDetailedItemLevelInfo(link) or 0) or 0
end

-- "stats" / "ilvl" when the item beats what it would replace, else nil.
local function UpgradeHow(link, usable)
    if not link or usable == false then return nil end
    local equipLoc = select(9, C_Item.GetItemInfo(link))
    local slots = equipLoc and SlotsFor(equipLoc)
    if not slots then return nil end
    local cand, how = Score(link)
    if not cand or cand <= 0 then return nil end
    local current
    local mh = GetInventoryItemLink("player", 16)
    local mhIs2H = mh and select(9, C_Item.GetItemInfo(mh)) == "INVTYPE_2HWEAPON"
    if mhIs2H and equipLoc ~= "INVTYPE_2HWEAPON" and (slots[1] == 16 or slots[1] == 17) and slots[#slots] ~= (rangedSlot or -1) then
        -- you wield a two-hander: a one-hander, shield or off-hand means giving it up,
        -- so it must beat the two-hander (an empty off hand is not a free slot)
        current = ScoreAs(mh, how)
    elseif equipLoc == "INVTYPE_2HWEAPON" then
        -- a two-hander replaces the main hand AND whatever is in the off hand: stat scores
        -- add up; item levels don't, so there it must beat the average of what you hold
        local mhLink, ohLink = GetInventoryItemLink("player", 16), GetInventoryItemLink("player", 17)
        local a, b = ScoreAs(mhLink, how), ScoreAs(ohLink, how)
        if how == "ilvl" then
            local n = (mhLink and 1 or 0) + (ohLink and 1 or 0)
            current = (n > 0) and ((a + b) / n) or 0
        else
            current = a + b
        end
    else
        for _, slot in ipairs(slots) do
            local s = ScoreAs(GetInventoryItemLink("player", slot), how)
            if not current or s < current then current = s end -- the weaker slot is the one it would replace
        end
    end
    if cand > (current or 0) + 0.01 then return how end
    return nil
end

-- Can this reward be listed on the AH once you have it? (most quest rewards bind on pickup)
local function CanAuction(i)
    if not (C_TooltipInfo and C_TooltipInfo.GetQuestItem) then return nil end
    local ok, data = pcall(C_TooltipInfo.GetQuestItem, "choice", i)
    if not ok or not data then return nil end
    if _G.VoidAH_Money and VoidAH_Money.IsBoundTooltip then
        return not VoidAH_Money.IsBoundTooltip(data.lines)
    end
    return nil
end

local function Value(i, link, count)
    local itemID = link and C_Item.GetItemInfoInstant(link)
    if not itemID then return 0, nil end
    local vendor = select(11, C_Item.GetItemInfo(link))
    vendor = (type(vendor) == "number" and vendor > 0) and vendor or 0
    local best, src = vendor, (vendor > 0) and "vendor" or nil
    if _G.VoidAH_Money and VoidAH_Money.Value then
        -- unknown binding counts as bound: most quest rewards bind on pickup
        local _, _, b, s = VoidAH_Money.Value(itemID, vendor, CanAuction(i) == true)
        if b then best, src = b, s end
    end
    return (best or 0) * math.max(1, count or 1), src
end

-- Markers sit on the item's icon (the name has no room: two lines fill the button):
-- a green arrow top-left for an upgrade, a gold coin top-right for the most gold.
-- The words go in the reward's tooltip.
local function Marks(button)
    if button.vqUp then return button.vqUp, button.vqGold end
    local icon = button.Icon or (button:GetName() and _G[button:GetName() .. "IconTexture"]) or button
    local up = button:CreateTexture(nil, "OVERLAY", nil, 7)
    up:SetSize(16, 16)
    up:SetPoint("TOPLEFT", icon, "TOPLEFT", -3, 3)
    if not pcall(up.SetAtlas, up, "bags-greenarrow") or not up:GetAtlas() then
        up:SetTexture("Interface\\PetBattles\\BattleBar-AbilityBadge-Strong")
    end
    local gold = button:CreateTexture(nil, "OVERLAY", nil, 7)
    gold:SetSize(14, 14)
    gold:SetPoint("TOPRIGHT", icon, "TOPRIGHT", 3, 3)
    gold:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
    up:Hide(); gold:Hide()   -- shown only for the reward they apply to
    button.vqUp, button.vqGold = up, gold
    return up, gold
end

local function ClearBadges(buttons)
    for _, b in ipairs(buttons or {}) do
        if b.vqUp then b.vqUp:Hide(); b.vqGold:Hide() end
        b.vqNote = nil
    end
end

local retryTimer, retries = nil, 0
local Annotate
Annotate = function(isRetry)
    if not isRetry then retries = 0 end
    local rf = QuestInfoFrame and QuestInfoFrame.rewardsFrame
    local buttons = rf and rf.RewardButtons
    if not buttons then return end
    ClearBadges(buttons)
    if not Enabled() or not (QuestFrame and QuestFrame:IsShown()) then return end
    if (GetNumQuestChoices and GetNumQuestChoices() or 0) < 2 then return end

    local rows, missing = {}, false
    for _, b in ipairs(buttons) do
        -- item choices only (currency choices have objectType "currency")
        if b:IsShown() and b.type == "choice" and (b.objectType == nil or b.objectType == "item") then
            local i = b:GetID()
            local link = GetQuestItemLink("choice", i)
            local _, _, count, _, usable = GetQuestItemInfo("choice", i)
            if link and C_Item.GetItemInfo(link) then
                local value, src = Value(i, link, count)
                rows[#rows + 1] = { button = b, value = value, src = src, up = UpgradeHow(link, usable) }
            else
                missing = true
            end
        end
    end
    -- Item data still loading: try again a few times, then leave it.
    if missing and not retryTimer and retries < 4 then
        retries = retries + 1
        retryTimer = C_Timer.NewTimer(0.5, function() retryTimer = nil; Annotate(true) end)
    end

    local richest
    for _, r in ipairs(rows) do
        if r.value > 0 and (not richest or r.value > richest.value) then richest = r end
    end
    for _, r in ipairs(rows) do
        local notes = {}
        local up, gold = Marks(r.button)
        if r.up then
            up:Show()
            notes[#notes + 1] = (r.up == "stats") and "|cff3ddc84VoidQuest: an upgrade over what you wear|r"
                or "|cff3ddc84VoidQuest: higher item level than what you wear|r"
        end
        if r == richest then
            gold:Show()
            notes[#notes + 1] = ("|cffffd100VoidQuest: worth the most gold, %s%s|r"):format(Money(r.value),
                r.src == "ah" and " on the AH after its cut" or " from a vendor")
        end
        r.button.vqNote = (#notes > 0) and table.concat(notes, "\n") or nil
    end
end

if QuestInfo_Display then
    hooksecurefunc("QuestInfo_Display", function() Annotate() end)
end

-- The explanation under the reward's tooltip. Added whenever the game (re)builds an item
-- tooltip owned by a marked reward button: a line added from the button's OnEnter is wiped
-- when item tooltips refresh (seen in game 2026-11-06).
if TooltipDataProcessor and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt)
        if tt ~= GameTooltip then return end
        local owner = tt:GetOwner()
        if owner and owner.vqNote then tt:AddLine(owner.vqNote, 1, 1, 1, true) end
    end)
end
local f = CreateFrame("Frame")
f:RegisterEvent("QUEST_COMPLETE")
f:RegisterEvent("QUEST_DETAIL")
f:RegisterEvent("QUEST_ITEM_UPDATE")   -- reward data arriving late (Blizzard redraws the rewards)
if QuestInfo_ShowRewards then hooksecurefunc("QuestInfo_ShowRewards", function() Annotate() end) end
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
f:SetScript("OnEvent", function() C_Timer.After(0, function() Annotate() end) end)

VoidQuestRewardAdvice = {
    Toggle = function()
        VoidQuestDB = VoidQuestDB or {}
        VoidQuestDB.rewardAdvice = not Enabled()
        print(("|cff00c7ffVoidQuest|r reward advice %s."):format(Enabled() and "on" or "off"))
        Annotate()
    end,
}
