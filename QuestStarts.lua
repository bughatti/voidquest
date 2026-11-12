----------------------------------------------------------------------
-- VoidQuest — where quests start, learned from your own play (account-wide)
--
-- The game gives no location for many quest starts: ones that start automatically
-- (an area trigger, a scripted event, the Pile of Rubble that starts "Violent Impact"),
-- ones from an object or item, and low-level ones it hides. So whenever any of your
-- characters accepts a quest, VoidQuest notes where you stood and how it started:
--   npc    -- you were talking to a quest giver (the "npc" unit exists)
--   object -- the quest window was open with no NPC (a board, a poster, an object)
--   auto   -- it just appeared (area trigger, event, item)
-- Every later character gets that spot as a pin. VoidQuestDB.starts[questID] =
-- { m, x, y, how, npc?, id? } (id = the giver's NPC ID). On retail nothing leaves your
-- machine; on WoW Forever NPC givers are shared with other VoidQuest players
-- (ForeverShare.lua: quest, NPC and spot only; /vq share turns it off).
----------------------------------------------------------------------
local VQ = VoidQuest
local S = {}
VQ.Starts = S

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end end
local function Secret(v) return issecretvalue and issecretvalue(v) end
local lastWindow   -- { t, how, npc }: the last quest / gossip window opened

-- Learned on this account first, then the bundled seed (QuestSeed.lua: the same data,
-- collected from the author's own characters by tools/cmd/vq-seed).
-- WoW Forever has its own seed (ForeverSeed.lua, nil on retail): it reuses Classic quest
-- IDs whose givers stand somewhere else on retail's maps.
local function Seed(qid)
    local t = VQ.ForeverSeed or VQ.QuestSeed
    return t and t[qid]
end

-- WoW Forever: a spot other VoidQuest players agree on (ForeverShare.lua), or nil.
local function Heard(qid)
    return VQ.Share and VQ.Share:Best(qid)
end

function S:Get(qid)
    if not qid then return nil end
    local own = VoidQuestDB and VoidQuestDB.starts and VoidQuestDB.starts[qid]
    if own then return own end
    local s = Seed(qid)
    if s and s.m then return { m = s.m, x = s.x, y = s.y, how = s.how } end
    local h = Heard(qid)
    if h then return { m = h.m, x = h.x, y = h.y, how = "npc", shared = true } end
end

-- Who gives / takes a quest: learned names (CampaignGuide's npcs table, this file's
-- starts), else the seed. nil when nobody has met them yet.
function S:Giver(qid)
    if not qid then return nil end
    local n = VoidQuestDB and VoidQuestDB.npcs and VoidQuestDB.npcs[qid]
    local st = VoidQuestDB and VoidQuestDB.starts and VoidQuestDB.starts[qid]
    local s = Seed(qid)
    local h = not (n and n.giver) and not (st and st.npc) and not (s and s.giver) and Heard(qid)
    return (n and n.giver) or (st and st.npc) or (s and s.giver) or (h and h.npc)
end
-- Where a quest is handed in: where you stood at its turn-in window (CampaignGuide records it), else
-- the seed's (NorgannonDB finisher NPC or object, tools/cmd/vq-seed). -> { m, x, y } or nil
function S:TurninSpot(qid)
    if not qid then return nil end
    local n = VoidQuestDB and VoidQuestDB.npcs and VoidQuestDB.npcs[qid]
    if n and n.tm and n.tx then return { m = n.tm, x = n.tx, y = n.ty } end
    local s = Seed(qid)
    if s and s.tm and s.tx then return { m = s.tm, x = s.tx, y = s.ty } end
end
function S:Turnin(qid)
    if not qid then return nil end
    local n = VoidQuestDB and VoidQuestDB.npcs and VoidQuestDB.npcs[qid]
    local s = Seed(qid)
    return (n and n.turnin) or (s and s.turnin)
end

-- Where an accepted quest came from: the quest window that showed THIS quest (matched by
-- its ID, so a slow read or a quest that pops up right after talking to someone doesn't
-- get the wrong origin). Without an ID (rare), the last window within 15 s, unless the
-- last quest window was for a different quest.
local lastDetail   -- { qid, t, how, npc, id, shared }: the last QUEST_DETAIL window
local function Origin(qid)
    local now = GetTime()
    if lastDetail and lastDetail.qid == qid and now - lastDetail.t < 300 then return lastDetail end
    if lastDetail and lastDetail.qid and lastDetail.qid ~= qid and now - lastDetail.t < 15 then return nil end
    if lastWindow and now - lastWindow.t < 15 then return lastWindow end
end

local function Learn(qid)
    if not (qid and VoidQuestDB) then return end
    VoidQuestDB.starts = VoidQuestDB.starts or {}
    local recent = Origin(qid)
    if recent and recent.shared then return end   -- shared by a party member: not where it starts
    local have = VoidQuestDB.starts[qid]
    -- first sighting wins, except that a real giver beats an earlier "auto"
    if have and not (have.how == "auto" and recent and recent.how == "npc") then return end
    local m = safe(C_Map.GetBestMapForUnit, "player")
    local pos = m and safe(C_Map.GetPlayerMapPosition, m, "player")
    local x, y
    if pos then
        local ok, px, py = pcall(pos.GetXY, pos)
        if ok and px and py and px > 0 and py > 0 then x, y = px, py end
    end
    if not x then return end   -- inside an instance: no usable spot
    -- the quest window that was open just before (the "npc" unit may be gone by now)
    local how, npc, id = "auto", nil, nil
    if recent then how, npc, id = recent.how, recent.npc, recent.id end
    -- t: when it was found. ForeverShare holds a fresh find back (privacy) whether or not
    -- sharing was on at the time, so turning sharing on later can't give it away early.
    VoidQuestDB.starts[qid] = { m = m, x = x, y = y, how = how, npc = npc, id = id, t = time() }
    if VQ.Share and how == "npc" then VQ.Share:Found({ qid }) end
end

-- WoW Forever: the quests an NPC OFFERS are saved too (not only the ones you take), at
-- where you stand. Forever's map shows no "!" for Classic quests and the Blizzard API has
-- no locations, so every giver you talk to fills in its zone's list (ForeverZone.lua).
-- Only real NPCs, only quests with no spot yet; never overwrites an accept-time spot.
-- WoW Forever: the game has no API for a quest's required level, so learn it from what a
-- giver offers. ids = the FULL list this NPC offers you now (gossip / greeting window).
--   offered -> VoidQuestDB.offerLevel[q] = lowest level any of your characters saw it at
--              (account-wide; the seed can carry it) and it's no longer blocked here.
--   one of this NPC's known quests NOT offered (not done, not in your log) -> blocked for
--              this character at this level (VoidQuestCharDB.blocked[q]): too low, or an
--              earlier quest first. ForeverZone keeps it off the map until you level past it.
-- Low-level ("gray") quests are hidden from offers unless Low-Level Quests tracking is on,
-- so only a quest whose level is KNOWN and not gray can be marked blocked (the game's own
-- gray line: C_QuestLog.IsQuestTrivial / UnitQuestTrivialLevelRange).
-- complete = ids is the NPC's whole offer list (gossip / greeting). A single quest window
-- (QUEST_DETAIL) only counts as "offered", never as "the others aren't".
local function Gray(q, ql, lvl)
    local t = safe(C_QuestLog.IsQuestTrivial, q)
    if t ~= nil and not Secret(t) then return t and true or false end
    local range = safe(UnitQuestTrivialLevelRange, "player") or 5
    return lvl - ql > range
end
-- Returns true when what's available changed (the zone list / map need a redraw).
local function LearnLevels(npc, ids, complete)
    if not (VQ.ForeverQuests and npc and VoidQuestDB and VoidQuestCharDB) then return false end
    local lvl = UnitLevel("player") or 0
    if lvl <= 0 then return false end
    VoidQuestDB.offerLevel = VoidQuestDB.offerLevel or {}
    VoidQuestCharDB.blocked = VoidQuestCharDB.blocked or {}
    local offered, changed = {}, false
    for _, q in ipairs(ids) do
        if type(q) == "number" and q > 0 and not Secret(q) then
            offered[q] = true
            local seen = VoidQuestDB.offerLevel[q]
            if not seen or lvl < seen then VoidQuestDB.offerLevel[q] = lvl; changed = true end
            if VoidQuestCharDB.blocked[q] then VoidQuestCharDB.blocked[q] = nil; changed = true end
        end
    end
    if not complete then return changed end
    local F = VQ.Forever
    for q, r in pairs(VQ.ForeverQuests) do
        if not offered[q] and S:Giver(q) == npc and (not F or F:Eligible(r))
            and not safe(C_QuestLog.IsQuestFlaggedCompleted, q) and not safe(C_QuestLog.GetLogIndexForQuestID, q) then
            -- level still loading (0) = can't tell gray from blocked: learn nothing this time
            local ql = F and F:Level(q) or 0
            if ql > 0 and not Gray(q, ql, lvl) and VoidQuestCharDB.blocked[q] ~= lvl then
                VoidQuestCharDB.blocked[q] = lvl
                changed = true
            end
        end
    end
    return changed
end

-- Finishing a quest can unlock the next one in a chain. A block on a quest that isn't
-- above your level was most likely waiting on an earlier quest, so turning one in clears
-- those (the next visit to its giver learns it again if it's still not offered). Blocks
-- on quests above your level stay: those are waiting on a level.
local function ClearChainBlocks()
    local b = VoidQuestCharDB and VoidQuestCharDB.blocked
    if not (b and VQ.Forever) then return end
    local lvl, any = UnitLevel("player") or 0, false
    for q in pairs(b) do
        local ql = VQ.Forever:Level(q)
        if ql > 0 and ql <= lvl then b[q] = nil; any = true end
    end
    if any and VQ.Forever.Refresh then VQ.Forever:Refresh() end
end

local function LearnOffers(event, npc, npcID)
    if not (VQ.ForeverQuests and npc and VoidQuestDB) then return end
    local ids = {}
    if event == "GOSSIP_SHOW" then
        for _, q in ipairs(safe(C_GossipInfo.GetAvailableQuests) or {}) do ids[#ids + 1] = q.questID end
    elseif event == "QUEST_GREETING" then
        for i = 1, safe(GetNumAvailableQuests) or 0 do
            -- 5th return; safe() keeps only 3, so pcall directly
            local ok, _, _, _, _, q = pcall(GetAvailableQuestInfo, i)
            if ok and q then ids[#ids + 1] = q end
        end
    elseif event == "QUEST_DETAIL" then
        ids[1] = safe(GetQuestID)
    end
    -- levels first: they don't need a map position (only the start spot below does)
    if LearnLevels(npc, ids, event ~= "QUEST_DETAIL") and VQ.Forever and VQ.Forever.Refresh then
        VQ.Forever:Refresh()
    end
    local m = safe(C_Map.GetBestMapForUnit, "player")
    local pos = m and safe(C_Map.GetPlayerMapPosition, m, "player")
    local ok, x, y
    if pos then ok, x, y = pcall(pos.GetXY, pos) end
    if not (ok and x and y and x > 0 and y > 0) then return end
    VoidQuestDB.starts = VoidQuestDB.starts or {}
    local new = {}
    for _, q in ipairs(ids) do
        local have = type(q) == "number" and q > 0 and not Secret(q) and VoidQuestDB.starts[q]
        if type(q) == "number" and q > 0 and not Secret(q) and not have then
            VoidQuestDB.starts[q] = { m = m, x = x, y = y, how = "npc", npc = npc, id = npcID, seen = true, t = time() }
            new[#new + 1] = q
        elseif have and have.how == "npc" and have.npc == npc and not have.id and npcID then
            have.id = npcID   -- older capture from before NPC IDs were kept: now shareable
            new[#new + 1] = q
        end
    end
    if #new > 0 then
        if VQ.Forever and VQ.Forever.Refresh then VQ.Forever:Refresh() end
        if VQ.Share then VQ.Share:Found(new) end
    end
end

-- The NPC ID from a unit's GUID ("Creature-0-...-<npcID>-..."), or nil. Only creatures:
-- players, pets and objects have none.
local function NpcID(unit)
    local guid = UnitGUID(unit)
    if not guid or Secret(guid) then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind ~= "Creature" then return nil end
    return tonumber(id)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "QUEST_ACCEPTED", "QUEST_DETAIL", "QUEST_GREETING", "GOSSIP_SHOW", "QUEST_TURNED_IN" }) do ev:RegisterEvent(e) end
ev:SetScript("OnEvent", function(_, event, qid)
    if event == "QUEST_ACCEPTED" then
        if type(qid) == "number" and not Secret(qid) then Learn(qid) end
        return
    end
    if event == "QUEST_TURNED_IN" then ClearChainBlocks(); return end
    -- a party member sharing a quest shows the quest window with THEM as "npc"; never
    -- keep a player's name
    local shared = UnitExists("npc") and UnitIsPlayer("npc") or false
    local n = not shared and UnitExists("npc") and UnitName("npc")
    if n and Secret(n) then n = nil end
    local id = n and NpcID("npc") or nil
    lastWindow = { t = GetTime(), how = n and "npc" or "object", npc = n or nil, id = id, shared = shared }
    if event == "QUEST_DETAIL" then
        local q = safe(GetQuestID)
        if type(q) == "number" and q > 0 and not Secret(q) then
            lastDetail = { qid = q, t = lastWindow.t, how = lastWindow.how, npc = lastWindow.npc, id = id, shared = shared }
        end
    end
    if n then LearnOffers(event, n, id) end
end)
