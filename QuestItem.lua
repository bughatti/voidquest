----------------------------------------------------------------------
-- VoidQuest — quest item buttons
-- Quests that need you to USE an item ("Use the Totem on the corpse") show a
-- clickable item next to the quest in Blizzard's tracker. With that tracker
-- hidden, VoidQuest had no way to use them. These are the same buttons, stacked
-- down the side of the guide panel, one per quest item.
--
-- Two kinds of quest item:
--  * linked: the quest log knows the item (GetQuestLogSpecialItemInfo) -- retail's
--    usual case.
--  * in your bags only: Classic-era quests (WoW Forever) hand you an item and never
--    link it -- Deep Cover's Flare Gun (2026-11-06: the box never offered it). These
--    are bag items with a Use: effect whose name the quest's own text mentions.
--    Quest items (item class Quest) with a Use: effect that no quest names come last.
-- Order: the quest whose objective you're closest to on top (standing at a quest's
-- spot, its item is the one you need); quests the game gives no distance for after,
-- the guided step's and the arrow's first, then quest log order.
--
-- Using an item is a PROTECTED action: these are SecureActionButtons (type=item), the
-- standard addon pattern. Attributes, Show/Hide and SetPoint are blocked in combat, so
-- changes queue until combat ends; the buttons you already have keep working mid-fight.
----------------------------------------------------------------------
local VQ = VoidQuest
local function safe(fn, ...) if not fn then return nil end local ok, a, b, c, d = pcall(fn, ...) if ok then return a, b, c, d end end

local SIZE, GAP, MAX = 34, 4, 6
-- Items show only near their quest (the user, 2026-11-06: the Digging Claw sat there
-- for hours, 4500 yd from its quest and then a continent away).
local NEAR_YARDS = 1000
local NEAR_SQ = NEAR_YARDS * NEAR_YARDS
local QUEST_CLASS = (Enum.ItemClass and Enum.ItemClass.Questitem) or 12

-- link, texture, charges for a quest's linked item (nil if it has none / it's done
-- and the item isn't meant to stay up after completion).
local function questItem(qid)
    local idx = qid and safe(C_QuestLog.GetLogIndexForQuestID, qid)
    if not idx then return nil end
    local link, tex, charges, showWhenComplete = safe(GetQuestLogSpecialItemInfo, idx)
    if not link then return nil end
    if safe(C_QuestLog.IsComplete, qid) and not showWhenComplete then return nil end
    return link, tex, charges, idx
end

-- Usable items in your bags: { itemID = { link, tex, count, name, isQuest } }.
local function bagUsables()
    local out = {}
    local last = (NUM_BAG_SLOTS or 4) + ((Constants and Constants.InventoryConstants and Constants.InventoryConstants.NumReagentBagSlots) or 0)
    for bag = 0, last do
        for slot = 1, (safe(C_Container.GetContainerNumSlots, bag) or 0) do
            local info = safe(C_Container.GetContainerItemInfo, bag, slot)
            local id = info and info.itemID
            if id and not (issecretvalue and issecretvalue(id)) then
                local e = out[id]
                if e then
                    e.count = e.count + (info.stackCount or 1)
                elseif safe(C_Item.GetItemSpell, id) then
                    local name = safe(C_Item.GetItemInfo, id)
                    -- classID is GetItemInfoInstant's 6th return (safe() keeps only 4)
                    local ok, _, _, _, _, _, classID = pcall(C_Item.GetItemInfoInstant, id)
                    if not ok then classID = nil end
                    if name then
                        out[id] = { id = id, link = info.hyperlink, tex = info.iconFileID, count = info.stackCount or 1,
                                    name = name, isQuest = (classID == QUEST_CLASS) }
                    end
                end
            end
        end
    end
    return out
end

----------------------------------------------------------------------
-- Items a quest hands you when you accept it. An item that appears in your bags
-- (from none) within 3 s of QUEST_ACCEPTED belongs to that quest -- before or after
-- the event, the server sends them in either order. Saved account-wide in
-- VoidQuestDB.questItems[questID][itemID] = true, so every character knows it.
-- This beats reading the quest text (the user, 2026-11-06: "when i get the quest
-- and i am also given an item for that quest, why cant that be tracked").
-- Only learned when it can't be anything else (Codex review): exactly ONE quest
-- accepted around the item's arrival, and no quest turned in around it (a chain's
-- reward -- often a usable potion -- lands as you accept the next quest). Decided
-- once the window has passed on both sides.
----------------------------------------------------------------------
local LEARN_WINDOW = 3
local bagCounts            -- itemID -> count, as last seen
local arrivals = {}        -- { id, t }: items that appeared from none, still being decided
local accepts = {}         -- { qid, t }
local turnIns = {}         -- GetTime() of each turn-in

local function countBags()
    local c = {}
    local last = (NUM_BAG_SLOTS or 4) + ((Constants and Constants.InventoryConstants and Constants.InventoryConstants.NumReagentBagSlots) or 0)
    for bag = 0, last do
        for slot = 1, (safe(C_Container.GetContainerNumSlots, bag) or 0) do
            local info = safe(C_Container.GetContainerItemInfo, bag, slot)
            local id = info and info.itemID
            if id and not (issecretvalue and issecretvalue(id)) then c[id] = (c[id] or 0) + (info.stackCount or 1) end
        end
    end
    return c
end

local function learn(qid, id)
    if not (qid and id) then return end
    VoidQuestDB = VoidQuestDB or {}
    VoidQuestDB.questItems = VoidQuestDB.questItems or {}
    local t = VoidQuestDB.questItems[qid] or {}
    VoidQuestDB.questItems[qid] = t
    t[id] = true
end

local function learnedFor(qid)
    return VoidQuestDB and VoidQuestDB.questItems and VoidQuestDB.questItems[qid]
end

-- Decide every arrival whose window has closed on both sides.
local function settle()
    local now = GetTime()
    local i = 1
    while i <= #arrivals do
        local a = arrivals[i]
        if now - a.t > LEARN_WINDOW then
            local qid, n = nil, 0
            for _, acc in ipairs(accepts) do
                if math.abs(acc.t - a.t) <= LEARN_WINDOW and acc.qid ~= qid then qid, n = acc.qid, n + 1 end
            end
            local turnedIn = false
            for _, ti in ipairs(turnIns) do
                if math.abs(ti - a.t) <= LEARN_WINDOW then turnedIn = true end
            end
            if n == 1 and not turnedIn then learn(qid, a.id) end
            table.remove(arrivals, i)
        else
            i = i + 1
        end
    end
    local function prune(list, getT)
        for j = #list, 1, -1 do if now - getT(list[j]) > 3 * LEARN_WINDOW then table.remove(list, j) end end
    end
    prune(accepts, function(x) return x.t end)
    prune(turnIns, function(x) return x end)
end

local function settleLater() C_Timer.After(LEARN_WINDOW + 0.5, settle) end

local function onBagsChanged()
    local now, t = countBags(), GetTime()
    if bagCounts then
        for id, n in pairs(now) do
            if n > 0 and (bagCounts[id] or 0) == 0 then
                arrivals[#arrivals + 1] = { id = id, t = t }
                settleLater()
            end
        end
    end
    bagCounts = now
end

local function onQuestAccepted(qid)
    if type(qid) ~= "number" then return end
    accepts[#accepts + 1] = { qid = qid, t = GetTime() }
    settleLater()
end

local function onQuestTurnedIn()
    turnIns[#turnIns + 1] = GetTime()
end

-- A quest's own words (description, objectives text, objective lines), lowercased.
-- Kept per quest once the description has loaded (it never changes).
local textCache = {}
local function questText(qid, idx)
    if textCache[qid] then return textCache[qid] end
    local parts = {}
    local desc, objText = safe(GetQuestLogQuestText, idx)
    parts[#parts + 1] = desc; parts[#parts + 1] = objText
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do parts[#parts + 1] = o.text end
    local t = {}
    for _, p in ipairs(parts) do
        if type(p) == "string" and not (issecretvalue and issecretvalue(p)) then t[#t + 1] = p end
    end
    local text = table.concat(t, "\n"):lower()
    if type(desc) == "string" and desc ~= "" then textCache[qid] = text end
    return text
end

-- Every quest item to offer right now, in button order:
-- { qid (nil for an unmatched quest item), link, item (the button's item attribute), tex, count, d }
local function pickEntries(includeFar)
    local G = VQ.Guide
    local guided, arrow = G and G._stepQid, safe(C_SuperTrack.GetSuperTrackedQuestID)
    local bags = bagUsables()
    local list, used = {}, {}
    -- 1st pass: every log quest, where it is, whether you're near it
    local quests = {}
    local zone, header = GetRealZoneText and GetRealZoneText(), nil
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        if info and info.isHeader then header = info.title end
        local qid = info and not info.isHeader and info.questID
        if qid then
            local d, onContinent = safe(C_QuestLog.GetDistanceSqToQuest, qid)
            local far = (onContinent == false)
            if type(d) ~= "number" or d < 0 or far then d = nil end
            -- near: its objective within NEAR_YARDS when the game knows where it is, else
            -- you're in the zone the quest log files it under
            local near
            if d then near = d <= NEAR_SQ else near = not far and header ~= nil and header == zone end
            if near or includeFar then
                quests[#quests + 1] = { qid = qid, i = i, d = d, near = near,
                    rank = (qid == guided) and 0 or (qid == arrow) and 1 or 2 }
            end
        end
    end
    -- 2nd pass, near quests first and closest first, so a quest you're at claims a bag
    -- item before a far one that also names it (Codex review)
    table.sort(quests, function(a, b)
        if a.near ~= b.near then return a.near end
        if a.d and b.d and a.d ~= b.d then return a.d < b.d end
        if (a.d ~= nil) ~= (b.d ~= nil) then return a.d ~= nil end
        return a.i < b.i
    end)
    local function add(q, e)
        e.qid, e.d, e.i, e.rank, e.near = q.qid, q.d, q.i, q.rank, q.near
        list[#list + 1] = e
    end
    for _, q in ipairs(quests) do
        local qid = q.qid
        local link, tex, charges = questItem(qid)
        if link then
            add(q, { link = link, item = link, tex = tex, count = charges })
            local id = safe(C_Item.GetItemInfoInstant, link)
            if id then used[id] = true end
        elseif not safe(C_QuestLog.IsComplete, qid) then
            -- 1) every item this quest handed you when you accepted it
            local got = false
            for id in pairs(learnedFor(qid) or {}) do
                local b = bags[id]
                if b and not used[id] then
                    used[id] = true; got = true
                    add(q, { link = b.link, item = "item:" .. id, tex = b.tex, count = b.count, itemID = id, how = "given with the quest" })
                end
            end
            -- 2) else an item in your bags this quest's text names (longest name wins:
            -- "Mor'shan Flare Gun" over "Flare Gun" when both fit)
            if not got then
                local text, best = questText(qid, q.i), nil
                for id, b in pairs(bags) do
                    if not used[id] and #b.name >= 4 and text:find(b.name:lower(), 1, true)
                       and (not best or #b.name > #best.name) then best = b end
                end
                if best then
                    used[best.id] = true
                    add(q, { link = best.link, item = "item:" .. best.id, tex = best.tex, count = best.count, itemID = best.id, how = "named in the quest" })
                end
            end
        end
    end
    -- quest items with a Use: effect no quest claims: never shown (no way to tell when
    -- you're near), only listed by /vq items
    if includeFar then
        for id, b in pairs(bags) do
            if b.isQuest and not used[id] then
                list[#list + 1] = { link = b.link, item = "item:" .. id, tex = b.tex, count = b.count, itemID = id,
                                    rank = 3, i = 100000 + id, how = "quest item, no quest known" }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.d and b.d then
            if a.d ~= b.d then return a.d < b.d end
        elseif a.d or b.d then
            return a.d ~= nil
        end
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.i < b.i
    end)
    return list
end

local function OnEnter(self)
    if not self.link then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    local idx = self.qid and not self.itemID and safe(C_QuestLog.GetLogIndexForQuestID, self.qid)
    if idx and GameTooltip.SetQuestLogSpecialItem then
        GameTooltip:SetQuestLogSpecialItem(idx)
    else
        GameTooltip:SetHyperlink(self.link)
    end
    if self.qid then
        GameTooltip:AddLine("Quest: " .. (safe(C_QuestLog.GetTitleForQuestID, self.qid) or "?"), 0.6, 0.8, 1)
    else
        GameTooltip:AddLine("Quest item from your bags", 0.6, 0.8, 1)
    end
    GameTooltip:Show()
end

-- The first keeps its old name so a key bound to CLICK VoidQuestItemButton still works.
local buttons = {}
for i = 1, MAX do
    local b = CreateFrame("Button", i == 1 and "VoidQuestItemButton" or ("VoidQuestItemButton" .. i), UIParent, "SecureActionButtonTemplate")
    b:SetSize(SIZE, SIZE)
    b:RegisterForClicks("AnyUp", "AnyDown")
    -- act on release even with "cast on key down" on -- an Up-only secure button otherwise
    -- does nothing (see wow-secure-button-keydown-cvar)
    b:SetAttribute("useOnKeyDown", false)
    b:SetAttribute("type", "item")
    b:Hide()
    b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.border = b:CreateTexture(nil, "BACKGROUND")
    b.border:SetPoint("TOPLEFT", -2, 2); b.border:SetPoint("BOTTOMRIGHT", 2, -2)
    b.border:SetColorTexture(0.0, 0.78, 1.0, 0.8)
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -1, 2)
    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate"); b.cd:SetAllPoints()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnEnter", OnEnter)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    buttons[i] = b
end

local function updateCooldowns()
    for _, b in ipairs(buttons) do
        if b:IsShown() and b.link then
            local start, duration, enable
            if b.itemID then
                start, duration, enable = safe(C_Container.GetItemCooldown, b.itemID)
            else
                start, duration, enable = safe(GetQuestLogSpecialItemCooldown, safe(C_QuestLog.GetLogIndexForQuestID, b.qid))
            end
            if start and duration and duration > 0 then
                b.cd:SetCooldown(start, duration)
                b.icon:SetDesaturated(enable == 0 or enable == false)
            else
                b.cd:Clear()
                b.icon:SetDesaturated(false)
            end
        end
    end
end

local function keyOf(list, n)
    local t = {}
    for i = 1, n do t[i] = (list[i].qid or 0) .. ":" .. tostring(list[i].item) .. ":" .. tostring(list[i].count) end
    return table.concat(t, ",")
end

local function fitCount(panel)
    return panel and math.max(1, math.floor(((panel:GetHeight() or 0) + GAP) / (SIZE + GAP))) or 0
end

local pending, shownKey = false, nil
local function update()
    if InCombatLockdown() then pending = true; return end
    pending = false
    local panel = _G.VoidQuestGuidePanel
    local list = (panel and panel:IsShown()) and pickEntries() or {}
    local n = math.min(#list, MAX, fitCount(panel))
    for i, b in ipairs(buttons) do
        local e = i <= n and list[i] or nil
        if not e then
            b.qid, b.link, b.itemID = nil, nil, nil
            b:SetAttribute("item", nil)
            b:Hide()
        else
            b.qid, b.link, b.itemID = e.qid, e.link, e.itemID
            b:SetAttribute("item", e.item)
            b.icon:SetTexture(e.tex)
            b.count:SetText((e.count and e.count > 1) and e.count or "")
            b:ClearAllPoints()
            b:SetPoint("TOPRIGHT", panel, "TOPLEFT", -4, -4 - (i - 1) * (SIZE + GAP))
            b:Show()
        end
    end
    shownKey = keyOf(list, n)
    updateCooldowns()
end

-- QuestText / LearnedFor are shared with Leftovers.lua (what your log's quests need).
VQ.QuestItem = { Update = update, QuestText = questText, LearnedFor = learnedFor }

-- /vq items: every quest item it knows, in order (distance in yards), and whether it's
-- near enough to show.
VQ.QuestItemDebug = function()
    local list = pickEntries(true)
    if #list == 0 then print("|cff00c7ffVoidQuest|r no quest items found (log or bags)") end
    for n, e in ipairs(list) do
        print(("|cff00c7ffVoidQuest|r %d. %s for %s: %s yd (%s) - %s"):format(n, e.link or e.item,
            e.qid and (safe(C_QuestLog.GetTitleForQuestID, e.qid) or e.qid) or "?",
            e.d and math.floor(math.sqrt(e.d)) or "?", e.how or "linked by the quest log",
            e.near and "|cff3ddc84shown|r" or "|cff888888hidden, not near|r"))
    end
end

-- follow the guide panel's own refreshes, plus anything that changes quest items
if VQ.Guide and VQ.Guide.Refresh then hooksecurefunc(VQ.Guide, "Refresh", update) end
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_REGEN_ENABLED", "QUEST_LOG_UPDATE", "SUPER_TRACKING_CHANGED",
                     "BAG_UPDATE_DELAYED", "BAG_UPDATE_COOLDOWN", "PLAYER_ENTERING_WORLD", "QUEST_ACCEPTED",
                     "QUEST_TURNED_IN" }) do
    ev:RegisterEvent(e)
end
ev:SetScript("OnEvent", function(_, e, arg1, arg2)
    if e == "BAG_UPDATE_COOLDOWN" then updateCooldowns(); return end
    if e == "QUEST_TURNED_IN" then onQuestTurnedIn(); return end
    -- retail and WoW Forever send (questID); Classic Era sends (questLogIndex, questID)
    if e == "QUEST_ACCEPTED" then onQuestAccepted(type(arg2) == "number" and arg2 or arg1) end
    if e == "BAG_UPDATE_DELAYED" or e == "PLAYER_ENTERING_WORLD" then onBagsChanged() end
    if e == "PLAYER_REGEN_ENABLED" and not pending then return end
    update()
end)

-- As you move: show items as you come near their quest, hide them as you leave, keep
-- the closest on top (out of combat; the buttons are only touched when that changes).
C_Timer.NewTicker(2, function()
    if InCombatLockdown() then return end
    local panel = _G.VoidQuestGuidePanel
    if not (panel and panel:IsShown()) then return end
    local list = pickEntries()
    if keyOf(list, math.min(#list, MAX, fitCount(panel))) ~= shownKey then update() end
end)
