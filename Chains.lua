----------------------------------------------------------------------
-- VoidQuest — quest chains + grey quest grading (part 1: your own characters)
-- The user, 2026-11-06: grey quests in the log, "are they needed for a future dungeon
-- quest or are they throw away". Blizzard keeps quest chains on its servers only: WoW
-- Forever's client has no quest lines for its Classic quests (C_QuestLine returned none,
-- even after RequestQuestLinesForMap), and the web API lists prerequisites for 57 of
-- 7,055 quests. So the chains are LEARNED, the moment the server reveals each link:
--   1. you turn in A and the same NPC's quest window opens with B within 3 s (the classic
--      follow-up), or
--   2. you saw that NPC's quest list before turning A in, and right after it offers a
--      quest that wasn't on it.
-- VoidQuestDB.chains[A] = { [B] = times seen }. Account-wide. Part 2 shares them through
-- VoidQuest's in-game sharing; the shipped seed is built from them on the author's machine
-- (never an uploader).
--
-- Grading (grey quests): KEEP when it's a dungeon / raid / elite / class quest, rewards a
-- blue or better item, or a known chain leads to one of those; LOW VALUE otherwise ("no
-- follow-up known yet" while nobody has followed it). Shown as a yellow star in front of a
-- grey KEEP quest; no star = safe to abandon. Marks only: nothing is abandoned.
-- The same grade drives WoW Forever's Min / Mid / Max (C:InScope).
----------------------------------------------------------------------
local VQ = VoidQuest
local function safe(fn, ...) if not fn then return nil end local ok, a, b, c, d = pcall(fn, ...) if ok then return a, b, c, d end end
local function secret(v) return issecretvalue and issecretvalue(v) end

local C = {}
VQ.Chains = C

local FOLLOWUP_WINDOW = 3     -- s: the next quest's window opening on its own
local LIST_WINDOW = 30        -- s: the NPC's quest list after a turn-in

local function DB()
    VoidQuestDB = VoidQuestDB or {}
    VoidQuestDB.chains = VoidQuestDB.chains or {}
    return VoidQuestDB.chains
end

-- Grades are cached; any quest-log change marks them stale, but they're redone at most
-- every STALE_FOR seconds: QUEST_LOG_UPDATE fires on every kill, and the Forever zone
-- list grades a whole zone (Min/Mid). Turn-ins, accepts and new links redo them at once.
local STALE_FOR = 2
local gradeCache, ownCache, prevOf, prevList = {}, {}, nil, nil
local stale, lastInv = false, 0
local function Invalidate() gradeCache, ownCache, prevOf, prevList, stale, lastInv = {}, {}, nil, nil, false, GetTime() end
local function Fresh() if stale and GetTime() - lastInv >= STALE_FOR then Invalidate() end end

-- strength: 2 = confirmed (the follow-up window opened by itself, no other window in
-- between), 1 = probable (a new entry on the NPC's list, which a level-up or reputation
-- unlock could also explain; Codex review). The stronger evidence is kept.
local function Link(a, b, strength)
    if not (a and b) or a == b then return end
    local t = DB()[a] or {}
    DB()[a] = t
    local cur = tonumber(t[b]) or 0
    if strength > cur then t[b] = strength end
    Invalidate()
end

-- The NPC you're talking to: its NPC ID (creatures only), or nil.
local function NpcNow()
    if not UnitExists("npc") or UnitIsPlayer("npc") then return nil end
    local g = UnitGUID("npc")
    if not g or secret(g) then return nil end
    local kind, _, _, _, _, id = strsplit("-", g)
    if kind ~= "Creature" then return nil end
    return tonumber(id)
end

-- What each NPC offered when you last saw its full list this session.
local offers = {}         -- npcID -> { [questID] = true }
local pending             -- { qid, npc, t, before }

local function OfferedNow(event)
    local ids = {}
    if event == "GOSSIP_SHOW" then
        for _, q in ipairs(safe(C_GossipInfo.GetAvailableQuests) or {}) do
            if q.questID and not secret(q.questID) then ids[q.questID] = true end
        end
    elseif event == "QUEST_GREETING" then
        for i = 1, safe(GetNumAvailableQuests) or 0 do
            local ok, _, _, _, _, q = pcall(GetAvailableQuestInfo, i)
            if ok and type(q) == "number" and not secret(q) then ids[q] = true end
        end
    end
    return ids
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_TURNED_IN",
                     "GOSSIP_CLOSED", "QUEST_FINISHED", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED",
                     "ITEM_DATA_LOAD_RESULT" }) do pcall(ev.RegisterEvent, ev, e) end
-- reward items whose quality we asked the game for: 1 = waiting, 2 = loaded; a failed load
-- is asked again after RETRY_AFTER s, up to MAX_TRIES times (Sol review: it was dropped
-- for good, so a blue-reward quest could stay graded low)
local itemAsked, itemTries = {}, {}
local RETRY_AFTER, MAX_TRIES = 60, 3
local redraw           -- a reward's quality arrived: redo the grades and redraw, once per burst
local function Redraw()
    if redraw then return end
    redraw = true
    C_Timer.After(0.5, function()
        redraw = nil
        Invalidate()
        if VQ.Forever and VQ.Forever.Refresh then VQ.Forever:Refresh() end
        if VQ.Guide and VQ.Guide.Refresh then VQ.Guide:Refresh() end
    end)
end
ev:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "QUEST_LOG_UPDATE" then stale = true; return end
    if event == "QUEST_ACCEPTED" then Invalidate(); return end
    if event == "ITEM_DATA_LOAD_RESULT" then   -- itemID, success
        if itemAsked[arg1] == 1 then
            if arg2 == false then
                itemAsked[arg1] = 3   -- failed
                if (itemTries[arg1] or 0) < MAX_TRIES then
                    local id = arg1
                    C_Timer.After(RETRY_AFTER, function() if itemAsked[id] == 3 then itemAsked[id] = nil; Redraw() end end)
                end
            else
                itemAsked[arg1] = 2
                Redraw()
            end
        end
        return
    end
    -- the window closed after the turn-in: whatever opens next may be a new interaction
    if event == "GOSSIP_CLOSED" or event == "QUEST_FINISHED" then
        if pending then pending.closed = true end
        return
    end
    local npc = NpcNow()
    if event == "QUEST_TURNED_IN" then
        Invalidate()
        local qid = type(arg1) == "number" and not secret(arg1) and arg1 or nil
        if qid and npc then
            local before = offers[npc]
            local copy
            if before then copy = {}; for q in pairs(before) do copy[q] = true end end
            pending = { qid = qid, npc = npc, t = GetTime(), before = copy, level = UnitLevel("player") }
        else
            pending = nil
        end
        return
    end
    if not npc then return end
    local now = GetTime()
    if event == "QUEST_DETAIL" then
        local q = safe(GetQuestID)
        if type(q) == "number" and q > 0 and not secret(q) and pending and pending.npc == npc
           and now - pending.t <= FOLLOWUP_WINDOW and q ~= pending.qid
           and not (pending.before and pending.before[q]) then   -- already on offer: not a follow-up
            -- rule 1: confirmed only when it opened straight from the turn-in (no window
            -- closed in between, no level gained)
            local sure = not pending.closed and UnitLevel("player") == pending.level
            Link(pending.qid, q, sure and 2 or 1)
            pending = nil
        end
        return
    end
    -- a full list (gossip / greeting): rule 2, always only probable
    local ids = OfferedNow(event)
    if pending and pending.npc == npc then
        if now - pending.t <= LIST_WINDOW and pending.before then
            for q in pairs(ids) do
                if not pending.before[q] and q ~= pending.qid then Link(pending.qid, q, 1) end
            end
        end
        -- a list came up: any quest window after it is a choice from the list, not a
        -- follow-up opening by itself (Codex review), with or without an earlier list
        pending = nil
    end
    offers[npc] = ids
end)

----------------------------------------------------------------------
-- Grading
----------------------------------------------------------------------
local function Info(qid)
    local F = VQ.Forever
    return F and F.Info and F:Info(qid)
end

local function Title(qid)
    local t = safe(C_QuestLog.GetTitleForQuestID, qid)
    if t and t ~= "" and not secret(t) then return t end
    local i = Info(qid)
    return (i and i.title) or ("quest " .. qid)
end

-- A blue (rare) or better reward of a quest you haven't picked up: WoW Forever's quest
-- data lists the reward item IDs, the game tells their quality (asked once per item;
-- ITEM_DATA_LOAD_RESULT regrades when it arrives).
local function BlueRewardByData(qid)
    local i = Info(qid)
    local ids = i and i.rewardIDs
    if not (ids and ids ~= "" and C_Item and C_Item.GetItemQualityByID) then return nil end
    for s in ids:gmatch("%d+") do
        local id = tonumber(s)
        local q = safe(C_Item.GetItemQualityByID, id)
        if type(q) == "number" and not secret(q) then
            if q >= 3 then
                local name = C_Item.GetItemNameByID and safe(C_Item.GetItemNameByID, id)
                return "rewards " .. ((type(name) == "string" and not secret(name) and name) or "a blue item")
            end
        elseif not itemAsked[id] and C_Item.RequestLoadItemDataByID then
            itemAsked[id] = 1
            itemTries[id] = (itemTries[id] or 0) + 1
            safe(C_Item.RequestLoadItemDataByID, id)
        end
    end
    return nil
end

-- Why a quest matters on its own, or nil. Cached until the quest log / chains change.
local OwnReasonUncached
local function OwnReason(qid)
    Fresh()
    local c = ownCache[qid]
    if c == nil then c = OwnReasonUncached(qid) or false; ownCache[qid] = c end
    return c or nil
end
OwnReasonUncached = function(qid)
    local i = Info(qid)
    if i then
        local f = i.flags or ""
        if f:find("R") then return "raid quest" end
        if f:find("D") then return "dungeon quest" end
        if f:find("E") then return "elite quest" end
        if i.classes and i.classes ~= "" then return "class quest" end
    else
        -- retail (not in Forever's quest data): the game's own tags (Codex review)
        local G = VQ.Guide
        if G and G.IsDungeonQuest and G:IsDungeonQuest(qid) then return "dungeon or raid quest" end
        if C_CampaignInfo and safe(C_CampaignInfo.IsCampaignQuest, qid) then return "campaign quest" end
        if safe(C_QuestLog.IsImportantQuest, qid) then return "important quest" end
        -- the old group / elite tag is Enum.QuestTag.Group (there's no "Elite" entry)
        local tag = safe(C_QuestLog.GetQuestTagInfo, qid)
        local T = Enum.QuestTag
        if tag and (tag.isElite or (T and T.Group and tag.tagID == T.Group)) then return "elite quest" end
    end
    -- a blue (rare) or better reward, read from the quest log (quests you have)
    if safe(C_QuestLog.GetLogIndexForQuestID, qid) then
        for i2 = 1, safe(GetNumQuestLogRewards, qid) or 0 do
            local ok, name, _, _, quality = pcall(GetQuestLogRewardInfo, i2, qid)
            if ok and type(quality) == "number" and quality >= 3 then return "rewards " .. tostring(name) end
        end
        for i2 = 1, safe(GetNumQuestLogChoices, qid) or 0 do
            local ok, name, _, _, quality = pcall(GetQuestLogChoiceInfo, i2, qid)
            if ok and type(quality) == "number" and quality >= 3 then return "reward choice " .. tostring(name) end
        end
        return nil
    end
    return BlueRewardByData(qid)
end

-- A quest's known follow-ups: { [next] = 2 confirmed / 1 probable }. Your own live
-- links (confirmed) plus the shipped seed (VoidQuest.ForeverChains, built on the author's
-- machine from collected data: confirmed links and probable ones from quest history).
local function NextOf(a)
    local out = {}
    for b, v in pairs((VQ.ForeverChains and VQ.ForeverChains[a]) or {}) do out[b] = v end
    for b, v in pairs(DB()[a] or {}) do
        v = math.max(1, math.min(2, tonumber(v) or 1))
        if v > (out[b] or 0) then out[b] = v end
    end
    return out
end
C.NextOf = NextOf

-- The quest that has to be done before this one, when you haven't done it (the user, 11-11: a "!" for the
-- third "The Swarm Grows" at Moktar Krin, who only offers it after the first two). Confirmed links only
-- (the seed's are NorgannonDB prerequisites + chains, and links seen live). Any one earlier quest
-- turned in is enough (quests with several ways in). Returns the earlier quest id, or nil.
function C:Earlier(qid)
    Fresh()
    if not prevList then
        prevList = {}
        local function add(a, t)
            for b, v in pairs(t) do
                if (tonumber(v) or 0) >= 2 then prevList[b] = prevList[b] or {}; table.insert(prevList[b], a) end
            end
        end
        for a, t in pairs(VQ.ForeverChains or {}) do add(a, t) end
        for a, t in pairs(DB()) do add(a, t) end
    end
    local ps = prevList[qid]
    if not ps then return nil end
    local first
    for _, a in ipairs(ps) do
        local ok, done = pcall(C_QuestLog.IsQuestFlaggedCompleted, a)
        if ok and done == true then return nil end
        first = first or a
    end
    return first
end

-- The first quest down a known chain that matters, with why ("probably" when a link on
-- the way is only probable); plus the first follow-up known at all. The whole reachable
-- chain is searched (seen stops loops; Codex review: a depth cap called a long chain to a
-- dungeon quest "low"), with a node cap only as a safety net.
local MAX_NODES = 400
-- One search. confirmedOnly: follow only confirmed links.
local function Search(qid, confirmedOnly)
    local seen, queue, anyNext = { [qid] = true }, { qid }, nil
    local visited, head = 0, 1
    while head <= #queue do
        local a = queue[head]
        head = head + 1
        for b, v in pairs(NextOf(a)) do
            if not seen[b] and (not confirmedOnly or v >= 2) then
                seen[b] = true
                visited = visited + 1
                if visited > MAX_NODES then return nil, nil, anyNext end
                anyNext = anyNext or b
                local why = OwnReason(b)
                if why then return b, why, anyNext end
                queue[#queue + 1] = b
            end
        end
    end
    return nil, nil, anyNext
end
-- Confirmed links first, so a probable branch found first can't hide a confirmed route to
-- the same quest (Codex review); then all links ("probably leads to").
local function ChainReason(qid)
    local b, why = Search(qid, true)
    if b then return ("leads to %s (%s)"):format(Title(b), why), b end
    local b2, why2, anyNext = Search(qid, false)
    if b2 then return ("probably leads to %s (%s)"):format(Title(b2), why2), b2 end
    return nil, anyNext
end

local function IsGrey(qid)
    local t = safe(C_QuestLog.IsQuestTrivial, qid)
    if t ~= nil and not secret(t) then return t and true or false end
    return false
end

-- "keep" | "low", reason. Any quest; the panel only marks grey ones. Cached: the panel
-- asks on every refresh (Codex review); cleared when the log or the chains change.
local function GradeUncached(qid)
    local own = OwnReason(qid)
    if own then return "keep", own end
    local why, anyNext = ChainReason(qid)
    if why then return "keep", why end
    if anyNext then return "low", ("leads to %s, nothing special after it so far"):format(Title(anyNext)) end
    return "low", "no notable reward, no follow-up known yet"
end
function C:Grade(qid)
    Fresh()
    local c = gradeCache[qid]
    if not c then
        local g, why = GradeUncached(qid)
        c = { g, why }
        gradeCache[qid] = c
    end
    return c[1], c[2]
end

-- The yellow star (the raid-marker star: in every client), sized to the text.
C.STAR = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t "

-- The user, 2026-11-07: a grey quest that matters gets a small yellow star in front of its
-- name ("do it and keep it"); a grey quest without one can be abandoned. Not grey: nothing.
function C:Star(qid)
    if not qid or not IsGrey(qid) then return "" end
    return self:Grade(qid) == "keep" and self.STAR or ""
end

-- Important = graded keep (any colour): the Forever zone list stars these.
function C:Important(qid) return qid and self:Grade(qid) == "keep" or false end

-- On a known chain: has a follow-up or comes after another quest.
local function HasPrev(q)
    if not prevOf then
        prevOf = {}
        for _, t in pairs(VQ.ForeverChains or {}) do for b in pairs(t) do prevOf[b] = true end end
        for _, t in pairs(DB()) do for b in pairs(t) do prevOf[b] = true end end
    end
    return prevOf[q] == true
end
function C:InChain(qid)
    Fresh()
    return HasPrev(qid) or next(NextOf(qid)) ~= nil
end

-- WoW Forever's Min / Mid / Max (retail runs on Blizzard's quest-line flags, which
-- Forever doesn't have): which quests to pick up.
--   Min: important ones (dungeon, raid, elite or class quest, a blue or better reward, or
--        a known chain leading to one)
--   Mid: + any quest on a known chain (not dailies / repeatables)
--   Max: every quest
function C:InScope(qid, density)
    density = density or (VQ.Guide and VQ.Guide.Density and VQ.Guide:Density()) or "max"
    if density == "max" then return true end
    if self:Important(qid) then return true end
    if density == "mid" then
        local i = Info(qid)
        return self:InChain(qid) and not (i and i.flags and i.flags:find("[dwr]"))
    end
    return false
end

-- The reason, under a quest's tooltip (grey quests only).
function C:AddTooltip(tt, qid)
    if not qid or not IsGrey(qid) then return end
    local g, why = self:Grade(qid)
    if g == "keep" then
        tt:AddLine(self.STAR .. "Grey, but worth doing and keeping: " .. why, 1, 0.82, 0, true)
    else
        tt:AddLine("Grey, no star: " .. why .. ". Safe to abandon.", 0.6, 0.6, 0.6, true)
    end
end

-- /vq chains: grey quests in your log with their grade, and how many links are known.
function C:List()
    local p = "|cff00c7ffVoidQuest|r "
    local links, shipped = 0, 0
    for _, t in pairs(DB()) do for _ in pairs(t) do links = links + 1 end end
    for _, t in pairs(VQ.ForeverChains or {}) do for _ in pairs(t) do shipped = shipped + 1 end end
    local any = false
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        local qid = info and not info.isHeader and info.questID
        if qid and IsGrey(qid) then
            any = true
            local g, why = self:Grade(qid)
            print(p .. (g == "keep" and "|cff3ddc84keep|r " or "|cff888888low|r ") .. (info.title or qid) .. " - " .. why)
        end
    end
    if not any then print(p .. "no grey quests in your log") end
    -- WoW Forever: how many quests you can pick up here each Min / Mid / Max tier keeps
    local F = VQ.Forever
    local zone = F and F.Active and F:Active() and F:PlayerZone()
    if zone then
        local open, mn, md, names = 0, 0, 0, {}
        for _, e in ipairs(F:ZoneList(zone)) do
            if e.status == "open" then
                open = open + 1
                if self:InScope(e.id, "min") then
                    mn = mn + 1
                    if #names < 6 then names[#names + 1] = e.title end
                end
                if self:InScope(e.id, "mid") then md = md + 1 end
            end
        end
        print(p .. ("%s: %d quests to pick up; Min keeps %d, Mid %d, Max %d"):format(zone, open, mn, md, open))
        if #names > 0 then print(p .. "important: " .. table.concat(names, ", ") .. (mn > #names and ", ..." or "")) end
    end
    print(p .. ("%d chain link%s learned on this account, %d shipped with VoidQuest"):format(
        links, links == 1 and "" or "s", shipped))
end
