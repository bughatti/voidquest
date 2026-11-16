----------------------------------------------------------------------
-- VoidQuest — leftover quest items
-- Quest items often stay in your bags after the quest is done, and it's hard to tell
-- which ones you can throw away (the user, 2026-11-06). This works out, for every
-- quest item in your bags, whether anything still needs it:
--
--   keep    : it starts a quest you haven't done, a quest in your log needs it (objective, the
--             item the quest handed you / links, or its text names it), a WoW Forever quest you
--             haven't done needs it (ForeverItemQuests.lua: "for a later quest"), or it's on the
--             hand-made KEEP list (used somewhere to make / summon what a quest needs)
--   done    : none of that, and a quest it belonged to is turned in ("safe to destroy" -- it
--             was seen tied to that quest)
--   unknown : no quest found for it. No mark in the bags, only a tooltip line ("keep it if
--             unsure"): it used to be a yellow ? that read as "delete me" (2026-11-16).
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

-- Chains no quest data shows: the item is used somewhere to make or summon what a quest needs (the
-- user, 2026-11-16: "i have a sacred mallet in my bag that is for a quest later"). Always "keep".
-- Checked: warcraft.wiki.gg Sacred_Mallet / Mallet_of_Zul'Farrak; VoidDB: Gahz'rilla (7273) drops
-- Gahz'rilla's Electrified Scale (8707), which the quest Gahz'rilla (2770) asks for.
local KEEP = {
    [9241] = { q = 2770, why = "Use it at the altar on top of Jintha'Alor (the Hinterlands) to make the Mallet of Zul'Farrak, which summons Gahz'rilla in Zul'Farrak" },
    [9240] = { q = 2770, why = "Strike the gong in Zul'Farrak with it to summon Gahz'rilla" },
}

-- The WoW Forever quests you haven't done (and can take) that need this item, from VoidDB's quest data
-- (ForeverItemQuests.lua), lowest level first: { q1, q2, ... } or nil.
local function MinLevel(q)
    local rule = VQ.ForeverRules and VQ.ForeverRules[q]
    return (rule and rule.ml) or 0
end
local function LaterQuests(itemID)
    local qs = VQ.ForeverItemQuests and VQ.ForeverItemQuests[itemID]
    if not qs then return nil end
    local F, out = VQ.Forever, {}
    for _, q in ipairs(qs) do
        if not safe(C_QuestLog.IsQuestFlaggedCompleted, q) then
            local row = VQ.ForeverQuests and VQ.ForeverQuests[q]
            local ok = true
            if F and F.Eligible and row then ok = F:Eligible(row) end
            if ok then out[#out + 1] = q end
        end
    end
    if #out == 0 then return nil end
    table.sort(out, function(a, b)
        local la, lb = MinLevel(a), MinLevel(b)
        if la ~= lb then return la < lb end
        return a < b
    end)
    return out
end

-- WoW Forever without the item -> quest index loaded (never expected, it ships): nothing may be
-- called "safe to destroy" then, since a later quest could need it (Codex review)
local function IndexMissing()
    return VQ.ForeverQuests ~= nil and VQ.ForeverItemQuests == nil
end

-- Tooltip lines for one quest: what, from whom and where, and whether you can take it yet.
local function MapName(m)
    local info = m and safe(C_Map.GetMapInfo, m)
    return info and info.name
end
local function QuestLines(tt, q)
    local F = VQ.Forever
    local lvl = F and F.Level and F:Level(q)
    local title = QuestTitle(q)
    tt:AddLine("  " .. title .. ((lvl and lvl > 0) and (" [" .. lvl .. "]") or ""), 1, 0.82, 0)
    local sd = VQ.ForeverSeed and VQ.ForeverSeed[q]
    if sd and sd.giver then
        local where = MapName(sd.m)
        local at = (where and sd.x and sd.y) and (" (%.1f, %.1f)"):format(sd.x * 100, sd.y * 100) or ""
        tt:AddLine("    From " .. sd.giver .. (where and (", " .. where) or "") .. at, 0.9, 0.9, 0.9)
    end
    if safe(C_QuestLog.GetLogIndexForQuestID, q) then
        tt:AddLine("    In your quest log", 0.24, 0.86, 0.52)
        return
    end
    local state, why = nil, nil
    if F and F.Rule then state, why = F:Rule(q) end
    if state == "later" and why then
        local mine = UnitLevel and UnitLevel("player")
        local extra = (why:find("^Needs level") and mine) and (" (you're " .. mine .. ")") or ""
        tt:AddLine("    " .. why .. extra, 1, 0.6, 0.2)
    elseif state ~= "never" then
        tt:AddLine("    You can take it now", 0.24, 0.86, 0.52)
    end
end

-- itemID -> { verdict = "keep" | "done" | "unknown", why = text, name = item name }
-- ("unknown" replaced "unneeded", which VoidBags drew as a yellow ?: people read it as "safe to delete"
-- when it only meant "no quest found", 2026-11-16. Unknown items get no mark, only a tooltip line.)
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
                    -- 2b) a quest you haven't picked up yet needs it (any WoW Forever quest)
                    if not v then
                        local later = LaterQuests(id)
                        if later then
                            local lvl = MinLevel(later[1])
                            v = { verdict = "keep", later = later,
                                  why = ("Keep: for a later quest, %s%s"):format(QuestTitle(later[1]),
                                      lvl > 0 and (" (from level " .. lvl .. ")") or "") }
                        end
                    end
                    -- 2c) chains the data can't see (KEEP above)
                    if not v and KEEP[id] then
                        local k = KEEP[id]
                        v = { verdict = "keep", how = k.why, later = (k.q and not Done(k.q)) and { k.q } or nil,
                              why = "Keep: " .. k.why .. ((k.q and not Done(k.q))
                                  and (" (quest: " .. QuestTitle(k.q) .. ")") or "") }
                    end
                    -- 3) nothing needs it now. "Safe to destroy" only when the evidence is
                    -- strong AND every quest it was ever tied to is turned in (an item tied
                    -- to two quests isn't done when only one is). Anything less: "unknown".
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
                        if anyStrong and allDone and not IndexMissing() then   -- (no index: never "safe", Codex)
                            v = { verdict = "done", why = (starts and named == starts)
                                and ("Starts %s, which you've done"):format(QuestTitle(starts))
                                or ("Leftover: %s is turned in"):format(QuestTitle(named)) }
                        end
                    end
                    v = v or { verdict = "unknown", why = "No quest found for this item" }
                    v.name = name
                    cache[id] = v
                end
            end
        end
    end
end

-- Verdict for an item in your bags: "keep" | "done" | "unknown" (nil = not a quest
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
    local done, unknown, keep = {}, {}, 0
    for _, v in pairs(cache) do
        if v.verdict == "done" then done[#done + 1] = v
        elseif v.verdict == "unknown" then unknown[#unknown + 1] = v
        else keep = keep + 1 end
    end
    local p = "|cff00c7ffVoidQuest|r "
    if #done + #unknown == 0 then
        print(p .. ("no leftover quest items (%d quest item%s in your bags, all still needed)"):format(keep, keep == 1 and "" or "s"))
        return
    end
    for _, v in ipairs(done) do print(p .. "|cff3ddc84safe to destroy|r " .. v.name .. " - " .. v.why) end
    for _, v in ipairs(unknown) do print(p .. "|cffaaaaaanot sure, keep if unsure|r " .. v.name .. " - " .. v.why) end
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
        elseif verdict == "unknown" then
            tt:AddLine("VoidQuest: " .. why .. ". Some items are used later, so keep it if unsure.", 0.67, 0.67, 0.67, true)
        elseif verdict == "keep" then
            -- What it's for and when (the user, 2026-11-16: "when we hover over an item like this it
            -- states what it is for and when, all the data they need to know"): the how-to for a
            -- hand-made chain, then each later quest with its giver, where, and whether you can take it.
            local v = cache[data.id]
            if v and (v.later or v.how) then
                tt:AddLine("VoidQuest: keep this" .. (v.later and ", a quest you haven't done needs it" or ""), 0.24, 0.86, 0.52, true)
                if v.how then tt:AddLine("  " .. v.how, 0.9, 0.9, 0.9, true) end
                for i, q in ipairs(v.later or {}) do
                    if i > 3 then
                        tt:AddLine(("  and %d more"):format(#v.later - 3), 0.6, 0.6, 0.6)
                        break
                    end
                    QuestLines(tt, q)
                end
            else
                tt:AddLine("VoidQuest: " .. why, 0.24, 0.86, 0.52, true)
            end
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
