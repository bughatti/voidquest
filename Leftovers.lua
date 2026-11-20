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
--   done    : none of that, and EVERY quest tied to it is settled: turned in for good, or one this
--             character can never take ("safe to destroy"). Ties = the quest data (needs it, hands it
--             to you: ForeverItemGiven, starts with it) + what VoidQuest saw in your log. 2026-11-19, the
--             user: "it doesnt always remove the item ... the first one has to be exact".
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

local function InLog(qid) return safe(C_QuestLog.GetLogIndexForQuestID, qid) ~= nil end

-- A quest you can do again (a repeatable turn-in's items stay useful -- Darkmoon artifacts; Codex
-- review). The game only knows for quests in your log, so VoidDB's flag (ForeverRepeatable) first.
local function Repeatable(qid)
    return (VQ.ForeverRepeatable and VQ.ForeverRepeatable[qid]) or safe(C_QuestLog.IsRepeatableQuest, qid) or false
end

-- Finished for good: done, and not a quest you can do again.
local function DoneForGood(qid)
    return Done(qid) and not Repeatable(qid)
end

-- This character can never take it: another faction, class or race, past its top level, or a branch
-- closed by a quest you DID (a rival only sitting in your log could still be abandoned, so that one
-- doesn't count; 2026-11-19, the user: "the first one has to be exact"). Returns true + the reason.
local function Never(qid)
    local row, F = nil, VQ.Forever
    if VQ.ForeverQuests then row = VQ.ForeverQuests[qid] end
    if not row or not F or not F.Eligible then return false end
    if F:Eligible(row) then return false end
    local rr = VQ.ForeverRules and VQ.ForeverRules[qid]
    if rr then
        for _, q in ipairs(rr.ex or {}) do
            if InLog(q) then return false end
        end
        if rr.bf and InLog(rr.bf) then return false end
    end
    local state, why = nil, nil
    if F.Rule then state, why = F:Rule(qid) end
    -- the rule's reason only when it's the one closing it (else: faction, class or race)
    return true, (state == "never" and why) or "not for your faction, class or race"
end

-- Settled: turned in for good, or one you can never take. Only when EVERY quest tied to an item is
-- settled can the item be "safe to destroy".
local function Settled(qid)
    return DoneForGood(qid) or (Never(qid))
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
    local out = {}
    for _, q in ipairs(qs) do
        -- not done (or done but repeatable), and one you can still take
        if not Settled(q) then out[#out + 1] = q end
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
    -- any of the three tables (one generated file): without "given" or "repeatable" a needed item could
    -- look settled (Codex Sol 2026-11-19)
    return VQ.ForeverQuests ~= nil and (VQ.ForeverItemQuests == nil or VQ.ForeverItemGiven == nil
        or VQ.ForeverRepeatable == nil)
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

-- itemID -> { verdict = "keep" | "done" | "unknown", why = text, name = item name } (false = not a quest item)
-- ("unknown" replaced "unneeded", which VoidBags drew as a yellow ?: people read it as "safe to delete"
-- when it only meant "no quest found", 2026-11-16. Unknown items get no mark, only a tooltip line.)
local cache, dirty = {}, true

local missing = false   -- a quest item whose data hadn't loaded: rebuild when it arrives
local logQuests = {}    -- what the quests in your log need (rebuilt with the cache)

local function ScanLog()
    local QI = VQ.QuestItem
    logQuests = {}
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
end

-- Every quest tied to the item: qid -> "strong" | "text". Strong = the quest data says the quest needs
-- it, hands it to you or is started by it (ForeverItemQuests / ForeverItemGiven), the game said so
-- (the quest log linked it, it starts the quest), or VoidQuest saw it tied while the quest was in your
-- log. Text = only the quest's story mentions it.
local function Ties(id, starts)
    local ties = {}
    for qid, s in pairs((VoidQuestDB and VoidQuestDB.itemSeen and VoidQuestDB.itemSeen[id]) or {}) do
        ties[qid] = (s == "strong") and "strong" or "text"
    end
    for qid, items in pairs((VoidQuestDB and VoidQuestDB.questItems) or {}) do
        if items[id] then ties[qid] = "strong" end
    end
    for _, q in ipairs((VQ.ForeverItemQuests and VQ.ForeverItemQuests[id]) or {}) do ties[q] = "strong" end
    for _, q in ipairs((VQ.ForeverItemGiven and VQ.ForeverItemGiven[id]) or {}) do ties[q] = "strong" end
    if starts then ties[starts] = "strong" end
    return ties
end

local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- The verdict for one quest item. starts = the quest it starts (from the bag slot), if known.
local function Judge(id, name, starts)
    local v
    -- 1) a quest in your log needs it: always wins, before anything that could call it done
    -- (Codex review). The quest data first (it needs the item or handed it to you), then what the
    -- log itself shows (the linked item, an objective naming it, its text mentioning it).
    local byData = {}
    for _, q in ipairs((VQ.ForeverItemQuests and VQ.ForeverItemQuests[id]) or {}) do byData[q] = true end
    for _, q in ipairs((VQ.ForeverItemGiven and VQ.ForeverItemGiven[id]) or {}) do byData[q] = true end
    local lname = name:lower()
    for _, q in ipairs(logQuests) do
        local strong = byData[q.qid] or (q.linked == id) or (q.learned and q.learned[id]) or q.objItems[lname]
        local mention = not strong and #lname >= 4 and q.text:find(lname, 1, true)
        if strong or mention then
            Seen(id, q.qid, strong and "strong" or "text")
            v = v or { verdict = "keep", why = ("Needed for %s"):format(QuestTitle(q.qid)) }
        end
    end
    -- 2) it starts a quest you can still do
    if not v and starts and not Settled(starts) then
        v = { verdict = "keep", why = ("Starts a quest: %s"):format(QuestTitle(starts)) }
    end
    -- 2b) a quest you haven't done (or can do again) needs it (any WoW Forever quest)
    if not v then
        local later = LaterQuests(id)
        if later then
            local lvl = MinLevel(later[1])
            v = { verdict = "keep", later = later,
                  why = ("Keep: for a later quest, %s%s"):format(QuestTitle(later[1]),
                      lvl > 0 and (" (from level " .. lvl .. ")") or "") }
        end
    end
    -- 2c) a quest that hands it to you isn't turned in (you took it and dropped it, or it's coming):
    -- the giver may not hand out a second one
    if not v then
        for _, q in ipairs((VQ.ForeverItemGiven and VQ.ForeverItemGiven[id]) or {}) do
            if not Settled(q) then
                v = { verdict = "keep", later = { q },
                      why = ("Keep: it comes with %s, which you haven't turned in"):format(QuestTitle(q)) }
                break
            end
        end
    end
    -- 2d) chains the data can't see (KEEP above)
    if not v and KEEP[id] then
        local k = KEEP[id]
        v = { verdict = "keep", how = k.why, later = (k.q and not Done(k.q)) and { k.q } or nil,
              why = "Keep: " .. k.why .. ((k.q and not Done(k.q))
                  and (" (quest: " .. QuestTitle(k.q) .. ")") or "") }
    end
    -- 3) nothing needs it now. "Safe to destroy" only when there's strong evidence AND every quest it
    -- was ever tied to is settled: turned in for good, or one you can never take (an item tied to two
    -- quests isn't done when only one is). Anything less: "unknown".
    if not v and not IndexMissing() then   -- (no index: never "safe", Codex)
        local ties = Ties(id, starts)
        local anyStrong, allSettled, open = false, next(ties) ~= nil, nil
        local doneQ, neverQ, neverWhy, n = nil, nil, nil, 0
        for _, qid in ipairs(sortedKeys(ties)) do
            n = n + 1
            if ties[qid] == "strong" then anyStrong = true end
            if DoneForGood(qid) then
                if ties[qid] == "strong" then doneQ = doneQ or qid end
            else
                local never, why = Never(qid)
                if never then
                    if ties[qid] == "strong" and not neverQ then neverQ, neverWhy = qid, why end
                else
                    allSettled = false
                    open = open or qid
                end
            end
        end
        if anyStrong and allSettled then
            local more = n > 1 and (" (all %d quests that use it are settled)"):format(n) or ""
            local why
            if doneQ and starts and doneQ == starts then
                why = ("Starts %s, which you've done"):format(QuestTitle(starts))
            elseif doneQ then
                why = ("Leftover: %s is turned in"):format(QuestTitle(doneQ))
            else
                why = ("Leftover: only for %s, which you can't take (%s)"):format(QuestTitle(neverQ), neverWhy)
            end
            v = { verdict = "done", why = why .. more }
        elseif open then
            v = { verdict = "unknown", why = (ties[open] == "strong" and "It was tied to %s, which isn't done"
                or "The text of %s, which isn't done, mentions it"):format(QuestTitle(open)) }
        end
    end
    v = v or { verdict = "unknown", why = "No quest found for this item" }
    v.name = name
    return v
end

local function Build()
    dirty = false
    missing = false
    cache = {}
    ScanLog()
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
                if isQuest and name then cache[id] = Judge(id, name, starts) end
            end
        end
    end
end

-- Verdict for a quest item: "keep" | "done" | "unknown" (nil = not a quest item), plus the reason.
-- Items in your bags are judged with what the bag slot tells (the quest it starts); anything else (the
-- bank, a link) the same way from the data, so its tooltip says it too. Used by VoidBags.
local function Verdict(itemID)
    if not itemID or (issecretvalue and issecretvalue(itemID)) then return nil end
    if dirty then Build() end
    local v = cache[itemID]
    if v == nil then
        local ok, _, _, _, _, _, classID = pcall(C_Item.GetItemInfoInstant, itemID)
        if not (ok and classID == QUEST_CLASS) then
            cache[itemID] = false
            return nil
        end
        local name = safe(C_Item.GetItemInfo, itemID)
        if not name then missing = true; return nil end
        v = Judge(itemID, name, nil)
        cache[itemID] = v
    end
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
        if not v then
            -- not a quest item (looked up from a tooltip)
        elseif v.verdict == "done" then done[#done + 1] = v
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
