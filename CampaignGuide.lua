----------------------------------------------------------------------
-- VoidQuest Campaign Guide
--
-- DYNAMIC campaign stepper. Reads the player's active campaign live from
-- C_CampaignInfo / C_QuestLine and walks the quest chain -- so it works on
-- brand-new content the moment it ships (Glint of History / Curse of Ula'tek),
-- where hand-written guides dead-end. No static database.
--
-- Waypoint lesson (validated 2026-08-12): C_QuestLog.GetNextWaypointText returns
-- unreliable generic routing ("take the portal to Stormwind") for out-of-zone /
-- stale quests -- so we ONLY guide the ACTIVE CAMPAIGN, and prefer real POI coords
-- (GetNextWaypoint) falling back to the quest line's own x/y.
----------------------------------------------------------------------
local _, ns = ...   -- ns.Route: this addon's own waypoint router (Route.lua)
local VQ = VoidQuest
local mod = VQ:NewModule("CampaignGuide")
VQ.Guide = mod

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end end

-- The guide panel holds a secure quest-item button, which makes the panel itself
-- protected in combat: SetHeight there is ADDON_ACTION_BLOCKED (BugGrabber, 2026-10-25).
-- Skip it then; the PLAYER_REGEN_ENABLED refresh sets the right height.
-- The buttons (Book, Zone, Lines, density, gear, tracker box) sit in a row along the panel's
-- BOTTOM (the user, 2026-11-10: "put buttons at bottom and let them move when the box is
-- readjusted"), pinned to the bottom edge. Every height below is the content's; PanelHeight
-- adds this footer, and PanelBudget (the saved height) takes it off.
local FOOTER = 24
local function PanelHeight(f, h)
    if InCombatLockdown() and f:IsProtected() then return end
    if f._sizing then return end   -- the player is dragging the corner: their height wins
    f:SetHeight(h + FOOTER)
end
-- Panel width (drag the corner grip; setting panelWidth) and the content width inside it.
-- Every row reads CW(), and texts cut to fit scale with it (truncTo).
local PANEL_W_MIN, PANEL_W_MAX = 260, 640
local function PW() return math.max(PANEL_W_MIN, math.min(PANEL_W_MAX, VQ:Get("panelWidth") or 300)) end
local function CW() return PW() - 16 end
-- Same for Show / Hide (BugGrabber 2026-10-25: Show() blocked in combat). The panel
-- is already in that state when shown mid-fight; a refresh after combat catches up.
local function PanelShown(f, on)
    if InCombatLockdown() and f:IsProtected() then return end
    f:SetShown(on)
end
-- In an instance (dungeon, delve, Labyrinth, raid)? Blizzard's tracker carries the
-- M+ timer and stage objectives there, so it defaults on (see ApplyBlizzTracker).
-- Only where the stage objectives live in Blizzard's tracker: a scenario (delves, the
-- Labyrinth, retail dungeons). A Classic dungeon on WoW Forever has none, and bringing
-- the tracker back there just stacked it on our panel (Shadowfang Keep, 2026-11-07).
local function blizzTrackerNeeded()
    local inInst, instType = IsInInstance()
    if not (inInst and instType ~= "none") then return false end
    local S = C_Scenario
    if S and S.IsInScenario then
        local ok, yes = pcall(S.IsInScenario)
        if ok then return yes and true or false end
    end
    return true
end

-- ===== Campaign Focus (lock to ONE campaign; strict scoping so other campaigns never
-- bleed in). lockedCampID + learned per-campaign questline set live per-character. =====
function mod:LockedCampID() return VoidQuestCharDB and VoidQuestCharDB.lockedCampID end
function mod:LockCampaign(campID)
    VoidQuestCharDB = VoidQuestCharDB or {}
    VoidQuestCharDB.lockedCampID = campID   -- nil = Auto (follow first campaign found)
    VoidQuestCharDB.zoneGuide = nil         -- picking a campaign means "follow the campaign"
    self._lastStep = nil
    self:Refresh()
    if self.picker and self.picker:IsShown() then self:RefreshPicker() end
end

-- Every campaign the player can SELECT: the ones with quests in the log,
-- plus C_CampaignInfo.GetAvailableCampaigns() (campaigns offered but maybe not started).
-- Returns { [campID]={name,state} } + ordered ids (in-log first, then available).
function mod:SelectableCampaigns()
    local out, order = {}, {}
    local function add(c)
        if c and c ~= 0 and not out[c] then
            local ci = safe(C_CampaignInfo.GetCampaignInfo, c)
            if ci and ci.name and ci.name ~= "" then
                out[c] = { name = ci.name, state = safe(C_CampaignInfo.GetState, c) }
                order[#order + 1] = c
            end
        end
    end
    add(self:LockedCampID())   -- the campaign you're following is always listed
    local _, activeOrder = self:ActiveCampaigns()
    for _, c in ipairs(activeOrder) do add(c) end
    for _, c in ipairs(safe(C_CampaignInfo.GetAvailableCampaigns) or {}) do add(c) end
    return out, order
end

-- EVERY campaign the game has data for on this char (probe IDs), not just the "available"
-- few. Cached per session. Sorted: in-progress, then not-started, then done; name within.
function mod:AllCampaigns()
    -- Only the expensive part is cached: probing 2600 IDs for which ones EXIST (names are
    -- static). States (in progress / stalled / done) are re-read on every call, so finishing
    -- or starting a campaign shows up the next time the picker opens -- no /reload needed.
    if not self._campNames then
        local names = {}
        for id = 1, 2600 do
            local ci = safe(C_CampaignInfo.GetCampaignInfo, id)
            local nm = ci and ci.name
            -- skip dev/test placeholders ("(DNT)" = Do Not Touch) and blanks
            if nm and nm ~= "" and not nm:find("DNT", 1, true) then names[#names + 1] = { id = id, name = nm } end
        end
        self._campNames = names
    end
    -- CampaignState enum: 0=Invalid(not started), 1=Complete, 2=InProgress, 3=Stalled
    -- (started but blocked, e.g. raid-gated). Blizzard's data has MANY duplicate records
    -- per name (faction variants, revamps: "Curse of Ula'tek" x2, "Azure Span" x5...) ->
    -- DEDUPE by name keeping the copy most relevant to this char:
    -- InProgress > Stalled > Complete > not-started; lower id on ties (older = live record).
    -- A record this char has ANY progress on (even Complete) is the real one; an untouched
    -- same-name copy is a faction/revamp phantom. (Ranking not-started above Complete hid
    -- Vede's finished "Curse of Ula'tek" 324 behind phantom 332.) Sort order (below) still
    -- floats not-started above done -- this rank is only for picking which duplicate to keep.
    local rank = { [2] = 0, [3] = 1, [1] = 2, [0] = 3 }
    local locked = self:LockedCampID()
    local map, order, byName = {}, {}, {}
    for _, rec in ipairs(self._campNames) do
        local id, nm = rec.id, rec.name
        do
            local state = safe(C_CampaignInfo.GetState, id) or 0
            local key = nm:lower()
            local held = byName[key]
            -- the campaign you're following always wins its name slot
            local better = held and ((id == locked) or (held ~= locked
                and (rank[state] or 3) < (rank[map[held].state] or 3)))
            if not held or better then
                if held then map[held] = nil end   -- replaced by a better-ranked duplicate
                byName[key] = id
                map[id] = { name = nm, state = state }
            end
        end
    end
    for _, id in pairs(byName) do order[#order + 1] = id end
    local srank = { [2] = 0, [3] = 1, [0] = 2, [1] = 3 }   -- display: active, available, then done
    table.sort(order, function(a, b)
        local ra, rb = srank[map[a].state] or 2, srank[map[b].state] or 2
        if ra ~= rb then return ra < rb end
        return (map[a].name or "") < (map[b].name or "")
    end)
    return map, order
end

-- Expansion classification by NAME (the API has no expansion field, and campaign IDs are
-- NOT chronological -- Legion 275-303 comes after TWW 236-242). Name signals are reliable
-- and auto-handle future campaigns. Utility/skip campaigns (intro skips, tutorials, catch-up,
-- test) return nil and are hidden. Rules are LOWERCASE substrings, checked in order; the
-- expansion blocks are ordered newest->oldest so ambiguous names resolve to the newer one.
local CAMP_SKIP = {
    "skip", "jump to chapter", "intro start", "tutorials", "testing", "test", "onboarding",
    "passport control", "catching up", "catch up", "laura",
}
local EXPANSION_ORDER = {
    "Midnight", "The War Within", "Dragonflight", "Shadowlands",
    "Battle for Azeroth", "Legion", "Mists of Pandaria", "Leveling", "Other",
}
local EXPANSION_RULES = {
    -- Midnight (12.x)
    { "ula'tek", "Midnight" }, { "call of the void", "Midnight" }, { "12.0", "Midnight" },
    { "arator", "Midnight" }, { "war of light and shadow", "Midnight" }, { "eversong", "Midnight" },
    { "naigtal", "Midnight" }, { "sunstrider", "Midnight" }, { "empowered folio", "Midnight" },
    { "lorewalking", "Midnight" }, { "ecological succession", "Midnight" }, { "welcome to val", "Midnight" },
    { "knife's edge", "Midnight" }, { "promise of tomorrow", "Midnight" }, { "midnight", "Midnight" },
    -- The War Within (11.x)
    { "siren isle", "The War Within" }, { "war within", "The War Within" }, { "isle of dorn", "The War Within" },
    { "ringing deeps", "The War Within" }, { "hallowfall", "The War Within" }, { "azj-kahet", "The War Within" },
    { "dark heart", "The War Within" }, { "harbinger", "The War Within" }, { "undermine", "The War Within" },
    { "kirin tor", "The War Within" }, { "xal'atath", "The War Within" }, { "red dawn", "The War Within" },
    { "ethereals", "The War Within" }, { "shadowed sun", "The War Within" },
    -- Dragonflight (10.x)
    { "dragonflight", "Dragonflight" }, { "dracthyr", "Dragonflight" }, { "waking shores", "Dragonflight" },
    { "ohn'ahran", "Dragonflight" }, { "azure span", "Dragonflight" }, { "thaldraszus", "Dragonflight" },
    { "valdrakken", "Dragonflight" }, { "tuskarr", "Dragonflight" }, { "neltharion", "Dragonflight" },
    { "zskera", "Dragonflight" }, { "flightstones", "Dragonflight" }, { "obsidian citadel", "Dragonflight" },
    { "dragonscale", "Dragonflight" }, { "oathstone", "Dragonflight" }, { "dreamer", "Dragonflight" },
    { "guardians of the dream", "Dragonflight" }, { "shadowflame", "Dragonflight" }, { "lingering shadows", "Dragonflight" },
    { "silver purpose", "Dragonflight" }, { "iskaara", "Dragonflight" },
    -- Shadowlands (9.x)
    { "covenant", "Shadowlands" }, { "venthyr", "Shadowlands" }, { "night fae", "Shadowlands" },
    { "kyrian", "Shadowlands" }, { "bastion", "Shadowlands" }, { "ardenweald", "Shadowlands" },
    { "revendreth", "Shadowlands" }, { "shadowlands", "Shadowlands" }, { "torghast", "Shadowlands" },
    { "chains of domination", "Shadowlands" }, { "first ones", "Shadowlands" }, { "threads of fate", "Shadowlands" },
    { "primus", "Shadowlands" }, { "looming dark", "Shadowlands" }, { "art of war", "Shadowlands" },
    { "9.0", "Shadowlands" }, { "box of many things", "Shadowlands" },
    -- Battle for Azeroth (8.x)
    { "battle for azeroth", "Battle for Azeroth" }, { "nazjatar", "Battle for Azeroth" },
    { "mechagon", "Battle for Azeroth" }, { "n'zoth", "Battle for Azeroth" }, { "visions of azeroth", "Battle for Azeroth" },
    { "war campaign", "Battle for Azeroth" }, { "arathi highlands", "Battle for Azeroth" },
    -- Legion (7.x)
    { "order hall", "Legion" }, { "legionfall", "Legion" }, { "legion", "Legion" }, { "argus", "Legion" },
    { "nightfallen", "Legion" }, { "insurrection", "Legion" }, { "val'sharah", "Legion" },
    { "highmountain", "Legion" }, { "stormheim", "Legion" }, { "azsuna", "Legion" }, { "suramar", "Legion" },
    -- Mists of Pandaria (5.x)
    { "pandaria", "Mists of Pandaria" }, { "landfall", "Mists of Pandaria" }, { "thunder king", "Mists of Pandaria" },
    { "siege of orgrimmar", "Mists of Pandaria" }, { "escalation", "Mists of Pandaria" },
    -- neutral leveling
    { "exile's reach", "Leveling" },
}

-- Fallback when no NAME rule matches: WHERE the campaign takes place. Walk its first
-- chapter's start map up through its parent maps (zone -> region -> continent) and match
-- place names, which change far less than campaign names (a new 12.2 campaign set in
-- Quel'Thalas classifies itself). Lowercase substrings, newest expansion first.
local PLACE_RULES = {
    { "quel'thalas", "Midnight" }, { "eversong", "Midnight" }, { "silvermoon", "Midnight" },
    { "zul'aman", "Midnight" }, { "harandar", "Midnight" }, { "voidstorm", "Midnight" },
    { "coiled isle", "Midnight" }, { "atal'utek", "Midnight" },
    { "khaz algar", "The War Within" }, { "isle of dorn", "The War Within" }, { "siren isle", "The War Within" },
    { "undermine", "The War Within" }, { "k'aresh", "The War Within" }, { "ringing deeps", "The War Within" },
    { "dragon isles", "Dragonflight" }, { "zaralek", "Dragonflight" }, { "emerald dream", "Dragonflight" },
    { "shadowlands", "Shadowlands" }, { "zereth mortis", "Shadowlands" }, { "the maw", "Shadowlands" },
    { "kul tiras", "Battle for Azeroth" }, { "zandalar", "Battle for Azeroth" }, { "nazjatar", "Battle for Azeroth" },
    { "mechagon", "Battle for Azeroth" },
    { "broken isles", "Legion" }, { "argus", "Legion" },
    { "pandaria", "Mists of Pandaria" },
}
function mod:CampaignPlaceExpansion(campID)
    if not campID then return nil end
    self._placeExp = self._placeExp or {}
    if self._placeExp[campID] ~= nil then return self._placeExp[campID] or nil end
    local found = false
    local pmap = safe(C_Map.GetBestMapForUnit, "player") or 0
    for _, ch in ipairs(safe(C_CampaignInfo.GetChapterIDs, campID) or {}) do
        local q = (safe(C_QuestLine.GetQuestLineQuests, ch) or {})[1]
        local m = q and (safe(GetQuestUiMapID, q) or 0)
        if q and (not m or m == 0) then
            local ql = safe(C_QuestLine.GetQuestLineInfo, q, pmap)
            m = ql and ql.startMapID
        end
        local hops = 0
        while m and m > 0 and hops < 8 and not found do
            local mi = safe(C_Map.GetMapInfo, m)
            if not mi then break end
            local low = (mi.name or ""):lower()
            for _, rule in ipairs(PLACE_RULES) do
                if low:find(rule[1], 1, true) then found = rule[2]; break end
            end
            m, hops = mi.parentMapID, hops + 1
        end
        if found then break end
    end
    self._placeExp[campID] = found   -- false = looked, nothing matched (don't re-probe)
    return found or nil
end

function mod:CampaignExpansion(name, campID)
    if not name then return nil end
    local low = name:lower()
    for _, s in ipairs(CAMP_SKIP) do if low:find(s, 1, true) then return nil end end
    for _, rule in ipairs(EXPANSION_RULES) do
        if low:find(rule[1], 1, true) then return rule[2] end
    end
    return self:CampaignPlaceExpansion(campID) or "Other"
end

-- Diagnostic: dump the LOCKED (or first active) campaign's full chapter chains with
-- per-quest status -- done / live(has data) / dead(no data) + titles. `/vq chain`.
function mod:DumpChain()
    local campID = self:LockedCampID()
    if not campID then campID = (self:ActiveCampaigns()) and select(2, self:ActiveCampaigns())[1] end
    if not campID then VQ:ShowCopy("VoidQuest — Chain", "no campaign locked/active"); return end
    local ci = safe(C_CampaignInfo.GetCampaignInfo, campID)
    local out = { ("campaign %d %s"):format(campID, (ci and ci.name) or "?"),
                  ("currentChapter=%s"):format(tostring(safe(C_CampaignInfo.GetCurrentChapterID, campID))) }
    for _, chID in ipairs(safe(C_CampaignInfo.GetChapterIDs, campID) or {}) do
        local chi = safe(C_CampaignInfo.GetCampaignChapterInfo, chID)
        local chain = safe(C_QuestLine.GetQuestLineQuests, chID) or {}
        out[#out + 1] = ("chapter %d %s (chapterQuestID=%s, chain=%d)"):format(
            chID, (chi and chi.name) or "?", tostring(chi and chi.questID), #chain)
        for i, cq in ipairs(chain) do
            safe(C_QuestLog.RequestLoadQuestByID, cq)
            local done = safe(C_QuestLog.IsQuestFlaggedCompleted, cq)
            local title = safe(C_QuestLog.GetTitleForQuestID, cq)
            local live = safe(HaveQuestData, cq) or (title ~= nil)
            out[#out + 1] = ("  %2d %-7d %s%s %s"):format(i, cq,
                done and "DONE" or "todo", live and "" or " DEAD", title or "")
        end
    end
    VQ:ShowCopy("VoidQuest — Chain dump (paste to Claude)", table.concat(out, "\n"))
end

-- One-time diagnostic: dump every campaign (id, name, state) to the copy-popup so a human
-- can bucket them into expansions (the API has no expansion field). `/vq dumpcampaigns`.
function mod:DumpCampaigns()
    local lines = { "id\tname\tstate" }
    for id = 1, 2600 do
        local ci = safe(C_CampaignInfo.GetCampaignInfo, id)
        local nm = ci and ci.name
        if nm and nm ~= "" then
            lines[#lines + 1] = ("%d\t%s\t%d"):format(id, nm, safe(C_CampaignInfo.GetState, id) or 0)
        end
    end
    lines[#lines + 1] = ("-- total: %d"):format(#lines - 1)
    VQ:ShowCopy("VoidQuest — All Campaigns (copy & paste this to me)", table.concat(lines, "\n"))
end

-- Entry-point quest for a campaign that may NOT be in the log yet: the current chapter's
-- quest, else the first not-completed chapter's quest (chapters expose a questID even when
-- unstarted). GetQuestLineInfo on it resolves the chain so Compute can guide from scratch.
function mod:CampaignChapterAnchor(campID)
    if not campID then return nil end
    local function chapQ(chID)
        local ci = chID and safe(C_CampaignInfo.GetCampaignChapterInfo, chID)
        return ci and ci.questID
    end
    local cur = safe(C_CampaignInfo.GetCurrentChapterID, campID)
    local q = chapQ(cur)
    if q then return q end
    local chapters = safe(C_CampaignInfo.GetChapterIDs, campID) or {}
    for _, chID in ipairs(chapters) do
        local cq = chapQ(chID)
        if cq and not safe(C_QuestLog.IsQuestFlaggedCompleted, cq) then return cq end
    end
    -- Chapters often carry NO questID. But chapter IDs frequently double as QUESTLINE ids
    -- (e.g. The Battle for Atal'Utek: chapter 6232 == questline 6232) -> probe each chapter
    -- as a questline and take the first not-completed quest in its chain. Current chapter
    -- first, then the rest in order. This is what finds "The Venomous Abyss" (93418) when
    -- the whole campaign sits at the raid gate with nothing in the log.
    local probeOrder = {}
    if cur then probeOrder[#probeOrder + 1] = cur end
    for _, chID in ipairs(chapters) do
        if chID ~= cur then probeOrder[#probeOrder + 1] = chID end
    end
    -- FRONTIER + LIVENESS: chains contain never-flagged PHANTOM variants (skipped intro
    -- paths -- e.g. 98541 at the head of Legacy of the Amani). Resume AFTER the last
    -- completed quest, and prefer candidates the client has real data for (phantoms have
    -- no title/map/data). A data-less candidate is kept only as a last-resort fallback.
    -- Chains are NOT linear: side/activity quests later in a chain can be DONE while the
    -- story quest earlier in it is still open (Battle for Atal'Utek: idx 5/6/8 done, idx 3
    -- "The Venomous Abyss" open). And chains carry DEAD phantom variants (no client data).
    -- Rule: campaign-forward, take the FIRST chapter's first LIVE not-done quest, wherever
    -- it sits in the chain. Dead-only candidates are a last resort (latest progressed
    -- chapter preferred).
    local weak
    for _, chID in ipairs(probeOrder) do
        local chain = safe(C_QuestLine.GetQuestLineQuests, chID) or {}
        local doneCount, todoCount, liveTodo, deadTodo, firstTodoIdx = 0, 0, nil, nil, nil
        for i, cq in ipairs(chain) do
            if safe(C_QuestLog.IsQuestFlaggedCompleted, cq) then
                doneCount = doneCount + 1
            elseif cq then
                todoCount = todoCount + 1
                firstTodoIdx = firstTodoIdx or i
                safe(C_QuestLog.RequestLoadQuestByID, cq)
                if not liveTodo and (safe(HaveQuestData, cq) or safe(C_QuestLog.GetTitleForQuestID, cq)
                   or (safe(GetQuestUiMapID, cq) or 0) > 0) then
                    liveTodo = cq
                end
                deadTodo = deadTodo or cq
            end
        end
        -- STALE-BREADCRUMB DEMOTION: a single not-done quest at the HEAD of an otherwise
        -- fully-completed chapter (e.g. "Return to Amani'Zar" as idx 1 of a 17/18-done
        -- chapter) is a skipped intro variant, not the player's frontier -- don't present
        -- it as the next step; keep only as last-resort fallback.
        local stale = (todoCount == 1) and (firstTodoIdx == 1) and (doneCount >= #chain - 1)
        if liveTodo and not stale then
            self:LearnQL(campID, chID)
            return liveTodo
        end
        local fallbackQ = liveTodo or deadTodo
        if fallbackQ and (doneCount > 0 or not weak) then weak = { qid = fallbackQ, chID = chID } end
    end
    if weak then self:LearnQL(campID, weak.chID); return weak.qid end
    return chapQ(chapters[1])
end

-- Distinct active campaigns in the log -> { [campID]={name,anchorQuest} }, plus ordered ids.
function mod:ActiveCampaigns()
    local out, order = {}, {}
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        if info and not info.isHeader and info.questID then
            local c = safe(C_CampaignInfo.GetCampaignID, info.questID)
            if c and c ~= 0 and not out[c] then
                local ci = safe(C_CampaignInfo.GetCampaignInfo, c)
                out[c] = { name = (ci and ci.name) or ("Campaign " .. c), anchorQuest = info.questID }
                order[#order + 1] = c
            end
        end
    end
    return out, order
end

-- Learned questlines that belong to a campaign (built as chapters are walked). Lets us
-- verify "same campaign" for un-accepted quests, where GetCampaignID returns 0.
-- A campaign's chapter IDs, as a set. Chapter IDs frequently DOUBLE as questline IDs
-- (Battle for Atal'Utek: chapter 6232 == questline 6232), so this identifies a chapter's
-- questline as belonging to the campaign BEFORE any of its quests is accepted. Static
-- game data -> cached per session.
function mod:ChapterSet(campID)
    if not campID then return {} end
    self._chapSets = self._chapSets or {}
    local s = self._chapSets[campID]
    if not s then
        s = {}
        for _, ch in ipairs(safe(C_CampaignInfo.GetChapterIDs, campID) or {}) do s[ch] = true end
        self._chapSets[campID] = s
    end
    return s
end

function mod:KnownQL(campID, qlID)
    if not (campID and qlID) then return false end
    local m = VoidQuestCharDB and VoidQuestCharDB.campQL and VoidQuestCharDB.campQL[campID]
    if m and m[qlID] then return true end
    return self:ChapterSet(campID)[qlID] and true or false
end

-- Does this questline belong to a DIFFERENT campaign than campID (learned or by chapter
-- list)? Checked against every campaign we know of on this character -- in the log,
-- offered, or followed. A positive answer means "definitely not yours": never suggest it.
function mod:OtherCampaignQL(campID, qlID)
    if not qlID then return false end
    local seen = {}
    local function check(c)
        if not c or c == 0 or c == campID or seen[c] then return false end
        seen[c] = true
        return self:KnownQL(c, qlID)
    end
    local _, active = self:ActiveCampaigns()
    for _, c in ipairs(active) do if check(c) then return true end end
    for _, c in ipairs(safe(C_CampaignInfo.GetAvailableCampaigns) or {}) do if check(c) then return true end end
    for c in pairs((VoidQuestCharDB and VoidQuestCharDB.campQL) or {}) do if check(c) then return true end end
    return false
end
function mod:LearnQL(campID, qlID)
    if not (campID and qlID) then return end
    VoidQuestCharDB = VoidQuestCharDB or {}
    VoidQuestCharDB.campQL = VoidQuestCharDB.campQL or {}
    VoidQuestCharDB.campQL[campID] = VoidQuestCharDB.campQL[campID] or {}
    VoidQuestCharDB.campQL[campID][qlID] = true
end

-- Strict = a lock is set OR more than one campaign is active (ambiguous -> don't let them
-- bleed together). In strict mode we only ever follow/auto-accept the tracked campaign.
function mod:Strict()
    if self:LockedCampID() then return true end
    local _, order = self:ActiveCampaigns()
    return #order > 1
end

-- Find the player's ACTIVE campaign. If LOCKED (Campaign Focus), follow only that one;
-- else the first campaign found in the log (default behaviour).
function mod:ActiveCampaign()
    local locked = self:LockedCampID()
    local firstC, firstQ
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        if info and not info.isHeader and info.questID then
            local c = safe(C_CampaignInfo.GetCampaignID, info.questID)
            if c and c ~= 0 then
                if locked and c == locked then return c, info.questID end
                if not firstC then firstC, firstQ = c, info.questID end
            end
        end
    end
    if locked then
        -- Locked to a campaign with nothing in the log (a SELECTED, not-yet-started campaign,
        -- or a turn-in gap): derive an anchor from its chapters so we can guide it from scratch.
        return locked, self:CampaignChapterAnchor(locked)
    end
    return firstC, firstQ
end

-- Compute the current step: campaign + chapter + the ordered chain + where you are.
function mod:Compute()
    local campID, anchorQuest = self:ActiveCampaign()
    local camp, ql, campName
    if anchorQuest then
        camp = safe(C_CampaignInfo.GetCampaignInfo, campID)
        local map = safe(C_Map.GetBestMapForUnit, "player")
        ql = safe(C_QuestLine.GetQuestLineInfo, anchorQuest, map)
        if ql and ql.questLineID then
            campName = camp and camp.name
            -- cache (PERSISTED) so the chain survives both the turn-in gap and a /reload --
            -- the quest leaves the log the instant it's turned in, before the next accept.
            -- PER-CHARACTER (VoidQuestCharDB): campaign PROGRESS must not bleed across alts --
            -- VoidQuestDB is account-wide, so a shared cache showed Vede's chapter on Murrath.
            VoidQuestCharDB = VoidQuestCharDB or {}
            local entry = {
                ql = { questLineID = ql.questLineID, startMapID = ql.startMapID, questLineName = ql.questLineName },
                campID = campID, campName = campName,
            }
            VoidQuestCharDB.chainCache = entry
            -- also per campaign: a lock must only ever reuse ITS OWN cached chain
            VoidQuestCharDB.chainCacheBy = VoidQuestCharDB.chainCacheBy or {}
            VoidQuestCharDB.chainCacheBy[campID] = entry
            self:LearnQL(campID, ql.questLineID)   -- remember this chapter's line belongs to campID
        end
    end
    -- no anchor quest in the log (just turned one in / right after reload)? use the cache.
    -- When LOCKED, only the locked campaign's own cache qualifies -- the shared chainCache
    -- may hold another campaign's chain (that's how Murrath's panel said "War of Light and
    -- Shadow / Gathering of the Elves" while following Curse of Ula'tek).
    if not (ql and ql.questLineID) then
        local locked = self:LockedCampID()
        local c
        if locked then
            c = VoidQuestCharDB and VoidQuestCharDB.chainCacheBy and VoidQuestCharDB.chainCacheBy[locked]
            if not c then
                local shared = VoidQuestCharDB and VoidQuestCharDB.chainCache
                if shared and shared.campID == locked then c = shared end
            end
        else
            c = VoidQuestCharDB and VoidQuestCharDB.chainCache
        end
        if c and c.ql and c.ql.questLineID then ql, campID, campName = c.ql, c.campID, c.campName end
    end
    -- name always comes from the campaign itself, never a stale cached label
    if campID then
        local ci = safe(C_CampaignInfo.GetCampaignInfo, campID)
        if ci and ci.name and ci.name ~= "" then campName = ci.name end
    end
    if not (ql and ql.questLineID) then
        -- LOCKED FALLBACK: a campaign the user explicitly selected must ALWAYS render,
        -- even with no quest in log, no cache, and no resolvable questline (fresh lock /
        -- post-migration empty cache). Use the chapter anchor as a raw step if we have one.
        local locked = self:LockedCampID()
        if locked then
            local ci = safe(C_CampaignInfo.GetCampaignInfo, locked)
            local cur = safe(C_CampaignInfo.GetCurrentChapterID, locked)
            local chInfo = cur and safe(C_CampaignInfo.GetCampaignChapterInfo, cur)
            local step
            local anchor = anchorQuest or self:CampaignChapterAnchor(locked)
            if anchor then
                safe(C_QuestLog.RequestLoadQuestByID, anchor)
                local inLog = safe(C_QuestLog.GetLogIndexForQuestID, anchor)
                step = {
                    qid = anchor, idx = 0, total = 0,
                    status = inLog and (safe(C_QuestLog.IsComplete, anchor) and "turnin" or "progress") or "pickup",
                    title = safe(C_QuestLog.GetTitleForQuestID, anchor),
                }
            end
            return {
                campID = locked, campName = (ci and ci.name) or "Campaign",
                chapter = (chInfo and chInfo.name) or "", ql = nil, chain = {},
                step = step, lockedNoData = (not step) or nil,
            }
        end
        return nil, "no campaign/questline"
    end
    local chain = safe(C_QuestLine.GetQuestLineQuests, ql.questLineID) or {}
    local chapterName = ql and ql.questLineName

    -- Priority: (1) a chain quest IN YOUR LOG = what you're doing; (2) anchor fallback;
    -- (3) turn-in gap -> MAP-discover the next AVAILABLE campaign quest (the map knows what's
    -- obtainable NOW; the chain's early entries can be unobtainable phantoms); (4) only then
    -- the chain frontier. This kills the "1/18 pick up, gated" phantom both mid-chapter and
    -- in the turn-in gap.
    local step, lastDone = nil, 0
    for idx, qid in ipairs(chain) do
        if safe(C_QuestLog.IsQuestFlaggedCompleted, qid) then
            lastDone = idx
        elseif not step and safe(C_QuestLog.GetLogIndexForQuestID, qid) then
            step = {
                qid = qid, idx = idx, total = #chain,
                status = safe(C_QuestLog.IsComplete, qid) and "turnin" or "progress",
                title = safe(C_QuestLog.GetTitleForQuestID, qid),
            }
        end
    end
    -- (2) ANCHOR FALLBACK: an in-log campaign quest the chain doesn't list.
    if not step and anchorQuest and safe(C_QuestLog.GetLogIndexForQuestID, anchorQuest)
       and not safe(C_QuestLog.IsQuestFlaggedCompleted, anchorQuest) then
        local aidx
        for i, q in ipairs(chain) do if q == anchorQuest then aidx = i; break end end
        step = {
            qid = anchorQuest, idx = aidx or 1, total = #chain,
            status = safe(C_QuestLog.IsComplete, anchorQuest) and "turnin" or "progress",
            title = safe(C_QuestLog.GetTitleForQuestID, anchorQuest),
        }
    end
    -- (3) TURN-IN GAP / chain done: nothing in the log. Discover the next AVAILABLE campaign
    -- quest from the map (giver present, native isCampaign + x/y). Works for the next quest
    -- in THIS chapter and the cross-chapter hand-off alike.
    if not step then
        local nx, unverified = self:NextCampaignPickup(campID)
        if nx then
            local crossChapter = nx.questLineID ~= ql.questLineID
            step = {
                qid = nx.questID, idx = 0, total = 0, status = "pickup", nextChapter = crossChapter or nil,
                unverified = unverified or nil,
                title = (nx.questName ~= "" and nx.questName) or nx.questLineName,
                wpMap = safe(C_Map.GetBestMapForUnit, "player"), wpX = nx.x, wpY = nx.y,
            }
            if crossChapter then chapterName = ("Next: |cffffd200%s|r"):format(nx.questLineName or "?") end
        end
    end
    -- (4) FRONTIER pickup: still nothing available on the map -> the next not-completed chain
    -- quest AFTER the last one you've completed (skip early bypassed phantoms). May be
    -- giver-less (shows a gated hint) but it's the correct next quest, not chain #1.
    if not step then
        for idx = lastDone + 1, #chain do
            local qid = chain[idx]
            if qid and not safe(C_QuestLog.IsQuestFlaggedCompleted, qid) then
                safe(C_QuestLog.RequestLoadQuestByID, qid)
                step = { qid = qid, idx = idx, total = #chain, status = "pickup",
                         title = safe(C_QuestLog.GetTitleForQuestID, qid) }
                break
            end
        end
    end

    return {
        campID = campID, campName = campName,
        chapter = chapterName, chapterMap = ql and ql.startMapID,
        ql = ql, chain = chain, step = step,
    }
end

-- Cross-chapter discovery: the first AVAILABLE campaign quest on the player's map whose
-- giver is present and that we haven't done/accepted yet. Native isCampaign flag = no
-- static database, works on day-one content the moment the giver spawns.
function mod:NextCampaignPickup(campID)
    local map = safe(C_Map.GetBestMapForUnit, "player")
    if not map then return end
    safe(C_QuestLine.RequestQuestLinesForMap, map)   -- warm cache (async; usually already loaded)
    local strict = self:Strict()
    local unknown = {}
    for _, q in ipairs(safe(C_QuestLine.GetAvailableQuestLines, map) or {}) do
        if q.isCampaign and q.questID
           and not safe(C_QuestLog.IsQuestFlaggedCompleted, q.questID)
           and not safe(C_QuestLog.GetLogIndexForQuestID, q.questID) then   -- not already in log
            if not strict then
                return q, false                                   -- unlocked: any campaign quest
            elseif campID and self:KnownQL(campID, q.questLineID) then
                return q, false                                   -- verified: this campaign's known line
            elseif not self:OtherCampaignQL(campID, q.questLineID) then
                unknown[#unknown + 1] = q                          -- a campaign quest we can't yet verify
            end                                                   -- (else: another campaign's -- never suggest)
        end
    end
    -- STRICT next chapter: its line isn't known until a quest is accepted+verified. If there's
    -- exactly ONE unverified campaign quest, point to it (marked unverified) but DON'T auto-accept
    -- -- accept it manually and VoidQuest learns + adopts it. If several, it's truly ambiguous.
    if strict and #unknown == 1 then return unknown[1], true end
    return nil
end

-- Enumerate every candidate waypoint source for a quest so we can see which one
-- actually returns the OBJECTIVE (not the giver). Diagnostic while we validate.
function mod:WaypointSources(qid, ql)
    local pmap = safe(C_Map.GetBestMapForUnit, "player")
    local out = {}
    -- NOTE: 0 is truthy in Lua, so we must EXPLICITLY reject map 0 / 0,0 coords --
    -- GetQuestLineInfo can return startMapID=0,x=0,y=0 when the data isn't loaded yet,
    -- and feeding that to SetUserWaypoint throws "bad argument".
    local function add(name, m, x, y)
        if m and m > 0 and x and y and x > 0 and y > 0 then out[#out+1] = { name = name, m = m, x = x, y = y } end
    end
    local m, x, y = safe(C_QuestLog.GetNextWaypoint, qid);                      add("GetNextWaypoint", m, x, y)
    if pmap then x, y = safe(C_QuestLog.GetNextWaypointForMap, qid, pmap);      add("ForMap(player="..pmap..")", pmap, x, y) end
    if ql and ql.startMapID then x, y = safe(C_QuestLog.GetNextWaypointForMap, qid, ql.startMapID); add("ForMap(start="..ql.startMapID..")", ql.startMapID, x, y) end
    -- quest POI on the current map (the objective marker)
    if pmap and C_QuestLog.GetQuestsOnMap then
        for _, q in ipairs(safe(C_QuestLog.GetQuestsOnMap, pmap) or {}) do
            if q.questID == qid then add("QuestsOnMap-POI", pmap, q.x, q.y) end
        end
    end
    -- fresh questline info for THIS quest -> giver's startMap + x/y. Works from a cached
    -- chain (no x/y stored) AND locates a giver in ANOTHER zone (the current-map sources
    -- above go blank when you're e.g. inside a dungeon but the giver is out in the world).
    local qli = safe(C_QuestLine.GetQuestLineInfo, qid, pmap)
    if qli and qli.x and qli.y then add("questline-info(giver)", qli.startMapID or pmap, qli.x, qli.y) end
    -- the quest's OWN zone map (works for not-in-log quests): ask the questline for its
    -- position on THAT map -- finds cross-zone locations the player-map queries miss.
    local qmap = safe(GetQuestUiMapID, qid)
    if qmap and qmap > 0 and qmap ~= pmap then
        local qli2 = safe(C_QuestLine.GetQuestLineInfo, qid, qmap)
        if qli2 and qli2.x and qli2.y then add("questline-info(questmap)", qli2.startMapID or qmap, qli2.x, qli2.y) end
    end
    if ql and ql.x and ql.y then add("questline-start(giver)", ql.startMapID, ql.x, ql.y) end
    -- offered in your faction's capital -- including the low-level ones the game hides
    -- (isHidden): "The War Within" (78713) sits on Orgrimmar's map hidden for a 76.
    local cap = (UnitFactionGroup("player") == "Alliance") and 84 or 85
    if #out == 0 and cap ~= pmap then
        for _, q in ipairs(safe(C_QuestLine.GetAvailableQuestLines, cap) or {}) do
            if q.questID == qid then add("offered(capital)", cap, q.x, q.y) end
        end
    end
    -- where one of your characters picked it up before (QuestStarts.lua)
    local learned = VQ.Starts and VQ.Starts:Get(qid)
    if learned then add("learned(" .. tostring(learned.how) .. ")", learned.m, learned.x, learned.y) end
    return out
end

-- No location anywhere: say what has to happen first. The quest before it in its chain,
-- or (first quest of a chapter) the chapter before it in the campaign -- e.g. "Violent
-- Impact" starts by itself after the intro chapter ends with "Departure".
function mod:WhyNoLocation(step, g)
    local qid = step and step.qid
    if not qid then return nil end
    local function title(q)
        safe(C_QuestLog.RequestLoadQuestByID, q)
        return safe(C_QuestLog.GetTitleForQuestID, q) or ("quest " .. q)
    end
    local function done(q) return safe(C_QuestLog.IsQuestFlaggedCompleted, q) end
    local chain = g and g.chain or {}
    for i, q in ipairs(chain) do
        if q == qid and i > 1 then
            local prev = chain[i - 1]
            if not done(prev) then
                return ("|cffffaa33Do '%s' first|r -- this one starts after it."):format(title(prev))
            end
            return nil
        end
    end
    -- first quest of its chapter: the previous chapter of the campaign
    local campID = g and g.campID
    local chapters = campID and safe(C_CampaignInfo.GetChapterIDs, campID) or {}
    for ci, chID in ipairs(chapters) do
        local ch = safe(C_QuestLine.GetQuestLineQuests, chID) or {}
        if ch[1] == qid and ci > 1 then
            local prevCh = chapters[ci - 1]
            local pq = safe(C_QuestLine.GetQuestLineQuests, prevCh) or {}
            local last = pq[#pq]
            if last and not done(last) then
                local info = safe(C_CampaignInfo.GetCampaignChapterInfo, prevCh)
                return ("|cffffaa33Finish the chapter '%s' first|r (it ends with '%s') -- this one starts after it."):format(
                    (info and info.name) or "?", title(last))
            end
            return nil
        end
    end
end

-- Availability verification. TRUE = the GAME confirms this quest is presentable right now
-- (it's in your log, or its giver is actively offering it) -- Blizzard never offers a quest
-- whose prerequisites aren't met, so this is a hard guarantee the previous quest was done.
-- NIL = chain order says all prior chain quests are flagged complete, but the game hasn't
-- shown us the giver yet -- present it as PROBABLE, not certain.
function mod:VerifyObtainable(qid)
    if not qid then return nil end
    if safe(C_QuestLog.GetLogIndexForQuestID, qid) then return true end
    local pmap = safe(C_Map.GetBestMapForUnit, "player")
    local qmap = safe(GetQuestUiMapID, qid)
    local tried = {}
    for _, m in ipairs({ qmap, pmap }) do
        if m and m > 0 and not tried[m] then
            tried[m] = true
            safe(C_QuestLine.RequestQuestLinesForMap, m)   -- async warm; confirms on a later refresh
            for _, q in ipairs(safe(C_QuestLine.GetAvailableQuestLines, m) or {}) do
                if q.questID == qid then return true end
            end
        end
    end
    return nil
end

-- Dungeon entrance POIs on a map. The API lives on C_EncounterJournal (it used to be
-- called on C_Map, where it doesn't exist, so this always came back empty).
local function DungeonEntrances(m)
    local fn = (C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap) or C_Map.GetDungeonEntrancesForMap
    return safe(fn, m) or {}
end

-- For a step with no quest giver: find the raid/dungeon ENTRANCE it points into, by
-- matching the step title against entrance POIs (DungeonEntrances) on the
-- quest's map, the player's map, and its parent. "The Venomous Abyss" (quest) matches
-- "The Venomous Abyss" (entrance) -- fully dynamic, no hardcoded locations.
function mod:FindContentEntrance(step)
    local title = step and step.title
    if not title or title == "" then return nil end
    local tlow = title:lower()
    local maps, seen = {}, {}
    local function addMap(m) if m and m > 0 and not seen[m] then seen[m] = true; maps[#maps + 1] = m end end
    addMap(safe(GetQuestUiMapID, step.qid))
    local pmap = safe(C_Map.GetBestMapForUnit, "player")
    addMap(pmap)
    local mi = pmap and safe(C_Map.GetMapInfo, pmap)
    addMap(mi and mi.parentMapID)
    for _, m in ipairs(maps) do
        for _, e in ipairs(DungeonEntrances(m)) do
            local en = e.name and e.name:lower()
            if en and (tlow:find(en, 1, true) or en:find(tlow, 1, true)) then
                local ok, x, y = pcall(function() return e.position:GetXY() end)
                if ok and x then return { m = m, x = x, y = y, name = e.name } end
            end
        end
    end
end

-- Our-pin tracking: remember the waypoint WE placed (+ which quest) so cleanup only
-- ever removes OUR pin, never a waypoint the user set by hand in another addon/map.
function mod:SetOurWaypoint(m, x, y, qid)
    if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint) then return false end
    -- a map that takes no pin: move the spot to a parent map that does (PinnableSpot)
    m, x, y = self:PinnableSpot(m, x, y)
    if not m then self:ClearOurWaypoint(); return false end
    -- Another continent: the arrow can't point there, so pin the portal first
    -- (Route.lua); after the zone change the real target is pinned (see below).
    local hop = ns.Route and ns.Route:Hop(m, x, y)
    if hop then
        local first = not (self._afterHop and self._afterHop.qid == qid)
        self._afterHop = { m = m, x = x, y = y, qid = qid }
        m, x, y = hop.map, hop.x, hop.y
        if first then print(("|cff00ccffVoidQuest|r it's on another continent: first the %s (%s)."):format(hop.name, hop.zone)) end
    else
        self._afterHop = nil
    end
    -- SetUserWaypoint returns nothing, so success = the call didn't error. (It used to be
    -- judged by its return value, which is always nil: the arrow never switched on.)
    self._settingTrack = true
    local ok = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(m, x, y))
    if ok and VQ:Get("superTrack") and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    self._settingTrack = nil
    if not ok then self:ClearOurWaypoint(); return false end
    self._wp = { m = m, x = x, y = y, qid = qid }
    VoidQuestCharDB = VoidQuestCharDB or {}
    VoidQuestCharDB.lastWp = { m = m, x = x, y = y, qid = qid }   -- tell ours from yours after a reload
    self:NoteOurTrack()
    return true
end

-- After taking a portal: pin the real target (or the next portal). Only when the pin
-- out there is still ours, or there is none -- a pin the player set is never replaced.
do
    local hf = CreateFrame("Frame")
    hf:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    hf:SetScript("OnEvent", function()
        C_Timer.After(1, function()
            local t = mod._afterHop
            if not t then return end
            if mod._manual then mod._afterHop = nil; return end   -- the player picked their own arrow
            local cur, wp = safe(C_Map.GetUserWaypoint), mod._wp
            local mine = not cur or (wp and cur.position and cur.uiMapID == wp.m
                and math.abs((cur.position.x or 0) - wp.x) < 0.0005 and math.abs((cur.position.y or 0) - wp.y) < 0.0005)
            if mine then mod:SetOurWaypoint(t.m, t.x, t.y, t.qid) end
        end)
    end)
end

-- Login / reload: the game restores the waypoint. Ours (lastWp) -> adopt it so it can be
-- cleared as ours; anything else is the player's -> hold, so the first refresh can't
-- replace it (Codex review). Runs at PLAYER_ENTERING_WORLD, before the debounced refresh.
function mod:TrackBaseline()
    if self._ourTrack then return end
    local wp = safe(C_Map.GetUserWaypoint)
    local last = VoidQuestCharDB and VoidQuestCharDB.lastWp
    if wp and wp.position then
        local same = last and last.m == wp.uiMapID and math.abs((wp.position.x or 0) - last.x) < 0.0005
            and math.abs((wp.position.y or 0) - last.y) < 0.0005
        if same then
            self._wp = { m = last.m, x = last.x, y = last.y, qid = last.qid, coach = last.coach }
        elseif C_SuperTrack and safe(C_SuperTrack.IsSuperTrackingUserWaypoint) then
            self._manual = true
            self._heldType = Enum and Enum.SuperTrackingType and Enum.SuperTrackingType.UserWaypoint or 1
        end
    end
    -- a dungeon / map-pin target is always the player's: VoidQuest never sets those
    if not self._manual and C_SuperTrack and safe(C_SuperTrack.IsSuperTrackingMapPin) then
        self._manual = true
        self._heldType = Enum and Enum.SuperTrackingType and Enum.SuperTrackingType.MapPin or 6
    end
    self:NoteOurTrack()
end

----------------------------------------------------------------------
-- MANUAL TRACKING HOLD. The guide re-pins whenever its step changes, and while you fly
-- the step changes a lot (nearest quest, side quest, zone border) -- so a pin you set
-- yourself (map click, a dungeon entrance) kept being replaced mid-flight (the player,
-- 2026-10-26: "i have pinned atal aman multiple times and on the flight to it, my arrow
-- changes"). WoW has ONE user waypoint, so ours overwrote theirs outright.
-- Now: any super-track change that isn't ours puts the guide on hold -- it keeps showing
-- steps but never touches the arrow or the waypoint -- until that target is cleared or
-- reached (the game drops it), or you click a line on the panel / the coach button.
----------------------------------------------------------------------
local function TrackState()
    if not C_SuperTrack then return "" end
    local t = safe(C_SuperTrack.GetHighestPrioritySuperTrackingType)
    local _, pinID = safe(C_SuperTrack.GetSuperTrackedMapPin)
    local parts = { tostring(t), tostring(safe(C_SuperTrack.GetSuperTrackedQuestID)),
                    tostring(safe(C_SuperTrack.IsSuperTrackingUserWaypoint)), tostring(pinID) }
    local wp = safe(C_Map.GetUserWaypoint)
    if wp and wp.position then
        parts[#parts + 1] = ("%d:%.4f:%.4f"):format(wp.uiMapID or 0, wp.position.x or 0, wp.position.y or 0)
    end
    return table.concat(parts, "|")
end

-- call right after every super-track / waypoint change VoidQuest makes. _settingTrack
-- covers the change events firing INSIDE our Set* calls (checked synchronously, so a
-- queued refresh can't re-pin before the check runs -- Codex review).
function mod:NoteOurTrack()
    self._ourTrack = TrackState()
    self._ourQuest = C_SuperTrack and safe(C_SuperTrack.GetSuperTrackedQuestID)
end
function mod:OwnTrack(fn, ...)
    self._settingTrack = true
    local ok = pcall(fn, ...)
    self._settingTrack = nil
    self:NoteOurTrack()
    return ok
end

function mod:OnTrackChanged()
    if self._settingTrack then return end             -- fired inside our own call
    if not self._ourTrack then return end             -- before our first pin: login restores
    local qType = Enum and Enum.SuperTrackingType and Enum.SuperTrackingType.Quest or 0
    local anything = C_SuperTrack and safe(C_SuperTrack.IsSuperTrackingAnything)
    local t = anything and safe(C_SuperTrack.GetHighestPrioritySuperTrackingType)
    if self._manual then
        -- release when the held target is gone (reached or cleared): nothing tracked, or
        -- only OUR old quest is left under a held map pin / waypoint (the game keeps it).
        -- A different quest there = the player picked it: still theirs (Codex review).
        local q = t == qType and safe(C_SuperTrack.GetSuperTrackedQuestID)
        if not anything or (t == qType and self._heldType ~= qType and (not q or q == 0 or q == self._ourQuest)) then
            self._manual, self._heldType = nil, nil
            self._lastStep = nil   -- guide again from the current step
            self._ourTrack = TrackState()
            return
        end
        self._heldType = t   -- a new pin of their own: still theirs
        return
    end
    if TrackState() == self._ourTrack then return end -- our own change
    if not anything then self._ourTrack = TrackState(); return end
    -- the game re-targets a quest by itself around turn-ins / accepts: not a manual pick
    if t == qType and self._questEventAt and GetTime() - self._questEventAt < 2 then
        self._ourTrack = TrackState()
        return
    end
    if self:ArrowOn() then   -- with the arrow off it's left alone anyway
        VQ:Print("you set your own pin -- I'll leave the arrow alone until you reach or clear it. Click a line on my panel to go back to my steps.")
    end
    self._manual, self._heldType = true, t
    self._wp = nil   -- the waypoint (if any) is theirs now: never clear it as ours
end

----------------------------------------------------------------------
-- QUESTS INSIDE AN INSTANCE. Halazzi's Lair (2026-10-27) is done and turned in inside
-- the Labyrinth of Kindo'jan. Out in the world the game's quest arrow can't point into
-- the instance: it sent the player 8.2K yds to a field in Silverpine Forest. For those
-- quests we point at the instance's entrance instead.
----------------------------------------------------------------------
local DUNGEON_MAP = (Enum and Enum.UIMapType and Enum.UIMapType.Dungeon) or 4
local ZONE_MAP = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3

-- The instance (Dungeon-type map) a map belongs to: map id + info, or nil.
local function InstanceMapOf(m)
    local mi = m and m > 0 and safe(C_Map.GetMapInfo, m)
    for _ = 1, 6 do
        if not mi then return nil end
        if mi.mapType == DUNGEON_MAP then return m, mi end
        if (mi.mapType or 0) <= ZONE_MAP or not (mi.parentMapID and mi.parentMapID > 0) then return nil end
        m = mi.parentMapID; mi = safe(C_Map.GetMapInfo, m)
    end
end

local function PosXY(v)
    if not v then return nil end
    local ok, x, y = pcall(function() return v:GetXY() end)
    if ok and x and y and x > 0 and y > 0 then return x, y end
end

-- The zone (Zone-type map) a map rolls up to.
local function ZoneOfMap(m)
    local mi = m and m > 0 and safe(C_Map.GetMapInfo, m)
    for _ = 1, 6 do
        if not mi then return nil end
        if Enum.UIMapType and mi.mapType == Enum.UIMapType.Zone then return m end
        m = mi.parentMapID; mi = m and m > 0 and safe(C_Map.GetMapInfo, m)
    end
end

local function NormName(s)
    if not s then return nil end
    s = s:lower():gsub("\226\128\153", ""):gsub("'", "")   -- curly or straight apostrophe
    return (s:gsub("^the ", ""))
end

local function NameMatch(a, b)
    a, b = NormName(a), NormName(b)
    if not a or not b or a == "" or b == "" then return false end
    return a:find(b, 1, true) or b:find(a, 1, true)
end

-- Ways in that the map doesn't mark and the game doesn't show as a crossing (walking in
-- stays on the zone map, same world, so nothing can be learned). Spots stood on in game.
-- Vaults of Atal'Utek: its own map is in another coordinate space, so its place on the
-- Coiled Isle can't be computed (that guess landed across water). Two gates; the west one
-- is the usual way in (the player, 2026-10-27).
local KNOWN_WAYS_IN = {
    { name = "Vaults of Atal'Utek", m = 2512, x = 0.319, y = 0.649, note = "(west gate)" },
}

-- An instance's entrance: a delve / area POI (tracked like a click on the map), or a
-- dungeon entrance, matched by name on the maps around it. Else the spot this account
-- last walked in from (learned on entry, VoidQuestDB.entrances).
function mod:InstanceEntrance(inst, iname)
    local maps, mi = {}, safe(C_Map.GetMapInfo, inst)
    local p = mi and mi.parentMapID
    for _ = 1, 4 do
        if not (p and p > 0) then break end
        maps[#maps + 1] = p
        local pi = safe(C_Map.GetMapInfo, p)
        if not pi or (pi.mapType or 0) <= ((Enum.UIMapType and Enum.UIMapType.Continent) or 2) then break end
        p = pi.parentMapID
    end
    for _, m in ipairs(maps) do
        local ids = {}
        for _, id in ipairs(safe(C_AreaPoiInfo.GetDelvesForMap, m) or {}) do ids[#ids + 1] = id end
        for _, id in ipairs(safe(C_AreaPoiInfo.GetAreaPOIForMap, m) or {}) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do
            local info = safe(C_AreaPoiInfo.GetAreaPOIInfo, m, id)
            if info and NameMatch(info.name, iname) then
                local x, y = PosXY(info.position)
                return { m = m, x = x, y = y, poi = id, name = info.name }
            end
        end
        for _, e in ipairs(DungeonEntrances(m)) do
            local x, y = PosXY(e.position)
            if x and NameMatch(e.name, iname) then return { m = m, x = x, y = y, name = e.name } end
        end
    end
    local l = VoidQuestDB and VoidQuestDB.entrances and VoidQuestDB.entrances[inst]
    if l then return { m = l.m, x = l.x, y = l.y, name = iname, learned = true } end
    for _, s in ipairs(KNOWN_WAYS_IN) do
        if NameMatch(iname, s.name) then return { m = s.m, x = s.x, y = s.y, name = s.name .. " " .. s.note } end
    end
end

-- A spot a map pin can actually go on. Some maps take no pin or arrow (Vaults of Atal'Utek:
-- "pin on Essence of Malice's giver" showed nothing, 2026-10-27), so move the spot up to
-- the first parent map that takes one, converting through world coordinates. A spot
-- inside an instance you're not in becomes its entrance. Returns m, x, y, note -- or nil.
-- The world (continent instance) a map spot lies in: the arrow only crosses within one.
local function WorldOf(m, x, y)
    if not (m and x and y and CreateVector2D) then return nil end
    return (safe(C_Map.GetWorldPosFromMapPos, m, CreateVector2D(x, y)))
end

local function PlayerWorld()
    local here = safe(C_Map.GetBestMapForUnit, "player")
    local hx, hy = PosXY(here and safe(C_Map.GetPlayerMapPosition, here, "player"))
    return WorldOf(here, hx, hy)
end

function mod:PinnableSpot(m, x, y)
    if not (m and m > 0 and x and y) then return nil end
    local inst, imi = InstanceMapOf(m)
    if inst and not (IsInInstance and IsInInstance()) then
        local e = self:InstanceEntrance(inst, imi.name)
        if e and e.x then return e.m, e.x, e.y, "entrance of " .. tostring(imi.name) end
        return nil, ("it's inside %s and I don't know its entrance yet"):format(tostring(imi.name))
    end
    -- a separate area reached through a portal (Vaults of Atal'Utek off the Coiled Isle):
    -- another world, the arrow can't point into it from here -> its way in, if the map shows one
    local myWorld, spotWorld = PlayerWorld(), WorldOf(m, x, y)
    if myWorld and spotWorld and myWorld ~= spotWorld then
        local a = m
        for _ = 1, 4 do
            local ami = safe(C_Map.GetMapInfo, a)
            if not ami then break end
            local e = self:InstanceEntrance(a, ami.name)
            if e and e.x and WorldOf(e.m, e.x, e.y) == myWorld then
                return e.m, e.x, e.y, "way into " .. tostring(ami.name)
            end
            a = ami.parentMapID
            if not (a and a > 0) then break end
        end
        -- No marked or known way in. (Its rectangle on a parent map is NOT a fallback: the
        -- area's map lives in another coordinate space, so for the Vaults it landed across
        -- the water, 2026-10-27.)
        local smi = safe(C_Map.GetMapInfo, m)
        self:PinProbe(m, x, y, myWorld, spotWorld)
        return nil, ("it's in %s, a separate area -- the arrow can't point there from here and I don't know the way in yet. Walk in once and I'll remember it"):format(
            tostring(smi and smi.name))
    end
    local canSet = C_Map.CanSetUserWaypointOnMap
    if not canSet or safe(canSet, m) then return m, x, y end
    local cont, world = safe(C_Map.GetWorldPosFromMapPos, m, CreateVector2D(x, y))
    if not (cont and world) then return nil end
    local a = m
    for _ = 1, 6 do
        local mi = safe(C_Map.GetMapInfo, a)
        a = mi and mi.parentMapID
        if not (a and a > 0) then return nil end
        if safe(canSet, a) then
            local _, pos = safe(C_Map.GetMapPosFromWorldPos, cont, world, a)
            local px, py = PosXY(pos)
            if px and px < 1 and py < 1 then
                local pmi = safe(C_Map.GetMapInfo, a)
                return a, px, py, "on " .. tostring(pmi and pmi.name)
            end
        end
    end
end

-- Diagnostic for a spot we couldn't route to: the map chain, worlds, rects and the POI
-- names on each parent, saved to VoidQuestCharDB.pinProbe.
function mod:PinProbe(m, x, y, myWorld, spotWorld)
    if not VoidQuestCharDB then return end
    local P = { at = date("%Y-%m-%d %H:%M:%S"), spot = ("%s @ %.3f, %.3f"):format(tostring(m), x, y),
        myWorld = tostring(myWorld), spotWorld = tostring(spotWorld), chain = {} }
    local a = m
    for _ = 1, 6 do
        local mi = safe(C_Map.GetMapInfo, a)
        if not mi then break end
        local ok, x1, x2, y1, y2 = pcall(C_Map.GetMapRectOnMap, m, a)
        local pois = {}
        for _, id in ipairs(safe(C_AreaPoiInfo.GetAreaPOIForMap, a) or {}) do
            local info = safe(C_AreaPoiInfo.GetAreaPOIInfo, a, id)
            if info and info.name then pois[#pois + 1] = info.name end
        end
        for _, e in ipairs(DungeonEntrances(a)) do pois[#pois + 1] = "EJ:" .. tostring(e.name) end
        P.chain[#P.chain + 1] = ("%d %s type %s canPin=%s rect=%s pois=[%s]"):format(a, tostring(mi.name),
            tostring(mi.mapType), tostring(safe(C_Map.CanSetUserWaypointOnMap, a)),
            ok and x1 and ("%.3f-%.3f,%.3f-%.3f"):format(x1, x2, y1, y2) or "none", table.concat(pois, "; "))
        a = mi.parentMapID
        if not (a and a > 0) then break end
    end
    VoidQuestCharDB.pinProbe = P
end

-- Pin a spot as the player's own pick (a click in our windows) and turn the arrow on it.
-- Says where it went, or why it couldn't.
function mod:PinForPlayer(m, x, y, label)
    local pm, px, py, note = self:PinnableSpot(m, x, y)
    if not pm then
        VQ:Print(("can't pin %s: %s."):format(label, px or "the game won't take a map pin there"))
        return false
    end
    if not (pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(pm, px, py)) and safe(C_Map.HasUserWaypoint)) then
        VQ:Print(("can't pin %s: the game refused the map pin."):format(label))
        return false
    end
    pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    VQ:Print(("pin on %s%s."):format(label, note and (" (" .. note .. ")") or ""))
    -- the arrow is the game's: if it still shows nothing a moment later, say so
    C_Timer.After(1, function()
        if C_Navigation and C_Navigation.GetFrame and not safe(C_Navigation.GetFrame)
           and safe(C_SuperTrack.IsSuperTrackingUserWaypoint) then
            VQ:Print("the pin is on your map, but the game shows no arrow to it from where you are.")
        end
    end)
    return true
end

-- A quest whose map is an instance you're not in: { inst, name, entrance }, else nil.
-- Open-world areas you only reach through a portal or a teleporting NPC (no instance),
-- with their way in per faction (0-1 coords). Darkmoon Island: the faire's Mystic Mages
-- (warcraft.wiki.gg, 2026-11-01). The game's quest arrow can't point there either.
-- Several ways in per faction: the closest one to you is used (from the Mulgore staging
-- area that's the portal right there, not the mage back in Orgrimmar).
local WAY_IN = {
    [407] = {   -- Darkmoon Island
        Horde    = { { m = 85, x = 0.48,  y = 0.62,  name = "the Darkmoon Faire Mystic Mage in Orgrimmar" },
                     { m = 7,  x = 0.360, y = 0.355, name = "the Darkmoon Faire portal in Mulgore" } },
        Alliance = { { m = 84, x = 0.62,  y = 0.73,  name = "the Darkmoon Faire Mystic Mage in Stormwind" },
                     { m = 37, x = 0.418, y = 0.696, name = "the Darkmoon Faire portal in Elwynn Forest" } },
    },
}

-- The way in closest to the player: same continent first, then straight-line distance.
local function ClosestWay(ways)
    local pm = safe(C_Map.GetBestMapForUnit, "player")
    local ppos = pm and safe(C_Map.GetPlayerMapPosition, pm, "player")
    local pc, pw
    if ppos then pc, pw = safe(C_Map.GetWorldPosFromMapPos, pm, ppos) end
    local best, bestD
    for _, w in ipairs(ways) do
        local c, wp = safe(C_Map.GetWorldPosFromMapPos, w.m, CreateVector2D(w.x, w.y))
        local d = math.huge
        if pc and c == pc and pw and wp then
            local dx, dy = pw.x - wp.x, pw.y - wp.y
            d = dx * dx + dy * dy
        end
        if not bestD or d < bestD then best, bestD = w, d end
    end
    return best
end

local function OnMapOrChild(map, area)
    local a = map
    for _ = 1, 6 do
        if not a or a <= 0 then return false end
        if a == area then return true end
        local mi = safe(C_Map.GetMapInfo, a)
        a = mi and mi.parentMapID
    end
    return false
end

function mod:InstanceQuest(qid)
    if not qid or qid == 0 or (IsInInstance and IsInInstance()) then return nil end
    local qmap = safe(GetQuestUiMapID, qid)
    local inst, mi = InstanceMapOf(qmap)
    if inst then
        return { inst = inst, name = mi.name, entrance = self:InstanceEntrance(inst, mi.name) }
    end
    -- a portal-only open-world area (Darkmoon Island), while you're not in it
    for area, ways in pairs(WAY_IN) do
        if qmap and OnMapOrChild(qmap, area) and not OnMapOrChild(safe(C_Map.GetBestMapForUnit, "player"), area) then
            local list = ways[UnitFactionGroup("player") or ""]
            local way = list and ClosestWay(list)
            local ami = safe(C_Map.GetMapInfo, area)
            if way then return { inst = area, name = ami and ami.name or "there", entrance = way, wayIn = true } end
        end
    end
    return nil
end

-- Point the arrow at the instance's entrance (or clear the arrow when we don't know the
-- entrance yet -- the game's own arrow for it is wrong). Counts as the player's pick.
function mod:PointAtInstance(qid, iq)
    local title = safe(C_QuestLog.GetTitleForQuestID, qid) or "That quest"
    local e = iq.entrance
    safe(C_SuperTrack.SetSuperTrackedQuestID, 0)
    local ok, kind = false, nil
    if e and e.poi and C_SuperTrack.SetSuperTrackedMapPin then
        ok = pcall(C_SuperTrack.SetSuperTrackedMapPin, Enum.SuperTrackingMapPinType.AreaPOI, e.poi)
        kind = ok and "poi" or nil
    end
    local hop
    if not ok and e and e.x and C_Map.SetUserWaypoint and UiMapPoint then
        -- the way in is on another continent: the portal first (Route.lua), then the
        -- zone-change handler below points at the way in itself
        local tm, tx, ty = e.m, e.x, e.y
        hop = ns.Route and ns.Route:Hop(tm, tx, ty)
        if hop then tm, tx, ty = hop.map, hop.x, hop.y end
        ok = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(tm, tx, ty))
        if ok and C_SuperTrack.SetSuperTrackedUserWaypoint then pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true) end
        kind = ok and "wp" or nil
    end
    self._instKind = kind   -- what we set, so clearing it never touches a pin of yours
    self._instQ = ok and qid or nil
    self._instHop = ok and hop ~= nil or nil
    self._instTrack = ok and TrackState() or nil   -- the entrance pin still up = this state
    if ok and iq.wayIn then
        VQ:Print(("%s is on %s -- arrow on %s%s (the game's quest arrow can't point there)."):format(
            title, iq.name, e.name or "the way in", hop and (", via the " .. hop.name .. " first") or ""))
    elseif ok then
        VQ:Print(("%s is inside %s -- arrow on its entrance%s (the game's quest arrow can't point into an instance)."):format(
            title, iq.name, hop and (", via the " .. hop.name .. " first") or ""))
    else
        VQ:Print(("%s is inside %s -- the game's quest arrow can't point in there and I don't know the entrance yet, so I cleared it. Enter it once and I'll remember the way."):format(title, iq.name))
    end
    return ok
end

-- Through the portal on the way to an entrance / way in: point at the entrance itself now,
-- if the portal pin is still the one we set (never a pin of yours).
do
    local hf = CreateFrame("Frame")
    hf:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    hf:SetScript("OnEvent", function()
        C_Timer.After(1, function()
            local q = mod._instQ
            if not (q and mod:InstancePinUp(q)) then return end
            local iq = mod:InstanceQuest(q)
            if not iq then
                -- arrived in the area (the mage teleported you onto Darkmoon Island): drop
                -- the way-in pin and give the arrow back to the quest, which works here
                mod:ClearInstancePin()
                if not (IsInInstance and IsInInstance()) and C_SuperTrack.SetSuperTrackedQuestID then
                    mod:OwnTrack(C_SuperTrack.SetSuperTrackedQuestID, q)
                end
            elseif mod._instHop then
                mod._settingTrack = true
                pcall(C_Map.ClearUserWaypoint)
                mod._settingTrack = nil
                mod:PointAtInstance(q, iq)
            end
        end)
    end)
end

-- Back outside with an instance quest super-tracked (the game tracks a quest you accept
-- in there by itself): swap the broken arrow for the entrance.
-- The quest-click entrance pin is still what the arrow shows (not replaced or reached).
function mod:InstancePinUp(qid)
    return qid and self._instQ == qid and self._instTrack == TrackState()
end

-- Take down the entrance target PointAtInstance set -- only that one -- and end the hold.
function mod:ClearInstancePin()
    if not self._instQ then return end
    self._settingTrack = true
    if self._instKind == "poi" and C_SuperTrack.ClearSuperTrackedMapPin then
        pcall(C_SuperTrack.ClearSuperTrackedMapPin)
    elseif self._instKind == "wp" and safe(C_Map.HasUserWaypoint) then
        pcall(C_Map.ClearUserWaypoint)
    end
    self._settingTrack = nil
    self._instQ, self._instKind, self._instTrack, self._instHop = nil, nil, nil, nil
    self._manual, self._heldType = nil, nil
    self:NoteOurTrack()
end

function mod:FixInstanceArrow()
    if not self:ArrowOn() then return end   -- arrow switched off: hands off, even a broken one
    -- only when the arrow really shows a quest (a pin of yours on top keeps priority)
    local qType = (Enum and Enum.SuperTrackingType and Enum.SuperTrackingType.Quest) or 0
    if not C_SuperTrack or safe(C_SuperTrack.GetHighestPrioritySuperTrackingType) ~= qType then return end
    local q = safe(C_SuperTrack.GetSuperTrackedQuestID)
    local iq = q and q ~= 0 and self:InstanceQuest(q)
    if iq then self:PointAtInstance(q, iq) end
end

-- Last spot outside an instance, so the way into one can be learned on entry.
-- Also learns the way into a separate open-world area (Vaults of Atal'Utek): when the world
-- changes between two samples a few seconds apart, the spot before the change is the way
-- into the area you're now in (saved for the area's map and its parents up to the zone).
-- A hearthstone / teleport spell (anything with a cast bar) also changes the world: those
-- aren't a way in, so a cast started shortly before the change blocks learning. Walking
-- through a portal is instant and still counts.
do
    local cf = CreateFrame("Frame")
    cf:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
    cf:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
    cf:SetScript("OnEvent", function() mod._castAt = GetTime() end)
end

C_Timer.NewTicker(2, function()
    if IsInInstance and IsInInstance() then return end
    local m = safe(C_Map.GetBestMapForUnit, "player")
    local x, y = PosXY(m and safe(C_Map.GetPlayerMapPosition, m, "player"))
    if not x then return end
    local w = WorldOf(m, x, y)
    local o = mod._lastOut
    local teleported = mod._castAt and GetTime() - mod._castAt < 30
    if o and o.w and w and o.w ~= w and GetTime() - o.t < 10 and not teleported and VoidQuestDB then
        VoidQuestDB.entrances = VoidQuestDB.entrances or {}
        local a = m
        for _ = 1, 4 do
            local mi = safe(C_Map.GetMapInfo, a)
            if not mi or (mi.mapType or 0) < ZONE_MAP then break end
            VoidQuestDB.entrances[a] = { m = o.m, x = o.x, y = o.y }
            if mi.mapType == ZONE_MAP then break end
            a = mi.parentMapID
        end
    end
    mod._lastOut = { m = m, x = x, y = y, w = w, t = GetTime() }
end)

function mod:LearnEntrance()
    local inst = InstanceMapOf(safe(C_Map.GetBestMapForUnit, "player"))
    local o = self._lastOut
    if not (inst and o and GetTime() - o.t < 60 and VoidQuestDB) then return end
    -- only a walk-in from the instance's own zone counts: a group-finder teleport or a
    -- summon from elsewhere isn't the way in
    local function zoneOf(m)
        local mi = m and safe(C_Map.GetMapInfo, m)
        for _ = 1, 6 do
            if not mi then return nil end
            if mi.mapType == ZONE_MAP then return m end
            m = mi.parentMapID; mi = m and m > 0 and safe(C_Map.GetMapInfo, m)
        end
    end
    local imi = safe(C_Map.GetMapInfo, inst)
    local zi, zo = zoneOf(imi and imi.parentMapID), zoneOf(o.m)
    if not (zi and zo and zi == zo) then return end
    VoidQuestDB.entrances = VoidQuestDB.entrances or {}
    VoidQuestDB.entrances[inst] = { m = o.m, x = o.x, y = o.y }
end

-- Entering an instance: drop the arrow WE set to an outside quest (a quest with its
-- objective in here stays). Leaving: re-pin the current step. Only our own target --
-- a pin or quest the player picked is never touched.
function mod:InstanceTrack()
    local inside = IsInInstance and IsInInstance()
    if inside then
        if not self._wasInside then
            self:WarnMeta("run", self._outCont)   -- a dungeon / delve / Labyrinth run
            self:LearnEntrance()
        end
        self._wasInside = true
        -- a tracked map spot (dungeon / delve / Labyrinth entrance clicked on the map) has
        -- been reached once you're inside; WoW clears a reached map pin but never these, so
        -- it pointed back out "8.4K yds" from inside the Labyrinth (2026-10-26)
        local pinType = (Enum and Enum.SuperTrackingType and Enum.SuperTrackingType.MapPin) or 6
        if C_SuperTrack and C_SuperTrack.ClearSuperTrackedMapPin and safe(C_SuperTrack.IsSuperTrackingMapPin) then
            self:OwnTrack(C_SuperTrack.ClearSuperTrackedMapPin)
            if self._heldType == pinType then self._manual, self._heldType = nil, nil end
            VQ:Print("you've arrived -- cleared the map spot your arrow was pointing at.")
        end
        -- our entrance pin for an instance quest: you're in, so it's done (still ours only
        -- if nothing replaced it)
        if self._instQ then
            if self._instTrack == TrackState() then self:ClearInstancePin()
            else self._instQ, self._instKind, self._instTrack, self._instHop = nil, nil, nil, nil end
        end
        if self._manual or TrackState() ~= self._ourTrack then return end
        local q = C_SuperTrack and safe(C_SuperTrack.GetSuperTrackedQuestID)
        if q and q ~= 0 then
            local here = safe(C_Map.GetBestMapForUnit, "player")
            local local_ = false
            for _, p in ipairs((here and safe(C_QuestLog.GetQuestsOnMap, here)) or {}) do
                if p.questID == q then local_ = true; break end
            end
            if not local_ then self:OwnTrack(C_SuperTrack.SetSuperTrackedQuestID, 0) end
        end
        self:ClearOurWaypoint()
    else
        if self._wasInside then
            self._wasInside = nil
            self._lastStep = nil   -- back outside: point at the current step again
        end
        self:FixInstanceArrow()
    end
end

-- the panel was clicked: the guide takes the arrow back and re-pins its step (also
-- turns a paused arrow back on -- clicking a step means "guide me")
function mod:TakeTrack()
    self._manual, self._heldType = nil, nil; self._lastStep = nil
    if not self:ArrowOn() then self:SetArrow(true) end
end

----------------------------------------------------------------------
-- ARROW SWITCH (button on the world map, `/vq arrow`). Off = the guide never sets the
-- arrow or a waypoint, for when you stop questing to fly to a dungeon or run errands
-- (the player, 2026-10-26: "if someone is questing but wants to stop questing and run
-- stuff ... it changing will confuse them"). The panel keeps showing steps. Per character.
----------------------------------------------------------------------
function mod:ArrowOn() return not (VoidQuestCharDB and VoidQuestCharDB.arrowOff) end
function mod:SetArrow(on)
    VoidQuestCharDB = VoidQuestCharDB or {}
    VoidQuestCharDB.arrowOff = (not on) or nil
    if on then
        self._manual, self._heldType = nil, nil
        self._lastStep = nil   -- re-pin the current step
        VQ:Print("arrow ON -- I'll point you at each step again.")
    else
        self:ClearOurWaypoint()   -- only ever our own pin; yours stays
        VQ:Print("arrow OFF -- I won't touch your arrow or pins. Steps still show on my panel. Turn it back on with the button on your world map.")
    end
    self:UpdateMapButton()
    self:Refresh()
end

-- Right-click on the map button: clear whatever the arrow points at -- the map pin AND
-- any super-tracked target (a dungeon entrance / map POI, a quest, a tracked item, a rare),
-- whoever set it (the player's click asks for it). Says what it was: the "8.4K yds"
-- diamond in the Labyrinth wasn't a map pin (2026-10-26).
local TRACK_NAMES = { [0] = "tracked quest", [1] = "map pin", [2] = "corpse", [3] = "scenario",
    [4] = "tracked item", [5] = "party member", [6] = "map spot (dungeon entrance / POI)", [7] = "rare / vignette" }
function mod:ClearAnyPin()
    local hadPin = safe(C_Map.HasUserWaypoint)
    local t = C_SuperTrack and safe(C_SuperTrack.GetHighestPrioritySuperTrackingType)
    local q = C_SuperTrack and safe(C_SuperTrack.GetSuperTrackedQuestID)
    if not hadPin and not (C_SuperTrack and safe(C_SuperTrack.IsSuperTrackingAnything)) then
        VQ:Print("the arrow isn't pointing at anything I can clear."); return
    end
    self._settingTrack = true
    if hadPin then pcall(C_Map.ClearUserWaypoint) end
    if C_SuperTrack then
        if C_SuperTrack.ClearAllSuperTracked then pcall(C_SuperTrack.ClearAllSuperTracked) end
        -- belt and braces where ClearAll leaves something behind
        if C_SuperTrack.ClearSuperTrackedMapPin then pcall(C_SuperTrack.ClearSuperTrackedMapPin) end
        if C_SuperTrack.ClearSuperTrackedContent then pcall(C_SuperTrack.ClearSuperTrackedContent) end
        if C_SuperTrack.SetSuperTrackedQuestID then pcall(C_SuperTrack.SetSuperTrackedQuestID, 0) end
        if C_SuperTrack.SetSuperTrackedUserWaypoint then pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, false) end
    end
    self._settingTrack = nil
    self._wp = nil
    if VoidQuestCharDB then VoidQuestCharDB.lastWp = nil end
    self._manual, self._heldType = nil, nil
    self:NoteOurTrack()
    local what = TRACK_NAMES[t] or (hadPin and "map pin") or "target"
    if t == 0 and q and q ~= 0 then
        what = ("%s '%s'"):format(what, safe(C_QuestLog.GetTitleForQuestID, q) or q)
    end
    VQ:Print(("cleared the arrow: it was a %s%s."):format(what, (hadPin and t ~= 1) and " (and your map pin)" or ""))
end

function mod:UpdateMapButton()
    local b = self.mapBtn
    if not b then return end
    b:SetText(self:ArrowOn() and "VQ arrow: |cff55ff55ON|r" or "VQ arrow: |cffff5555OFF|r")
    b:SetWidth((b:GetFontString():GetStringWidth() or 80) + 18)
end

function mod:EnsureMapButton()
    if self.mapBtn or not WorldMapFrame then return end
    -- bottom-center of the map: top-left is where the floor dropdown sits (it covered the
    -- button in the Labyrinth, 2026-10-26), and map pins draw well above the canvas level
    local area = WorldMapFrame.ScrollContainer or WorldMapFrame
    local b = CreateFrame("Button", nil, WorldMapFrame, "UIPanelButtonTemplate")
    b:SetHeight(20)
    b:SetPoint("BOTTOM", area, "BOTTOM", 0, 8)
    b:SetFrameLevel(math.min(area:GetFrameLevel() + 1500, 9000))
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then mod:ClearAnyPin() else mod:SetArrow(not mod:ArrowOn()) end
    end)
    b:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText("VoidQuest arrow")
        GameTooltip:AddLine("ON: the guide points your arrow at each quest step.", .8, .8, .8, true)
        GameTooltip:AddLine("OFF: it never touches your arrow or map pins -- for flying to a dungeon or running errands. Steps still show on the VoidQuest panel.", .8, .8, .8, true)
        GameTooltip:AddLine("A pin you set yourself is always left alone until you reach or clear it.", 1, .82, 0, true)
        GameTooltip:AddLine("Right-click: clear whatever the arrow points at -- map pin, dungeon entrance, tracked quest (yours or VoidQuest's).", .55, .8, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.mapBtn = b
    self:UpdateMapButton()
end

-- The continent a map sits on (walks up parents), for "travel there first" hints.
function mod:ContinentOf(m)
    local contType = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
    for _ = 1, 8 do
        local mi = m and m > 0 and safe(C_Map.GetMapInfo, m)
        if not mi then return nil end
        if mi.mapType == contType then return mi end
        m = mi.parentMapID
    end
end

function mod:ClearOurWaypoint(keepRoute)
    -- navigation cancelled: no next leg after the portal either (keepRoute: arrived AT the portal)
    if not keepRoute then self._afterHop = nil end
    local ours = self._wp
    if not ours then return end
    self._wp = nil
    -- only if the waypoint on the map is still the one WE set: the player may have
    -- replaced it with their own since (one waypoint slot), and that one stays
    local cur = safe(C_Map.GetUserWaypoint)
    if cur and cur.position and (cur.uiMapID ~= ours.m or math.abs((cur.position.x or 0) - ours.x) > 0.0005
       or math.abs((cur.position.y or 0) - ours.y) > 0.0005) then return end
    self._settingTrack = true
    if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, false) end
    self._settingTrack = nil
    if VoidQuestCharDB then VoidQuestCharDB.lastWp = nil end
    self:NoteOurTrack()
end

-- Set the waypoint to the OBJECTIVE. For in-progress/turn-in quests use a real
-- objective source; only fall back to the quest-line start (giver) for a PICKUP.
function mod:Waypoint(step, ql)
    if not step then return end
    -- the player's own pin holds the arrow (MANUAL TRACKING HOLD), the arrow is off, or
    -- you're in an instance (an arrow to the outside world is noise there: "8.4K yds" in
    -- the Labyrinth, 2026-10-26 -- see InstanceTrack). Also a pin you CLICKED on the panel
    -- (step line or an extra line) locks to that quest: other steps never replace it
    -- ("if i have a pin i set specifically ... why is it even looking for other
    -- locations to pin", 2026-10-26). The locked quest itself may move on (giver ->
    -- objective -> turn-in).
    local lockQ = (self._pinLock and self._pinLock.qid) or self._sidePin
    if self._manual or not self:ArrowOn() or (IsInInstance and IsInInstance())
       or (lockQ and step.qid ~= lockQ) then
        if VQ.Ring then VQ.Ring:Set(step) end
        return nil, nil, nil, "manual-hold"
    end
    local iq = step.status ~= "pickup" and self:InstanceQuest(step.qid)
    if iq then
        -- in your log but inside an instance you're not in: the quest arrow can't point
        -- there (Halazzi's Lair -> Silverpine, 2026-10-27), so pin the entrance ourselves
        local e = iq.entrance
        if VQ.Ring then VQ.Ring:Set(step, e and e.m, e and e.x, e and e.y) end
        if not VQ:Get("setWaypoint") then   -- guidance-only: no pin
            self:ClearOurWaypoint()
            return e and e.m, e and e.x, e and e.y, "instance-entrance"
        end
        if e and e.x and self:SetOurWaypoint(e.m, e.x, e.y, step.qid) then
            return e.m, e.x, e.y, "instance-entrance"
        end
        self:ClearOurWaypoint()   -- the last step's pin would point at the wrong thing
        return nil, nil, nil, "instance-no-entrance"
    end
    if step.status ~= "pickup" then
        -- Quest is IN YOUR LOG (doing the objective OR ready to turn in): super-track the
        -- QUEST. The game shows the objective-area blob (the "circle") while incomplete,
        -- then AUTO-SWITCHES the arrow + POI to the turn-in NPC the moment it's complete.
        -- Drop OUR pickup pin now that it's in the log (don't touch a manual waypoint).
        self:ClearOurWaypoint()
        if VQ:Get("superTrack") and C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
            self:OwnTrack(C_SuperTrack.SetSuperTrackedQuestID, step.qid)
        end
        if VQ.Ring then VQ.Ring:Set(step) end   -- ring follows the quest's own POI per map
        return nil, nil, nil, "supertrack-quest"
    end
    -- PICKUP (not in your log yet): waypoint to the giver so you know where to grab it.
    local m, x, y, srcName
    if step.wpMap and step.wpX and step.wpY then
        m, x, y, srcName = step.wpMap, step.wpX, step.wpY, "next-chapter-giver"   -- cross-chapter discovery
    else
        for _, s in ipairs(self:WaypointSources(step.qid, ql)) do
            m, x, y, srcName = s.m, s.x, s.y, s.name
            if s.name:find("giver") then break end
        end
    end
    if VQ.Ring then
        local ok = m and m > 0 and x and y and x > 0 and y > 0
        VQ.Ring:Set(step, ok and m or nil, ok and x or nil, ok and y or nil)
    end
    -- Validate before building the point: map must be >0 and coords in (0,1] (0 is truthy
    -- in Lua so an unset 0,0 would otherwise slip through), and pcall the set as a backstop.
    if not VQ:Get("setWaypoint") then self:ClearOurWaypoint(); return m, x, y, srcName end   -- guidance-only: no pin
    if m and m > 0 and x and y and x > 0 and y > 0 then
        self:SetOurWaypoint(m, x, y, step.qid)
        return m, x, y, srcName
    end
    self:ClearOurWaypoint()   -- couldn't resolve a giver -> make sure no stale pin lingers
end

-- Text summary (v1 display -- panel integration comes next).
function mod:Describe()
    local g = self:Compute()
    if not g then return "|cffff5555No active campaign found.|r" end
    local lines = {}
    lines[#lines+1] = ("|cff00c7ff%s|r"):format(g.campName or "Campaign")
    lines[#lines+1] = ("Chapter: |cffffd200%s|r"):format(g.chapter or "?")
    if g.step then
        local verb = ({ pickup = "Pick up", progress = "Complete", turnin = "Turn in" })[g.step.status] or "Do"
        if g.step.nextChapter then
            lines[#lines+1] = ("|cffffd200Next chapter|r  %s: |cff55ff55%s|r"):format(
                verb, g.step.title or ("quest " .. g.step.qid))
        else
            lines[#lines+1] = ("Step %d/%d  %s: |cff55ff55%s|r"):format(
                g.step.idx, g.step.total, verb, g.step.title or ("quest " .. g.step.qid))
        end
        local mapID, x, y, srcName = self:Waypoint(g.step, g.ql)
        if mapID then
            lines[#lines+1] = ("Waypoint -> |cffffd200%.1f, %.1f|r (map %d) via |cff88ddff%s|r"):format(x*100, y*100, mapID, srcName or "?")
        else
            lines[#lines+1] = "|cffff5555(no waypoint coords available)|r"
        end
        -- DIAGNOSTIC: dump every candidate so we can see which is the real objective
        lines[#lines+1] = "|cff888888-- candidate sources --|r"
        for _, s in ipairs(self:WaypointSources(g.step.qid, g.ql)) do
            lines[#lines+1] = ("|cff888888  %-24s %.1f, %.1f (map %d)|r"):format(s.name, s.x*100, s.y*100, s.m or 0)
        end
        -- DIAGNOSTIC: step-resolution internals (title/entrance/availability)
        local qid = g.step.qid
        lines[#lines+1] = "-- step diag --"
        lines[#lines+1] = ("qid=%s status=%s lockedNoData=%s"):format(tostring(qid), tostring(g.step.status), tostring(g.lockedNoData))
        lines[#lines+1] = ("title(raw)=%s"):format(tostring(safe(C_QuestLog.GetTitleForQuestID, qid)))
        local qmap = safe(GetQuestUiMapID, qid)
        lines[#lines+1] = ("GetQuestUiMapID=%s"):format(tostring(qmap))
        lines[#lines+1] = ("VerifyObtainable=%s"):format(tostring(self:VerifyObtainable(qid)))
        local ent = self:FindContentEntrance(g.step)
        lines[#lines+1] = ent and ("entrance=%s %.1f,%.1f map %d"):format(ent.name, ent.x*100, ent.y*100, ent.m)
            or "entrance=nil (needs a resolved title to match)"
        for _, m in ipairs({ qmap, safe(C_Map.GetBestMapForUnit, "player") }) do
            if m and m > 0 then
                local es = DungeonEntrances(m)
                lines[#lines+1] = ("entrances on map %d: %d"):format(m, #es)
                for _, e in ipairs(es) do lines[#lines+1] = "  " .. tostring(e.name) end
            end
        end
    else
        lines[#lines+1] = "|cff55ff55Chapter complete!|r"
    end
    return table.concat(lines, "\n")
end

function mod:Guide()
    VQ:ShowCopy("VoidQuest — Campaign Guide", self:Describe())
end

----------------------------------------------------------------------
-- DENSITY TIERS (min / mid / max) + quest-line PICKER.  A hand-written guide lets you
-- pick lines + a min/mid/max amount, but hand-authors each variant. We
-- don't need to: every GetAvailableQuestLines entry carries the native
-- isCampaign / isImportant / isLocalStory flags, so the tiers fall out of LIVE data.
--   min = story campaign only            (isCampaign)
--   mid = campaign + zone side stories    (isCampaign, isImportant or isLocalStory)
--   max = every quest line                (all)
-- Mid used to be campaign + isImportant only. Few lines carry that flag, so Mid added
-- almost nothing (2026-10-26: 80 -> 87 in Midnight with no side quests suggested).
-- The picker stores per-line overrides in VoidQuestDB.pick[questLineID].
----------------------------------------------------------------------
local DENSITY_ORDER = { "min", "mid", "max" }
local DENSITY_SHORT = { min = "Min", mid = "Mid", max = "Max" }
local DENSITY_LABEL = { min = "Min (story)", mid = "Mid (+side stories)", max = "Max (all)" }

-- WoW Forever keeps its own tier (Chains.lua C:InScope; default Max): density did nothing
-- there before 0.3.2, so a shared "min" default would have hidden most quests overnight.
local function DensityKey() return VQ.ForeverQuests and "foreverDensity" or "density" end
mod.DensityKey = DensityKey
function mod:Density() return VQ:Get(DensityKey()) end
function mod:SetDensity(d)
    self._lastStep = nil                       -- force the waypoint to re-fire
    self._stick = nil                          -- a new tier picks its own side quest
    VQ:Set(DensityKey(), d)                     -- writes + Apply() -> Refresh + settings sync
    if self.picker and self.picker:IsShown() then self:RefreshPicker() end
end
function mod:CycleDensity()
    local cur, nxt = self:Density(), "min"
    for i, d in ipairs(DENSITY_ORDER) do
        if d == cur then nxt = DENSITY_ORDER[(i % #DENSITY_ORDER) + 1]; break end
    end
    self:SetDensity(nxt)
end

-- Is a quest line in scope? Explicit picker override wins; else the density tier
-- (or the tier passed in -- a level-gated campaign looks at Mid even when set to Min).
function mod:InScope(entry, density)
    local pick = VoidQuestDB and VoidQuestDB.pick
    if pick and entry.questLineID and pick[entry.questLineID] ~= nil then
        return pick[entry.questLineID]
    end
    local d = density or self:Density()
    if d == "max" then return true end
    if entry.isCampaign then return true end
    if d == "mid" and (entry.isImportant or entry.isLocalStory) and not entry.isDaily then return true end
    return false
end

-- Is this quest's line explicitly PICKED (opt-in to hands-free auto-run)?
function mod:IsPicked(qid)
    local pick = VoidQuestDB and VoidQuestDB.pick
    if not (pick and qid) then return false end
    local qli = safe(C_QuestLine.GetQuestLineInfo, qid, safe(C_Map.GetBestMapForUnit, "player"))
    return (qli and pick[qli.questLineID] == true) or false
end

----------------------------------------------------------------------
-- QUEST XP. GetQuestLogRewardXP(qid) answers for quests NOT in the log too (`/vq xp`,
-- 2026-10-26: all 183 Quel'Thalas offers at 87 came back). Everything scales to your
-- level, so a quest pays the same in every zone: 1,840 breadcrumb, 14,605 normal,
-- 18,285 finale, 58k dungeon quest, 110k special. What differs per zone is how much
-- is LEFT there. Map queries also return the neighbors' offers (Eversong's list held
-- most of Zul'Aman), and only each storyline's first quest is offered, so the index
-- dedupes by quest, files each under its storyline's startMapID, and values whole
-- storylines (GetQuestLineQuests) rather than the first quest.
----------------------------------------------------------------------
local xpCache, xpAsked, xpLevel = {}, {}, nil
local META_CLASS = (Enum and Enum.QuestClassification and Enum.QuestClassification.Meta) or 4
local function QuestXP(qid)
    local lvl = UnitLevel("player")
    if xpLevel ~= lvl then xpCache, xpAsked, xpLevel = {}, {}, lvl end   -- rewards rescale on level-up
    local v = xpCache[qid]
    if v then return v end
    local x = safe(GetQuestLogRewardXP, qid)
    if x and x > 0 then xpCache[qid] = x; return x end
    -- ask ONCE per level: the answer (QUEST_DATA_LOAD_RESULT) refreshes the panel, and a
    -- quest that really pays 0 (max level, phantom variants) would otherwise loop that
    if not xpAsked[qid] then
        xpAsked[qid] = true
        safe(C_QuestLog.RequestLoadQuestByID, qid)
    end
    return 0
end
mod.QuestXP = function(_, qid) return QuestXP(qid) end

-- XP still to earn in a storyline: every not-done quest in it (phantom variants have
-- no data and add 0). Cached 30s per line; at least the offered quest's own XP.
local lineCache = {}
local function LineXP(qlID, firstQid)
    local own = firstQid and QuestXP(firstQid) or 0
    if not qlID then return own end
    local c = lineCache[qlID]
    if c and c.lvl == xpLevel and GetTime() - c.t < 30 then return math.max(c.xp, own) end
    local sum = 0
    for _, q in ipairs(safe(C_QuestLine.GetQuestLineQuests, qlID) or {}) do
        if not safe(C_QuestLog.IsQuestFlaggedCompleted, q) then sum = sum + QuestXP(q) end
    end
    lineCache[qlID] = { xp = sum, t = GetTime(), lvl = xpLevel }
    return math.max(sum, own)
end

function mod:InvalidateXP() lineCache = {}; self._xpIdx = nil end

local function kxp(n)
    n = n or 0
    if n >= 99500 then return ("%dk"):format(math.floor(n / 1000 + 0.5)) end
    if n >= 1000 then return ("%.1fk"):format(n / 1000) end
    return tostring(n)
end
mod.FormatXP = function(_, n) return kxp(n) end
-- "14.6k XP" plus the storyline's total when the line is worth clearly more than this quest
local function XPTag(e)
    if not (e and (e.xp or 0) > 0) or mod:AtMaxLevel() then return "" end
    local s = kxp(e.xp) .. " XP"
    if (e.lineXP or 0) > e.xp * 1.2 then s = s .. ", storyline " .. kxp(e.lineXP) end
    return s
end

function mod:AtMaxLevel()
    -- the fallback cap is 60 on WoW Forever, not Midnight's 90 (Forever audit, 2026-11-10)
    local maxLvl = (GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion())
        or (VQ.ForeverQuests and 60) or 90
    return (UnitLevel("player") or 0) >= maxLvl
end

-- Every offer on your continent, deduped, filed under its storyline's start zone, with
-- XP. Cached 10s. Returns { entries, zones = {[mapID]={name,total}}, normal = the most
-- common quest XP (a "normal quest" at your level) }.
function mod:XPIndex()
    local here = safe(C_Map.GetBestMapForUnit, "player")
    local cont = here and self:ContinentOf(here)
    if not cont then return nil end
    local c = self._xpIdx
    if c and c.cont == cont.mapID and c.lvl == UnitLevel("player") and GetTime() - c.t < 10 then return c end
    local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
    local zones, isZone = {}, {}
    for _, z in ipairs(safe(C_Map.GetMapChildrenInfo, cont.mapID, zoneType, true) or {}) do
        zones[#zones + 1] = z; isZone[z.mapID] = z.name
    end
    local byQ, order = {}, {}
    for _, z in ipairs(zones) do
        safe(C_QuestLine.RequestQuestLinesForMap, z.mapID)
        for _, q in ipairs(safe(C_QuestLine.GetAvailableQuestLines, z.mapID) or {}) do
            if q.questID and not q.isHidden and not safe(C_QuestLog.IsQuestFlaggedCompleted, q.questID) then
                local e = byQ[q.questID]
                if not e then
                    e = { q = q, qid = q.questID, qlID = q.questLineID, map = z.mapID, x = q.x, y = q.y,
                          -- activity quest ("complete 10 world quests, dungeons, delves"): checked
                          -- live 2026-10-26, Hope in the Darkest Corners = isMeta, classification 4
                          meta = q.isMeta or safe(C_QuestInfoSystem.GetQuestClassification, q.questID) == META_CLASS,
                          title = (q.questName ~= "" and q.questName) or q.questLineName, lineName = q.questLineName,
                          inLog = safe(C_QuestLog.GetLogIndexForQuestID, q.questID) and true or false }
                    byQ[q.questID] = e; order[#order + 1] = e
                end
                -- the storyline's own start zone wins over a neighbor that also lists it
                if q.startMapID and q.startMapID == z.mapID then e.map, e.x, e.y = z.mapID, q.x, q.y end
            end
        end
    end
    local counts, lineSeen = {}, {}
    for _, e in ipairs(order) do
        e.xp = QuestXP(e.qid)
        e.lineXP = LineXP(e.qlID, e.qid)
        if e.xp > 0 then counts[e.xp] = (counts[e.xp] or 0) + 1 end
    end
    local normal, best = 0, 0
    for xp, n in pairs(counts) do if n > best or (n == best and xp > normal) then normal, best = xp, n end end
    local zt = {}
    for _, e in ipairs(order) do
        local key = e.qlID or e.qid
        if not lineSeen[key] then
            lineSeen[key] = true
            local t = zt[e.map] or { name = isZone[e.map] or "?", total = 0 }
            t.total = t.total + e.lineXP
            zt[e.map] = t
        end
    end
    self._outCont = cont.mapID   -- the continent you're on outdoors (for WarnMeta on a run)
    c = { cont = cont.mapID, lvl = UnitLevel("player"), t = GetTime(), entries = order, zones = zt, normal = normal }
    self._xpIdx = c
    return c
end

-- Level-gated: the zone with the most XP left (in scope), where the zone you're in gets
-- a travel allowance of ~4 normal quests. Returns pool (that zone's offers, nearest first
-- when it's this zone, biggest storyline first elsewhere) and the zone ranking for the
-- panel text.
function mod:LevelPool(excludeQLID, density)
    local idx = self:XPIndex()
    if not idx then return nil end
    local here = safe(C_Map.GetBestMapForUnit, "player")
    local inScope, totals = {}, {}
    for _, e in ipairs(idx.entries) do
        if e.qlID ~= excludeQLID and not e.inLog and self:InScope(e.q, density) then
            inScope[#inScope + 1] = e
        end
    end
    local lineSeen = {}
    for _, e in ipairs(inScope) do
        local key = e.qlID or e.qid
        if not lineSeen[key] then
            lineSeen[key] = true
            totals[e.map] = (totals[e.map] or 0) + e.lineXP
        end
    end
    local rank = {}
    for m, t in pairs(totals) do
        rank[#rank + 1] = { map = m, total = t, name = (idx.zones[m] and idx.zones[m].name) or "?" }
    end
    table.sort(rank, function(a, b) return a.total > b.total end)
    -- STICK WITH A ZONE. Re-ranking every refresh flipped between near-tied zones as each
    -- quest lowered its zone's total (Zul'Aman -> Harandar for one quest -> Voidstorm,
    -- 2026-10-26: "this is a poor design"). Now: the zone you're in while it still has a
    -- real amount left; else the zone we sent you to, until it runs low; only then the
    -- zone with the most left -- and that choice is kept (VoidQuestCharDB.xpZone).
    local enough = 2 * math.max(idx.normal or 0, 1)
    local committed = VoidQuestCharDB and VoidQuestCharDB.xpZone
    local bestMap, why
    if here and (totals[here] or 0) >= enough then
        bestMap, why = here, "here"
    elseif committed and (totals[committed] or 0) >= enough then
        bestMap, why = committed, "committed"
    elseif rank[1] and rank[1].total >= enough then
        bestMap, why = rank[1].map, "best"
    -- only scraps left everywhere: finish them where you are / where we sent you, instead
    -- of re-ranking the leftovers after every quest (Codex review)
    elseif here and (totals[here] or 0) > 0 then
        bestMap, why = here, "here"
    elseif committed and (totals[committed] or 0) > 0 then
        bestMap, why = committed, "committed"
    elseif rank[1] then
        bestMap, why = rank[1].map, "best"
    end
    if bestMap then
        VoidQuestCharDB = VoidQuestCharDB or {}
        VoidQuestCharDB.xpZone = bestMap
        -- chosen zone first in the ranking the panel / coach show
        for i, z in ipairs(rank) do
            if z.map == bestMap then table.remove(rank, i); table.insert(rank, 1, z); break end
        end
        rank.why = why
    end
    local px, py = 0.5, 0.5
    local pos = here and safe(C_Map.GetPlayerMapPosition, here, "player")
    if pos and pos.GetXY then local a, b = pos:GetXY(); if a then px, py = a, b end end
    local pool = {}
    for _, e in ipairs(inScope) do
        if e.map == bestMap then
            local dist = 1 - (e.lineXP / 1e7)   -- other zone: biggest storyline first
            if bestMap == here then
                local dx, dy = (e.x or px) - px, (e.y or py) - py
                dist = math.sqrt(dx * dx + dy * dy)
            end
            pool[#pool + 1] = { qid = e.qid, x = e.x, y = e.y, map = e.map, qlID = e.qlID, title = e.title,
                                lineName = e.lineName, dist = dist, inLog = false, xp = e.xp, lineXP = e.lineXP }
        end
    end
    table.sort(pool, function(a, b) return a.dist < b.dist end)
    return pool, rank
end

-- Activity ("meta") quests not picked up yet. Their objectives count only from the moment
-- they're in your log, so they must be grabbed BEFORE the dungeons / delves / world quests
-- they count. Offer = the one in the zone you're in, else the biggest-XP one on the
-- continent; any density, any level (they reward more than XP). MetaGoal = its objective
-- ("Complete World Quests, Dungeons, and Delves in Midnight zones"), readable before you
-- accept (checked live 2026-10-26; data may need a moment to load).
function mod:MetaOffer()
    local idx = self:XPIndex()
    if not idx then return nil end
    local here = safe(C_Map.GetBestMapForUnit, "player")
    local best
    for _, e in ipairs(idx.entries) do
        if e.meta and not e.inLog and not safe(C_QuestLog.GetLogIndexForQuestID, e.qid) then
            local better = not best
                or (e.map == here and best.map ~= here)
                or ((e.map == here) == (best.map == here) and (e.xp or 0) > (best.xp or 0))
            if better then best = e end
        end
    end
    -- remembered for inside instances, where the continent's offers can't be read
    if best then self._lastMeta = best end
    return best
end

local metaGoal = {}
function mod:MetaGoal(qid)
    if metaGoal[qid] then return metaGoal[qid] end
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
        if type(o.text) == "string" and o.text ~= "" then
            -- "0/10 Complete World Quests, ..." -> "10 World Quests, ..." reads better after "counts"
            local n, rest = o.text:match("^%s*%d+%s*/%s*(%d+)%s+(.+)$")
            local goal = n and (n .. " " .. rest:gsub("^[Cc]omplete%s+", "")) or o.text
            metaGoal[qid] = goal
            return goal
        end
    end
    -- ask once: the load event refreshes the panel, so asking every refresh could loop
    if not metaGoal["asked" .. qid] then
        metaGoal["asked" .. qid] = true
        safe(C_QuestLog.RequestLoadQuestByID, qid)
    end
    return nil
end

-- Starting something an unpicked activity quest would have counted (entering a dungeon /
-- delve / scenario, accepting a world quest): say so loudly, once per quest per 10 min.
local metaWarned = {}
-- cont = the continent the activity is on (for a run: the one you entered it from). The
-- quest counts its own expansion's zones only, so an old-world dungeon or a world quest
-- elsewhere stays quiet (and doesn't use up the 10-minute cooldown -- Codex review).
function mod:WarnMeta(what, cont)
    local m = self:MetaOffer() or self._lastMeta
    if not m or safe(C_QuestLog.GetLogIndexForQuestID, m.qid)
       or safe(C_QuestLog.IsQuestFlaggedCompleted, m.qid) then return end
    local mc = self:ContinentOf(m.map)
    if not (cont and mc and mc.mapID == cont) then return end
    local now = GetTime()
    if metaWarned[m.qid] and now - metaWarned[m.qid] < 600 then return end
    metaWarned[m.qid] = now
    local mi = safe(C_Map.GetMapInfo, m.map)
    local msg = ("You haven't picked up '%s' yet (%s) -- this %s won't count toward it."):format(
        m.title or ("quest " .. m.qid), (mi and mi.name) or "?", what)
    VQ:Print("|cffff8800" .. msg .. "|r")
    if UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage(msg, 1, 0.53, 0) end
end

-- The single biggest-XP offer on the continent (3+ normal quests' worth): a dungeon
-- quest or a special one is worth knowing about wherever it is. Below max level only.
function mod:BigXPOffer()
    if self:AtMaxLevel() then return nil end
    local idx = self:XPIndex()
    if not (idx and (idx.normal or 0) > 0) then return nil end
    local best
    for _, e in ipairs(idx.entries) do
        if not e.inLog and not e.q.isDaily and e.xp >= 3 * idx.normal and (not best or e.xp > best.xp) then best = e end
    end
    return best
end

-- Does this offer belong on mapID? GetAvailableQuestLines(map) also returns the
-- neighbors' offers; Blizzard's map shows one only when its storyline starts on that map
-- or a child of it (QuestOfferDataProvider). Same rule, so we never point at a quest the
-- map has no "!" for.
function mod:OfferOnMap(q, mapID)
    local s = q and q.startMapID
    if not s or s == 0 or s == mapID then return true end
    return MapUtil and MapUtil.IsChildMapCached and MapUtil.IsChildMapCached(s, mapID) or false
end

-- Ordered pool of in-scope ZONE quests (the campaign story line is excluded --
-- the story stepper owns it), NEAREST-giver-first from the player's position.
-- opts.density = the tier to use instead of the setting.
function mod:ZonePool(excludeQLID, opts)
    local map = safe(C_Map.GetBestMapForUnit, "player")
    if not map then return {} end
    local density = opts and opts.density
    local px, py = 0.5, 0.5
    local pos = safe(C_Map.GetPlayerMapPosition, map, "player")
    if pos then
        if pos.GetXY then local a, b = pos:GetXY(); if a then px, py = a, b end
        elseif pos.x then px, py = pos.x, pos.y end
    end
    local pool, seen = {}, {}
    safe(C_QuestLine.RequestQuestLinesForMap, map)
    for _, q in ipairs(safe(C_QuestLine.GetAvailableQuestLines, map) or {}) do
        if q.questID and q.questLineID ~= excludeQLID and not seen[q.questID] and self:OfferOnMap(q, map)
           and self:InScope(q, density) and not safe(C_QuestLog.IsQuestFlaggedCompleted, q.questID) then
            seen[q.questID] = true
            local dx, dy = (q.x or px) - px, (q.y or py) - py
            pool[#pool+1] = {
                qid = q.questID, x = q.x, y = q.y, map = map, qlID = q.questLineID,
                title = (q.questName ~= "" and q.questName) or q.questLineName,
                lineName = q.questLineName,
                isCampaign = q.isCampaign, dist = math.sqrt(dx * dx + dy * dy),
                inLog = safe(C_QuestLog.GetLogIndexForQuestID, q.questID) and true or false,
                xp = QuestXP(q.questID), lineXP = LineXP(q.questLineID, q.questID),
            }
        end
    end
    if VQ:Get("zoneOrder") == "grouped" then
        -- finish one quest line before the next: cluster by line (nearest line first),
        -- ordered within a line by proximity. Less back-and-forth, a bit more travel.
        local near = {}
        for _, e in ipairs(pool) do
            if not near[e.qlID] or e.dist < near[e.qlID] then near[e.qlID] = e.dist end
        end
        table.sort(pool, function(a, b)
            if a.qlID ~= b.qlID then return (near[a.qlID] or 9) < (near[b.qlID] or 9) end
            return a.dist < b.dist
        end)
    else
        table.sort(pool, function(a, b) return a.dist < b.dist end)   -- nearest-first
    end
    return pool
end

-- `/vq xp` diagnostic: can we read the XP of quests NOT in the log? Every offered quest
-- line start on this continent (all tiers), with GetQuestLogRewardXP + the quest's scaled
-- level, summed per zone. Data loads async, so it reads 3s after the requests.
-- Saved to VoidQuestCharDB.xpProbe (read from SavedVariables after /reload).
-- Diagnostic: what the game says about the super-tracked quest (map, waypoint, objectives),
-- saved to VoidQuestCharDB.trackProbe. Runs on login and when the tracked quest changes.
function mod:TrackProbe()
    -- where you are: instance flags, map chain, world (why an entrance was / wasn't learned)
    if VoidQuestCharDB then
        local here = safe(C_Map.GetBestMapForUnit, "player")
        local hx, hy = PosXY(here and safe(C_Map.GetPlayerMapPosition, here, "player"))
        local inInst, instType = IsInInstance()
        local name, itype, _, _, _, _, _, instID = GetInstanceInfo()
        local A = { at = date("%Y-%m-%d %H:%M:%S"), inInstance = tostring(inInst), instType = tostring(instType),
            instanceInfo = ("%s / %s / id %s"):format(tostring(name), tostring(itype), tostring(instID)),
            world = tostring(WorldOf(here, hx, hy)), pos = ("%.3f, %.3f"):format(hx or 0, hy or 0),
            castAgo = mod._castAt and ("%.0f s"):format(GetTime() - mod._castAt) or "none",
            lastOut = mod._lastOut and ("%s @ %.3f, %.3f world %s, %.0f s ago"):format(tostring(mod._lastOut.m),
                mod._lastOut.x, mod._lastOut.y, tostring(mod._lastOut.w), GetTime() - mod._lastOut.t) or "none",
            chain = {} }
        local a = here
        for _ = 1, 5 do
            local mi = a and safe(C_Map.GetMapInfo, a)
            if not mi then break end
            A.chain[#A.chain + 1] = ("%d %s (type %s)"):format(a, tostring(mi.name), tostring(mi.mapType))
            a = mi.parentMapID
        end
        -- every log quest the game puts on this map (or in this zone): what the minimap has
        -- to draw its area with
        A.quests = {}
        local pois = {}
        for _, p in ipairs((here and safe(C_QuestLog.GetQuestsOnMap, here)) or {}) do pois[p.questID] = p end
        for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
            local info = safe(C_QuestLog.GetInfo, i)
            local q = info and not info.isHeader and info.questID
            if q then
                local onMap, localPOI = safe(C_QuestLog.IsOnMap, q)
                local qm = safe(GetQuestUiMapID, q)
                if onMap or pois[q] or ZoneOfMap(qm) == ZoneOfMap(here) then
                    local p = pois[q]
                    local wm, wx, wy = safe(C_QuestLog.GetNextWaypoint, q)
                    A.quests[#A.quests + 1] = ("%d %s | map %s world %s | onMap %s localPOI %s | poi %s | watch %s | super %s | insideBlob %s | wp %s"):format(
                        q, tostring(info.title), tostring(qm), tostring(qm and WorldOf(qm, .5, .5)),
                        tostring(onMap), tostring(localPOI),
                        p and ("%.3f,%.3f"):format(p.x or 0, p.y or 0) or "none",
                        tostring(safe(C_QuestLog.GetQuestWatchType, q)),
                        tostring(safe(C_SuperTrack.GetSuperTrackedQuestID) == q),
                        tostring(C_Minimap and safe(C_Minimap.IsInsideQuestBlob, q)),
                        wm and ("%s %.3f,%.3f"):format(tostring(wm), wx or 0, wy or 0) or "none")
                end
            end
        end
        A.tasks = {}
        for _, q in ipairs(safe(GetTasksTable) or {}) do
            local inArea, _, nObj, tname = safe(GetTaskInfo, q)
            if inArea then A.tasks[#A.tasks + 1] = ("%d %s objectives %s"):format(q, tostring(tname), tostring(nObj)) end
        end
        VoidQuestCharDB.areaProbe = A
    end
    -- your map pin: where it is, and where each map in its chain puts it
    local wp = VoidQuestCharDB and safe(C_Map.GetUserWaypoint)
    if wp and wp.uiMapID then
        local W = { at = date("%Y-%m-%d %H:%M:%S"), chain = {} }
        local a = wp.uiMapID
        for _ = 1, 5 do
            local mi = safe(C_Map.GetMapInfo, a)
            if not mi then break end
            local pos = safe(C_Map.GetUserWaypointPositionForMap, a)
            local px, py = PosXY(pos)
            W.chain[#W.chain + 1] = ("%d %s (type %s): %s"):format(a, tostring(mi.name), tostring(mi.mapType),
                px and ("%.3f, %.3f"):format(px, py) or "not on this map")
            a = mi.parentMapID
            if not (a and a > 0) then break end
        end
        local p = wp.position
        W.pin = ("%d @ %.3f, %.3f"):format(wp.uiMapID, p and p.x or 0, p and p.y or 0)
        VoidQuestCharDB.pinProbe2 = W
    end
    local qid = safe(C_SuperTrack.GetSuperTrackedQuestID)
    if not qid or qid == 0 or not VoidQuestCharDB then return end
    local function mapStr(m)
        local mi = m and m > 0 and safe(C_Map.GetMapInfo, m)
        return mi and ("%d %s (type %s, parent %s)"):format(m, tostring(mi.name), tostring(mi.mapType), tostring(mi.parentMapID)) or tostring(m)
    end
    local here = safe(C_Map.GetBestMapForUnit, "player")
    local pos = here and safe(C_Map.GetPlayerMapPosition, here, "player")
    local px, py = 0, 0
    if pos and pos.GetXY then px, py = pos:GetXY() end
    local P = { at = date("%Y-%m-%d %H:%M:%S"), qid = qid,
        title = safe(C_QuestLog.GetTitleForQuestID, qid),
        player = mapStr(here) .. (" @ %.3f, %.3f"):format(px or 0, py or 0),
        questUiMap = mapStr(safe(GetQuestUiMapID, qid)),
        isOnMap = tostring(safe(C_QuestLog.IsOnMap, qid)),
        classification = tostring(safe(C_QuestInfoSystem and C_QuestInfoSystem.GetQuestClassification, qid)),
        campaign = tostring(safe(C_CampaignInfo.GetCampaignID, qid)),
        isTask = tostring(safe(C_QuestLog.IsQuestTask, qid)),
        waypointText = tostring(safe(C_QuestLog.GetNextWaypointText, qid)),
        sources = {}, objectives = {} }
    local wm, wx, wy = safe(C_QuestLog.GetNextWaypoint, qid)
    P.nextWaypoint = ("%s @ %s, %s"):format(mapStr(wm), tostring(wx), tostring(wy))
    for _, s in ipairs(self:WaypointSources(qid)) do
        P.sources[#P.sources + 1] = ("%s: %s @ %.3f, %.3f"):format(s.name, mapStr(s.m), s.x, s.y)
    end
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
        P.objectives[#P.objectives + 1] = ("%s [%s] %s/%s"):format(tostring(o.text), tostring(o.type), tostring(o.numFulfilled), tostring(o.numRequired))
    end
    VoidQuestCharDB.trackProbe = P
end

function mod:XPProbe()
    local here = safe(C_Map.GetBestMapForUnit, "player")
    local cont = here and self:ContinentOf(here)
    if not cont then VQ:Print("xp probe: can't tell which continent you're on."); return end
    local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
    local maps = {}
    for _, c in ipairs(safe(C_Map.GetMapChildrenInfo, cont.mapID, zoneType, true) or {}) do maps[#maps + 1] = c end
    local list = {}
    for _, z in ipairs(maps) do
        safe(C_QuestLine.RequestQuestLinesForMap, z.mapID)
        for _, q in ipairs(safe(C_QuestLine.GetAvailableQuestLines, z.mapID) or {}) do
            if q.questID and not q.isHidden then
                safe(C_QuestLog.RequestLoadQuestByID, q.questID)
                if C_TaskQuest then safe(C_TaskQuest.RequestPreloadRewardData, q.questID) end
                list[#list + 1] = { z = z, q = q }
            end
        end
    end
    VQ:Print(("xp probe: %d quest offers in %d zones of %s -- reading in 3s..."):format(#list, #maps, cont.name or "?"))
    C_Timer.After(3, function()
        local out, perZone, order = {}, {}, {}
        out[1] = ("XP probe %s  level %d  continent %s"):format(date("%Y-%m-%d %H:%M"), UnitLevel("player") or 0, cont.name or "?")
        for _, e in ipairs(list) do
            local q, z = e.q, e.z
            local xp = safe(GetQuestLogRewardXP, q.questID)
            local lvl = safe(C_QuestLog.GetQuestDifficultyLevel, q.questID)
            local pz = perZone[z.mapID]
            if not pz then pz = { name = z.name, n = 0, known = 0, sum = 0 }; perZone[z.mapID] = pz; order[#order + 1] = z.mapID end
            pz.n = pz.n + 1
            if xp and xp > 0 then pz.known = pz.known + 1; pz.sum = pz.sum + xp end
            out[#out + 1] = ("  %-22s %6d %-34s xp=%s line=%d lvl=%s start=%s camp=%s imp=%s local=%s daily=%s"):format(
                z.name or "?", q.questID, (q.questName or "?"):sub(1, 34), tostring(xp), LineXP(q.questLineID, q.questID),
                tostring(lvl), tostring(q.startMapID), tostring(q.isCampaign), tostring(q.isImportant),
                tostring(q.isLocalStory), tostring(q.isDaily))
        end
        out[#out + 1] = "PER ZONE (offers / with xp / avg xp):"
        for _, id in ipairs(order) do
            local pz = perZone[id]
            out[#out + 1] = ("  %-22s %3d / %3d / %s"):format(pz.name or "?", pz.n, pz.known,
                pz.known > 0 and tostring(math.floor(pz.sum / pz.known)) or "-")
        end
        mod._xpIdx = nil
        local idx = mod:XPIndex()
        if idx then
            out[#out + 1] = ("DEDUPED BY START ZONE (storyline XP left, all tiers) -- normal quest = %s:"):format(kxp(idx.normal))
            for _, z in pairs(idx.zones) do out[#out + 1] = ("  %-22s %s"):format(z.name or "?", kxp(z.total)) end
            local big = mod:BigXPOffer()
            if big then out[#out + 1] = ("BIG XP: %s %s"):format(big.title or big.qid, kxp(big.xp)) end
        end
        VoidQuestCharDB = VoidQuestCharDB or {}
        VoidQuestCharDB.xpProbe = out
        VQ:ShowCopy("VoidQuest — XP probe (saved; /reload so Claude can read it)", table.concat(out, "\n"))
    end)
end

-- Wrap a zone-pool entry as a step object the panel/Waypoint understand.
function mod:ZoneStep(z)
    local status = "pickup"
    if z.inLog then status = safe(C_QuestLog.IsComplete, z.qid) and "turnin" or "progress" end
    return { qid = z.qid, status = status, title = z.title, zone = true,
             wpMap = z.map, wpX = z.x, wpY = z.y, xp = z.xp, lineXP = z.lineXP }
end

-- Decide the PRIMARY step: the campaign story while it's actionable, else (mid/max)
-- the nearest in-scope zone quest. "campaign first, then nearest."
-- When there's no campaign, mirror the Blizzard tracker: guide the CURRENT quest -- the
-- super-tracked one (what you're actively doing), else the first incomplete quest in the
-- log, else the first turn-in-ready. So the panel is never blank while you have quests.
function mod:CurrentQuestStep()
    local function valid(q) return q and q ~= 0 and safe(C_QuestLog.GetLogIndexForQuestID, q) end
    -- 1) the super-tracked quest (what you clicked / the game is guiding)
    local qid = safe(C_SuperTrack.GetSuperTrackedQuestID)
    if not valid(qid) then
        qid = nil
        -- 2) the WATCHED quests -- i.e. exactly what shows in Blizzard's tracker (prefer the
        -- first not-complete). This avoids grabbing background emissary/tracking quests
        -- (e.g. "Court of Farondis") that sit in the log but aren't what you're doing.
        local firstWatch
        for i = 1, (safe(C_QuestLog.GetNumQuestWatches) or 0) do
            local wq = safe(C_QuestLog.GetQuestIDForQuestWatchIndex, i)
            if wq then
                firstWatch = firstWatch or wq
                if not safe(C_QuestLog.IsComplete, wq) then qid = wq; break end
            end
        end
        qid = qid or firstWatch
        -- 3) last resort: first incomplete quest anywhere in the log
        if not qid then
            for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
                local info = safe(C_QuestLog.GetInfo, i)
                if info and not info.isHeader and info.questID and not safe(C_QuestLog.IsComplete, info.questID) then
                    qid = info.questID; break
                end
            end
        end
    end
    if not qid then return nil end
    return {
        qid = qid, questOnly = true,
        title = safe(C_QuestLog.GetTitleForQuestID, qid) or ("quest " .. qid),
        status = safe(C_QuestLog.IsComplete, qid) and "turnin" or "progress",
    }
end

-- Is the campaign's current step something to do HERE? In your log (doing it / turning it
-- in), or a pickup whose giver is on the continent you're on. A campaign from another
-- expansion still sitting in the log doesn't count.
function mod:CampaignHere(g)
    local cs = g and g.step
    if not cs or not cs.qid then return false end
    if cs.status ~= "pickup" then return true end
    local src = self:WaypointSources(cs.qid, g.ql)[1]
    local m = (cs.wpMap) or (src and src.m)
    local there = m and self:ContinentOf(m)
    local here = self:ContinentOf(safe(C_Map.GetBestMapForUnit, "player"))
    return there ~= nil and here ~= nil and there.mapID == here.mapID
end

function mod:ResolveRaw()
    local g = self:Compute()
    -- A followed ZONE GUIDE takes over the panel (like picking a guide) -- unless the
    -- campaign has a step here: the campaign is the main story and comes first. Before, a
    -- zone guide hid an in-log campaign quest ("Proving Oneself", Dragonflight, 2026-10-24)
    -- behind the nearest side storyline, and with Blizzard's tracker off it was invisible.
    if VQ.Zones and VQ.Zones:Active() and not self:CampaignHere(g) then
        local zg, zstep = VQ.Zones:Step()
        if zg then return { g = zg, primary = zstep, density = self:Density() } end
    end
    if not g then
        -- No campaign -> fall back to the current quest so the panel mirrors the Blizzard
        -- tracker instead of going blank ("why aren't my quests in VoidQuest").
        local qs = self:CurrentQuestStep()
        if qs then
            return { g = { campName = "Current quest", chapter = "" }, primary = qs,
                     questOnly = true, density = self:Density() }
        end
        return nil
    end
    local cs = g.step
    -- a campaign pickup with no giver on ANY map is "gated" (e.g. raid-locked) -> not actionable
    local campaignActionable = cs and not (cs.status == "pickup" and #self:WaypointSources(cs.qid, g.ql) == 0)
    -- "Reach level 90" sits in the log like any step, but walking to it does nothing: XP
    -- comes from everything else. Hand the main line to side quests in the zone with the
    -- most XP left (at least Mid scope, even on Min) until the level is reached.
    local levelGate = campaignActionable and self:LevelGate(cs)
    local pool, zoneRank
    if levelGate then
        pool, zoneRank = self:LevelPool(g.ql and g.ql.questLineID,
            (self:Density() == "max") and "max" or "mid")
    elseif self:Density() ~= "min" then
        pool = self:ZonePool(g.ql and g.ql.questLineID)
    end
    local primary, isZone
    -- level-gated and already carrying side quests here: finish those before new pickups
    local logged = levelGate and self:LoggedHere(cs and cs.qid)
    if logged then
        primary, isZone = logged, true
    elseif campaignActionable and not (levelGate and pool and #pool > 0) then
        primary = cs
    elseif pool and #pool > 0 then
        primary, isZone = self:ZoneStep(pool[1]), true
    else
        primary = cs   -- may be nil / gated -> handled by the panel text
    end
    -- STICKY SIDE QUEST. The pick above is nearest-first, so while you fly another quest
    -- became "nearest" for a moment (or a zone border changed the list) and the pin jumped
    -- 1.5k away, then back (2026-10-26). Keep the side quest already chosen until it's
    -- done, abandoned or no longer offered; proximity only picks the NEXT one.
    -- A quest whose pin you CLICKED is the step, whatever else is nearest or due -- the
    -- campaign included -- until it's turned in / dropped (lock released in Refresh).
    -- (applied on top of everything in mod:Resolve below; here it only stops the sticky
    -- side quest from overriding the locked one)
    local L = self._pinLock
    if isZone and primary then
        local kept = self._stick and self._stick.qid ~= primary.qid and self:StillDoable(self._stick)
        -- quests you carry here still come before a new pickup (Codex review)
        if kept and kept.status == "pickup" and logged then kept = nil end
        if L and L.qid == primary.qid then kept = nil end   -- the lock already decided
        if kept then primary = kept end
        self._stick = primary
    else
        self._stick = nil   -- the campaign has the step again
    end
    return { g = g, primary = primary, isZone = isZone, pool = pool, levelGate = levelGate, zoneRank = zoneRank,
             density = self:Density(), campaignGated = cs and not campaignActionable }
end

-- Is the side quest we stuck with still worth guiding? Its in-log step once accepted; the
-- same pickup while still offered; nil once turned in, abandoned or gone from the offers.
function mod:StillDoable(s)
    if not (s and s.qid) or safe(C_QuestLog.IsQuestFlaggedCompleted, s.qid) then return nil end
    if safe(C_QuestLog.GetLogIndexForQuestID, s.qid) then
        return { qid = s.qid, zone = true, xp = s.xp, lineXP = s.lineXP,
                 title = s.title or safe(C_QuestLog.GetTitleForQuestID, s.qid),
                 status = safe(C_QuestLog.IsComplete, s.qid) and "turnin" or "progress" }
    end
    if s.status ~= "pickup" then return nil end   -- was in the log, now isn't: turned in / dropped
    local idx = self._xpIdx
    if idx and idx.entries then   -- still offered? (no index inside instances: keep it)
        local found = false
        for _, e in ipairs(idx.entries) do if e.qid == s.qid then found = true; break end end
        if not found then return nil end
    end
    return s
end

-- The nearest quest in your log with its objective / turn-in on the map you're on (not
-- the campaign step, not world quests or bonus tasks) as a zone step, or nil.
function mod:LoggedHere(excludeQid)
    local here = safe(C_Map.GetBestMapForUnit, "player")
    if not here then return nil end
    local pos = safe(C_Map.GetPlayerMapPosition, here, "player")
    local px, py = 0.5, 0.5
    if pos and pos.GetXY then local a, b = pos:GetXY(); if a then px, py = a, b end end
    local best, bestD
    for _, q in ipairs(safe(C_QuestLog.GetQuestsOnMap, here) or {}) do
        local qid = q.questID
        if qid and qid ~= excludeQid and q.x and safe(C_QuestLog.GetLogIndexForQuestID, qid)
           and not safe(C_QuestLog.IsWorldQuest, qid) and not safe(C_QuestLog.IsQuestTask, qid) then
            local dx, dy = q.x - px, q.y - py
            local d = dx * dx + dy * dy
            if not bestD or d < bestD then best, bestD = qid, d end
        end
    end
    if not best then return nil end
    return { qid = best, zone = true, title = safe(C_QuestLog.GetTitleForQuestID, best),
             status = safe(C_QuestLog.IsComplete, best) and "turnin" or "progress" }
end

-- What the panel guides: ResolveRaw's pick, except that a quest whose pin you CLICKED
-- (step line or an extra line) stays the step until it's turned in, dropped or no longer
-- offered -- in every mode: campaign, zone guide, level gate, no campaign at all (Codex
-- review: early returns used to skip the lock). The lock ends here or in Refresh.
function mod:Resolve()
    local r = self:ResolveRaw()
    local L = self._pinLock
    if not L then return r end
    -- (quest-only mode renders a list without pins, so it still gets converted below)
    if r and not r.questOnly and r.primary and r.primary.qid == L.qid then return r end
    local locked = self:StillDoable(L.step or { qid = L.qid, status = "pickup", zone = true })
    if not (locked and (locked.status ~= "pickup" or locked.wpMap or not locked.zone)) then
        -- gone (done, dropped, no longer offered): never freeze the arrow on it
        if self._sidePin == L.qid then self._sidePin = nil end
        self._pinLock = nil
        self._lastStep = nil
        return r
    end
    if not r or r.questOnly then
        return { g = { campName = "Pinned quest", chapter = "" }, primary = locked, isZone = true,
                 density = self:Density() }
    end
    r.primary, r.isZone = locked, locked.zone and true or r.isZone
    return r
end

-- A campaign step whose open objective is "reach level N" (N above yours) -> N, else nil.
function mod:LevelGate(step)
    if not (step and step.qid and step.status == "progress") then return nil end
    local lvl = UnitLevel("player") or 0
    local word = ((type(LEVEL) == "string" and LEVEL ~= "") and LEVEL or "level"):lower()
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, step.qid) or {}) do
        if not o.finished and type(o.text) == "string" then
            local t = o.text:lower()
            local s = t:find(word, 1, true)
            -- "reach level 90", or number-first locales ("90 레벨")
            local want = s and tonumber(t:match("^%s*(%d+)", s + #word) or t:sub(1, s - 1):match("(%d+)%s*$"))
            if want and want > lvl then return want end
        end
    end
end

-- Map position -> world yards (nil when the game can't place it, e.g. in an instance).
local function WorldXY(m, x, y)
    if not (m and x and y and CreateVector2D and C_Map.GetWorldPosFromMapPos) then return nil end
    local cont, w = safe(C_Map.GetWorldPosFromMapPos, m, CreateVector2D(x, y))
    if not (cont and w) then return nil end
    local wx, wy = w:GetXY()
    return wx, wy, cont
end
local function YardsBetween(a, b)
    if not (a and b) or a.c ~= b.c then return nil end
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end
local function Pt(m, x, y)
    local wx, wy, c = WorldXY(m, x, y)
    return wx and { x = wx, y = wy, c = c } or nil
end
mod.SIDE_DETOUR = 150   -- yards of extra travel a side quest may add to the trip

-- Where the main step sends you on the current map: the giver for a pickup, else the
-- quest's own map POI (objective area, or the turn-in once complete). nil if elsewhere.
function mod:StepTarget(step, ql, map)
    if not step then return nil end
    if step.status == "pickup" then
        if step.wpMap == map and step.wpX then return step.wpX, step.wpY end
        for _, s in ipairs(self:WaypointSources(step.qid, ql)) do
            if s.m == map then return s.x, s.y end
        end
        return nil
    end
    for _, q in ipairs(safe(C_QuestLog.GetQuestsOnMap, map) or {}) do
        if q.questID == step.qid and q.x then return q.x, q.y end
    end
    local wm, wx, wy = safe(C_QuestLog.GetNextWaypoint, step.qid)
    if wm == map and wx then return wx, wy end
end

-- The side quest worth grabbing on the way: the in-scope zone quest whose giver adds
-- the least travel to where the main step sends you (or is closest to you when the step
-- has no spot here). Nothing halfway across the zone: over SIDE_DETOUR yards it's skipped.
-- Also returns how many in-scope quests the zone has left (for the "before you leave" hint).
function mod:SideQuest(r, ql)
    local pool, step = r.pool, r.primary
    if not (pool and step) then return nil end
    local map = safe(C_Map.GetBestMapForUnit, "player")
    local pos = map and safe(C_Map.GetPlayerMapPosition, map, "player")
    local px, py
    if pos then
        if pos.GetXY then px, py = pos:GetXY() elseif pos.x then px, py = pos.x, pos.y end
    end
    local P = px and Pt(map, px, py)
    if not P then return nil end
    local tx, ty = self:StepTarget(step, ql, map)
    local D = tx and Pt(map, tx, ty)
    local PD = D and YardsBetween(P, D)
    local best, bestCost, left = nil, nil, 0
    for _, e in ipairs(pool) do
        if e.map == map and e.qid ~= step.qid and not e.inLog then
            left = left + 1
            local E = (e.x and e.x > 0) and Pt(map, e.x, e.y)
            local PE = E and YardsBetween(P, E)
            local cost
            if PE and D and PD then
                local ED = YardsBetween(E, D)
                cost = ED and (PE + ED - PD)
            else
                cost = PE
            end
            if cost and cost <= self.SIDE_DETOUR and (not bestCost or cost < bestCost) then
                best, bestCost = e, cost
                best.yards = PE
            end
        end
    end
    return best, left, D ~= nil
end

----------------------------------------------------------------------
-- Persistent auto-advancing panel
----------------------------------------------------------------------
local VERB = { pickup = "Pick up", progress = "Complete", turnin = "Turn in" }

function mod:EnsurePanel()
    if self.frame then return self.frame end
    local f = CreateFrame("Frame", "VoidQuestGuidePanel", UIParent, "BackdropTemplate")
    f:SetSize(PW(), 90)
    local p = (VoidQuestDB and VoidQuestDB.guidePoint) or { "RIGHT", -24, 120 }
    f:SetPoint(p[1], UIParent, p[1], p[2], p[3])
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(s) if not VQ:Get("lockPanel") then s:StartMoving() end end)
    f:SetScript("OnDragStop", function(s)
        s:StopMovingOrSizing()
        local a, _, _, x, y = s:GetPoint()
        VoidQuestDB.guidePoint = { a, x, y }
    end)
    VQ:CreateBackdrop(f, 0.9)
    -- Resize: drag the grip in the bottom-right corner (the player, 2026-11-05: "drag the
    -- box to make it bigger"). Width and height are saved (panelWidth / panelHeight; the
    -- height is the panel's fixed size, more room = more quest lines). Not in combat: the
    -- panel holds a secure quest-item button, so it can't be resized then.
    f:SetResizable(true)
    if f.SetResizeBounds then f:SetResizeBounds(PANEL_W_MIN, 120, PANEL_W_MAX, 800) end
    f.grip = CreateFrame("Button", nil, f)
    f.grip:SetSize(14, 14); f.grip:SetPoint("BOTTOMRIGHT", -2, 2)
    f.grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    f.grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    f.grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    f.grip:SetScript("OnMouseDown", function(_, btn)
        if btn ~= "LeftButton" or InCombatLockdown() or VQ:Get("lockPanel") then return end
        f._sizing = true
        f:StartSizing("BOTTOMRIGHT")
    end)
    -- Live while dragging (the user, 2026-11-10: "make sure it can grow and shrink depending on
    -- how i shape it"): the lines, buttons and title follow the edge, and a taller / shorter
    -- panel shows more / fewer quest lines as you drag. At most 10 redraws a second; the
    -- height is the drag's (PanelHeight skips while sizing); saved and rounded on let go.
    f:SetScript("OnSizeChanged", function(self)
        if not self._sizing or self._livePending then return end
        self._livePending = true
        C_Timer.After(0.1, function()
            self._livePending = nil
            if not self._sizing or (InCombatLockdown() and self:IsProtected()) then return end
            VoidQuestDB.panelWidth = self:GetWidth()
            VoidQuestDB.panelHeight = self:GetHeight()
            self._live = true
            local ok, err = pcall(mod.Refresh, mod)
            self._live = nil
            if not ok then geterrorhandler()(err) end
        end)
    end)
    -- Let go: stop, save, redraw. If a fight started mid-drag the panel is protected and
    -- can't be stopped now -- finish as soon as combat ends.
    local function finishSizing()
        if not f._sizing then return end
        if InCombatLockdown() and f:IsProtected() then
            f._finishAfterCombat = true
            f:RegisterEvent("PLAYER_REGEN_ENABLED")
            return
        end
        f._sizing, f._finishAfterCombat = nil, nil
        f:StopMovingOrSizing()
        VoidQuestDB.panelWidth = math.floor(f:GetWidth() + 0.5)
        VoidQuestDB.panelHeight = math.floor(f:GetHeight() + 0.5)
        -- keep the panel where it is (StartSizing re-anchors it to its top-left)
        local a, _, _, x, y = f:GetPoint()
        VoidQuestDB.guidePoint = { a, x, y }
        mod:ApplyWidth()
        mod:Refresh()
    end
    f.grip:SetScript("OnMouseUp", finishSizing)
    f:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_ENABLED" and f._finishAfterCombat then
            f:UnregisterEvent("PLAYER_REGEN_ENABLED")
            finishSizing()
        end
    end)
    f.grip:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Drag to resize")
        GameTooltip:AddLine("Taller shows more quest lines.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    f.grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.camp = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(f.camp, 12, "OUTLINE"); f.camp:SetPoint("TOPLEFT", 12, -9); f.camp:SetWidth(PW() - 200); f.camp:SetWordWrap(false); f.camp:SetJustifyH("LEFT")
    f.chapter = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(f.chapter, 10); f.chapter:SetPoint("TOPLEFT", 12, -27); f.chapter:SetWidth(CW()); f.chapter:SetWordWrap(false); f.chapter:SetJustifyH("LEFT"); f.chapter:SetTextColor(1, 0.82, 0)
    -- Zones | Dungeons tabs, in the chapter line's spot (WoW Forever's zone guide; the
    -- player, 2026-11-05: "make it a button, next to it put dungeons as a button"). They
    -- switch the quest lines under the guide; the guide's own step stays.
    local function makeTab(key)
        local b = CreateFrame("Button", nil, f)
        b:SetHeight(14)
        b.text = b:CreateFontString(nil, "OVERLAY"); VQ:SetFont(b.text, 10, "OUTLINE")
        b.text:SetPoint("LEFT", 0, 0)
        b.line = b:CreateTexture(nil, "OVERLAY"); b.line:SetHeight(1)
        b.line:SetPoint("BOTTOMLEFT", 0, 0); b.line:SetPoint("BOTTOMRIGHT", 0, 0)
        b.line:SetColorTexture(0, 0.78, 1, 0.9)
        b:SetScript("OnClick", function() mod:SetQuestTab(key) end)
        b:Hide()
        return b
    end
    f.tabZones, f.tabDungeons = makeTab("zones"), makeTab("dungeons")
    f.step = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(f.step, 12); f.step:SetPoint("TOPLEFT", 12, -44); f.step:SetWidth(CW()); f.step:SetJustifyH("LEFT")
    f.obj = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(f.obj, 10); f.obj:SetPoint("TOPLEFT", f.step, "BOTTOMLEFT", 0, -4); f.obj:SetWidth(CW()); f.obj:SetJustifyH("LEFT"); f.obj:SetTextColor(0.7, 0.7, 0.7)

    -- Blizzard-tracker show/hide checkbox (far right) + gear + density + quest-line picker
    f.trackerCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.trackerCheck:SetSize(22, 22); f.trackerCheck:SetPoint("BOTTOMRIGHT", -18, 1)   -- bottom row, left of the resize grip
    f.trackerCheck:SetChecked(VQ:Get("blizzTracker") ~= false)
    f.trackerCheck:SetScript("OnClick", function(s)
        if blizzTrackerNeeded() then
            -- Inside an instance the tracker defaults ON (M+ timer, delve/dungeon
            -- objectives live only there). Unchecking hides it for THIS instance only;
            -- the saved outdoor preference is untouched. (It used to snap straight
            -- back to checked here, which read as VoidQuest locking up.)
            mod._instanceHide = not s:GetChecked()
            mod._instanceHideID = select(8, GetInstanceInfo())   -- which instance it applies to
            if mod._instanceHide and InCombatLockdown() then
                VQ:Print("Blizzard's tracker will hide when combat ends.")
            end
        else
            VQ:Set("blizzTracker", s:GetChecked() and true or false)
        end
        mod:ApplyBlizzTracker()
    end)
    f.trackerCheck:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_LEFT")
        GameTooltip:SetText("Blizzard quest tracker")
        GameTooltip:AddLine("Checked = show Blizzard's default tracker.", .8, .8, .8, true)
        GameTooltip:AddLine("Uncheck to hide it (VoidQuest lists your quests here).", .8, .8, .8, true)
        if blizzTrackerNeeded() then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("In dungeons and delves it's on by default: it holds the Mythic+ timer, enemy forces and stage objectives. Unchecking here hides it for this instance only.", 1, .82, 0, true)
        end
        GameTooltip:Show()
    end)
    f.trackerCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.cfgBtn = CreateFrame("Button", nil, f)
    f.cfgBtn:SetSize(18, 18); f.cfgBtn:SetPoint("TOPRIGHT", f.trackerCheck, "TOPLEFT", -1, -2)
    f.cfgBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    f.cfgBtn:SetHighlightTexture("Interface\\Buttons\\UI-OptionsButton", "ADD")
    f.cfgBtn:SetScript("OnClick", function() if VQ.Settings then VQ.Settings:Toggle() end end)
    f.cfgBtn:SetScript("OnEnter", function(s) GameTooltip:SetOwner(s, "ANCHOR_LEFT"); GameTooltip:SetText("VoidQuest settings"); GameTooltip:Show() end)
    f.cfgBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.densityBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.densityBtn:SetSize(42, 18); f.densityBtn:SetPoint("TOPRIGHT", f.cfgBtn, "TOPLEFT", -3, 0)
    f.densityBtn:SetText(DENSITY_SHORT[self:Density()])
    f.densityBtn:SetScript("OnClick", function() mod:CycleDensity() end)
    f.densityBtn:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_LEFT")
        GameTooltip:AddLine("Quest density (click to cycle)")
        if VQ.ForeverQuests then
            -- WoW Forever: which quests the guide and the map's "!" suggest (Chains.lua)
            GameTooltip:AddLine("Min = important quests: dungeon, elite and class quests, blue rewards, and chains that lead to them", .7, .7, .7, true)
            GameTooltip:AddLine("Mid = + every quest on a known chain", .7, .7, .7)
            GameTooltip:AddLine("Max = every quest", .7, .7, .7)
            GameTooltip:AddLine("Quests in your log always show. A yellow star marks the important ones.", .7, .7, .7, true)
        else
            GameTooltip:AddLine("Min = story campaign only", .7, .7, .7)
            GameTooltip:AddLine("Mid = + the zone's side storylines", .7, .7, .7)
            GameTooltip:AddLine("Max = every quest in the zone", .7, .7, .7)
            GameTooltip:AddLine("Mid and Max also show a side quest on the way to your current step.", .7, .7, .7, true)
        end
        GameTooltip:Show()
    end)
    f.densityBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.pickBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.pickBtn:SetSize(42, 18); f.pickBtn:SetPoint("TOPRIGHT", f.densityBtn, "TOPLEFT", -3, 0)
    f.pickBtn:SetText("Lines")
    f.pickBtn:SetScript("OnClick", function() mod:TogglePicker() end)

    -- "where do I level?" -- shows/hides the Leveling Coach strip (step-by-step to max level)
    f.zoneBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.zoneBtn:SetSize(46, 18); f.zoneBtn:SetPoint("TOPRIGHT", f.pickBtn, "TOPLEFT", -3, 0)
    f.zoneBtn:SetText("Level")
    f.zoneBtn:SetScript("OnClick", function() if VQ.Coach then VQ.Coach:Toggle() end end)
    f.zoneBtn:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_LEFT")
        GameTooltip:AddLine("Leveling Coach")
        GameTooltip:AddLine("Shows or hides the coach strip at the top of this panel: the next thing to do to level fast -- pick an era, get there, quest the zone that fits you -- with a pin. 'All zones...' lists every zone storyline.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.zoneBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- WoW Forever: no Chromie / expansion coach there; the button opens the zone's full
    -- quest list instead (ForeverZone.lua)
    if VQ.ForeverQuests and VQ.Forever then
        f.zoneBtn:SetText("Zone")
        f.zoneBtn:SetScript("OnClick", function() VQ.Forever:Toggle() end)
        f.zoneBtn:SetScript("OnEnter", function(s)
            GameTooltip:SetOwner(s, "ANCHOR_LEFT")
            GameTooltip:AddLine("Zone quests")
            GameTooltip:AddLine("Every quest in this zone you can do: done, in your log, or still open. Click one to pin where it starts (when known). Known starts also show as a \"!\" on your world map.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        -- the Quest Book (QuestBook.lua): every zone, done / can do, search by reward item
        f.bookBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        f.bookBtn:SetSize(46, 18); f.bookBtn:SetPoint("TOPRIGHT", f.zoneBtn, "TOPLEFT", -3, 0)
        f.bookBtn:SetText("Book")
        f.bookBtn:SetScript("OnClick", function() if VQ.Book then VQ.Book:Toggle() end end)
        f.bookBtn:SetScript("OnEnter", function(s)
            GameTooltip:SetOwner(s, "ANCHOR_LEFT")
            GameTooltip:AddLine("Quest Book")
            GameTooltip:AddLine("Every quest in every zone: what you've done, what you can do now, what comes later. Search by quest, zone or reward item.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        f.bookBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- (2026-11-10: no Share button any more; each quest line has a small "S" in a group, see
    -- SetLineParty. A one-click "share everything" pushed a whole log on 4 people.)
    mod:FitHeader(f)

    -- click the STEP or OBJECTIVE line to (re)pin its waypoint -- "take me there"
    local function pinClick()
        -- shift: VoidGPS guides you there instead (the tooltip says so when it's in another zone)
        if IsShiftKeyDown() and mod:GuideToQuest(mod._stepQid) then return end
        mod:TakeTrack(); mod._sidePin = nil
        -- lock the arrow to THIS quest until it's turned in / dropped (see Waypoint, Resolve)
        mod._pinLock = mod._stepQid and { qid = mod._stepQid, step = mod._shownStep } or nil
        mod:Refresh()
        -- say what happened: a pin (where), or the quest itself being tracked
        local wp = mod._wp
        if wp then
            local mi = safe(C_Map.GetMapInfo, wp.m)
            VQ:Print(("pin set at %.1f, %.1f in %s -- open your map (M) to see it."):format(
                wp.x * 100, wp.y * 100, (mi and mi.name) or ("map " .. wp.m)))
        else
            VQ:Print("no pin for this step -- if the quest is in your log, its area is tracked on your map instead.")
        end
    end
    local function pinEnter(s)
        local qid = mod._stepQid
        if qid and mod.StepTooltip then mod:StepTooltip(s, qid) return end
        GameTooltip:SetOwner(s, "ANCHOR_LEFT")
        GameTooltip:SetText("Click: set a map pin for this step")
        GameTooltip:Show()
    end
    f.stepBtn = CreateFrame("Button", nil, f)
    f.stepBtn:SetAllPoints(f.step)
    f.stepBtn:SetScript("OnClick", pinClick)
    f.stepBtn:SetScript("OnEnter", pinEnter)
    f.stepBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.objBtn = CreateFrame("Button", nil, f)
    f.objBtn:SetAllPoints(f.obj)
    f.objBtn:SetScript("OnClick", pinClick)
    f.objBtn:SetScript("OnEnter", pinEnter)
    f.objBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- second line: a side quest on the way (Mid/Max), or what's left before leaving the zone.
    -- Click pins its giver; clicking the step line pins the main step again.
    local function pinExtra(e)
        if not (e and e.x and e.x > 0) then return end
        mod._manual = nil   -- clicked on the panel: the guide may set the arrow again
        if mod:SetOurWaypoint(e.map, e.x, e.y, e.qid) then
            mod._sidePin = e.qid
            -- same lock as a step-line click: the arrow follows THIS quest from its giver to
            -- its objectives and turn-in (Codex review: it used to let go on accept)
            mod._pinLock = { qid = e.qid, step = { qid = e.qid, status = "pickup", zone = true, title = e.title,
                wpMap = e.map, wpX = e.x, wpY = e.y, xp = e.xp, lineXP = e.lineXP } }
            local mi = safe(C_Map.GetMapInfo, e.map)
            VQ:Print(("pin set on %s at %.1f, %.1f in %s. Click the step line to go back to the main step."):format(
                e.title or "the side quest", e.x * 100, e.y * 100, (mi and mi.name) or ("map " .. e.map)))
        end
    end
    local function extraLine(tip, detail, key)
        local fs = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(fs, 10); fs:SetWidth(CW()); fs:SetJustifyH("LEFT")
        fs:Hide()
        local b = CreateFrame("Button", nil, f)
        b:SetAllPoints(fs)
        b:SetScript("OnClick", function() pinExtra(mod[key]) end)
        b:SetScript("OnEnter", function(s)
            GameTooltip:SetOwner(s, "ANCHOR_LEFT")
            GameTooltip:SetText(tip)
            GameTooltip:AddLine(detail, .8, .8, .8, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:Hide()
        return fs, b
    end
    f.side, f.sideBtn = extraLine("Click: pin this side quest's giver",
        "Only quests that add little travel to your current step show here.", "_side")
    -- big-XP offer anywhere on the continent (dungeon / special quest)
    -- activity ("meta") quest not picked up yet: its activities only count once accepted
    f.meta, f.metaBtn = extraLine("Click: pin this quest's giver",
        "An activity quest: the dungeons, delves or world quests it asks for only count after you pick it up. Grab it before you run them.", "_meta")
    f.big, f.bigBtn = extraLine("Click: pin this quest's giver",
        "Worth 3+ normal quests at your level -- worth the trip from another zone.", "_big")
    -- the way to the step when it's in another zone (VoidGPS): click = guide me there
    f.way, f.wayBtn = extraLine("Click: guide me there",
        "VoidGPS leads you leg by leg: the flight paths, zeppelins and boats to take, then the path to walk.", "_way")
    f.wayBtn:SetScript("OnClick", function() mod:GuideToQuest(mod._stepQid) end)

    f.questRows = {}   -- pool for the "all current quests" list (quest-only mode)
    f.popupRows = {}   -- pool for auto-quest OFFER/COMPLETE alert rows
    self.frame = f
    self:ApplyPanelStyle()
    return f
end

-- Show/hide Blizzard's default quest tracker (ObjectiveTrackerFrame). Combat-guarded to
-- avoid taint; re-applied after combat + on every refresh so it stays as chosen (the
-- tracker re-shows itself on quest events otherwise).
-- Inside delves / the Labyrinth / dungeons the room & stage objectives live ONLY in
-- Blizzard's tracker (scenario block), so it shows there by default whatever the
-- outdoor setting (2026-10-21: hiding it hid every Labyrinth room objective);
-- unchecking the box inside hides it for that instance only (mod._instanceHide).
-- blizzTrackerNeeded() is defined near the top of the file.

function mod:ApplyBlizzTracker()
    local inInstance = blizzTrackerNeeded()
    if not inInstance then self._instanceHide = nil end   -- per-instance choice ends on leaving
    local want = VQ:Get("blizzTracker") ~= false or (inInstance and not self._instanceHide)
    if inInstance and self._instanceHide then want = false end
    if self.frame and self.frame.trackerCheck then self.frame.trackerCheck:SetChecked(want) end
    local otf = _G.ObjectiveTrackerFrame
    if not otf then return end
    -- Hook Show ONCE so any Blizzard re-show (super-track/quest events pop the tracker open)
    -- is countered on the same frame -- kills the ~0.4s flash we got when only re-hiding on
    -- the debounced refresh. Out-of-combat only (hiding a secure frame in combat taints).
    if not self._otfHooked then
        self._otfHooked = true
        -- In combat the frame can't be hidden (it holds secure quest-item buttons), and
        -- combat is exactly when Blizzard pops it open (attacking a bonus-objective mob,
        -- 2026-10-24). So in combat it goes fully transparent instead (SetAlpha isn't
        -- protected); after combat ApplyBlizzTracker hides it properly and restores alpha.
        local function enforce(s)
            local inInst = blizzTrackerNeeded()
            local hide = (inInst and mod._instanceHide)
                or (not inInst and VQ:Get("blizzTracker") == false)
            if not hide then return end
            if InCombatLockdown and InCombatLockdown() then
                s:SetAlpha(0); mod._otfFaded = true
            else
                s:Hide()
            end
        end
        pcall(hooksecurefunc, otf, "Show", enforce)
        -- Blizzard also re-shows it with SetShown(true), which the Show hook never saw
        pcall(hooksecurefunc, otf, "SetShown", function(s, shown) if shown then enforce(s) end end)
        -- re-evaluate on every zone-in/out (entering a delve must bring it back)
        local zf = CreateFrame("Frame")
        zf:RegisterEvent("PLAYER_ENTERING_WORLD")
        zf:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        zf:RegisterEvent("PLAYER_REGEN_ENABLED")
        zf:SetScript("OnEvent", function(_, event)
            -- A loading screen into a DIFFERENT instance starts fresh (tracker back on).
            -- Same instance (a teleport with a loading screen mid-run) keeps the choice --
            -- clearing on every PLAYER_ENTERING_WORLD popped it back mid-dungeon (Codex review).
            -- Leaving the instance clears it in ApplyBlizzTracker.
            if event == "PLAYER_ENTERING_WORLD" and select(8, GetInstanceInfo()) ~= mod._instanceHideID then
                mod._instanceHide = nil
            end
            C_Timer.After(0.5, function() mod:ApplyBlizzTracker() end)
        end)
    end
    if InCombatLockdown and InCombatLockdown() then
        if not want and otf:IsShown() then otf:SetAlpha(0); self._otfFaded = true end
        if want and self._otfFaded then self._otfFaded = nil; otf:SetAlpha(1) end   -- turned back on mid-combat
        return
    end
    if otf:IsShown() ~= want then otf:SetShown(want) end
    if self._otfFaded then   -- undo the in-combat fade once it's really hidden (or wanted back)
        self._otfFaded = nil
        otf:SetAlpha(1)
    end
end

-- Apply live-adjustable style from Settings (scale, opacity, objective-line visibility).
function mod:ApplyPanelStyle()
    local f = self.frame
    if not f then return end
    f:SetScale(VQ:Get("panelScale") or 1.0)
    if VQ.palette and VQ.palette.bg then
        f:SetBackdropColor(VQ.palette.bg[1], VQ.palette.bg[2], VQ.palette.bg[3], VQ:Get("panelOpacity") or 0.9)
    end
    if f.obj then f.obj:SetShown(VQ:Get("showObjective") ~= false) end
end

-- Toggle the guide panel's visibility (bound to /vq + the minimap button now that the
-- legacy JourneyTracker panel is retired). guideHidden is a preference (account-wide).
function mod:ToggleShown()
    VoidQuestDB.guideHidden = not VoidQuestDB.guideHidden
    if VoidQuestDB.guideHidden then
        self:ClearOurWaypoint()
        if self.frame then self.frame:Hide() end
    else
        self:Refresh()   -- always shows now: a campaign, or the "select one" state
    end
end

-- A switch in the Void hub's quick box (left-click the hub; VoidHubBundle.lua). The panel
-- holds secure quest-item buttons, so in combat it waits for the fight to end.
VoidHubToggles = VoidHubToggles or {}
table.insert(VoidHubToggles, {
    id = "VoidQuest.panel", group = "Quests", label = "Quest panel", noCombat = true,
    tip = "VoidQuest's guide box with your next step and quests. Hiding it also drops its arrow.",
    get = function() return VoidQuestDB and not VoidQuestDB.guideHidden end,
    set = function(on)
        if (not VoidQuestDB.guideHidden) ~= (on and true or false) then mod:ToggleShown() end
    end,
})

function mod:ResetPos()
    VoidQuestDB.guidePoint = nil
    if self.frame then
        self.frame:ClearAllPoints()
        self.frame:SetPoint("RIGHT", UIParent, "RIGHT", -24, 120)
    end
    VQ:Print("Guide panel position reset.")
end

-- All current quests to list, mirroring the Blizzard tracker: watched quests first (or the
-- whole log if nothing's watched), PLUS the auto-added in-area content the tracker shows --
-- world-quest watches (auto-watched when you enter their area) and bonus-objective tasks.
-- Returns (list of qids, kinds map qid->"wq"|"task" for tagging).
function mod:CurrentQuests()
    local out, seen, kinds = {}, {}, {}
    for i = 1, (safe(C_QuestLog.GetNumQuestWatches) or 0) do
        local qid = safe(C_QuestLog.GetQuestIDForQuestWatchIndex, i)
        if qid and not seen[qid] and safe(C_QuestLog.GetLogIndexForQuestID, qid) then
            seen[qid] = true; out[#out + 1] = qid
        end
    end
    if #out == 0 then
        for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
            local info = safe(C_QuestLog.GetInfo, i)
            if info and not info.isHeader and info.questID and not seen[info.questID] then
                seen[info.questID] = true; out[#out + 1] = info.questID
            end
        end
    end
    -- world quests the game auto-watches when you're in their area
    for i = 1, (safe(C_QuestLog.GetNumWorldQuestWatches) or 0) do
        local qid = safe(C_QuestLog.GetQuestIDForWorldQuestWatchIndex, i)
        if qid and not seen[qid] then
            seen[qid] = true; out[#out + 1] = qid; kinds[qid] = "wq"
        end
    end
    -- in-area bonus objectives / tasks (not in the normal log). Filter like Blizzard's
    -- tracker does -- GetTaskInfo: only IN-AREA tasks WITH objectives. This drops hidden
    -- internal tracking quests ("HIDDEN QUEST - ..." titles) that the game keeps but never
    -- displays. taskName from GetTaskInfo is the real display title.
    local titles = {}
    for _, qid in ipairs(safe(GetTasksTable) or {}) do
        if qid and not seen[qid] and not safe(C_QuestLog.IsQuestFlaggedCompleted, qid) then
            local isInArea, _, numObjectives, taskName = safe(GetTaskInfo, qid)
            if isInArea and (numObjectives or 0) > 0
               and not (taskName and taskName:find("HIDDEN", 1, true)) then
                seen[qid] = true; out[#out + 1] = qid; kinds[qid] = "task"
                if taskName and taskName ~= "" then titles[qid] = taskName end
            end
        end
    end
    return out, kinds, titles
end

-- n = characters that fit the default 284 px width; scaled to the panel's width now
local function truncTo(s, n)
    n = math.floor(n * CW() / 284)
    return (#s > n) and (s:sub(1, n - 2) .. "..") or s
end

-- Quests with a progress-bar objective ("camp invaded 8%", bonus objectives): their
-- percent, else nil. Blizzard's tracker draws these bars; with it hidden we draw our own.
local function ProgressPercent(qid)
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
        if o.type == "progressbar" then
            return safe(GetQuestProgressBarPercent, qid) or 0
        end
    end
end

local function MakeProgressBar(parent, w)
    local b = CreateFrame("StatusBar", nil, parent)
    b:SetSize(w, 8)
    b:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    b:SetStatusBarColor(1, 0.78, 0.18)
    b:SetMinMaxValues(0, 100)
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints(); b.bg:SetColorTexture(0, 0, 0, 0.55)
    b.text = b:CreateFontString(nil, "OVERLAY"); VQ:SetFont(b.text, 8, "OUTLINE")
    b.text:SetPoint("CENTER")
    b:Hide()
    return b
end

local function SetProgress(bar, pct)
    if not pct then bar:Hide() return end
    bar:SetValue(pct)
    bar.text:SetText(("%d%%"):format(math.floor(pct + 0.5)))
    bar:Show()
end

----------------------------------------------------------------------
-- QUEST LINES (2026-10-26, "stop having to look at VoidQuest AND Blizzard's tracker"):
-- the panel keeps a FIXED height (setting panelHeight) and fills whatever the guide
-- leaves free with one line per quest -- this zone's first (C_QuestLog.IsOnMap, the
-- tracker's own "in zone" test), in-area events / world quests / bonus objectives on
-- top; when the zone has none, quests from other zones (same continent first) with the
-- zone named, so you can click one to go there. What doesn't fit is "+N more": hover
-- lists it, click opens My Quests (click a quest there to track it). Clicking a line
-- tracks that quest; that's your choice, so the guide holds the arrow (manual hold).
----------------------------------------------------------------------
local QROW = 13

-- One-line objective summary: "turn in", a progress-bar percent, or the first
-- unfinished objective (+N when there are more).
local function ObjSummary(qid)
    if safe(C_QuestLog.IsComplete, qid) then return "|cff55ff55turn in|r" end
    local pct = ProgressPercent(qid)
    if pct then return ("%d%%"):format(math.floor(pct + 0.5)) end
    local first, more = nil, 0
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
        if o.text and o.text ~= "" and not o.finished then
            if first then more = more + 1 else first = o.text end
        end
    end
    if not first then return "" end
    return first .. (more > 0 and (" |cff888888+%d|r"):format(more) or "")
end

-- Zone name for a quest's map (a cave / district rolls up to its zone; an instance keeps
-- its own name -- "Eversong Woods" for a Labyrinth quest sent the player looking there).
local function QuestZone(qid)
    local m = safe(GetQuestUiMapID, qid)
    local mi = m and m > 0 and safe(C_Map.GetMapInfo, m)
    while mi and Enum.UIMapType and mi.mapType and mi.mapType > Enum.UIMapType.Zone
          and mi.mapType ~= Enum.UIMapType.Dungeon
          and mi.parentMapID and mi.parentMapID > 0 do
        m = mi.parentMapID; mi = safe(C_Map.GetMapInfo, m)
    end
    return mi and mi.name, m
end


-- A quest belongs on "this zone's" lines when: you just picked it up (15 min -- it's what
-- you're doing now), the game shows it on your map, its map is your zone, or it has no
-- map at all (do-anywhere: "upgrade an item"). Upgrade Practicum, picked up in Silvermoon,
-- sat behind "+12 more" with a Silvermoon quest tagged [Silvermoon City] (2026-10-27).
-- A dungeon or raid quest (grouped on its own in the quest lines).
--   WoW Forever: Blizzard's quest data flags them (ForeverQuests "D" dungeon / "R" raid).
--   Retail: the quest's tag (Dungeon / Raid / Raid 10 / Raid 25), or its map is an
--   instance you're not in (InstanceQuest).
local DUNGEON_TAGS = {}
do
    local T = Enum and Enum.QuestTag
    for _, k in ipairs({ "Dungeon", "Raid", "Raid10", "Raid25" }) do
        if T and T[k] then DUNGEON_TAGS[T[k]] = true end
    end
    if not next(DUNGEON_TAGS) then DUNGEON_TAGS = { [81] = true, [62] = true, [88] = true, [89] = true } end
end
function mod:IsDungeonQuest(qid)
    local fq = VQ.ForeverQuests and VQ.ForeverQuests[qid]
    if fq then return (fq[6] or ""):find("[DR]") ~= nil end
    local info = safe(C_QuestLog.GetQuestTagInfo, qid)
    if info and info.tagID and DUNGEON_TAGS[info.tagID] then return true end
    return self:InstanceQuest(qid) ~= nil
end

-- The dungeon a dungeon quest belongs to, for its heading on the Dungeons tab.
--   WoW Forever: the quest's area in Blizzard's quest data (Ruins of Lordaeron, Wailing
--   Caverns...), else its group. Retail: the instance its map is in, else its zone.
function mod:DungeonName(qid)
    local F = VQ.Forever
    local info = F and F.Info and F:Info(qid)
    if info then return info.zone or info.group or "Other dungeons" end
    local iq = self:InstanceQuest(qid)
    if iq and iq.name then return iq.name end
    return (QuestZone(qid)) or "Other dungeons"
end

-- In a dungeon or raid (not delves / scenarios: their quests live on the map outside).
local function InDungeon()
    local inInst, t = IsInInstance()
    return inInst and (t == "party" or t == "raid")
end
mod.InDungeon = InDungeon

-- Inside a dungeon: does this quest belong to it? Matched by the dungeon's NAME, not the
-- dungeon flag: Forever's quest data puts every Wailing Caverns quest in "Wailing Caverns",
-- but Waking Naralex is typed "Elite", not "Dungeon".
function mod:IsThisInstanceQuest(qid)
    local name = GetInstanceInfo and GetInstanceInfo()
    if type(name) ~= "string" or name == "" or not qid then return false end
    return self:DungeonName(qid) == name
end

function mod:IsLocalQuest(qid, hereZone)
    local t = VoidQuestCharDB and VoidQuestCharDB.acceptedAt and VoidQuestCharDB.acceptedAt[qid]
    local fresh = t and time() - t < 900
    -- in a dungeon "here" is the dungeon: Wailing Caverns sits in the Barrens map, and the
    -- Barrens quests filled the list while the dungeon's own went behind "+8 more"
    -- (the user, 2026-11-06). Checked before "just picked up", or Barrens quests taken
    -- on the way in jump the dungeon's (Codex review).
    if InDungeon() then
        local mine = self:IsThisInstanceQuest(qid)
        return mine, mine and fresh or nil
    end
    if fresh then return true, true end
    if safe(C_QuestLog.IsOnMap, qid) then return true end
    local _, zmap = QuestZone(qid)
    if not zmap or zmap == 0 then return true end
    return hereZone ~= nil and ZoneOfMap(zmap) == hereZone
end

-- Ordered entries for the quest lines: event, in-area tasks / world quests, this zone's
-- log quests, then (only when the zone has none) other zones' quests. `skip` = the guided
-- step's quest (already on the panel). Returns entries, plus every quest left out of the
-- primary list (for "+N more").
function mod:QuestBlockEntries(skip)
    local out, rest = {}, {}
    local scen = self:ScenarioEntry()
    if scen then out[#out + 1] = { event = true, name = scen.name, obj = scen.obj, pct = scen.pct } end
    -- max level: coffer keys still to get this week (WeeklyTracker.lua); not in instances
    local cof = not (IsInInstance and IsInInstance()) and VQ.Coffer and VQ.Coffer:PanelLine()
    if cof then out[#out + 1] = { coffer = true, text = cof } end
    local quests, kinds, taskTitles = self:CurrentQuests()
    local here = safe(C_Map.GetBestMapForUnit, "player")
    local hereCont = here and self:ContinentOf(here)
    local hereZone = ZoneOfMap(here)
    local seen = { [skip or 0] = true }
    local area, inZone, others = {}, {}, {}
    local n = 0
    local function addLog(qid)   -- a normal log quest: this zone, or another (with its zone)
        n = n + 1
        local isLocal, fresh = self:IsLocalQuest(qid, hereZone)
        if fresh then
            table.insert(inZone, 1, { qid = qid, fresh = true })   -- just picked up: first
        elseif isLocal then
            inZone[#inZone + 1] = { qid = qid }
        else
            local zname, zmap = QuestZone(qid)
            local c = zmap and self:ContinentOf(zmap)
            others[#others + 1] = { qid = qid, zone = zname,
                near = (hereCont and c and c.mapID == hereCont.mapID) and 0 or 1, order = n }
        end
    end
    for _, qid in ipairs(quests) do
        if not seen[qid] then
            seen[qid] = true
            if kinds[qid] then
                area[#area + 1] = { qid = qid, kind = kinds[qid], title = taskTitles and taskTitles[qid] }
            else
                addLog(qid)   -- watched quests elsewhere too (Codex review: they vanished)
            end
        end
    end
    -- the rest of the log (CurrentQuests only returns watched quests when any are watched)
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        local qid = info and not info.isHeader and not info.isHidden and info.questID
        if qid and not seen[qid] then
            seen[qid] = true
            addLog(qid)
        end
    end
    table.sort(others, function(a, b)
        if a.near ~= b.near then return a.near < b.near end
        return a.order < b.order
    end)
    -- this zone's quests: just picked up first, then nearest to you (objective / turn-in on
    -- your map), then the rest in log order -- the list reorders as you move (2026-11-05)
    local dist = {}
    local pos = here and safe(C_Map.GetPlayerMapPosition, here, "player")
    local px, py
    if pos and pos.GetXY then px, py = pos:GetXY() end
    if px and px > 0 and py > 0 then
        -- scale to yards: a map is rarely square (1:1 if its size is unknown)
        local w, h = safe(C_Map.GetMapWorldSize, here)
        if not (w and h and w > 0 and h > 0) then w, h = 1, 1 end
        for _, q in ipairs(safe(C_QuestLog.GetQuestsOnMap, here) or {}) do
            if q.questID and q.x and q.y then
                local d = math.sqrt(((q.x - px) * w) ^ 2 + ((q.y - py) * h) ^ 2)
                if not dist[q.questID] or d < dist[q.questID] then dist[q.questID] = d end
            end
        end
    end
    for i, e in ipairs(inZone) do e.order = i end
    table.sort(inZone, function(a, b)
        if (a.fresh or false) ~= (b.fresh or false) then return a.fresh == true end
        local da, db = dist[a.qid], dist[b.qid]
        if da and db and da ~= db then return da < db end
        if (da ~= nil) ~= (db ~= nil) then return da ~= nil end
        return a.order < b.order
    end)
    -- dungeon and raid quests in a group of their own, after this zone's quests (the
    -- player, 2026-11-05: "separate dungeon quests in a grouping from other quests")
    local dungeons = {}
    local inDungeon, hereInst = InDungeon(), 0
    local function pullDungeons(list)
        local keep = {}
        for _, e in ipairs(list) do
            local mine = inDungeon and e.qid and self:IsThisInstanceQuest(e.qid)
            if mine then hereInst = hereInst + 1 end
            if e.qid and (mine or self:IsDungeonQuest(e.qid)) then
                e.dungeon = true
                dungeons[#dungeons + 1] = e
                -- inside it, its quests are this zone's on the Zones tab too
                if mine and self._tabMode == "zones" then keep[#keep + 1] = e end
            else
                keep[#keep + 1] = e
            end
        end
        return keep
    end
    inZone = pullDungeons(inZone)
    others = pullDungeons(others)
    self._dungeonCount = #dungeons
    -- Dungeons tab: only dungeon / raid quests, under a heading per dungeon (several
    -- dungeons' quests at once is common), dungeons A-Z, log order inside each
    if self._tabMode == "dungeons" then
        local groups, names = {}, {}
        for _, e in ipairs(dungeons) do
            local name = self:DungeonName(e.qid)
            if not groups[name] then groups[name] = {}; names[#names + 1] = name end
            e.zone = nil   -- the heading already says where
            table.insert(groups[name], e)
        end
        table.sort(names)
        local list = {}
        for _, name in ipairs(names) do
            list[#list + 1] = { header = ("%s (%d)"):format(name, #groups[name]) }
            for _, e in ipairs(groups[name]) do list[#list + 1] = e end
        end
        if #list == 0 then list[1] = { header = "No dungeon quests in your log" } end
        return list, {}
    end
    for _, e in ipairs(area) do out[#out + 1] = e end
    for _, e in ipairs(inZone) do out[#out + 1] = e end
    -- without tabs (retail, campaigns) dungeons are a group in the same list; on the
    -- Zones tab they're left out (they have their own tab)
    if #dungeons > 0 and self._tabMode ~= "zones" then
        out[#out + 1] = { header = ("Dungeon quests (%d)"):format(#dungeons) }
        for _, e in ipairs(dungeons) do out[#out + 1] = e end
    end
    -- other zones fill in only when nothing here needs doing: no zone quest, no in-area
    -- event / task, and the guided quest itself isn't here
    local localWork = #inZone > 0 or #area > 0 or scen or hereInst > 0 or (skip and safe(C_QuestLog.IsOnMap, skip))
    if not localWork then
        for _, e in ipairs(others) do out[#out + 1] = e end
    else
        for _, e in ipairs(others) do rest[#rest + 1] = e end
    end
    return out, rest
end

local function QuestTitle(e)
    return e.title or safe(C_QuestLog.GetTitleForQuestID, e.qid) or ("quest " .. e.qid)
end

local function BlockRow(f, i)
    f.qRows = f.qRows or {}
    local row = f.qRows[i]
    if row then return row end
    row = CreateFrame("Button", nil, f)
    row:SetSize(CW(), QROW)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.text = row:CreateFontString(nil, "OVERLAY"); VQ:SetFont(row.text, 10)
    row.text:SetAllPoints(); row.text:SetJustifyH("LEFT"); row.text:SetWordWrap(false)
    row:SetScript("OnEnter", function(s) if s.tip then s.tip(s) end end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.qRows[i] = row
    return row
end

-- How-to hints for quests whose objective the game doesn't explain, by title (any case,
-- either apostrophe). Checked against online sources before adding.
local QUEST_HINTS = {
    -- warcraft.wiki.gg + method.gg (2026-10-27), and seen in game by the player
    ["from whence it came"] = "Ancient Foe: finish any Vaults incursion (e.g. the wagon) and it spawns. One foe per week; 10 min to kill; group of 3.",
}

function mod:QuestHint(qid)
    local t = qid and safe(C_QuestLog.GetTitleForQuestID, qid)
    return t and QUEST_HINTS[NormName(t)]
end

-- Right-click a quest line: its full page in Blizzard's quest log (left-click tracks it).
local function OpenQuestDetails(qid)
    if not qid then return end
    -- VoidMap's own quest page when it's installed (no Blizzard quest-log calls from addon
    -- code, which can taint the objective tracker's quest-item buttons)
    if VoidMap and VoidMap.ShowQuest and VoidMap.ShowQuest(qid) then return end
    if QuestMapFrame_OpenToQuestDetails then
        if pcall(QuestMapFrame_OpenToQuestDetails, qid) then return end
    end
    VQ:Print("couldn't open the quest log here (in combat?). Try again after the fight.")
end
mod.OpenQuestDetails = OpenQuestDetails

-- The quest's own words for the hover: "what to do" (the log's short text) and its story.
-- Whole (the user, 2026-11-07: the cut-off text left out wording); only a runaway text is cut.
local STORY_MAX = 3000
local function Secret(v) return issecretvalue and issecretvalue(v) end
local function QuestText(qid)
    local idx = safe(C_QuestLog.GetLogIndexForQuestID, qid)
    if not idx or not GetQuestLogQuestText then return nil, nil end
    local ok, story, todo = pcall(GetQuestLogQuestText, idx)
    if not ok then return nil, nil end
    if type(story) ~= "string" or Secret(story) then story = nil end
    if type(todo) ~= "string" or Secret(todo) then todo = nil end
    if story and #story > STORY_MAX then
        story = story:sub(1, STORY_MAX):gsub("[\192-\255][\128-\191]*$", ""):gsub("%s+%S*$", "") .. "..."
    end
    return story ~= "" and story or nil, todo ~= "" and todo or nil
end

-- clickHint: what a click does on THIS line, in place of the quest-row hints (the step line
-- sets a map pin instead of tracking)
local function QuestTip(qid, zone, clickHint)
    return function(s)
        GameTooltip:SetOwner(s, "ANCHOR_LEFT")
        GameTooltip:SetText(safe(C_QuestLog.GetTitleForQuestID, qid) or ("quest " .. qid))
        if zone then GameTooltip:AddLine(zone, .53, .8, 1) end
        local hint = mod:QuestHint(qid)
        if hint then GameTooltip:AddLine(hint, 1, .82, 0, true) end
        local story, todo = QuestText(qid)
        if todo then GameTooltip:AddLine(todo, 1, 1, 1, true) end
        if story then GameTooltip:AddLine(story, .75, .75, .75, true) end
        if todo or story then GameTooltip:AddLine(" ") end
        if safe(C_QuestLog.IsComplete, qid) then
            GameTooltip:AddLine("Ready to turn in", .33, 1, .33)
        else
            for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
                if o.text and o.text ~= "" then
                    if o.finished then GameTooltip:AddLine(o.text, .33, 1, .33, true)
                    else GameTooltip:AddLine(o.text, .85, .85, .85, true) end
                end
            end
        end
        if clickHint then
            GameTooltip:AddLine(clickHint, .6, .6, .6)
        else
            GameTooltip:AddLine("Left-click: track it (arrow); again to stop.", .6, .6, .6)
            GameTooltip:AddLine("Right-click: open the whole quest.", .6, .6, .6)
            if IsInGroup and IsInGroup() then GameTooltip:AddLine("Alt-click: share it with your group.", .6, .6, .6) end
        end
        GameTooltip:Show()
    end
end

-- Hover list for "+N more": every left-out quest, grouped by zone.
local function MoreTip(list)
    return function(s)
        GameTooltip:SetOwner(s, "ANCHOR_LEFT")
        GameTooltip:SetText(("%d more quest%s"):format(#list, #list == 1 and "" or "s"))
        local lastZone, shown = nil, 0
        for _, e in ipairs(list) do
            if shown >= 28 then GameTooltip:AddLine("...", .6, .6, .6); break end
            if e.event then
                GameTooltip:AddLine(e.name .. " |cff88ccff[event]|r", 1, .82, 0)
            elseif e.recipe then
                GameTooltip:AddLine("  " .. e.name .. " |cff88ccff[recipe]|r", .9, .9, .9)
            elseif e.coffer then
                GameTooltip:AddLine(e.text, 1, .82, 0)
            elseif e.header then
                -- the group's quests below bring their own "Dungeon quests" heading
            else
                local z = (e.dungeon and "Dungeon quests") or e.zone or (e.kind and "In this area") or "This zone"
                if z ~= lastZone then GameTooltip:AddLine(z, 0, .78, 1); lastZone = z end
                local done = safe(C_QuestLog.IsComplete, e.qid)
                GameTooltip:AddLine("  " .. QuestTitle(e) .. (done and " |cff55ff55(turn in)|r" or ""), .9, .9, .9)
            end
            shown = shown + 1
        end
        GameTooltip:AddLine("Click: open My Quests -- click one there to track it.", .6, .6, .6, true)
        GameTooltip:Show()
    end
end

-- Draw up to `fit` lines below `anchor` (a region on f). Returns lines used.
-- A quest title's colour for its level vs yours, as Blizzard's quest log does it:
-- gray (far below you), green, yellow (about your level), orange, red (well above).
-- "ffffff" when the level isn't known.
local function LevelColor(qid)
    local lvl = qid and safe(C_QuestLog.GetQuestDifficultyLevel, qid)
    if not lvl or Secret(lvl) or lvl <= 0 or not GetQuestDifficultyColor then return "ffffff", nil end
    local ok, c = pcall(GetQuestDifficultyColor, lvl, false, qid)
    if not ok or type(c) ~= "table" or type(c.r) ~= "number" then return "ffffff", lvl end
    local function hex(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
    return ("%02x%02x%02x"):format(hex(c.r), hex(c.g), hex(c.b)), lvl
end

-- Who in your group (party or raid, not you) is on this quest: count and names.
-- C_QuestLog.IsUnitOnQuest is what Blizzard's own quest log uses for party members.
local function GroupOnQuest(qid)
    if not (qid and IsInGroup and IsInGroup() and C_QuestLog.IsUnitOnQuest) then return 0, nil end
    local names = {}
    local raid = IsInRaid and IsInRaid()
    for i = 1, raid and 40 or 4 do
        local unit = (raid and "raid" or "party") .. i
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local ok, on = pcall(C_QuestLog.IsUnitOnQuest, unit, qid)
            if ok and not (issecretvalue and issecretvalue(on)) and on == true then
                local n = UnitName(unit)
                if n and not (issecretvalue and issecretvalue(n)) then names[#names + 1] = n end
            end
        end
    end
    return #names, (#names > 0) and table.concat(names, ", ") or nil
end

-- Sharing (the user, 2026-11-07: "a quicker way from voidquest to share quests"):
--   alt-click a quest line = offer it to your group
--   the header's Share button = offer every quest someone in the group doesn't have,
--   one every 0.6 s (the game drops pushes sent all at once)
local function Shareable(qid)
    if not (qid and IsInGroup and IsInGroup()) then return false end
    if C_QuestLog.IsPushableQuest then
        local ok, p = pcall(C_QuestLog.IsPushableQuest, qid)
        if not ok or not p or (issecretvalue and issecretvalue(p)) then return false end
    end
    return true
end

local function ShareQuest(qid, quiet)
    if InCombatLockdown() then   -- the game refuses quest sharing in combat
        if not quiet then VQ:Print("You can share quests after the fight.") end
        return false
    end
    if not (IsInGroup and IsInGroup()) then
        if not quiet then VQ:Print("Join a group first to share quests.") end
        return false
    end
    if not Shareable(qid) then
        if not quiet then VQ:Print("That quest can't be shared.") end
        return false
    end
    local idx = safe(C_QuestLog.GetLogIndexForQuestID, qid)
    if not (idx and QuestLogPushQuest) then return false end
    QuestLogPushQuest(idx)
    return true
end
mod.ShareQuest = ShareQuest

-- Who in your group is NOT on this quest (names, for the "S" share button's tooltip).
local function GroupMissing(qid)
    local names = {}
    local raid = IsInRaid and IsInRaid()
    for i = 1, raid and 40 or 4 do
        local unit = (raid and "raid" or "party") .. i
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local ok, on = pcall(C_QuestLog.IsUnitOnQuest, unit, qid)
            if not (ok and not (issecretvalue and issecretvalue(on)) and on == true) then
                local n = UnitName(unit)
                names[#names + 1] = (n and not (issecretvalue and issecretvalue(n))) and n or "?"
            end
        end
    end
    return names
end

-- Share one quest: a small "S" at the right end of its line (the user, 2026-11-10: "take the
-- share button off and put a small s on the right side of the quests for each one that i just
-- click to share that quest"; the old header button shared the whole log with everyone).
-- Shown in a group when the quest can be shared and someone in the group doesn't have it.
local function ShareTip(s)
    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Share with your group")
    local t = s.qid and safe(C_QuestLog.GetTitleForQuestID, s.qid)
    if t then GameTooltip:AddLine(t, 1, 1, 1) end
    if s.missing and #s.missing > 0 then
        GameTooltip:AddLine("Doesn't have it: " .. table.concat(s.missing, ", "), 0.8, 0.8, 0.8, true)
    end
    GameTooltip:Show()
end
local function ShareS(holder)
    local b = holder.shareS
    if b then return b end
    b = CreateFrame("Button", nil, holder)
    b:SetSize(11, 11)
    b:SetFrameLevel(holder:GetFrameLevel() + 2)   -- over the line, so the click is the S's
    local bg = b:CreateTexture(nil, "ARTWORK")
    bg:SetAllPoints(); bg:SetColorTexture(0.1, 0.5, 0.2, 1)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.25)
    b.text = b:CreateFontString(nil, "OVERLAY"); VQ:SetFont(b.text, 9, "")
    b.text:SetPoint("CENTER", 0, 0); b.text:SetTextColor(1, 1, 1); b.text:SetText("S")
    b:SetScript("OnClick", function(s) if s.qid then ShareQuest(s.qid) end end)
    b:SetScript("OnEnter", ShareTip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    holder.shareS = b
    return b
end

-- Put a group count at the right of a line's text (fs = the line's text, holder = the
-- frame it sits in): a white number on a solid blue badge, so it reads over any ground
-- behind a see-through panel (plain coloured digits got lost, 2026-11-06). The text stops
-- short of the badge so they never overlap. shareQid: the line's quest, for its "S" (right
-- of the badge, at the end of the line).
local function SetLineParty(holder, fs, n, shareQid)
    if not holder.partyBg then
        local bg = holder:CreateTexture(nil, "ARTWORK")
        bg:SetColorTexture(0.05, 0.32, 0.85, 1)
        bg:SetHeight(11)
        holder.partyBg = bg
        holder.party = holder:CreateFontString(nil, "OVERLAY"); VQ:SetFont(holder.party, 9, "")
        holder.party:SetPoint("CENTER", bg, "CENTER", 0, 0)
        holder.party:SetTextColor(1, 1, 1)
    end
    local missing = shareQid and IsInGroup and IsInGroup() and C_QuestLog.IsUnitOnQuest and Shareable(shareQid)
        and GroupMissing(shareQid)
    local edge, gap = holder, 0   -- what the next thing to the left lines up against
    if missing and #missing > 0 then
        local s = ShareS(holder)
        s.qid, s.missing = shareQid, missing
        s:ClearAllPoints(); s:SetPoint("RIGHT", holder, "RIGHT", 0, 0)
        s:Show()
        edge, gap = s, -3
    elseif holder.shareS then
        holder.shareS:Hide(); holder.shareS.qid = nil
    end
    local bg = holder.partyBg
    bg:ClearAllPoints()
    bg:SetPoint("RIGHT", edge, edge == holder and "RIGHT" or "LEFT", gap, 0)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", holder, "TOPLEFT"); fs:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT")
    if n and n > 0 then
        holder.party:SetText(tostring(n))
        bg:SetWidth(math.max(11, (holder.party:GetStringWidth() or 6) + 6))
        bg:Show(); holder.party:Show()
        fs:SetPoint("RIGHT", bg, "LEFT", -4, 0)
    else
        holder.party:SetText(""); holder.party:Hide(); bg:Hide()
        fs:SetPoint("RIGHT", edge, edge == holder and "RIGHT" or "LEFT", edge == holder and 0 or -4, 0)
    end
end
local function SetRowParty(row, n, qid) SetLineParty(row, row.text, n, qid) end

-- The way to a quest's next stop in another zone, through VoidGPS (the user, 2026-11-09: "i have
-- a quest to turn in near grom gol, yet i dont know how to get there, im in camp t so somewhere it
-- telling me the path to take would be great"). Nothing without VoidGPS.
local function gps() return VoidGPS and VoidGPS.DescribeRoute and VoidGPS.RouteTo and VoidGPS or nil end

local function zoneOfMap(m)   -- a map rolled up to its zone (caves, floors, cities stay themselves)
    local info = m and safe(C_Map.GetMapInfo, m)
    local zoneType = Enum.UIMapType and Enum.UIMapType.Zone or 3
    while info and info.mapType and info.mapType > zoneType and info.parentMapID and info.parentMapID > 0 do
        m = info.parentMapID
        info = safe(C_Map.GetMapInfo, m)
    end
    return m, info
end

-- Where the quest takes you next: { name, map, x, y (0-1), why } or nil.
local function QuestTarget(qid)
    if not qid then return nil end
    -- ready to turn in: the turn-in NPC, where VoidGPS knows them
    if safe(C_QuestLog.IsComplete, qid) and VQ.Starts and gps() and VoidGPS.FindNPC then
        local who = VQ.Starts:Turnin(qid)
        local at = who and VoidGPS:FindNPC(who)
        if at then at.why = "turn in to " .. who; return at end
    end
    -- not picked up yet: its giver
    if not safe(C_QuestLog.GetLogIndexForQuestID, qid) then
        local s = VQ.Starts and VQ.Starts:Get(qid)
        if s and s.m and s.x and s.y and s.x > 0 then
            local who = VQ.Starts:Giver(qid)
            return { name = who or "the giver", map = s.m, x = s.x, y = s.y, why = "pick up" .. (who and (" from " .. who) or "") }
        end
    end
    -- the game's own next stop (objective area or turn-in)
    local m, x, y = safe(C_QuestLog.GetNextWaypoint, qid)
    if m and m > 0 and x and y and x > 0 and y > 0 then return { name = "the next step", map = m, x = x, y = y, why = "next step" } end
end

-- "fly Camp Taurajo → Orgrimmar → zeppelin to Grom'gol (Orgrimmar) → walk 300 yd", seconds, target, zone name;
-- nil when the quest's next stop is in this zone (or unknown, or no VoidGPS)
local function QuestWay(qid)
    if not gps() then return nil end
    local t = QuestTarget(qid)
    if not t then return nil end
    local here = zoneOfMap(safe(C_Map.GetBestMapForUnit, "player"))
    local there, info = zoneOfMap(t.map)
    if not here or here == there then return nil end
    local ok, text, secs, steps = pcall(VoidGPS.DescribeRoute, VoidGPS, t)
    if not (ok and text) then return nil end
    return text, secs, t, info and info.name, steps
end
local function minutes(secs) return (secs and secs > 90) and (" (~%d min)"):format(math.floor(secs / 60 + 0.5)) or "" end

-- Start VoidGPS's guide to the quest's next stop. True if it started.
function mod:GuideToQuest(qid)
    local t = gps() and QuestTarget(qid)
    if not t then return false end
    local title = safe(C_QuestLog.GetTitleForQuestID, qid) or ("quest " .. tostring(qid))
    return VoidGPS:RouteTo({ name = title, sub = t.why, map = t.map, x = t.x, y = t.y }) and true or false
end

-- A quest's tooltip plus who in your group is on it.
local function QuestTipWithGroup(qid, zone, groupNames, clickHint)
    local base = QuestTip(qid, zone, clickHint)
    return function(s)
        base(s)
        -- in another zone: the way there (VoidGPS), and shift-click to be guided
        local way, secs, t, zname, steps = QuestWay(qid)
        if way then
            -- one numbered step per line (the user, 2026-11-09: the one-line route was confusing)
            GameTooltip:AddLine(("Way there%s (%s%s):"):format(minutes(secs), t.why, zname and (", " .. zname) or ""), .53, .8, 1, true)
            if type(steps) == "table" and #steps > 0 then
                for i, s in ipairs(steps) do GameTooltip:AddLine(("%d. %s"):format(i, s), 1, 1, 1, true) end
            else
                GameTooltip:AddLine(way, 1, 1, 1, true)
            end
            GameTooltip:AddLine("Shift-click: guide me there (VoidGPS)", .6, .6, .6)
        end
        local _, lvl = LevelColor(qid)
        if lvl then GameTooltip:AddLine(("Quest level %d (you: %d)"):format(lvl, UnitLevel("player") or 0), .7, .7, .7) end
        if groupNames then
            GameTooltip:AddLine("In your group on this quest: " .. groupNames, .53, .8, 1, true)
        end
        -- where its items come from, as you've looted them (Drops.lua)
        if VQ.Drops then VQ.Drops:AddQuestLines(GameTooltip, qid) end
        -- grey quests: worth keeping, or low value (Chains.lua)
        if VQ.Chains then VQ.Chains:AddTooltip(GameTooltip, qid) end
        -- WoW Forever: what the rest of the chain and the reputation are worth to you (QuestWorth.lua)
        if VQ.Worth then VQ.Worth:AddTooltip(GameTooltip, qid) end
        GameTooltip:Show()   -- resize for the added lines
    end
end

-- The guided step's lines at the top of the panel: the same quest details as the rows below
-- (the user, 2026-11-09: "if i hover over it it doesnt show the details like all the ones
-- below it"). The panel is built above this point in the file, so it calls in through mod.
function mod:StepTooltip(s, qid)
    QuestTipWithGroup(qid, nil, nil, "Click: set a map pin for this step")(s)
end

-- The "Way there" line under the guided step (render code below calls this)
function mod:StepWayText(qid)
    local way, secs = QuestWay(qid)
    if not way then return nil end
    return ("|cff88ccffWay there:|r %s%s |cff888888- click: guide me|r"):format(way, minutes(secs))
end

function mod:RenderQuestBlock(f, anchor, fit, skip)
    local entries, rest = self:QuestBlockEntries(skip)
    local tracked = safe(C_SuperTrack.GetSuperTrackedQuestID)
    fit = math.max(0, fit or 0)
    -- other zones' quests (held back while this zone has work) still show when there's
    -- room for all of them -- no "+1 more" over empty space (the player, 2026-11-05)
    if #rest > 0 and #entries + 1 + #rest <= fit then
        entries[#entries + 1] = { header = "Other zones" }
        for _, e in ipairs(rest) do entries[#entries + 1] = e end
        rest = {}
    end
    local shown = #entries
    local hidden = {}
    if #entries + #rest > fit then
        -- something won't fit (here or in `rest`): keep the last line for "+N more"
        shown = math.max(0, math.min(#entries, fit - 1))
        for i = shown + 1, #entries do hidden[#hidden + 1] = entries[i] end
    end
    for _, e in ipairs(rest) do hidden[#hidden + 1] = e end
    local used = 0
    for i = 1, shown do
        local e, row = entries[i], BlockRow(f, i)
        local text
        if e.event then
            text = ("|cffffd200%s%s|r |cff88ccff[event]|r %s"):format(e.name,
                e.pct and (" %d%%"):format(e.pct) or "", e.obj or "")
            row.tip = function(s)
                GameTooltip:SetOwner(s, "ANCHOR_LEFT"); GameTooltip:SetText(e.name)
                GameTooltip:AddLine((e.obj or ""):gsub(" | ", "\n"), .85, .85, .85, true); GameTooltip:Show()
            end
            row:SetScript("OnClick", nil)
        elseif e.coffer then
            text = e.text
            row.tip = function(s) VQ.Coffer:Tooltip(s) end
            row:SetScript("OnClick", function() VQ.Coffer:Toggle() end)
        elseif e.header then   -- a group title ("Dungeon quests")
            text = "|cff88ccff" .. e.header .. "|r"
            row.tip = nil
            row:SetScript("OnClick", nil)
        else
            local qid = e.qid
            local mark = (qid == tracked or self:InstancePinUp(qid)) and "|cff55ff55> |r" or ""
            local tag = (e.kind == "wq" and " |cff88ccff[WQ]|r") or (e.kind == "task" and " |cff88ccff[bonus]|r")
                or (e.zone and (" |cff888888[%s]|r"):format(e.zone)) or ""
            -- grey quests that matter: a yellow star in front (Chains.lua); no star = abandon
            local star = (VQ.Chains and not e.kind) and VQ.Chains:Star(qid) or ""
            -- ready to turn in: say so FIRST. At the end it was the first thing cut off on a long
            -- line ("Hunting in Stranglethorn [Stranglethorn Vale]: t...", the user 2026-11-09)
            local done = safe(C_QuestLog.IsComplete, qid)
            local sum = done and "" or ObjSummary(qid)
            text = ("%s%s%s|cff%s%s|r%s%s"):format(mark, star, done and "|cff55ff55Turn in:|r " or "",
                (LevelColor(qid)), truncTo(QuestTitle(e), 28), tag,
                sum ~= "" and ("|cffaaaaaa: %s|r"):format(sum) or "")
            local nGroup, groupNames = GroupOnQuest(qid)
            row.tip = QuestTipWithGroup(qid, e.zone, groupNames)
            row.partyN = nGroup
            row.shareQid = qid
            row:SetScript("OnClick", function(_, btn)   -- right: the whole quest; left: track
                if IsShiftKeyDown() and mod:GuideToQuest(qid) then   -- shift: VoidGPS guides you to its next stop
                elseif IsAltKeyDown() then ShareQuest(qid)
                elseif btn == "RightButton" then OpenQuestDetails(qid) else mod:ToggleTrack(qid); mod:Refresh() end
            end)
        end
        SetRowParty(row, row.partyN or 0, row.shareQid)   -- 0 / no S for events, coffers and group titles
        row.partyN, row.shareQid = nil, nil
        row.text:SetText(text)
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6 - (i - 1) * QROW); row:SetPoint("RIGHT", f, "RIGHT", -4, 0)   -- follows the right edge live while resizing
        row:Show()
        used = used + 1
    end
    -- "+N more" (only when there's room for a line at all)
    local nHidden = 0   -- group titles aren't quests
    for _, e in ipairs(hidden) do if not e.header then nHidden = nHidden + 1 end end
    if nHidden > 0 and fit > used then
        used = used + 1
        local row = BlockRow(f, used)
        SetRowParty(row, 0)
        row.text:SetText(("|cff88ccff+%d more quest%s|r |cff888888- hover to list, click to open|r"):format(
            nHidden, nHidden == 1 and "" or "s"))
        row.tip = MoreTip(hidden)
        row:SetScript("OnClick", function() mod:ToggleQuestLog() end)
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6 - (used - 1) * QROW); row:SetPoint("RIGHT", f, "RIGHT", -4, 0)   -- follows the right edge live while resizing
        row:Show()
    end
    for i = used + 1, #(f.qRows or {}) do f.qRows[i]:Hide() end
    return used
end

function mod:HideQuestBlock(f)
    for _, row in ipairs(f.qRows or {}) do row:Hide() end
end

-- Fixed panel height (Settings > Guide panel > Height). The guide grows past it only if
-- its own lines don't fit; quest lines only fill what's left.
local function PanelBudget() return (VQ:Get("panelHeight") or 230) - FOOTER end   -- room for content (the footer row is under it)

-- How tall the guide's own part is: from the panel's top to the bottom of `below` (the
-- region the quest lines hang from), plus room at the bottom for the resize grip. Both
-- are on the same frame, so screen units match. nil when the layout isn't known yet.
local function MeasuredCore(f, below)
    local top, bottom = f:GetTop(), below and below:GetBottom()
    if not (top and bottom) or top <= bottom then return nil end
    local es = f:GetEffectiveScale() or 1
    local bs = below.GetEffectiveScale and below:GetEffectiveScale() or es
    return (top - bottom * bs / es) + 12
end

-- Click a quest to super-track it (arrow); click the SAME one again to UN-track (clear arrow).
function mod:ToggleTrack(qid)
    if not (qid and C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID) then return end
    -- inside an instance you're not in: the entrance instead (the quest arrow can't get there)
    local iq = self:InstanceQuest(qid)
    if iq then
        if self:InstancePinUp(qid) then
            self:ClearInstancePin()
        else
            self:PointAtInstance(qid, iq)
        end
        return
    end
    self._instQ = nil
    if safe(C_SuperTrack.GetSuperTrackedQuestID) == qid then
        C_SuperTrack.SetSuperTrackedQuestID(0)   -- 0 = untrack (remove the arrow)
    else
        C_SuperTrack.SetSuperTrackedQuestID(qid)
    end
end

-- Active zone event / scenario (Temple Strikes, sieges, world scenarios): the banner
-- content the Blizzard tracker auto-shows when you enter the area. Not a quest -- read
-- via C_ScenarioInfo and render as a header row.
-- Delve / Labyrinth header: tier and the currencies Blizzard draws on it -- your remaining
-- lives (2026-10-26: with Blizzard's tracker hidden there was nowhere to see them). It's a
-- UI widget (ScenarioHeaderDelves) in the stage's widget set; we read the same widget.
-- Any secret field is skipped, never concatenated.
local function plainStr(v) return type(v) == "string" and not (issecretvalue and issecretvalue(v)) and v ~= "" and v or nil end
function mod:DelveHeader(st)
    local setID = st and st.widgetSetID
    if not (setID and setID ~= 0 and C_UIWidgetManager and C_UIWidgetManager.GetAllWidgetsBySetID
            and Enum.UIWidgetVisualizationType and Enum.UIWidgetVisualizationType.ScenarioHeaderDelves) then
        return nil
    end
    for _, w in ipairs(safe(C_UIWidgetManager.GetAllWidgetsBySetID, setID) or {}) do
        if w.widgetType == Enum.UIWidgetVisualizationType.ScenarioHeaderDelves then
            local info = safe(C_UIWidgetManager.GetScenarioHeaderDelvesWidgetVisualizationInfo, w.widgetID)
            if info and info.shownState ~= Enum.WidgetShownState.Hidden then
                local parts = {}
                local tier = plainStr(info.tierText)
                if tier then parts[#parts + 1] = "|cffffd200Tier " .. tier .. "|r" end
                for _, c in ipairs(info.currencies or {}) do
                    local txt = plainStr(c.text)
                    if txt then
                        local icon = (type(c.iconFileID) == "number" and c.iconFileID > 0)
                            and ("|T%d:12:12|t "):format(c.iconFileID) or ""
                        local lead = plainStr(c.leadingText)
                        parts[#parts + 1] = icon .. (lead and (lead .. " ") or "") .. "|cffffffff" .. txt .. "|r"
                    end
                end
                if #parts > 0 then return table.concat(parts, "  ") end
            end
        end
    end
end

function mod:ScenarioEntry()
    local si = safe(C_ScenarioInfo.GetScenarioInfo)
    if not (si and si.name and si.name ~= "") then return nil end
    local st = safe(C_ScenarioInfo.GetScenarioStepInfo)
    local lines, pct = {}, nil
    for i = 1, (st and st.numCriteria) or 0 do
        local c = safe(C_ScenarioInfo.GetCriteriaInfo, i)
        if c and c.description and c.description ~= "" then
            if c.completed then
                lines[#lines + 1] = "|cff55ff55" .. c.description .. "|r"
            elseif c.isWeightedProgress then
                lines[#lines + 1] = ("%d%% %s"):format(c.quantity or 0, c.description)
                if not (issecretvalue and issecretvalue(c.quantity)) then pct = pct or (c.quantity or 0) end
            else
                lines[#lines + 1] = ("%d/%d %s"):format(c.quantity or 0, c.totalQuantity or 0, c.description)
                local secret = issecretvalue and (issecretvalue(c.quantity) or issecretvalue(c.totalQuantity))
                if not pct and not secret and (c.totalQuantity or 0) > 0 then
                    pct = math.floor((c.quantity or 0) * 100 / c.totalQuantity)
                end
            end
        end
    end
    local name = (st and st.title and st.title ~= "" and st.title) or si.name
    local obj = table.concat(lines, " | ")
    local head = self:DelveHeader(st)   -- tier + lives, first so they never get cut off
    if head then obj = head .. (obj ~= "" and ("  " .. obj) or "") end
    -- the stage's progress (room / event %) goes right after its name: it's what you watch
    return { name = name, obj = obj, pct = pct }
end

-- Tracked profession RECIPES (the Blizzard tracker's "Profession" block -- e.g. "Light's
-- Potential"). Not quests at all: C_TradeSkillUI.GetRecipesTracked. Objectives = required
-- reagents as have/need (counts include bank + reagent bank, like Blizzard's checklist).
function mod:TrackedRecipes()
    if not (C_TradeSkillUI and C_TradeSkillUI.GetRecipesTracked) then return {} end
    local out = {}
    for _, isRecraft in ipairs({ false, true }) do
        for _, rid in ipairs(safe(C_TradeSkillUI.GetRecipesTracked, isRecraft) or {}) do
            local info = safe(C_TradeSkillUI.GetRecipeInfo, rid)
            local parts = {}
            local schem = safe(C_TradeSkillUI.GetRecipeSchematic, rid, isRecraft)
            for _, slot in ipairs((schem and schem.reagentSlotSchematics) or {}) do
                local required = (not Enum.CraftingReagentType) or (slot.reagentType == Enum.CraftingReagentType.Basic)
                local need = slot.quantityRequired or 0
                local r1 = slot.reagents and slot.reagents[1]
                if required and need > 0 and r1 and r1.itemID then
                    local have = safe(C_Item.GetItemCount, r1.itemID, true, false, true, true) or 0
                    local iname = safe(C_Item.GetItemNameByID, r1.itemID) or "reagent"
                    local met = have >= need
                    parts[#parts + 1] = (met and "|cff55ff55" or "") .. ("%d/%d %s"):format(math.min(have, 999), need, iname) .. (met and "|r" or "")
                end
            end
            out[#out + 1] = { name = (info and info.name) or ("recipe " .. rid), obj = table.concat(parts, " | ") }
        end
    end
    return out
end

-- Render ALL current quests as a list in the panel (quest-only mode = no campaign).
function mod:RenderQuestList(f, popH)
    popH = popH or 0
    if f.pbar then f.pbar:Hide() end   -- list mode: bars are per row
    f.chapter:Hide(); f.step:Hide(); f.obj:Hide()
    f.tabZones:Hide(); f.tabDungeons:Hide(); self._tabMode = nil
    if f.stepBtn then f.stepBtn:Hide() end
    if f.objBtn then f.objBtn:Hide() end
    self:HideQuestBlock(f)
    local quests, kinds, taskTitles = self:CurrentQuests()
    local scen = self:ScenarioEntry()
    local recipes = self:TrackedRecipes()
    local tracked = safe(C_SuperTrack.GetSuperTrackedQuestID)
    f.camp:SetText(("|cff00c7ffMy Quests|r |cff888888(%d)|r"):format(#quests + (scen and 1 or 0) + #recipes)); mod:FitHeader(f)   -- the title comes first
    local ROWH, top = 26, -28 - popH
    -- fixed height (panelHeight): in-area events / WQs / bonus objectives and this zone's
    -- quests; other zones' quests (tagged with their zone) only when this zone has none;
    -- what doesn't fit goes behind a "+N more" row (hover / click)
    local localQ, elsewhere, zoneTag, overflow = {}, {}, {}, {}
    local hereZone = ZoneOfMap(safe(C_Map.GetBestMapForUnit, "player"))
    for _, qid in ipairs(quests) do
        local isLocal, fresh = self:IsLocalQuest(qid, hereZone)
        if fresh then table.insert(localQ, 1, qid)
        elseif kinds[qid] or isLocal then localQ[#localQ + 1] = qid
        else elsewhere[#elsewhere + 1] = qid end
    end
    if #localQ > 0 or scen then
        for _, qid in ipairs(elsewhere) do overflow[#overflow + 1] = { qid = qid, zone = (QuestZone(qid)) } end
        quests = localQ
    else
        for _, qid in ipairs(elsewhere) do zoneTag[qid] = (QuestZone(qid)) end
        quests = elsewhere
    end
    -- dungeon / raid quests grouped at the end, tagged (same grouping as the step mode's lines);
    -- inside a dungeon its own quests ARE the local list, so they stay on top
    local dungeonQ = {}
    if InDungeon() then
        for _, qid in ipairs(quests) do if self:IsDungeonQuest(qid) or self:IsThisInstanceQuest(qid) then dungeonQ[qid] = true end end
    else
        local normal, dung = {}, {}
        for _, qid in ipairs(quests) do
            if self:IsDungeonQuest(qid) then dungeonQ[qid] = true; dung[#dung + 1] = qid else normal[#normal + 1] = qid end
        end
        for _, qid in ipairs(dung) do normal[#normal + 1] = qid end
        quests = normal
    end
    local room = math.max(1, math.floor((PanelBudget() - 34 - popH) / ROWH)) - (scen and 1 or 0)
    local moreFits = true
    if #quests + #recipes + (#overflow > 0 and 1 or 0) > room then
        room = room - 1   -- the "+N more" row
        moreFits = room >= 0   -- popups can leave no line for it at all
        local keepQ = math.max(0, math.min(#quests, room))
        for i = keepQ + 1, #quests do
            overflow[#overflow + 1] = { qid = quests[i], zone = zoneTag[quests[i]] or (QuestZone(quests[i])) }
        end
        for i = #quests, keepQ + 1, -1 do quests[i] = nil end
        -- recipes count too, and the ones cut are listed under "+N more"
        local keepR = math.max(0, room - keepQ)
        for i = keepR + 1, #recipes do overflow[#overflow + 1] = { recipe = true, name = recipes[i].name } end
        for i = #recipes, keepR + 1, -1 do recipes[i] = nil end
    end
    -- zone event / scenario banner first (non-clickable, like the Blizzard tracker's block)
    local rowOffset = 0
    if scen then
        rowOffset = 1
        local row = f.questRows[1]
        if not row then
            row = {}
            row.btn = CreateFrame("Button", nil, f); row.btn:SetSize(CW(), 13)
            row.btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row.title = row.btn:CreateFontString(nil, "OVERLAY"); VQ:SetFont(row.title, 11)
            row.title:SetAllPoints(row.btn); row.title:SetJustifyH("LEFT")
            row.obj = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(row.obj, 9)
            row.obj:SetTextColor(.65, .65, .65); row.obj:SetJustifyH("LEFT"); row.obj:SetWidth(CW() - 4)
            f.questRows[1] = row
        end
        row.btn:ClearAllPoints(); row.btn:SetPoint("TOPLEFT", 12, top); row.btn:SetPoint("RIGHT", f, "RIGHT", -4, 0)   -- follows the right edge live while resizing
        row.obj:ClearAllPoints(); row.obj:SetPoint("TOPLEFT", 18, top - 13)
        SetLineParty(row.btn, row.title, 0)
        row.title:SetText("|cffffd200" .. truncTo(scen.name, 36) .. "|r |cff88ccff[event]|r")
        row.obj:SetText(truncTo(scen.obj, 52)); row.obj:SetWidth(CW() - 4)
        if row.bar then row.bar:Hide() end
        row.btn:SetScript("OnClick", nil); row.btn:SetScript("OnEnter", nil)   -- no leftover quest tooltip
        row.btn:Show(); row.obj:Show()
    end
    for i, qid in ipairs(quests) do
        local ri = i + rowOffset
        local row = f.questRows[ri]
        if not row then
            row = {}
            row.btn = CreateFrame("Button", nil, f); row.btn:SetSize(CW(), 13)
            row.btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row.title = row.btn:CreateFontString(nil, "OVERLAY"); VQ:SetFont(row.title, 11)
            row.title:SetAllPoints(row.btn); row.title:SetJustifyH("LEFT")
            row.obj = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(row.obj, 9)
            row.obj:SetTextColor(.65, .65, .65); row.obj:SetJustifyH("LEFT"); row.obj:SetWidth(CW() - 4)
            f.questRows[ri] = row
        end
        row.btn:ClearAllPoints(); row.btn:SetPoint("TOPLEFT", 12, top - (ri - 1) * ROWH); row.btn:SetPoint("RIGHT", f, "RIGHT", -4, 0)   -- follows the right edge live while resizing
        row.obj:ClearAllPoints(); row.obj:SetPoint("TOPLEFT", 18, top - (ri - 1) * ROWH - 13)
        local complete = safe(C_QuestLog.IsComplete, qid)
        local title = (taskTitles and taskTitles[qid])           -- GetTaskInfo display name first
            or safe(C_QuestLog.GetTitleForQuestID, qid)
        if not title and kinds[qid] then                        -- tasks/WQs aren't always in the log
            local ti = safe(C_TaskQuest.GetQuestInfoByQuestID, qid)
            title = (type(ti) == "table" and ti.questTitle) or (type(ti) == "string" and ti) or nil
        end
        title = title or ("quest " .. qid)
        local tag = (kinds[qid] == "wq" and " |cff88ccff[WQ]|r") or (kinds[qid] == "task" and " |cff88ccff[bonus]|r")
            or (dungeonQ[qid] and " |cff88ccff[dungeon]|r")
            or (zoneTag[qid] and (" |cff888888[%s]|r"):format(zoneTag[qid])) or ""
        -- grey quests that matter: a yellow star in front (Chains.lua); no star = abandon
        local star = (VQ.Chains and not kinds[qid]) and VQ.Chains:Star(qid) or ""
        local mark = (qid == tracked) and "|cff55ff55> |r" or ""
        row.title:SetText(mark .. star .. "|cff" .. (LevelColor(qid)) .. truncTo(title, zoneTag[qid] and 26 or 36) .. "|r" .. tag)
        local obj = ""
        local pct = (not complete) and ProgressPercent(qid) or nil
        if complete then
            obj = "|cff55ff55Ready to turn in|r"
        else
            for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
                if o.text and o.text ~= "" then obj = obj .. (obj ~= "" and " | " or "") .. o.text end
            end
            obj = truncTo(obj, pct and 34 or 52)
        end
        row.obj:SetText(obj)
        -- progress-bar quests: a small bar at the right end of the objective line
        row.bar = row.bar or MakeProgressBar(f, 80)
        row.obj:SetWidth(pct and (CW() - 94) or (CW() - 4))   -- room for the 80 px bar
        row.bar:ClearAllPoints(); row.bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, top - (ri - 1) * ROWH - 14)
        SetProgress(row.bar, pct)
        row.btn:SetScript("OnClick", function(_, btn)   -- right: the whole quest; left: track
            if IsShiftKeyDown() and mod:GuideToQuest(qid) then   -- shift: VoidGPS guides you to its next stop
            elseif IsAltKeyDown() then ShareQuest(qid)
            elseif btn == "RightButton" then OpenQuestDetails(qid) else mod:ToggleTrack(qid); mod:Refresh() end
        end)
        local nGroup, groupNames = GroupOnQuest(qid)
        SetLineParty(row.btn, row.title, nGroup, qid)
        row.btn:SetScript("OnEnter", QuestTipWithGroup(qid, zoneTag[qid], groupNames))
        row.btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.btn:Show(); row.obj:Show()
    end
    -- tracked profession recipes at the bottom (non-clickable, like Blizzard's Profession block)
    for j, rec in ipairs(recipes) do
        local ri = rowOffset + #quests + j
        local row = f.questRows[ri]
        if not row then
            row = {}
            row.btn = CreateFrame("Button", nil, f); row.btn:SetSize(CW(), 13)
            row.btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row.title = row.btn:CreateFontString(nil, "OVERLAY"); VQ:SetFont(row.title, 11)
            row.title:SetAllPoints(row.btn); row.title:SetJustifyH("LEFT")
            row.obj = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(row.obj, 9)
            row.obj:SetTextColor(.65, .65, .65); row.obj:SetJustifyH("LEFT"); row.obj:SetWidth(CW() - 4)
            f.questRows[ri] = row
        end
        row.btn:ClearAllPoints(); row.btn:SetPoint("TOPLEFT", 12, top - (ri - 1) * ROWH); row.btn:SetPoint("RIGHT", f, "RIGHT", -4, 0)   -- follows the right edge live while resizing
        row.obj:ClearAllPoints(); row.obj:SetPoint("TOPLEFT", 18, top - (ri - 1) * ROWH - 13)
        SetLineParty(row.btn, row.title, 0)   -- a reused quest row: no leftover group badge
        row.title:SetText("|cffffffff" .. truncTo(rec.name, 34) .. "|r |cff88ccff[recipe]|r")
        row.obj:SetText(truncTo(rec.obj, 52)); row.obj:SetWidth(CW() - 4)
        if row.bar then row.bar:Hide() end
        row.btn:SetScript("OnClick", nil); row.btn:SetScript("OnEnter", nil)   -- no leftover quest tooltip
        row.btn:Show(); row.obj:Show()
    end

    local used = #quests + rowOffset + #recipes
    for i = used + 1, #f.questRows do
        local r = f.questRows[i]
        r.btn:Hide(); r.obj:Hide(); if r.bar then r.bar:Hide() end
    end
    if #overflow > 0 and moreFits then
        local row = BlockRow(f, 1)
        SetRowParty(row, 0)
        row.text:SetText(("|cff88ccff+%d more quest%s|r |cff888888- hover to list, click to open|r"):format(
            #overflow, #overflow == 1 and "" or "s"))
        row.tip = MoreTip(overflow)
        row:SetScript("OnClick", function() mod:ToggleQuestLog() end)
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", f, "TOPLEFT", 12, top - used * ROWH); row:SetPoint("RIGHT", f, "RIGHT", -4, 0)   -- follows the right edge live while resizing
        row:Show()
        used = used + 1
    end
    PanelHeight(f, math.max(PanelBudget(), 34 + popH + math.max(1, used) * ROWH))
end

-- Auto-quest popups: OFFER = a new quest waiting to be accepted; COMPLETE = a quest you can
-- turn in from here (no NPC). These normally live in Blizzard's tracker -- if that's hidden
-- we surface + action them ourselves so nothing is lost.
function mod:AutoQuestPopups()
    local out = {}
    for i = 1, (GetNumAutoQuestPopUps and GetNumAutoQuestPopUps() or 0) do
        local qid, kind = GetAutoQuestPopUp(i)
        if qid then
            out[#out + 1] = { qid = qid, kind = kind,
                title = safe(C_QuestLog.GetTitleForQuestID, qid) or ("quest " .. qid) }
        end
    end
    return out
end

-- Render popup rows at the top of the panel; returns the pixel height they consume.
function mod:RenderPopups(f)
    local pops = self:AutoQuestPopups()
    local ROW = 20
    for i, pu in ipairs(pops) do
        local row = f.popupRows[i]
        if not row then
            row = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            row:SetSize(CW(), 17)
            f.popupRows[i] = row
        end
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", 12, -27 - (i - 1) * ROW); row:SetPoint("RIGHT", f, "RIGHT", -4, 0)   -- follows the right edge live while resizing
        local isComplete = (pu.kind == "COMPLETE")
        row:SetText((isComplete and "|cff55ff55Turn in:|r " or "|cffffd200New quest:|r ") .. truncTo(pu.title, 30))
        local qid, complete = pu.qid, isComplete
        row:SetScript("OnClick", function()
            if complete then
                if ShowQuestComplete then ShowQuestComplete(qid) end
            elseif ShowQuestOffer then
                ShowQuestOffer(qid)
            end
            if RemoveAutoQuestPopUp then RemoveAutoQuestPopUp(qid) end   -- dismiss like Blizzard does
            mod:Refresh()
        end)
        row:Show()
    end
    for i = #pops + 1, #f.popupRows do f.popupRows[i]:Hide() end
    return #pops * ROW
end

-- Which quest lines show under the guide when the tabs are up: "zones" or "dungeons"
-- (per character). Without tabs (retail, campaigns) the lines show both, dungeons grouped.
function mod:QuestTab() return (VoidQuestCharDB and VoidQuestCharDB.questTab) or "zones" end
function mod:SetQuestTab(key)
    VoidQuestCharDB = VoidQuestCharDB or {}
    VoidQuestCharDB.questTab = key
    self:Refresh()
end

-- Tabs up (and the chapter line hidden) or not; labels and the active tab's look.
function mod:ShowTabs(f, on, popH)
    f.tabZones:SetShown(on); f.tabDungeons:SetShown(on)
    f.chapter:SetShown(not on)
    self._tabMode = on and self:QuestTab() or nil
    if not on then return end
    local top = -25 - (popH or 0)
    f.tabZones:ClearAllPoints(); f.tabZones:SetPoint("TOPLEFT", 12, top)
    f.tabDungeons:ClearAllPoints(); f.tabDungeons:SetPoint("LEFT", f.tabZones, "RIGHT", 14, 0)
    self:UpdateTabLabels(f)
end
function mod:UpdateTabLabels(f)
    local n = self._dungeonCount or 0
    local active = self:QuestTab()
    for key, b in pairs({ zones = f.tabZones, dungeons = f.tabDungeons }) do
        local on = key == active
        local label = key == "zones" and "Zones" or (n > 0 and ("Dungeons (%d)"):format(n) or "Dungeons")
        b.text:SetText(on and ("|cffffffff" .. label .. "|r") or ("|cff8c8c9e" .. label .. "|r"))
        b:SetWidth(b.text:GetStringWidth() + 2)
        b.line:SetShown(on)
    end
end

-- Show the single-step (campaign) widgets, hide the quest-list rows, offset below popups.
function mod:SetStepMode(f, popH)
    popH = popH or 0
    if f.pbar then f.pbar:Hide() end   -- re-shown below for a progress-bar step
    f.chapter:Show(); f.step:Show()
    f.tabZones:Hide(); f.tabDungeons:Hide(); self._tabMode = nil   -- Refresh decides (ShowTabs)
    if f.stepBtn then f.stepBtn:Show() end
    if f.objBtn then f.objBtn:Show() end
    if f.obj then f.obj:SetShown(VQ:Get("showObjective") ~= false) end
    if f.questRows then for _, row in ipairs(f.questRows) do row.btn:Hide(); row.obj:Hide(); if row.bar then row.bar:Hide() end end end
    self:HideQuestBlock(f)   -- re-drawn by the step / no-step branch
    f.chapter:ClearAllPoints(); f.chapter:SetPoint("TOPLEFT", 12, -27 - popH)
    f.step:ClearAllPoints(); f.step:SetPoint("TOPLEFT", 12, -44 - popH)
    -- Hang the objective off the step's BOTTOM so a step that wraps to two lines
    -- ("Next chapter Pick up: <long name>") pushes it down instead of overlapping.
    f.obj:ClearAllPoints(); f.obj:SetPoint("TOPLEFT", f.step, "BOTTOMLEFT", 0, -4)
    PanelHeight(f, 90 + popH)
end

-- The button row along the bottom (Book, Zone, Lines, density, then the gear and the tracker box
-- at the right, left of the resize grip). The title has the whole top line to itself. The text
-- buttons keep their size while they fit; on a narrow panel they shrink, never below their text,
-- and switch to the small font when even that doesn't fit. Runs on resize and title changes.
local FOOTER_RIGHT = 62   -- grip + tracker box + gear, from the right edge to the first text button
local FOOTER_BTNS = { { "densityBtn", 42 }, { "pickBtn", 42 }, { "zoneBtn", 46 }, { "bookBtn", 46 } }
function mod:FitHeader(f)
    f = f or self.frame   -- the build passes its panel: self.frame isn't set yet then
    if not (f and f.densityBtn) then return end
    f.camp:SetWidth(PW() - 24)
    f.camp:SetAlpha(1)
    local btns, sum = {}, 0   -- { button, natural width }, right to left
    for _, e in ipairs(FOOTER_BTNS) do
        local b = f[e[1]]
        if b and b:IsShown() then btns[#btns + 1] = { b, e[2] }; sum = sum + e[2] end
    end
    local gaps = 3 * #btns
    local avail = PW() - 8 - FOOTER_RIGHT - gaps   -- 8: the panel's left padding
    local function measure(small)
        local mins, minSum = {}, 0
        for i, e in ipairs(btns) do
            local b = e[1]
            if b._vqSmall ~= small then
                b:SetNormalFontObject(small and GameFontNormalSmall or GameFontNormal)
                b:SetHighlightFontObject(small and GameFontHighlightSmall or GameFontHighlight)
                b:SetDisabledFontObject(small and GameFontDisableSmall or GameFontDisable)
                b._vqSmall = small
            end
            local fs = b:GetFontString()
            mins[i] = math.ceil(fs and fs:GetStringWidth() or 20) + 8
            minSum = minSum + mins[i]
        end
        return mins, minSum
    end
    local mins, minSum = measure(false)
    if minSum > avail then mins, minSum = measure(true) end
    for i, e in ipairs(btns) do
        local w = e[2]
        if avail < sum then   -- squeeze: from natural toward the text-only width
            local k = (sum > minSum) and math.max(0, (avail - minSum) / (sum - minSum)) or 0
            w = mins[i] + (e[2] - mins[i]) * k
        end
        e[1]:SetWidth(math.floor(math.max(w, mins[i])))
    end
end

-- Width changed (corner grip, or a setting): every line follows. Rows made earlier kept
-- the width they were created with, so set them all again. Cheap; skipped while resizing
-- by hand and in combat (the panel is protected then).
function mod:ApplyWidth()
    local f = self.frame
    if not f or (f._sizing and not f._live) or (InCombatLockdown() and f:IsProtected()) then return end
    local pw, cw = PW(), CW()
    if not f._sizing and math.abs(f:GetWidth() - pw) > 0.5 then f:SetWidth(pw) end
    self:FitHeader()
    for _, fs in ipairs({ f.chapter, f.step, f.obj, f.side, f.meta, f.big }) do if fs then fs:SetWidth(cw) end end
    for _, row in ipairs(f.qRows or {}) do row:SetWidth(cw) end
    for _, row in ipairs(f.questRows or {}) do
        if row.btn then row.btn:SetWidth(cw) end
        if row.obj then row.obj:SetWidth(cw - 4) end
    end
    for _, row in ipairs(f.popupRows or {}) do row:SetWidth(cw) end
end

-- Clicks that didn't land (the user, 2026-11-07: "clicking inside the box doesn't always
-- land"): the panel redraws up to every 0.4 s while questing (QUEST_LOG_UPDATE, bags, POIs,
-- zone changes), and a redraw hides and re-shows its lines and buttons. One that lands
-- between a mouse press and its release drops that click. So while a mouse button is held
-- over the panel, the redraw waits for the release (at most 2 s, so the panel never freezes).
local function MouseHeldOver(f)
    return f:IsShown() and f:IsMouseOver()
        and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) or false
end

function mod:Refresh()
    local f = self:EnsurePanel()
    -- (not during a live resize redraw: dragging the grip IS holding the mouse over the panel)
    if not f._live and MouseHeldOver(f) and (not self._clickHoldAt or GetTime() - self._clickHoldAt < 2) then
        if not self._clickHoldAt then
            self._clickHoldAt = GetTime()
            local function retry()
                if MouseHeldOver(f) and GetTime() - self._clickHoldAt < 2 then
                    C_Timer.After(0.05, retry)
                    return
                end
                self:Refresh()
                self._clickHoldAt = nil
            end
            C_Timer.After(0.05, retry)
        end
        return
    end
    self._stepQid = nil   -- set again below only when a guided step is shown
    if f._sizing and not f._live then return end   -- being resized by hand: only the live redraw (OnSizeChanged)
    self:ApplyWidth()
    f.side:Hide(); f.sideBtn:Hide(); self._side = nil   -- re-shown below in step mode
    f.big:Hide(); f.bigBtn:Hide(); self._big = nil
    f.meta:Hide(); f.metaBtn:Hide(); self._meta = nil
    if f.way then f.way:Hide(); f.wayBtn:Hide() end
    -- a side-quest pin did its job once that quest is picked up: back to the main step's pin
    if self._sidePin and (safe(C_QuestLog.GetLogIndexForQuestID, self._sidePin)
       or safe(C_QuestLog.IsQuestFlaggedCompleted, self._sidePin)) then
        self._sidePin = nil; self._lastStep = nil   -- (_pinLock keeps following that quest)
    end
    -- a step-line pin lock ends when that quest is turned in, or dropped after accepting
    local L = self._pinLock
    if L then
        local inLog = safe(C_QuestLog.GetLogIndexForQuestID, L.qid) and true or false
        if safe(C_QuestLog.IsQuestFlaggedCompleted, L.qid) or (L.inLog and not inLog) then
            self._pinLock = nil; self._lastStep = nil
        elseif inLog then
            L.inLog = true
        end
    end
    self:ApplyBlizzTracker()   -- keep the Blizzard tracker in its chosen show/hide state
    if VoidQuestDB and VoidQuestDB.guideHidden then self:ClearOurWaypoint(); PanelShown(f, false); return end
    local popH = self:RenderPopups(f)   -- auto-quest offer/turn-in alerts, above everything
    -- Leveling Coach strip (below max level): the next thing to do, then the usual content
    if VQ.Coach then popH = popH + VQ.Coach:RenderStrip(f, popH) end
    local r = self:Resolve()
    if not r then
        -- No campaign AND no quests at all. Show the box (with its buttons) so you can reach
        -- the campaign selector -- hiding it entirely left no way to pick one.
        self:SetStepMode(f, popH)
        f.camp:SetText("|cff00c7ffVoidQuest|r"); mod:FitHeader(f)   -- the title comes first
        f.chapter:SetText("No campaign or quests on this character")
        f.step:SetText("|cffffd200Click the gear (top-right) or 'Lines'|r")
        f.obj:SetText("|cff888888then Select campaign -- or pick up a quest.|r")
        if f.densityBtn then f.densityBtn:SetText(DENSITY_SHORT[self:Density()]) end
        if not (self._wp and self._wp.coach) then self:ClearOurWaypoint() end   -- a coach pin stays
        if VQ.Ring then VQ.Ring:Set(nil) end
        self._lastStep = nil
        PanelHeight(f, math.max(PanelBudget(), 90 + popH))   -- same fixed size as always
        PanelShown(f, true)
        return
    end
    if r.questOnly then
        -- No campaign -> list ALL current quests (mirrors the Blizzard tracker).
        f.densityBtn:SetText(DENSITY_SHORT[r.density])
        -- a pin the coach button set stays (this ran on the refresh right after setting it)
        if not (self._wp and self._wp.coach) then self:ClearOurWaypoint() end
        if VQ.Ring then VQ.Ring:Set(nil) end
        self:RenderQuestList(f, popH)
        self._lastStep = nil
        PanelShown(f, true)
        return
    end
    self:SetStepMode(f, popH)   -- campaign mode: single-step widgets
    local g = r.g
    f.camp:SetText("|cff00c7ff" .. (g.campName or "Campaign") .. "|r"); mod:FitHeader(f)   -- the title comes first
    f.chapter:SetText((self:ArrowOn() and "" or "|cffff5555[arrow off -- world map button]|r ") .. (g.chapter or ""))
    -- WoW Forever's zone guide: Zones | Dungeons tabs instead of the chapter line
    -- (an arrow-off warning keeps the chapter line, so it can't go unseen)
    self:ShowTabs(f, (g.zoneGuide and VQ.Forever and VQ.Forever:Active() and self:ArrowOn()) and true or false, popH)
    f.densityBtn:SetText(DENSITY_SHORT[r.density])

    local step = r.primary
    self._stepQid = step and step.qid   -- the quest-item button follows the guided step
    self._shownStep = step              -- a step-line click locks to this (pinClick)
    if step then
        local verb = VERB[step.status] or "Do"
        -- show the qid while the name loads so a stuck step is identifiable at a glance
        local name = step.title or ("quest " .. tostring(step.qid) .. " |cff888888(name loading)|r")
        if not step.title and not self._titleNudge then
            -- quest-data load is async and can miss the first paint -> nudge one re-refresh
            self._titleNudge = true
            safe(C_QuestLog.RequestLoadQuestByID, step.qid)
            C_Timer.After(1.5, function() self._titleNudge = nil; self:Refresh() end)
        end
        if step.zone then
            f.step:SetText(("|cff88ccffZone|r  %s: |cff55ff55%s|r"):format(verb, name))
        elseif step.nextChapter then
            f.step:SetText(("|cffffd200Next chapter|r  %s: |cff55ff55%s|r"):format(verb, name))
        elseif (step.idx or 0) > 0 and (step.total or 0) > 0 then
            f.step:SetText(("%d/%d  %s: |cff55ff55%s|r"):format(step.idx, step.total, verb, name))
        else
            f.step:SetText(("%s: |cff55ff55%s|r"):format(verb, name))   -- discovery pickup, no chain index
        end

        -- objective text (in-log) / gated hint / zone summary
        local obj = ""
        for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, step.qid) or {}) do
            if o.text and o.text ~= "" then obj = obj .. (obj ~= "" and " | " or "") .. o.text end
        end
        local showZone = VQ:Get("showZoneSummary") ~= false
        -- WHO: remembered giver/turn-in NPC (learned on any character), else the game's own
        -- waypoint hint ("Speak to Turalyon") for an in-log quest.
        local who
        local giver = VQ.Starts and VQ.Starts:Giver(step.qid)
        local taker = VQ.Starts and VQ.Starts:Turnin(step.qid)
        if step.status == "pickup" and giver then
            who = "Talk to " .. giver
        elseif step.status == "turnin" and taker then
            who = "Turn in to " .. taker
        elseif step.status ~= "pickup" then
            -- only when it names a PERSON -- for out-of-zone quests it returns generic
            -- routing ("Take the portal to Stormwind"), which would mislead (see header)
            local wt = safe(C_QuestLog.GetNextWaypointText, step.qid)
            if type(wt) == "string" and (wt:find("^Speak") or wt:find("^Talk") or wt:find("^Meet")
               or wt:find("^Report") or wt:find("^Return to")) and not wt:lower():find("portal", 1, true) then
                who = wt
            end
        end
        if step.unverified then
            obj = "|cffffd200Accept this one yourself -- focus is locked, so it isn't auto-accepted.|r"
        elseif step.status == "pickup" and not step.zone then
            -- pickup: show WHERE (coords + zone) when we can resolve a location, and make
            -- the click-to-pin affordance explicit; be honest + specific when we can't.
            local srcs = self:WaypointSources(step.qid, g.ql)
            local chosen
            for _, s in ipairs(srcs) do chosen = s; if s.name:find("giver") then break end end
            if step.wpMap and step.wpX and step.wpY then
                chosen = { m = step.wpMap, x = step.wpX, y = step.wpY }
            end
            -- availability guarantee: game-confirmed (in log / giver offering) vs chain-inferred
            local conf = step.nextChapter or step.confirmed or self:VerifyObtainable(step.qid)
            local function zoneOf(m)
                local mi = safe(C_Map.GetMapInfo, m)
                return (mi and mi.name) and (" in " .. mi.name) or ""
            end
            if chosen then
                -- on another continent (e.g. Draenor from Orgrimmar)? say so first
                local there = self:ContinentOf(chosen.m)
                local here = self:ContinentOf(safe(C_Map.GetBestMapForUnit, "player"))
                local travel = (there and here and there.mapID ~= here.mapID)
                    and ("|cffffaa33Travel to %s first.|r "):format(there.name) or ""
                obj = ("%s|cff55ff55Go to %.1f, %.1f%s|r %s |cff888888- click this line to set a pin|r"):format(
                    travel, chosen.x * 100, chosen.y * 100, zoneOf(chosen.m),
                    conf and "" or "|cffaaaaaa(unconfirmed)|r")
            else
                -- no giver anywhere -> is this step a raid/dungeon? route to its ENTRANCE
                local ent = self:FindContentEntrance(step)
                if ent then
                    step.wpMap, step.wpX, step.wpY = ent.m, ent.x, ent.y   -- pin targets the entrance
                    obj = ("|cff55ff55Enter %s|r (any difficulty -- LFR/Raid Finder counts once open). |cff55ff55Entrance %.1f, %.1f%s|r |cff888888- click this line to set a pin|r"):format(
                        ent.name, ent.x * 100, ent.y * 100, zoneOf(ent.m))
                else
                    obj = self:WhyNoLocation(step, r.g)
                        or "|cffff8800This step has no map location yet -- it starts automatically or inside an instance. I'll show it as soon as the game exposes one.|r"
                end
            end
        elseif step.zone and step.status == "pickup" and step.wpMap and step.wpX and step.wpX > 0 then
            local here = safe(C_Map.GetBestMapForUnit, "player")
            local mi = (step.wpMap ~= here) and safe(C_Map.GetMapInfo, step.wpMap)
            local tag = XPTag(step)
            -- how far, when it's on this map: a pin 60 yd away sits in view as a diamond with
            -- no arrow, and read as "no pin" (2026-10-26)
            local far = ""
            if step.wpMap == here then
                local pos = safe(C_Map.GetPlayerMapPosition, here, "player")
                local px, py
                if pos and pos.GetXY then px, py = pos:GetXY() end
                local yd = px and YardsBetween(Pt(here, px, py), Pt(here, step.wpX, step.wpY))
                if yd then far = yd < 40 and " -- right here" or (" (%d yd)"):format(math.floor(yd + 0.5)) end
            end
            obj = ("%s|cff55ff55Go to %.1f, %.1f%s%s|r |cff888888- click this line to set a pin|r"):format(
                tag ~= "" and ("|cffffd200" .. tag .. "|r  ") or "",
                step.wpX * 100, step.wpY * 100, (mi and mi.name) and (" in " .. mi.name) or "", far)
        elseif showZone and r.campaignGated and r.pool and #r.pool > 0 then
            obj = ("|cff88ccff[%s] campaign gated -- %d zone quest%s in scope.|r"):format(
                DENSITY_SHORT[r.density], #r.pool, #r.pool == 1 and "" or "s")
        elseif showZone and r.pool then
            local more = #r.pool - (r.isZone and 1 or 0)
            if more > 0 then obj = obj .. (obj ~= "" and "  " or "") .. ("|cff888888(+%d in-scope)|r"):format(more) end
        end
        if who then obj = ("|cffffffff%s|r"):format(who) .. (obj ~= "" and "  " .. obj or "") end
        if r.levelGate then
            local lvl = UnitLevel("player") or 0
            local why
            if r.isZone and r.zoneRank and r.zoneRank[1] then
                -- the zone we stick with (see LevelPool) and why
                local z = r.zoneRank[1]
                if r.zoneRank.why == "here" then
                    why = ("side quests here first: %s has %s XP left."):format(z.name, kxp(z.total))
                elseif r.zoneRank.why == "committed" then
                    why = ("keep going in %s: %s XP left."):format(z.name, kxp(z.total))
                else
                    local nextZ = r.zoneRank[2]
                    why = ("most XP left in side quests: %s %s%s."):format(z.name, kxp(z.total),
                        nextZ and (" (next: %s %s)"):format(nextZ.name, kxp(nextZ.total)) or "")
                end
            else
                why = "no side stories left nearby -- queue dungeons (Group Finder) or run delves for XP."
            end
            -- how far that is: the rest of this level in normal quests
            local idx = self._xpIdx
            local need = (UnitXPMax("player") or 0) - (UnitXP("player") or 0)
            local per = idx and idx.normal or 0
            local howFar = (per > 0 and need > 0)
                and (" ~%d normal quests to %d."):format(math.ceil(need / per), lvl + 1) or ""
            obj = ("|cffffd200Campaign waits for level %d (you're %d): %s%s|r"):format(r.levelGate, lvl, why, howFar)
                .. (obj ~= "" and "  " .. obj or "")
        end
        f.obj:SetText(obj)
        -- progress-bar quests (in your log): a bar under the objective, like Blizzard's tracker
        f.pbar = f.pbar or MakeProgressBar(f, 276)
        f.pbar:ClearAllPoints(); f.pbar:SetPoint("TOPLEFT", f.obj:IsShown() and f.obj or f.step, "BOTTOMLEFT", 0, -4)
        SetProgress(f.pbar, step.status == "progress" and ProgressPercent(step.qid) or nil)
        -- side quest on the way (Mid/Max), or what this zone still has before you leave it
        local sideText
        if showZone and r.pool then
            local here = safe(C_Map.GetBestMapForUnit, "player")
            local side, left = self:SideQuest(r, g.ql)
            if side then
                self._side = side
                local tag = XPTag(side)
                sideText = ("|cff88ccffOn the way:|r %s |cff55ff55%s|r |cff888888(%s%d yd) - click to pin|r"):format(
                    VERB.pickup, side.title or ("quest " .. side.qid),
                    tag ~= "" and (tag .. ", ") or "", math.floor((side.yards or 0) + 0.5))
            elseif (left or 0) > 0 then
                -- the main step points to another zone: say what's left here before you go
                local tm = (step.status == "pickup") and (step.wpMap or (self:WaypointSources(step.qid, g.ql)[1] or {}).m)
                    or safe(C_QuestLog.GetNextWaypoint, step.qid)
                if tm and here and tm ~= here then
                    for _, e in ipairs(r.pool) do
                        if e.map == here and not e.inLog and e.qid ~= step.qid and e.x and e.x > 0 then self._side = e; break end
                    end
                    local mi = safe(C_Map.GetMapInfo, here)
                    if self._side then
                        sideText = ("|cff88ccffBefore you leave %s:|r %d side quest%s left -- nearest |cff55ff55%s|r |cff888888- click to pin|r"):format(
                            (mi and mi.name) or "this zone", left, left == 1 and "" or "s", self._side.title or ("quest " .. self._side.qid))
                    end
                end
            end
        end
        -- extra lines under the step, in priority order: pick-up-first (meta quest), the
        -- side quest on the way, the big-XP offer
        -- last VISIBLE line: a hidden objective keeps its size, so anchoring under it put the
        -- quest lines below text the height math didn't count (Codex review)
        local sideH, below = 0, (f.pbar:IsShown() and f.pbar) or (f.obj:IsShown() and f.obj) or f.step
        local function extra(fs, btn, text)
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -4)
            fs:SetText(text); fs:Show(); btn:Show()
            sideH = sideH + (fs:GetStringHeight() or 12) + 4
            below = fs
        end
        -- an activity ("meta") quest not picked up yet: its activities only count once it's
        -- in your log, so it goes first, any density (2026-10-26: a Labyrinth run and world
        -- quests done before "Hope in the Darkest Corners" counted for nothing)
        -- the way to the step when it's in another zone (VoidGPS): first, it's about the step itself
        local wayText = self:StepWayText(step.qid)
        if wayText then extra(f.way, f.wayBtn, wayText) end
        local meta = self:MetaOffer()
        if meta and meta.qid ~= step.qid then
            self._meta = meta
            local mi = safe(C_Map.GetMapInfo, meta.map)
            local goal = self:MetaGoal(meta.qid)
            extra(f.meta, f.metaBtn, ("|cffff8800Pick up first:|r |cff55ff55%s|r%s |cff888888(%s%s) - click to pin|r"):format(
                meta.title or ("quest " .. meta.qid), goal and (" |cffffd200-- counts " .. goal .. "|r") or "",
                (meta.xp or 0) > 0 and (kxp(meta.xp) .. " XP, ") or "", (mi and mi.name) or "?"))
        end
        if sideText then extra(f.side, f.sideBtn, sideText) end
        -- one big-XP offer anywhere on the continent (dungeon quest, special quest): worth
        -- a trip even from another zone. Mid/Max or level-gated, below max level.
        -- (not on WoW Forever: it runs on quest lines, which Forever has none of)
        local big = not VQ.ForeverQuests and (r.levelGate or r.density ~= "min") and self:BigXPOffer()
        if big and big.qid ~= step.qid and not (meta and big.qid == meta.qid) then
            self._big = big
            local mi = safe(C_Map.GetMapInfo, big.map)
            extra(f.big, f.bigBtn, ("|cffffd200Big XP:|r |cff55ff55%s|r |cffffd200%s XP|r |cff888888(%s) - click to pin|r"):format(
                big.title or ("quest " .. big.qid), kxp(big.xp), (mi and mi.name) or "?"))
        end
        -- the guide's own lines set the minimum (long text never spills past the border);
        -- the panel stays at the fixed height and quest lines fill what's left
        local sh = f.step:GetStringHeight() or 14
        local oh = (f.obj:IsShown() and f.obj:GetStringHeight()) or 0
        local bh = f.pbar:IsShown() and 12 or 0
        local core = math.max(90 + popH, 44 + popH + sh + 4 + oh + bh + sideH + 14)
        local budget = PanelBudget()
        -- measure where the guide's lines really end (the estimate above runs ~90 px high,
        -- which left a resized panel with empty space AND "+N more", 2026-11-05)
        local measured = MeasuredCore(f, below)
        if measured then core = measured end
        local fit = math.floor((budget - core - 6) / QROW)
        local lines = self:RenderQuestBlock(f, below, fit, step.qid)
        if self._tabMode then self:UpdateTabLabels(f) end   -- the dungeon count is known now
        PanelHeight(f, math.max(budget, core + (lines > 0 and (lines * QROW + 6) or 0)))

        local key = (r.isZone and "z:" or "c:") .. step.qid .. ":" .. step.status
        if self._lastStep ~= key then
            self._lastStep = key
            self:Waypoint(step, g.ql)   -- re-fires on objective->turn-in transition too
        end
    else
        if r.g and r.g.lockedNoData then
            f.step:SetText("|cffffd200No pickup found for this campaign yet|r")
            f.obj:SetText("|cff888888Travel toward its zone / check after weekly unlocks -- I'll grab it when it appears.|r")
        elseif r.density == "min" and r.campaignGated then
            f.step:SetText("|cffffd200Campaign gated|r")
            f.obj:SetText("|cff888888Raid/renown/patch. Click Min\226\134\146Mid/Max for zone quests.|r")
        else
            f.step:SetText("|cff55ff55All in-scope quests complete!|r"); f.obj:SetText("")
        end
        -- nothing to guide to -> no stale pin (but keep one you clicked on an extra line,
        -- e.g. "Pick up first"; it clears itself once that quest is picked up)
        if not self._sidePin then self:ClearOurWaypoint() end
        if VQ.Ring then VQ.Ring:Set(nil) end
        self._lastStep = nil
        -- no step, but an unpicked activity quest still matters (Codex review)
        local meta = self:MetaOffer()
        if meta then
            self._meta = meta
            local mi = safe(C_Map.GetMapInfo, meta.map)
            local goal = self:MetaGoal(meta.qid)
            f.meta:ClearAllPoints(); f.meta:SetPoint("TOPLEFT", f.obj, "BOTTOMLEFT", 0, -4)
            f.meta:SetText(("|cffff8800Pick up first:|r |cff55ff55%s|r%s |cff888888(%s) - click to pin|r"):format(
                meta.title or ("quest " .. meta.qid), goal and (" |cffffd200-- counts " .. goal .. "|r") or "",
                (mi and mi.name) or "?"))
            f.meta:Show(); f.metaBtn:Show()
        end
        -- nothing to guide: the free space shows your quests (other zones' too)
        local core = 90 + popH + (f.meta:IsShown() and ((f.meta:GetStringHeight() or 12) + 6) or 0)
        local budget = PanelBudget()
        local anchor = (f.meta:IsShown() and f.meta) or (f.obj:IsShown() and f.obj) or f.step
        local measured = MeasuredCore(f, anchor)
        if measured then core = measured end
        local lines = self:RenderQuestBlock(f, anchor, math.floor((budget - core - 6) / QROW), nil)
        if self._tabMode then self:UpdateTabLabels(f) end
        PanelHeight(f, math.max(budget, core + (lines > 0 and (lines * QROW + 6) or 0)))
    end
    PanelShown(f, true)
end

----------------------------------------------------------------------
-- Quest-line PICKER: tick which lines VoidQuest guides (and auto-runs).
----------------------------------------------------------------------
function mod:EnsurePicker()
    if self.picker then return self.picker end
    local p = CreateFrame("Frame", "VoidQuestPickerFrame", UIParent, "BackdropTemplate")
    p:SetSize(320, 480)
    p:SetPoint("CENTER", UIParent, "CENTER", -180, 0)   -- offset so it doesn't stack on Settings
    p:SetFrameStrata("DIALOG"); p:SetToplevel(true)
    p:SetMovable(true); p:EnableMouse(true); p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving); p:SetScript("OnDragStop", p.StopMovingOrSizing)
    VQ:CreateBackdrop(p, 0.95)
    p.title = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.title, 13, "OUTLINE")
    p.title:SetPoint("TOP", 0, -8); p.title:SetText("Guide Focus \226\128\148 campaign + lines")
    local close = CreateFrame("Button", nil, p, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)
    -- Campaign focus: lock to ONE campaign (or Auto). Buttons built in RefreshPicker.
    p.campLabel = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.campLabel, 10, "OUTLINE")
    p.campLabel:SetPoint("TOPLEFT", 12, -28); p.campLabel:SetText("|cff00c7ffCampaign:|r")
    p.campHolder = CreateFrame("Frame", nil, p); p.campHolder:SetPoint("TOPLEFT", 12, -42); p.campHolder:SetSize(296, 44)
    p.campBtns = {}
    -- density hint + quest-line checkboxes
    p.dtext = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.dtext, 10)
    p.dtext:SetPoint("TOPLEFT", 12, -90); p.dtext:SetWidth(296); p.dtext:SetJustifyH("LEFT"); p.dtext:SetTextColor(.8, .8, .8)
    p.reset = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    p.reset:SetSize(96, 18); p.reset:SetPoint("BOTTOM", 0, 10); p.reset:SetText("Reset picks")
    p.reset:SetScript("OnClick", function() VoidQuestDB.pick = {}; mod:RefreshPicker(); mod:Refresh() end)
    p.container = CreateFrame("Frame", nil, p)
    p.container:SetPoint("TOPLEFT", 14, -120); p.container:SetPoint("BOTTOMRIGHT", -14, 34)
    p.rows = {}
    p:Hide()   -- created hidden so the FIRST toggle-click shows it (CreateFrame shows by default)
    self.picker = p
    return p
end

function mod:RefreshPicker()
    local p = self:EnsurePicker()

    -- Campaign focus: current lock + a button to open the full campaign selector.
    local locked = self:LockedCampID()
    local lockedName = "Auto (whatever I'm on)"
    if locked then
        local camps = self:SelectableCampaigns()
        lockedName = (camps[locked] and camps[locked].name) or ("Campaign " .. locked)
    end
    p.campLabel:SetText(("|cff00c7ffCampaign:|r |cff55ff55%s|r"):format(lockedName))
    local sb = p.campBtns[1]
    if not sb then
        sb = CreateFrame("Button", nil, p.campHolder, "UIPanelButtonTemplate")
        sb:SetSize(180, 20); sb:SetPoint("TOPLEFT", 0, 0); sb:SetText("Select campaign...")
        sb:SetScript("OnClick", function() mod:ToggleCampaignSelect() end)
        p.campBtns[1] = sb
    end
    sb:Show()
    local zb = p.campBtns[2]
    if not zb then
        zb = CreateFrame("Button", nil, p.campHolder, "UIPanelButtonTemplate")
        zb:SetSize(110, 20); zb:SetPoint("LEFT", sb, "RIGHT", 6, 0); zb:SetText("Zone guides...")
        zb:SetScript("OnClick", function() if VQ.Zones then VQ.Zones:ToggleWindow() end end)
        p.campBtns[2] = zb
    end
    zb:Show()
    for i = 3, #p.campBtns do p.campBtns[i]:Hide() end

    p.dtext:SetText(("Density: |cff55ff55%s|r  \226\128\148  checkmarks show the current tier; tick to override a line."):format(DENSITY_LABEL[self:Density()]))
    local map = safe(C_Map.GetBestMapForUnit, "player")
    local list, seen = {}, {}
    for _, q in ipairs((map and safe(C_QuestLine.GetAvailableQuestLines, map)) or {}) do
        if q.questLineID and not seen[q.questLineID] and not safe(C_QuestLog.IsQuestFlaggedCompleted, q.questID) then
            seen[q.questLineID] = true; list[#list+1] = q
        end
    end
    table.sort(list, function(a, b)
        if a.isCampaign ~= b.isCampaign then return a.isCampaign end
        if a.isImportant ~= b.isImportant then return a.isImportant end
        return (a.questLineName or "") < (b.questLineName or "")
    end)
    for i, q in ipairs(list) do
        local row = p.rows[i]
        if not row then
            row = CreateFrame("CheckButton", nil, p.container, "UICheckButtonTemplate")
            row:SetSize(20, 20); row:SetPoint("TOPLEFT", 0, -(i - 1) * 20)
            row.label = row:CreateFontString(nil, "OVERLAY"); VQ:SetFont(row.label, 10)
            row.label:SetPoint("LEFT", row, "RIGHT", 2, 0); row.label:SetWidth(258); row.label:SetJustifyH("LEFT")
            row:SetScript("OnClick", function(s)
                VoidQuestDB.pick = VoidQuestDB.pick or {}
                VoidQuestDB.pick[s.qlID] = s:GetChecked() and true or false
                mod:Refresh()
            end)
            p.rows[i] = row
        end
        row.qlID = q.questLineID
        local tag = q.isCampaign and " |cff00c7ff[campaign]|r" or (q.isImportant and " |cffffd200[important]|r" or "")
        row.label:SetText((q.questLineName or ("line " .. q.questLineID)) .. tag)
        row:SetChecked(self:InScope(q))
        row:Show()
    end
    for i = #list + 1, #p.rows do p.rows[i]:Hide() end
end

function mod:TogglePicker()
    local p = self:EnsurePicker()
    if p:IsShown() then p:Hide() else self:RefreshPicker(); p:Show() end
end

----------------------------------------------------------------------
-- CAMPAIGN SELECT: pick ANY campaign to follow -- including
-- one you haven't started (GetAvailableCampaigns) -- and lock onto it.
----------------------------------------------------------------------
function mod:EnsureCampaignSelect()
    if self.campSel then return self.campSel end
    local p = CreateFrame("Frame", "VoidQuestCampaignSelect", UIParent, "BackdropTemplate")
    p:SetSize(320, 470); p:SetPoint("CENTER", UIParent, "CENTER", 200, 0); p:SetClampedToScreen(true)
    p:SetFrameStrata("FULLSCREEN_DIALOG"); p:SetToplevel(true)   -- above Settings, offset to the right
    p:SetMovable(true); p:EnableMouse(true); p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving); p:SetScript("OnDragStop", p.StopMovingOrSizing)
    VQ:CreateBackdrop(p, 0.96)
    p.title = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.title, 13, "OUTLINE")
    p.title:SetPoint("TOP", 0, -8); p.title:SetText("Select Campaign to follow")
    p.sub = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.sub, 10)
    p.sub:SetPoint("TOPLEFT", 12, -26); p.sub:SetWidth(296); p.sub:SetJustifyH("LEFT"); p.sub:SetTextColor(.8, .8, .8)
    local close = CreateFrame("Button", nil, p, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)
    -- Show-all toggle: probe EVERY campaign the game knows (else just the available few).
    p.showAll = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
    p.showAll:SetSize(20, 20); p.showAll:SetPoint("TOPLEFT", 12, -40)
    p.showAll.text = p.showAll:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.showAll.text, 10)
    p.showAll.text:SetPoint("LEFT", p.showAll, "RIGHT", 2, 0)
    p.showAll.text:SetText("Show all (incl. done / other expansions)")
    p.showAll:SetScript("OnClick", function(s)
        VoidQuestDB.campShowAll = s:GetChecked() and true or false
        p.scrollOffset = 0; mod:RefreshCampaignSelect()
    end)
    p.scrollOffset = 0
    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(_, delta)
        p.scrollOffset = (p.scrollOffset or 0) - delta; mod:RefreshCampaignSelect()
    end)
    p.rows = {}
    p:Hide()   -- created hidden so the FIRST click opens it
    self.campSel = p
    return p
end

function mod:RefreshCampaignSelect()
    local p = self:EnsureCampaignSelect()
    local showAll = VoidQuestDB and VoidQuestDB.campShowAll
    p.showAll:SetChecked(showAll and true or false)
    -- NOTE: `A and f() or g()` truncates multi-returns to 1 value -> order came back nil.
    local camps, order
    if showAll then camps, order = self:AllCampaigns() else camps, order = self:SelectableCampaigns() end
    local locked = self:LockedCampID()

    -- Entries: Auto, then campaigns grouped by EXPANSION with headers (newest first). Within
    -- an expansion, in-progress/available float above completed. Utility campaigns filtered.
    local function trunc(s) return (#s > 40) and (s:sub(1, 38) .. "..") or s end
    local groups = {}
    for _, c in ipairs(order) do
        local exp = self:CampaignExpansion(camps[c].name, c)
        if exp then groups[exp] = groups[exp] or {}; groups[exp][#groups[exp] + 1] = c end
    end
    -- CampaignState: 2=InProgress best, 3=Stalled (started, gated), 0=not started, 1=Complete
    local staterank = { [2] = 0, [3] = 1, [0] = 2, [1] = 3 }
    local statetag = {
        [2] = " |cffffd200(in progress)|r",
        [3] = " |cffff8800(stalled)|r",     -- started but gated (raid/renown/patch)
        [1] = " |cff888888(done)|r",
    }
    local entries = { { id = nil, text = "Auto (whatever I'm on)" } }
    local total = 0
    for _, exp in ipairs(EXPANSION_ORDER) do
        local list = groups[exp]
        if list and #list > 0 then
            table.sort(list, function(a, b)
                local ra, rb = staterank[camps[a].state] or 2, staterank[camps[b].state] or 2
                if ra ~= rb then return ra < rb end
                return (camps[a].name or "") < (camps[b].name or "")
            end)
            entries[#entries + 1] = { header = true, text = ("%s (%d)"):format(exp, #list) }
            for _, c in ipairs(list) do
                entries[#entries + 1] = { id = c, text = trunc(camps[c].name) .. (statetag[camps[c].state] or "") }
                total = total + 1
            end
        end
    end

    local VISIBLE = 15
    local maxOff = math.max(0, #entries - VISIBLE)
    p.scrollOffset = math.max(0, math.min(p.scrollOffset or 0, maxOff))
    local off = p.scrollOffset
    p.sub:SetText(("Following: |cff55ff55%s|r  \226\128\148  %d campaigns%s"):format(
        (locked and ((camps[locked] and camps[locked].name) or tostring(locked))) or "Auto",
        total, maxOff > 0 and "  |cff888888(scroll)|r" or ""))
    for i = 1, VISIBLE do
        local row = p.rows[i]
        if not row then
            row = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
            row:SetSize(296, 20); row:SetPoint("TOPLEFT", 12, -64 - (i - 1) * 21)
            p.rows[i] = row
        end
        local e = entries[i + off]
        if e then
            if e.header then
                row:SetEnabled(false); row:SetScript("OnClick", nil)
                row:SetText("|cff00c7ff" .. e.text .. "|r")
            else
                row:SetEnabled(true)
                row:SetText(((e.id == locked) and "|cff55ff55> |r" or "") .. e.text)
                local id = e.id
                row:SetScript("OnClick", function() mod:LockCampaign(id); mod:RefreshCampaignSelect() end)
            end
            row:Show()
        else
            row:Hide()
        end
    end
end

function mod:ToggleCampaignSelect()
    local p = self:EnsureCampaignSelect()
    if p:IsShown() then p:Hide() else self:RefreshCampaignSelect(); p:Show() end
end

----------------------------------------------------------------------
-- MY QUESTS: track/guide ALL active quests (not just campaign), grouped by
-- the quest log's own zone headers. Click a quest -> super-track + waypoint.
-- Answers "why aren't my current quests in VoidQuest" -- because VoidQuest was
-- campaign-only; this surfaces everything in the log.
----------------------------------------------------------------------
function mod:QuestsByZone()
    local zones, order = {}, {}
    local cur = "Quests"
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        if info then
            if info.isHeader then
                cur = (info.title and info.title ~= "" and info.title) or "Quests"
            elseif info.questID then
                if not zones[cur] then zones[cur] = {}; order[#order + 1] = cur end
                zones[cur][#zones[cur] + 1] = {
                    qid = info.questID, title = info.title or ("quest " .. info.questID),
                    complete = safe(C_QuestLog.IsComplete, info.questID) and true or false,
                }
            end
        end
    end
    return zones, order
end

function mod:EnsureQuestLog()
    if self.qlog then return self.qlog end
    local p = CreateFrame("Frame", "VoidQuestMyQuests", UIParent, "BackdropTemplate")
    p:SetSize(340, 480); p:SetPoint("CENTER", UIParent, "CENTER", -200, 0); p:SetClampedToScreen(true)
    p:SetFrameStrata("FULLSCREEN_DIALOG"); p:SetToplevel(true)
    p:SetMovable(true); p:EnableMouse(true); p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving); p:SetScript("OnDragStop", p.StopMovingOrSizing)
    VQ:CreateBackdrop(p, 0.96)
    p.title = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.title, 13, "OUTLINE")
    p.title:SetPoint("TOP", 0, -8); p.title:SetText("My Quests \226\128\148 click to track + waypoint")
    p.sub = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.sub, 10)
    p.sub:SetPoint("TOPLEFT", 12, -26); p.sub:SetWidth(316); p.sub:SetJustifyH("LEFT"); p.sub:SetTextColor(.8, .8, .8)
    local close = CreateFrame("Button", nil, p, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)
    p.scrollOffset = 0
    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(_, d) p.scrollOffset = (p.scrollOffset or 0) - d; mod:RefreshQuestLog() end)
    p.rows = {}
    p:Hide()
    self.qlog = p
    return p
end

function mod:RefreshQuestLog()
    local p = self:EnsureQuestLog()
    local zones, order = self:QuestsByZone()
    local tracked = safe(C_SuperTrack.GetSuperTrackedQuestID)
    local function trunc(s) return (#s > 44) and (s:sub(1, 42) .. "..") or s end
    local entries, total = {}, 0
    for _, zone in ipairs(order) do
        entries[#entries + 1] = { header = true, text = ("%s (%d)"):format(zone, #zones[zone]) }
        for _, q in ipairs(zones[zone]) do entries[#entries + 1] = { q = q }; total = total + 1 end
    end
    local VISIBLE = 16
    local maxOff = math.max(0, #entries - VISIBLE)
    p.scrollOffset = math.max(0, math.min(p.scrollOffset or 0, maxOff))
    local off = p.scrollOffset
    p.sub:SetText(("%d active quests%s  \226\128\148  |cff55ff55green|r = ready to turn in"):format(
        total, maxOff > 0 and "  (scroll)" or ""))
    for i = 1, VISIBLE do
        local row = p.rows[i]
        if not row then
            row = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
            row:SetSize(316, 20); row:SetPoint("TOPLEFT", 12, -44 - (i - 1) * 20)
            p.rows[i] = row
        end
        local e = entries[i + off]
        if e then
            if e.header then
                row:SetEnabled(false); row:SetScript("OnClick", nil)
                row:SetText("|cff00c7ff" .. e.text .. "|r")
            else
                row:SetEnabled(true)
                local q = e.q
                local mark = (q.qid == tracked) and "|cff55ff55> |r" or ""
                local body = (q.complete and "|cff55ff55" or "|cffffffff") .. trunc(q.title) .. "|r"
                row:SetText(mark .. body .. (q.complete and " |cff55ff55(ready)|r" or ""))
                local qid = q.qid
                row:SetScript("OnClick", function()
                    mod:ToggleTrack(qid)
                    mod:RefreshQuestLog()
                end)
            end
            row:Show()
        else
            row:Hide()
        end
    end
end

function mod:ToggleQuestLog()
    local p = self:EnsureQuestLog()
    if p:IsShown() then p:Hide() else self:RefreshQuestLog(); p:Show() end
end

-- Debounced live refresh (QUEST_LOG_UPDATE fires a lot).
do
    local ev = CreateFrame("Frame")
    local pending
    local function queue()
        if pending then return end
        pending = true
        C_Timer.After(0.4, function()
            pending = false
            if VQ.Guide then
                VQ.Guide:Refresh()   -- waits by itself while a click is held on the panel
                local q = VQ.Guide.qlog
                if q and q:IsShown() then
                    -- same for the My Quests window: never redraw under a held click
                    if MouseHeldOver(q) then queue() else VQ.Guide:RefreshQuestLog() end
                end
            end
        end)
    end
    for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "QUEST_ACCEPTED", "QUEST_TURNED_IN",
                         "QUEST_LOG_UPDATE", "QUEST_POI_UPDATE", "QUEST_WATCH_UPDATE",
                         "QUESTLINE_UPDATE",        -- async next-chapter discovery lands here
                         "QUEST_DATA_LOAD_RESULT",  -- title of a not-yet-in-log pickup resolves here
                         "QUEST_REMOVED",           -- abandon: drop the pin, then re-evaluate
                         "SUPER_TRACKING_CHANGED",  -- follow the quest you super-track
                         "USER_WAYPOINT_UPDATED",   -- your own map pin -> manual hold
                         "PLAYER_REGEN_ENABLED",    -- re-apply Blizz-tracker hide after combat
                         "QUEST_AUTOCOMPLETE",      -- auto-quest offer/turn-in popups appear
                         "GROUP_ROSTER_UPDATE",     -- group counts on quest lines (GroupOnQuest)
                         "UNIT_QUEST_LOG_CHANGED",  -- a party member took or finished a quest
                         "TASK_PROGRESS_UPDATE",    -- in-area bonus objectives / world quests
                         "SCENARIO_UPDATE",         -- zone events (Temple Strikes etc.) start/stage
                         "SCENARIO_CRITERIA_UPDATE", -- zone-event objective progress
                         "UPDATE_UI_WIDGET",        -- delve header: lives left (scenarios only, below)
                         "TRACKED_RECIPE_UPDATE",   -- profession recipe tracked/untracked
                         "BAG_UPDATE_DELAYED",      -- reagent counts for recipe checklists
                         "CURRENCY_DISPLAY_UPDATE", -- coffer keys / shards line
                         "ZONE_CHANGED" }) do       -- new subzone: re-pick the side quest on the way
        ev:RegisterEvent(e)
    end
    ev:SetScript("OnEvent", function(_, event, arg1)
        -- widgets update all the time everywhere; only a scenario's header (delve lives) matters
        if event == "UPDATE_UI_WIDGET" and not (C_Scenario and C_Scenario.IsInScenario and C_Scenario.IsInScenario()) then
            return
        end
        if event == "QUEST_REMOVED" and VQ.Guide then
            -- Abandoned/removed a quest: if it was the one we're pinning, clear immediately
            -- (don't wait for the debounce) so the stale pin doesn't hang around.
            local wp = VQ.Guide._wp
            if wp and arg1 == wp.qid then VQ.Guide:ClearOurWaypoint() end
            VQ.Guide._lastStep = nil   -- force the next Refresh to re-pin the new step
        end
        if VQ.Guide and (event == "QUEST_ACCEPTED" or event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED") then
            VQ.Guide._questEventAt = GetTime()   -- the game may re-target the arrow now
        end
        if VQ.Guide and event == "QUEST_ACCEPTED" and type(arg1) == "number" then
            VoidQuestCharDB = VoidQuestCharDB or {}
            local acc = VoidQuestCharDB.acceptedAt or {}
            local now = time()
            for q, t in pairs(acc) do if now - t > 900 then acc[q] = nil end end
            acc[arg1] = now   -- shows first on the quest lines for a while (survives /reload)
            VoidQuestCharDB.acceptedAt = acc
        end
        -- starting a world quest an unpicked activity quest would have counted
        if VQ.Guide and event == "QUEST_ACCEPTED" and arg1 and C_QuestLog.IsWorldQuest
           and safe(C_QuestLog.IsWorldQuest, arg1) then
            local c = VQ.Guide:ContinentOf(safe(C_Map.GetBestMapForUnit, "player"))
            VQ.Guide:WarnMeta("world quest", c and c.mapID)
        end
        if VQ.Guide and event == "PLAYER_ENTERING_WORLD" then
            VQ.Guide:EnsureMapButton()
            VQ.Guide:TrackBaseline()   -- tell a restored pin of yours from ours, before any refresh
            VQ.Guide:InstanceTrack()   -- in an instance: drop our arrow to an outside quest
        end
        if VQ.Guide and (event == "SUPER_TRACKING_CHANGED" or event == "USER_WAYPOINT_UPDATED") then
            VQ.Guide:OnTrackChanged()   -- now, before any queued refresh can re-pin
        end
        -- whoever tracked it (auto-track on accept, Blizzard's quest log, a map click): a
        -- quest inside an instance you're not in gets its entrance instead of a bogus arrow
        if VQ.Guide and event == "SUPER_TRACKING_CHANGED" then
            C_Timer.After(0, function() VQ.Guide:FixInstanceArrow() end)
        end
        if VQ.Guide and (event == "SUPER_TRACKING_CHANGED" or event == "PLAYER_ENTERING_WORLD") then
            C_Timer.After(3, function() VQ.Guide:TrackProbe() end)
        end
        -- quest data arrived / quests changed: XP totals were built without it. (Not on
        -- QUESTLINE_UPDATE: the index itself requests quest lines, so that would loop.)
        if VQ.Guide and (event == "QUEST_DATA_LOAD_RESULT" or event == "QUEST_TURNED_IN"
           or event == "QUEST_ACCEPTED") then
            VQ.Guide:InvalidateXP()
        end
        queue()
    end)
end

-- Proximity auto-clear: once you actually ARRIVE at our pickup pin, drop it (throttled,
-- and only for a pin WE placed). Objective/turn-in pins are game-super-tracked and clear
-- themselves; this handles the "I'm standing on the giver, kill the pin" case.
do
    local t, tick = 0, CreateFrame("Frame")
    tick:SetScript("OnUpdate", function(_, e)
        t = t + e
        if t < 0.5 then return end
        t = 0
        local g = VQ.Guide
        local wp = g and g._wp
        if not wp then return end
        local map = safe(C_Map.GetBestMapForUnit, "player")
        if map ~= wp.m then return end
        local pos = safe(C_Map.GetPlayerMapPosition, map, "player")
        local px, py
        if pos then if pos.GetXY then px, py = pos:GetXY() elseif pos.x then px, py = pos.x, pos.y end end
        if not px then return end
        local dx, dy = px - wp.x, py - wp.y
        -- arrived (at a portal mid-route the next leg survives: it's pinned after the zone change)
        if (dx * dx + dy * dy) < (0.006 * 0.006) then g:ClearOurWaypoint(g._afterHop ~= nil) end
    end)
end

----------------------------------------------------------------------
-- AUTO-RUN engine: hands-free turn-in + accept, SCOPED to the campaign
-- chain (never touches random side quests). Follows the campaign's exact
-- gossip/quest chain.
----------------------------------------------------------------------
function mod:AutoEnabled() return VQ:Get("auto") and true or false end

-- set of quest IDs in the current chapter chain + the campaign ID.
function mod:ChainSet()
    local g = self:Compute()
    local set = {}
    if g and g.chain then for _, q in ipairs(g.chain) do if q then set[q] = true end end end
    if VQ.Zones and VQ.Zones:Active() then   -- the followed zone guide's chapter chain too
        for q in pairs(VQ.Zones:ChainSet()) do set[q] = true end
    end
    local campID = (g and g.campID) or self:LockedCampID()
        or (VoidQuestCharDB and VoidQuestCharDB.chainCache and VoidQuestCharDB.chainCache.campID)
    return set, campID
end

-- Does the campaign "own" this quest? In the current chapter's chain OR anywhere in
-- the same campaign (this is what makes it flow ACROSS chapters -- the next chapter's
-- quest isn't in the cached chain yet, but it IS in the campaign). Random side quests
-- (campaignID 0 or a different campaign) are never owned -> never auto-handled.
-- Is this quest part of ANY campaign questline? Works for UN-accepted quests (where
-- GetCampaignID returns 0) -- this is how we catch the NEXT chapter's quest the moment
-- it's offered, since gossip has no isCampaign flag and chapters expose no questLine.
function mod:IsCampaignQuest(qid)
    if not qid then return false end
    local ql = safe(C_QuestLine.GetQuestLineInfo, qid, safe(C_Map.GetBestMapForUnit, "player"))
    return (ql and ql.isCampaign == true) or false
end

function mod:Owns(qid, set, campID)
    if not qid then return false end
    if VQ:Get("autoAllQuests") then return true end                                          -- opted in: every quest
    if set and set[qid] then return true end                                                 -- current chapter chain
    if campID and campID ~= 0 and safe(C_CampaignInfo.GetCampaignID, qid) == campID then return true end -- accepted, same campaign
    if self:Strict() then
        -- Locked / multi-campaign: ONLY this campaign's known questlines -- never auto-accept
        -- an un-verifiable campaign quest (could belong to a DIFFERENT campaign). A new
        -- chapter is adopted once its line is learned (user accepts one quest -> verified).
        local ql = safe(C_QuestLine.GetQuestLineInfo, qid, safe(C_Map.GetBestMapForUnit, "player"))
        if ql and self:KnownQL(campID, ql.questLineID) then return true end
    else
        if self:IsCampaignQuest(qid) then return true end                                     -- single campaign: any campaign questline (auto next-chapter)
    end
    if self:IsPicked(qid) then return true end                                                -- line the user opted into via the picker
    return false
end

do
    local af = CreateFrame("Frame")
    for _, e in ipairs({ "GOSSIP_SHOW", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_DETAIL" }) do
        af:RegisterEvent(e)
    end
    local function announce(fmt, ...)
        if VQ:Get("announceActions") then VQ:Print(fmt:format(...)) end
    end
    -- Remember WHO gives / takes each quest (the API never exposes it until you talk to them).
    -- Account-wide: quest givers are static game data, so Vede's run teaches Murrath's panel.
    local function remember(qid, role)
        -- a PLAYER as "npc" (a party member sharing a quest, or yourself) is no quest giver,
        -- and player names must never end up in the shipped seed (tools/cmd/vq-seed)
        if safe(UnitIsPlayer, "npc") or safe(UnitIsPlayer, "questnpc") then return end
        local npc = safe(UnitName, "npc") or safe(UnitName, "questnpc")
        -- Inside instances the NPC's name can be a SECRET value: comparing it errors,
        -- and storing it in VoidQuestDB would make the save file unwritable. Skip it.
        if issecretvalue and issecretvalue(npc) then return end
        if not (qid and qid > 0 and npc and npc ~= "") then return end
        VoidQuestDB = VoidQuestDB or {}
        VoidQuestDB.npcs = VoidQuestDB.npcs or {}
        local e = VoidQuestDB.npcs[qid] or {}
        e[role] = npc
        VoidQuestDB.npcs[qid] = e
    end
    af:SetScript("OnEvent", function(_, event)
        if event == "GOSSIP_SHOW" then
            for _, q in ipairs(safe(C_GossipInfo.GetAvailableQuests) or {}) do remember(q.questID, "giver") end
            for _, q in ipairs(safe(C_GossipInfo.GetActiveQuests) or {}) do
                if q.isComplete then remember(q.questID, "turnin") end
            end
        elseif event == "QUEST_DETAIL" then
            remember(safe(GetQuestID), "giver")
        elseif event == "QUEST_COMPLETE" or event == "QUEST_PROGRESS" then
            remember(safe(GetQuestID), "turnin")
        end
        if not mod:AutoEnabled() then return end
        local set, campID = mod:ChainSet()
        if event == "GOSSIP_SHOW" then
            -- 1) turn in a COMPLETED campaign quest at this NPC
            if VQ:Get("autoTurnIn") then
                for _, q in ipairs(safe(C_GossipInfo.GetActiveQuests) or {}) do
                    if q.isComplete and mod:Owns(q.questID, set, campID) then
                        announce("Turning in |cff55ff55%s|r", q.title or ("quest " .. q.questID))
                        C_GossipInfo.SelectActiveQuest(q.questID); return
                    end
                end
            end
            -- 2) else pick up an AVAILABLE campaign quest (incl. the next chapter's)
            if VQ:Get("autoAccept") then
                for _, q in ipairs(safe(C_GossipInfo.GetAvailableQuests) or {}) do
                    if mod:Owns(q.questID, set, campID) then
                        announce("Picking up |cff55ff55%s|r", q.title or ("quest " .. q.questID))
                        C_GossipInfo.SelectAvailableQuest(q.questID); return
                    end
                end
            end
        elseif event == "QUEST_PROGRESS" then
            local qid = safe(GetQuestID)
            if VQ:Get("autoTurnIn") and mod:Owns(qid, set, campID) and safe(IsQuestCompletable) then CompleteQuest() end
        elseif event == "QUEST_COMPLETE" then
            local qid = safe(GetQuestID)
            if VQ:Get("autoTurnIn") and mod:Owns(qid, set, campID) then
                local choices = safe(GetNumQuestChoices) or 0
                if choices >= 2 and VQ:Get("pauseOnChoice") then
                    VQ:Print("|cffffd200Pick your reward|r for |cff55ff55" .. (safe(GetTitleText) or "this quest") .. "|r -- auto-turn-in paused (choice quest).")
                elseif choices < 2 and not VQ:Get("autoReward") then
                    VQ:Print("|cffffd200Reward ready|r for |cff55ff55" .. (safe(GetTitleText) or "this quest") .. "|r -- auto-claim is off.")
                else
                    announce("Completing |cff55ff55%s|r", safe(GetTitleText) or "quest")
                    GetQuestReward(1)   -- single reward, or a choice quest with pause disabled
                end
            end
        elseif event == "QUEST_DETAIL" then
            local qid = safe(GetQuestID)
            if VQ:Get("autoAccept") and mod:Owns(qid, set, campID) then
                announce("Accepting |cff55ff55%s|r", safe(GetTitleText) or "quest")
                AcceptQuest()
            end
        end
    end)
end
