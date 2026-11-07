----------------------------------------------------------------------
-- VoidQuest — leftover quest items
-- Quest items often stay in your bags after the quest is done, and it's hard to tell
-- which ones you can throw away (the user, 2026-11-06). This works out, for every
-- quest item in your bags, whether anything still needs it:
--
--   keep    : it starts a quest you haven't done, or a quest in your log needs it
--             (objective, the item the quest handed you / links, or its text names it)
--   done    : no quest in your log needs it, and a quest it belonged to is turned in
--             ("safe to destroy" -- it was seen tied to that quest)
--   unneeded: no quest in your log needs it, and VoidQuest never saw what it was for.
--             Softer: some chains drop an item before you have the quest that uses it.
--
-- Marks only: nothing is ever deleted or sold for you. VoidBags shows the verdict on
-- the item and in its tooltip; /vq leftovers lists them.
-- The quests an item was seen tied to are kept in VoidQuestDB.itemSeen[itemID][questID],
-- which is what lets "done" name the quest after it has left your log.
----------------------------------------------------------------------
local VQ = VoidQuest
local function safe(fn, ...) if not fn then return nil end local ok, a, b, c, d = pcall(fn, ...) if ok then return a, b, c, d end end

local QUEST_CLASS = (Enum.ItemClass and Enum.ItemClass.Questitem) or 12

local function QuestTitle(qid)
    local t = safe(C_QuestLog.GetTitleForQuestID, qid)
    if t and t ~= "" then return t end
    local F = VQ.Forever
    local info = F and F.Info and F:Info(qid)
    return (info and info.title) or ("quest " .. qid)
end

-- How sure the tie is: "strong" = the quest's objective lists the item, the quest log
-- links it, or the quest handed it to you; "text" = only its story text mentions it
-- (could be a passing mention). Only strong ties can make an item "safe to destroy".
-- (Older saves stored `true`: read as "text".)
local function Seen(itemID, qid, strength)
    VoidQuestDB = VoidQuestDB or {}
    VoidQuestDB.itemSeen = VoidQuestDB.itemSeen or {}
    local t = VoidQuestDB.itemSeen[itemID] or {}
    VoidQuestDB.itemSeen[itemID] = t
    if t[qid] ~= "strong" then t[qid] = strength end
end

-- The item names a quest's ITEM objectives ask for, exactly ("Witching Talon: 0/8" ->
-- "witching talon"), as a set. Only an exact name counts as a strong tie: an item whose
-- name merely sits inside another objective's text is a mention (Codex review).
local function ObjectiveItems(qid)
    local set = {}
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
        local t = o.text
        if o.type == "item" and type(t) == "string" and not (issecretvalue and issecretvalue(t)) then
            t = t:gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub("%s*:%s*%d+%s*/%s*%d+%s*$", "")
            set[t:lower()] = true
        end
    end
    return set
end

local function Done(qid)
    return safe(C_QuestLog.IsQuestFlaggedCompleted, qid) and not safe(C_QuestLog.GetLogIndexForQuestID, qid)
end

-- Finished for good: done, and not a quest you can do again (a repeatable turn-in's items
-- stay useful -- Darkmoon artifacts; Codex review). Only this can make an item "done".
local function DoneForGood(qid)
    return Done(qid) and not safe(C_QuestLog.IsRepeatableQuest, qid)
end

-- itemID -> { verdict = "keep" | "done" | "unneeded", why = text, name = item name }
local cache, dirty = {}, true

local missing = false   -- a quest item whose data hadn't loaded: rebuild when it arrives

local function Build()
    dirty = false
    missing = false
    cache = {}
    local QI = VQ.QuestItem
    -- what the quests in your log need
    local logQuests = {}
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        local qid = info and not info.isHeader and info.questID
        if qid then
            local link = safe(GetQuestLogSpecialItemInfo, i)
            logQuests[#logQuests + 1] = {
                qid = qid,
                text = (QI and QI.QuestText and QI.QuestText(qid, i)) or "",
                objItems = ObjectiveItems(qid),
                linked = link and safe(C_Item.GetItemInfoInstant, link),
                learned = QI and QI.LearnedFor and QI.LearnedFor(qid),
            }
        end
    end
    local last = (NUM_BAG_SLOTS or 4) + ((Constants and Constants.InventoryConstants and Constants.InventoryConstants.NumReagentBagSlots) or 0)
    for bag = 0, last do
        for slot = 1, (safe(C_Container.GetContainerNumSlots, bag) or 0) do
            local info = safe(C_Container.GetContainerItemInfo, bag, slot)
            local id = info and info.itemID
            if id and not cache[id] and not (issecretvalue and issecretvalue(id)) then
                local qi = safe(C_Container.GetContainerItemQuestInfo, bag, slot)
                local ok, _, _, _, _, _, classID = pcall(C_Item.GetItemInfoInstant, id)
                local name = safe(C_Item.GetItemInfo, id)
                local starts = qi and qi.questID
                -- quest starters count even when not flagged as quest items (Codex review)
                local isQuest = (qi and qi.isQuestItem) or starts or (ok and classID == QUEST_CLASS)
                if isQuest and not name then missing = true end
                if isQuest and name then
                    local v
                    -- 1) a quest in your log needs it: always wins, before anything that
                    -- could call it done (Codex review)
                    local lname = name:lower()
                    for _, q in ipairs(logQuests) do
                        local strong = (q.linked == id) or (q.learned and q.learned[id])
                            or q.objItems[lname]
                        local mention = not strong and #lname >= 4 and q.text:find(lname, 1, true)
                        if strong or mention then
                            Seen(id, q.qid, strong and "strong" or "text")
                            v = v or { verdict = "keep", why = ("Needed for %s"):format(QuestTitle(q.qid)) }
                        end
                    end
                    -- 2) it starts a quest you haven't done
                    if not v and starts and not Done(starts) then
                        v = { verdict = "keep", why = ("Starts a quest: %s"):format(QuestTitle(starts)) }
                    end
                    -- 3) nothing needs it now. "Safe to destroy" only when the evidence is
                    -- strong AND every quest it was ever tied to is turned in (an item tied
                    -- to two quests isn't done when only one is). Anything less: "unneeded".
                    if not v then
                        local ties = {}
                        for qid, s in pairs((VoidQuestDB and VoidQuestDB.itemSeen and VoidQuestDB.itemSeen[id]) or {}) do
                            ties[qid] = (s == "strong") and "strong" or "text"
                        end
                        for qid, items in pairs((VoidQuestDB and VoidQuestDB.questItems) or {}) do
                            if items[id] then ties[qid] = "strong" end
                        end
                        if starts then ties[starts] = "strong" end
                        local anyStrong, allDone, named = false, next(ties) ~= nil, nil
                        for qid, s in pairs(ties) do
                            if s == "strong" then anyStrong = true; named = named or qid end
                            if not DoneForGood(qid) then allDone = false end
                        end
                        if anyStrong and allDone then
                            v = { verdict = "done", why = (starts and named == starts)
                                and ("Starts %s, which you've done"):format(QuestTitle(starts))
                                or ("Leftover: %s is turned in"):format(QuestTitle(named)) }
                        end
                    end
                    v = v or { verdict = "unneeded", why = "No quest in your log needs this" }
                    v.name = name
                    cache[id] = v
                end
            end
        end
    end
end

-- Verdict for an item in your bags: "keep" | "done" | "unneeded" (nil = not a quest
-- item, or not in your bags), plus the reason. Used by VoidBags.
local function Verdict(itemID)
    if not itemID then return nil end
    if dirty then Build() end
    local v = cache[itemID]
    if v then return v.verdict, v.why end
    return nil
end

VQ.Leftovers = { Verdict = Verdict, Refresh = function() dirty = true end }
-- the public hook other addons look for
VoidQuest_LeftoverVerdict = Verdict

-- /vq leftovers
VQ.LeftoversList = function()
    Build()
    local done, unneeded, keep = {}, {}, 0
    for _, v in pairs(cache) do
        if v.verdict == "done" then done[#done + 1] = v
        elseif v.verdict == "unneeded" then unneeded[#unneeded + 1] = v
        else keep = keep + 1 end
    end
    local p = "|cff00c7ffVoidQuest|r "
    if #done + #unneeded == 0 then
        print(p .. ("no leftover quest items (%d quest item%s in your bags, all still needed)"):format(keep, keep == 1 and "" or "s"))
        return
    end
    for _, v in ipairs(done) do print(p .. "|cff3ddc84safe to destroy|r " .. v.name .. " - " .. v.why) end
    for _, v in ipairs(unneeded) do print(p .. "|cffffd100probably not needed|r " .. v.name .. " - " .. v.why) end
    if keep > 0 then print(p .. ("%d other quest item%s still needed"):format(keep, keep == 1 and "" or "s")) end
end

-- The reason, in the item's own tooltip (any bag window, not only VoidBags).
if TooltipDataProcessor and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
        if tt ~= GameTooltip or not data or type(data.id) ~= "number" then return end
        if issecretvalue and issecretvalue(data.id) then return end
        local verdict, why = Verdict(data.id)
        if verdict == "done" then
            tt:AddLine("VoidQuest: " .. why .. " - safe to destroy", 1, 0.42, 0.42, true)
        elseif verdict == "unneeded" then
            tt:AddLine("VoidQuest: " .. why .. " (some quests use an item before you have them)", 1, 0.82, 0, true)
        elseif verdict == "keep" then
            tt:AddLine("VoidQuest: " .. why, 0.24, 0.86, 0.52, true)
        end
    end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "QUEST_LOG_UPDATE", "BAG_UPDATE_DELAYED", "QUEST_TURNED_IN", "PLAYER_ENTERING_WORLD",
                     "GET_ITEM_INFO_RECEIVED" }) do
    ev:RegisterEvent(e)
end
ev:SetScript("OnEvent", function(_, e)
    -- item data arriving only matters when an item was skipped for lacking it
    if e == "GET_ITEM_INFO_RECEIVED" and not missing then return end
    dirty = true
end)
