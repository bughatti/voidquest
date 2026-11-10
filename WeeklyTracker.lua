----------------------------------------------------------------------
-- VoidQuest Weekly Tracker -- Restored Coffer Keys (Midnight Season 2).
--
-- Panel line at max level: keys you hold + how many more you can still get this week.
-- Click it for the window: the weekly key sources (done / in progress / left, quickest
-- first) and, read LIVE from the game, every other quest giving shards or keys right now.
--
-- Live from the game: keys held (currency 3028), shards earned this week vs the 600 cap
-- (3310 -- 100 shards = 1 key, so 6 keys), Undercoins (2803), Delver's Journey rank
-- (3464), each weekly quest's completed flag, and the reward of every quest in your log,
-- offered on your continent's maps, or up as a world quest. The live scan exists because
-- a fixed list misses things: "Seasonal Refresher: Midnight" (Silvermoon, gives shards)
-- wasn't in it (2026-10-27).
--
-- Naleidea Rivergleam's 2 keys (Delver's HQ, Silvermoon; 2,000 Undercoins each, journey
-- rank 6) don't count against the cap and have no tracking quest: we read her stock when
-- you open her window and remember it for the week.
--
-- Fixed list researched 2026-10-27 (public quest pages); the minutes
-- are estimates. A quest's live title replaces ours once the game loads it.
----------------------------------------------------------------------
local VQ = VoidQuest
local mod = VQ:NewModule("WeeklyTracker")
VQ.Coffer = mod

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end end

-- WoW Forever has no coffer keys or delves, and its cap is 60, so a level-60 character got
-- "Coffer keys: 0" lines and quest-line scans on every zone change. ForeverQuests.lua loads
-- first and only sets this table on Forever (Forever audit, 2026-11-10).
local FOREVER = VQ.ForeverQuests ~= nil

local CUR_KEYS, CUR_SHARDS, CUR_UNDERCOIN, CUR_JOURNEY = 3028, 3310, 2803, 3464
local SHARDS_PER_KEY, VENDOR_KEYS, VENDOR_PRICE, VENDOR_RANK = 100, 2, 2000, 6
local VENDOR_NPC = 242398
local VENDOR_ITEMS = { [263188] = true, [263191] = true }
local MAX_LIVE_ROWS = 8

-- Weekly sources whose caches hold shards (all count against the 600 cap). Their caches
-- aren't quest rewards the game lists as shards, so the live scan can't see them.
local SOURCES = {
    { name = "Stand Your Ground", mins = 15, qids = { 94581 },
      where = "Voidstorm: Stormarion Assault (starts every 30 min)" },
    -- 89268 "Lost Legends" only picks the relic; the relic's story quest (one of
    -- 88993-88999) is the part that pays, so that's what counts as done
    { name = "Legends of the Haranir", mins = 15, qids = { 89268, 88993, 88994, 88995, 88996, 88997, 88998, 88999 },
      doneQ = { 88993, 88994, 88995, 88996, 88997, 88998, 88999 }, keepName = true,
      where = "Harandar: the Den (once a week per account)" },
    { name = "Abundant Offerings", mins = 20, qids = { 89507 },
      where = "Zul'Aman: Chel the Chip, Amani'Zar Village" },
    { name = "Fortify the Runestones", mins = 20, qids = { 90573, 90574, 90575, 90576 },
      where = "Eversong Woods: Saltheril's Soiree (pick your faction first)" },
    { name = "Unity Against the Void", mins = 30, qids = { 93744 },
      where = "Silvermoon City: Lady Liadrin" },
    { name = "Purging the Vaults", mins = 120, qids = { 95520 },
      where = "Coiled Isle: Vaults of Atal'Utek (125 shards + a cache)" },
}
local LISTED = {}
for _, s in ipairs(SOURCES) do for _, q in ipairs(s.qids) do LISTED[q] = true end end

local FILLER = "Also shards: rares (25), Prey hunts (50), Special Assignments."

local function Cur(id) return safe(C_CurrencyInfo.GetCurrencyInfo, id) end

local function WeekID()
    local s = safe(C_DateAndTime.GetSecondsUntilWeeklyReset)
    return s and math.floor((time() + s) / 3600) or 0   -- the hour of the next reset
end

local function MaxLevel()
    local cap = safe(GetMaxLevelForPlayerExpansion)
    return cap and (UnitLevel("player") or 0) >= cap
end

local function Num(n) return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n) end

-- Source state: "done", "log" (in your quest log), or "left".
local function SourceState(s)
    for _, q in ipairs(s.doneQ or s.qids) do
        if safe(C_QuestLog.IsQuestFlaggedCompleted, q) then return "done", q end
    end
    for _, q in ipairs(s.qids) do
        local idx = safe(C_QuestLog.GetLogIndexForQuestID, q)
        if idx and idx > 0 then return "log", q end
    end
    return "left", s.qids[1]
end

local asked = {}   -- qid -> true: quest data / reward data requested once per session

local function SourceTitle(s)
    if s.keepName then return s.name end
    local q = s.qids[1]
    local t = safe(C_QuestLog.GetTitleForQuestID, q)
    if not t or t == "" then
        if not asked[q] then asked[q] = true; safe(C_QuestLog.RequestLoadQuestByID, q) end
        return s.name
    end
    return t
end

-- Naleidea's keys left this week: number, or nil when we haven't seen her stock this week.
local function VendorLeft()
    local v = VoidQuestCharDB and VoidQuestCharDB.cofferVendor
    if v and v.week == WeekID() then return v.left end
end

----------------------------------------------------------------------
-- Live scan: quests (log / offered / world quests) whose reward has shards or keys.
----------------------------------------------------------------------
local askedMaps = {}   -- quest lines requested once per map per session (the reply event rescans)

-- A quest's shard / key reward, remembered for the session once the game has sent it
-- (rewards don't change), so a rescan is instant instead of waiting on the server again.
-- false = has rewards, but no shards or keys.
local rewardCache = {}

local function KeyReward(qid)
    local c = rewardCache[qid]
    if c ~= nil then
        if c then return c.amount, c.kind end
        return nil
    end
    local list = safe(C_QuestLog.GetQuestRewardCurrencies, qid)
    if not list or #list == 0 then
        if not asked[qid] then
            asked[qid] = true
            safe(C_QuestLog.RequestLoadQuestByID, qid)
            if C_TaskQuest then safe(C_TaskQuest.RequestPreloadRewardData, qid) end
        end
        return nil
    end
    for _, cur in ipairs(list) do
        local kind = (cur.currencyID == CUR_SHARDS and "shards") or (cur.currencyID == CUR_KEYS and "keys")
        if kind then
            local amount = cur.totalRewardAmount or cur.baseRewardAmount or 0
            rewardCache[qid] = { amount = amount, kind = kind }
            return amount, kind
        end
    end
    rewardCache[qid] = false
end

-- Maps to scan: your zone up to the continent, and every zone on that continent.
local function ScanMaps()
    local maps, seen = {}, {}
    local function add(m) if m and m > 0 and not seen[m] then seen[m] = true; maps[#maps + 1] = m end end
    local contType = (Enum.UIMapType and Enum.UIMapType.Continent) or 2
    local zoneType = (Enum.UIMapType and Enum.UIMapType.Zone) or 3
    local m = safe(C_Map.GetBestMapForUnit, "player")
    local cont
    for _ = 1, 8 do
        local mi = m and m > 0 and safe(C_Map.GetMapInfo, m)
        if not mi then break end
        add(m)
        if mi.mapType == contType then cont = m; break end
        m = mi.parentMapID
    end
    if cont then
        for _, c in ipairs(safe(C_Map.GetMapChildrenInfo, cont, zoneType, true) or {}) do add(c.mapID) end
    end
    return maps
end

function mod:Scan()
    local found, seen = {}, {}
    local function consider(qid, how, m, x, y)
        if not qid or seen[qid] or LISTED[qid] then return end
        seen[qid] = true
        if safe(C_QuestLog.IsQuestFlaggedCompleted, qid) then return end
        local amount, kind = KeyReward(qid)
        if not amount or amount <= 0 then return end
        local mi = m and safe(C_Map.GetMapInfo, m)
        found[#found + 1] = { qid = qid, how = how, amount = amount, kind = kind,
            m = m, x = x, y = y, zone = mi and mi.name }
    end
    -- your log first (a quest you hold is "in your log", wherever it was offered)
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        if info and not info.isHeader and not info.isHidden and info.questID then
            consider(info.questID, "log", safe(GetQuestUiMapID, info.questID))
        end
    end
    for _, m in ipairs(ScanMaps()) do
        if not askedMaps[m] then askedMaps[m] = true; safe(C_QuestLine.RequestQuestLinesForMap, m) end
        for _, q in ipairs(safe(C_QuestLine.GetAvailableQuestLines, m) or {}) do
            -- the list also holds neighbor zones' offers (their x/y aren't on this map):
            -- keep only this map's, like Blizzard's map does (VQ.Guide:OfferOnMap)
            local onMap = not (VQ.Guide and VQ.Guide.OfferOnMap) or VQ.Guide:OfferOnMap(q, m)
            if onMap and q.questID and not safe(C_QuestLog.GetLogIndexForQuestID, q.questID) then
                consider(q.questID, "offer", m, q.x, q.y)
            end
        end
        for _, qid in ipairs(safe(C_QuestLine.GetForceVisibleQuests, m) or {}) do
            if not safe(C_QuestLog.GetLogIndexForQuestID, qid) then
                local li = safe(C_QuestLine.GetQuestLineInfo, qid, m)
                consider(qid, "offer", m, li and li.x, li and li.y)
            end
        end
        if C_TaskQuest and C_TaskQuest.GetQuestsOnMap then
            -- world quests, bonus objectives and task-based offers alike
            for _, t in ipairs(safe(C_TaskQuest.GetQuestsOnMap, m) or {}) do
                if t.questID and not safe(C_QuestLog.GetLogIndexForQuestID, t.questID) then
                    local wq = safe(C_QuestLog.IsWorldQuest, t.questID)
                    consider(t.questID, wq and "wq" or "offer", t.mapID or m, t.x, t.y)
                end
            end
        end
    end
    -- in your log first, then the biggest rewards (keys count as 100 shards)
    table.sort(found, function(a, b)
        if (a.how == "log") ~= (b.how == "log") then return a.how == "log" end
        local va = a.kind == "keys" and a.amount * SHARDS_PER_KEY or a.amount
        local vb = b.kind == "keys" and b.amount * SHARDS_PER_KEY or b.amount
        return va > vb
    end)
    self.live, self.liveAt = found, GetTime()
    return found
end

-- The live list. Rescans when something changed (quests, zone, data arriving) or it's a
-- minute old; the scan itself is quick once rewards are cached.
function mod:Live()
    if not self.live or self.dirty or GetTime() - (self.liveAt or 0) > 60 then
        self.dirty = nil
        self:Scan()
    end
    return self.live
end

-- Warm up in the background (login, new zone): the reward requests go out now, so the
-- window opens full instead of filling in.
function mod:Prewarm()
    if FOREVER then return end   -- no coffer keys on Forever (Forever audit, 2026-11-10)
    if not MaxLevel() or (IsInInstance and IsInInstance()) then return end
    self.dirty = true
    self:Live()
end

local function LiveTitle(e)
    return safe(C_QuestLog.GetTitleForQuestID, e.qid) or ("quest " .. e.qid)
end

local function LiveReward(e)
    return e.kind == "keys" and ("%d key%s"):format(e.amount, e.amount == 1 and "" or "s")
        or ("%d shards"):format(e.amount)
end

----------------------------------------------------------------------
-- State / panel line / tooltip
----------------------------------------------------------------------
function mod:State()
    local keys, shards, coin, journey = Cur(CUR_KEYS), Cur(CUR_SHARDS), Cur(CUR_UNDERCOIN), Cur(CUR_JOURNEY)
    local st = {
        keys = keys and keys.quantity or 0,
        earned = shards and shards.quantityEarnedThisWeek or 0,
        cap = (shards and shards.maxWeeklyQuantity and shards.maxWeeklyQuantity > 0) and shards.maxWeeklyQuantity or 600,
        loose = shards and shards.quantity or 0,
        coin = coin and coin.quantity or 0,
        rank = journey and journey.quantity or 0,
        vendor = VendorLeft(),
    }
    -- Shards only turn into keys when you enter a delve or talk to Naleidea, so 258 shards
    -- = 2 keys waiting (2026-10-27: "i have 2 keys and 258 shards, it should say 4").
    st.pending = math.floor(st.loose / SHARDS_PER_KEY)
    st.total = st.keys + st.pending
    -- still to earn: the rest of the cap, plus whatever completes the loose remainder
    st.shardKeys = math.max(0, math.floor((st.cap - st.earned + st.loose % SHARDS_PER_KEY) / SHARDS_PER_KEY))
    st.vendorOpen = st.rank >= VENDOR_RANK
    st.vendorKeys = st.vendorOpen and (st.vendor or VENDOR_KEYS) or 0
    st.left = st.shardKeys + st.vendorKeys
    return st
end

-- Panel line text, or nil when there's nothing left to get this week (or below max level).
function mod:PanelLine()
    if FOREVER then return nil end   -- no coffer keys on Forever (Forever audit, 2026-11-10)
    if not MaxLevel() then return nil end
    local st = self:State()
    if st.left <= 0 then return nil end
    local have = st.pending > 0 and ("|cffffffff%d|r (%d in shards)"):format(st.total, st.pending)
        or ("|cffffffff%d|r"):format(st.total)
    return ("|cffffd200Coffer keys:|r %s, |cff55ff55+%d|r left this week |cff88ccff[keys]|r"):format(have, st.left)
end

function mod:Tooltip(owner)
    local st = self:State()
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:SetText("Restored Coffer Keys")
    GameTooltip:AddLine(("%d keys: %d held + %d waiting in %d shards. Shards this week: %d / %d (%d more key%s)."):format(
        st.total, st.keys, st.pending, st.loose, st.earned, st.cap, st.shardKeys, st.shardKeys == 1 and "" or "s"), .9, .9, .9, true)
    if st.pending > 0 then
        GameTooltip:AddLine("Shards become keys when you enter a delve or talk to Naleidea.", .6, .6, .6, true)
    end
    local best = self:Quickest(st)
    if best then GameTooltip:AddLine("Quickest: " .. best, .33, 1, .33, true) end
    GameTooltip:AddLine("Click: what you've done this week and what's left.", .6, .6, .6)
    GameTooltip:Show()
end

-- Fixed sources sorted: in your log first, then left (quickest first), then done.
function mod:Sorted()
    local list = {}
    for _, s in ipairs(SOURCES) do
        local state, qid = SourceState(s)
        list[#list + 1] = { s = s, state = state, qid = qid }
    end
    local rank = { log = 0, left = 1, done = 2 }
    table.sort(list, function(a, b)
        if rank[a.state] ~= rank[b.state] then return rank[a.state] < rank[b.state] end
        return a.s.mins < b.s.mins
    end)
    return list
end

function mod:Quickest(st)
    if st.shardKeys <= 0 then
        if st.vendorKeys > 0 then return "shards are capped -- buy your keys from Naleidea." end
        return nil
    end
    local parts = {}
    if st.vendorKeys > 0 and st.coin >= VENDOR_PRICE then parts[#parts + 1] = "Naleidea (1 min)" end
    -- a live quest you already hold, or the biggest one on offer
    local live = self:Live()[1]
    if live then parts[#parts + 1] = ("%s (%s)"):format(LiveTitle(live), LiveReward(live)) end
    for _, e in ipairs(self:Sorted()) do
        if e.state ~= "done" and #parts < 3 then
            parts[#parts + 1] = ("%s (~%d min)"):format(SourceTitle(e.s), e.s.mins)
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local W = 380

function mod:Ensure()
    if self.win then return self.win end
    local p = CreateFrame("Frame", "VoidQuestCofferKeys", UIParent, "BackdropTemplate")
    p:SetSize(W, 300); p:SetPoint("CENTER", UIParent, "CENTER", -200, 40); p:SetClampedToScreen(true)
    p:SetFrameStrata("FULLSCREEN_DIALOG"); p:SetToplevel(true)
    p:SetMovable(true); p:EnableMouse(true); p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving); p:SetScript("OnDragStop", p.StopMovingOrSizing)
    VQ:CreateBackdrop(p, 0.96)
    p.title = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.title, 13, "OUTLINE")
    p.title:SetPoint("TOP", 0, -8); p.title:SetText("Coffer Keys \226\128\148 this week")
    local close = CreateFrame("Button", nil, p, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)
    p.sum = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.sum, 11)
    p.sum:SetPoint("TOPLEFT", 12, -30); p.sum:SetWidth(W - 24); p.sum:SetJustifyH("LEFT"); p.sum:SetSpacing(2)
    p.rows, p.heads = {}, {}
    p.foot = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(p.foot, 10)
    p.foot:SetWidth(W - 24); p.foot:SetJustifyH("LEFT"); p.foot:SetTextColor(.6, .6, .6)
    p:Hide()
    self.win = p
    return p
end

local function Row(p, i)
    local r = p.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, p)
    r:SetSize(W - 24, 28)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT"); r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 1, 1, .06)
    r.top = r:CreateFontString(nil, "OVERLAY"); VQ:SetFont(r.top, 11)
    r.top:SetPoint("TOPLEFT", 0, -1); r.top:SetWidth(W - 24); r.top:SetJustifyH("LEFT"); r.top:SetWordWrap(false)
    r.sub = r:CreateFontString(nil, "OVERLAY"); VQ:SetFont(r.sub, 10)
    r.sub:SetPoint("TOPLEFT", 10, -14); r.sub:SetWidth(W - 34); r.sub:SetJustifyH("LEFT"); r.sub:SetWordWrap(false)
    r.sub:SetTextColor(.7, .7, .7)
    r:SetScript("OnEnter", function(s)
        if not s.hint then return end
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:SetText(s.hint, 1, .82, 0, 1, true); GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p.rows[i] = r
    return r
end

local function Head(p, i)
    local h = p.heads[i]
    if h then return h end
    h = p:CreateFontString(nil, "OVERLAY"); VQ:SetFont(h, 11, "OUTLINE"); h:SetTextColor(0, .78, 1)
    p.heads[i] = h
    return h
end

-- Arrow to a live quest: in your log / a world quest -> track the quest; an offer -> a
-- pin on its giver. Counts as the player's own pick (VoidQuest leaves it alone).
local function TrackLive(e)
    if e.how ~= "offer" then
        if VQ.Guide then VQ.Guide:ToggleTrack(e.qid); VQ.Guide:Refresh() end
        return
    end
    if not (e.m and e.x and e.y and e.x > 0) then
        VQ:Print(("%s: the game gives no spot for its giver yet."):format(LiveTitle(e)))
        return
    end
    if VQ.Guide then VQ.Guide:PinForPlayer(e.m, e.x, e.y, LiveTitle(e) .. "'s giver") end
end

function mod:Refresh()
    local p = self.win
    if not (p and p:IsShown()) then return end
    local st = self:State()
    local lines = {}
    if st.pending > 0 then
        lines[#lines + 1] = ("Keys: |cffffffff%d|r -- %d held + %d waiting in your %d shards (they become keys when you enter a delve or talk to Naleidea)"):format(
            st.total, st.keys, st.pending, st.loose)
    else
        lines[#lines + 1] = ("Keys: |cffffffff%d|r%s"):format(st.keys,
            st.loose > 0 and (" (+%d loose shards)"):format(st.loose) or "")
    end
    lines[#lines + 1] = ("Shards this week: |cffffffff%d / %d|r -- %s"):format(st.earned, st.cap,
        st.shardKeys > 0 and ("|cff55ff55%d more key%s|r from shards"):format(st.shardKeys, st.shardKeys == 1 and "" or "s")
        or "|cff888888capped|r")
    local vend
    if not st.vendorOpen then
        vend = ("|cff888888locked -- Delver's Journey rank %d needed (you're %d)|r"):format(VENDOR_RANK, st.rank)
    elseif st.vendor == nil then
        vend = ("|cffffd200up to %d|r -- open her window once this week and I'll know (%s Undercoins)"):format(
            VENDOR_KEYS, Num(st.coin))
    elseif st.vendor > 0 then
        vend = ("|cff55ff55%d left|r (%d Undercoins each, you have %s)"):format(st.vendor, VENDOR_PRICE, Num(st.coin))
    else
        vend = "|cff55ff55bought|r"
    end
    lines[#lines + 1] = "Naleidea (Delver's HQ, Silvermoon): " .. vend
    local best = self:Quickest(st)
    lines[#lines + 1] = best and ("|cff55ff55Quickest:|r " .. best) or "|cff55ff55Nothing left to get this week.|r"
    p.sum:SetText(table.concat(lines, "\n"))

    local capped = st.shardKeys <= 0
    local y = -30 - p.sum:GetStringHeight() - 10
    local ri, hi = 0, 0
    local function head(text)
        hi = hi + 1
        local h = Head(p, hi)
        h:SetText(text); h:ClearAllPoints(); h:SetPoint("TOPLEFT", 12, y); h:Show()
        y = y - 16
    end
    local function row(top, sub, onClick, hint)
        ri = ri + 1
        local r = Row(p, ri)
        r.top:SetText(top); r.sub:SetText(sub or "")
        r.hint = hint
        r:SetScript("OnClick", onClick)
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", 12, y); r:Show()
        y = y - 30
    end

    head("Weekly caches")
    for _, e in ipairs(self:Sorted()) do
        local tag
        if e.state == "done" then tag = "|cff55ff55done|r"
        elseif e.state == "log" then tag = "|cffffd200in your log|r -- click to track"
        elseif capped then tag = "|cff888888shards capped|r"
        else tag = ("|cffffffff~%d min|r"):format(e.s.mins) end
        local col = (e.state == "done" or (capped and e.state == "left")) and "|cff888888" or "|cffffffff"
        local qid = e.qid
        row(("%s%s|r  %s"):format(col, SourceTitle(e.s), tag), e.s.where, (e.state == "log") and function()
            if VQ.Guide then VQ.Guide:ToggleTrack(qid); VQ.Guide:Refresh() end
        end or nil)
    end

    local live = self:Live()
    head(("Giving shards or keys right now (%d)"):format(#live))
    if #live == 0 then
        row("|cff888888none found on this continent|r", "Quests in your log, offered here, and world quests are checked live.")
    end
    for i, e in ipairs(live) do
        if i > MAX_LIVE_ROWS then
            row(("|cff888888+%d more|r"):format(#live - MAX_LIVE_ROWS), nil, nil)
            break
        end
        local how = (e.how == "log" and "|cffffd200in your log|r") or (e.how == "wq" and "world quest") or "pick up"
        local col = capped and e.kind == "shards" and "|cff888888" or "|cffffffff"
        local hint = VQ.Guide and VQ.Guide.QuestHint and VQ.Guide:QuestHint(e.qid)
        row(("%s%s|r  |cff55ff55%s|r%s"):format(col, LiveTitle(e), LiveReward(e), hint and "  |cffffd200(tip)|r" or ""),
            ("%s%s -- click for the arrow"):format(how, e.zone and (", " .. e.zone) or ""),
            function() TrackLive(e) end, hint)
    end
    for i = ri + 1, #p.rows do p.rows[i]:Hide() end
    for i = hi + 1, #p.heads do p.heads[i]:Hide() end

    p.foot:ClearAllPoints(); p.foot:SetPoint("TOPLEFT", 12, y - 4)
    p.foot:SetText(FILLER .. " Naleidea's keys don't count toward the shard cap.")
    p:SetHeight(-(y - 4) + p.foot:GetStringHeight() + 12)
end

function mod:Toggle()
    local p = self:Ensure()
    if p:IsShown() then p:Hide() else p:Show(); self:Refresh() end   -- the list is kept, not rebuilt
end

----------------------------------------------------------------------
-- Naleidea's stock: read when her window opens (and after each purchase).
----------------------------------------------------------------------
local function ReadVendor()
    local guid = UnitGUID("npc")
    if not guid or (issecretvalue and issecretvalue(guid)) then return end
    local npcID = tonumber((select(6, strsplit("-", guid))))
    if npcID ~= VENDOR_NPC then return end
    local left, found = 0, false
    for i = 1, (safe(GetMerchantNumItems) or 0) do
        local id = safe(GetMerchantItemID, i)
        if id and VENDOR_ITEMS[id] then
            local info = safe(C_MerchantFrame.GetItemInfo, i)
            if not info then return end   -- stock not loaded yet: MERCHANT_UPDATE comes back
            found = true
            local n = info.numAvailable
            if n and n > 0 then left = left + n end
        end
    end
    -- not on her list: bought out, filtered (merchant filter), or not loaded -- can't tell,
    -- so keep what we knew rather than guess 0
    if not found then return end
    VoidQuestCharDB = VoidQuestCharDB or {}
    VoidQuestCharDB.cofferVendor = { week = WeekID(), left = left }
    mod:Refresh()
    if VQ.Guide then VQ.Guide:Refresh() end
end

----------------------------------------------------------------------
-- Delve companion probe (dev): role, combat / utility curios and the "flavor" slot
-- (Valeera's poisons), each with every option, its rarity (rank) and whether you own it.
-- Read the same way Blizzard's companion window does (C_DelvesUI + C_Traits; a nil
-- companion ID = your active companion). Saved to VoidQuestCharDB.companionProbe.
----------------------------------------------------------------------
function mod:CompanionProbe()
    if FOREVER then return end   -- no delves on Forever (Forever audit, 2026-11-10)
    if not (VoidQuestCharDB and C_DelvesUI and C_DelvesUI.GetTraitTreeForCompanion and C_Traits) then return end
    local tree = safe(C_DelvesUI.GetTraitTreeForCompanion)
    local config = tree and safe(C_Traits.GetConfigIDByTreeID, tree)
    if not config then return end
    local P = { at = date("%Y-%m-%d %H:%M:%S"), tree = tree, config = config, slots = {} }
    local fac = safe(C_DelvesUI.GetFactionForCompanion)
    local fr = fac and C_GossipInfo and safe(C_GossipInfo.GetFriendshipReputation, fac)
    P.companion = fr and ("%s %s"):format(tostring(fr.name), tostring(fr.reaction)) or tostring(fac)
    local rarityName = {}
    for k, v in pairs(Enum.CurioRarity or {}) do rarityName[v] = k end
    local slots = {
        { "Role", safe(C_DelvesUI.GetRoleNodeForCompanion) },
        { "Combat", Enum.CurioType and safe(C_DelvesUI.GetCurioNodeForCompanion, Enum.CurioType.Combat) },
        { "Utility", Enum.CurioType and safe(C_DelvesUI.GetCurioNodeForCompanion, Enum.CurioType.Utility) },
        { "Flavor (" .. tostring(safe(C_DelvesUI.GetFlavorNodeNameForCompanion)) .. ")", safe(C_DelvesUI.GetFlavorNodeForCompanion) },
    }
    for _, s in ipairs(slots) do
        local label, node = s[1], s[2]
        local ni = node and node ~= 0 and safe(C_Traits.GetNodeInfo, config, node)
        local out = { active = "none", options = {} }
        if ni then
            local active = ni.activeEntry and ni.activeEntry.entryID
            for _, eid in ipairs(ni.entryIDs or {}) do
                local ei = safe(C_Traits.GetEntryInfo, config, eid)
                local name, desc, rarity, owned = "?", "", "?", "?"
                if ei and ei.subTreeID then
                    local st = safe(C_Traits.GetSubTreeInfo, config, ei.subTreeID)
                    name = st and st.name or "?"; desc = st and st.description or ""
                elseif ei and ei.definitionID then
                    local di = safe(C_Traits.GetDefinitionInfo, ei.definitionID)
                    local sid = di and (di.overriddenSpellID or di.spellID)
                    local sp = sid and safe(C_Spell.GetSpellInfo, sid)
                    name = (sp and sp.name or "?") .. " [" .. tostring(sid) .. "]"
                    desc = sid and safe(C_Spell.GetSpellDescription, sid) or ""
                end
                for _, cid in ipairs((ei and ei.conditionIDs) or {}) do
                    local ci = safe(C_Traits.GetConditionInfo, config, cid, true)
                    if ci and ci.traitCondAccountElementID then
                        local r = safe(C_DelvesUI.GetCurioRarityByTraitCondAccountElementID, ci.traitCondAccountElementID)
                        rarity = rarityName[r] or tostring(r)
                    end
                    if ci and ci.isMet ~= nil then owned = tostring(ci.isMet) end
                end
                local line = ("%s | rarity %s | owned %s | %s"):format(name, rarity, owned, (desc or ""):gsub("\n", " "))
                out.options[#out.options + 1] = line
                if eid == active then out.active = name end
            end
        end
        P.slots[label] = out
    end
    VoidQuestCharDB.companionProbe = P
end

function mod:Init()
    if FOREVER then return end   -- no events, timers or probe on Forever (Forever audit, 2026-11-10)
    local f = CreateFrame("Frame")
    for _, e in ipairs({ "MERCHANT_SHOW", "MERCHANT_UPDATE", "CURRENCY_DISPLAY_UPDATE", "QUEST_TURNED_IN",
                         "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_DATA_LOAD_RESULT", "QUESTLINE_UPDATE",
                         "ZONE_CHANGED_NEW_AREA" }) do
        f:RegisterEvent(e)
    end
    C_Timer.After(8, function() mod:Prewarm() end)   -- after login / reload settles
    C_Timer.After(6, function() mod:CompanionProbe() end)
    local pending
    f:SetScript("OnEvent", function(_, event, qid, success)
        if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then ReadVendor(); return end
        -- only data we asked for, and only when it actually loaded (a failed load would
        -- otherwise rescan -> nothing new -> forever)
        if event == "QUEST_DATA_LOAD_RESULT" and not (success and asked[qid]) then return end
        -- something changed: rescan on the next look, but keep showing the current list
        if event ~= "CURRENCY_DISPLAY_UPDATE" then mod.dirty = true end
        if event == "ZONE_CHANGED_NEW_AREA" then C_Timer.After(3, function() mod:Prewarm() end) end
        if not (mod.win and mod.win:IsShown()) then return end         -- closed: nothing to redraw
        -- reward data arrives in bursts: one refresh per second at most
        if pending then return end
        pending = true
        C_Timer.After(1, function() pending = nil; mod:Refresh() end)
    end)
end
