----------------------------------------------------------------------
-- VoidQuest — QuestLFG: find a group for a hard quest (WoW Forever)
--
-- The user, 2026-11-19: "adding a lfg next to a quest, we just did a couple quests we had to look
-- in lfg and adding an easier way to find people to complete a hard quest would be nice". Decided
-- the same day: "elite quests only, show the message first".
--
-- An orange "LFG" badge at the right end of every ELITE quest line in your log (not dungeon / raid
-- quests: the LFG board has those). Click it: a small window for that quest with
--   * In chat: the chat lines of the last 30 minutes that name the quest or the elite it asks
--     you to kill ("LFG Broken Alliances", "anyone for Blacklash?"). Click a line = whisper them
--     (the chat box opens with a ready line, you press Enter); right-click = an empty whisper.
--   * Your post: the line for LFG chat, written for you and editable. Nothing is sent until you
--     click Post (once per 30 s). Channel button = which channel (LookingForGroup first).
--   * Ask VoidQuest players: GroupUp's search (same as Ctrl-click on the quest line).
--   * LFG board: VoidLFG's board, when it's installed.
-- And while the window is closed: one chat line when someone in chat names one of your elite
-- quests, their name clickable to whisper (Settings, on by default; once per player and quest
-- every 10 minutes).
--
-- Chat lines and names live in memory only (never saved), like VoidLFG's board.
----------------------------------------------------------------------
local _, ns = ...
local VQ = VoidQuest
if not VQ.ForeverQuests then return end   -- WoW Forever only

local L = {}
VQ.QuestLFG = L

local KEEP      = 1800   -- chat lines count this long
local MAX_LINES = 300    -- chat lines kept
local ROWS      = 6      -- chat lines shown
local POST_GAP  = 30     -- seconds between posts (people put spammers on ignore)
local ALERT_GAP = 600    -- the same player and quest, at most one chat line per this

local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

local function safe(fn, ...)
    if not fn then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
end
local function secret(v) return issecretvalue and issecretvalue(v) end
local function say(msg) VQ:Print(msg) end
local function db() VoidQuestDB = VoidQuestDB or {}; return VoidQuestDB end

local function title(qid)
    local t = safe(C_QuestLog.GetTitleForQuestID, qid)
    if type(t) == "string" and not secret(t) and t ~= "" then return t end
    local r = VQ.ForeverQuests[qid]
    return r and r[1] or ("quest " .. tostring(qid))
end
local function zoneName(qid)
    local r = VQ.ForeverQuests[qid]
    return r and r[2] and VQ.ForeverNames and VQ.ForeverNames[r[2]] or nil
end

----------------------------------------------------------------------
-- Which quests
----------------------------------------------------------------------
-- An elite quest out in the world (QuestWorth's kind: a dungeon-zone elite like Waking Naralex
-- counts as a dungeon quest, and those go through the LFG board).
function L:IsElite(qid)
    local r = qid and VQ.ForeverQuests[qid]
    if not r then return false end
    if VQ.Worth and VQ.Worth.QuestKind then
        local ok, kind = pcall(VQ.Worth.QuestKind, r)
        if ok then return kind == "elite" end
    end
    local f = r[6] or ""
    return f:find("E") ~= nil and not f:find("[DR]")
end

-- The LFG badge: an elite quest in your log, not finished, and room in your group.
function L:Offer(qid)
    if not self:IsElite(qid) then return false end
    if not safe(C_QuestLog.GetLogIndexForQuestID, qid) or safe(C_QuestLog.IsComplete, qid) then return false end
    if IsInRaid() then return false end
    if IsInGroup() and (GetNumGroupMembers() or 1) >= 5 then return false end
    return true
end

----------------------------------------------------------------------
-- What chat lines name a quest
----------------------------------------------------------------------
local function norm(s)
    return " " .. s:lower():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|h", " ")
        :gsub("[^%w]+", " "):gsub("^ +", ""):gsub(" +$", "") .. " "
end

-- the elites an objective names: "Blacklash slain: 0/1" / "0/1 Blacklash slain" (few to kill)
local function objectiveMobs(qid)
    local out = {}
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
        local t = o.text
        if o.type == "monster" and type(t) == "string" and not secret(t) and (tonumber(o.numRequired) or 99) <= 3 then
            t = t:gsub("%d+%s*/%s*%d+", ""):gsub(":", ""):gsub("[Ss]lain", ""):gsub("^%s+", ""):gsub("%s+$", "")
            if #t >= 5 then out[#out + 1] = t end
        end
    end
    return out
end

local keyCache = {}   -- [qid] = { " broken alliances ", " blacklash " }
local function keys(qid)
    local k = keyCache[qid]
    if k then return k end
    k = {}
    local seen = {}
    local function add(s)
        local n = norm(s)
        local bare = n:gsub("^ the ", " ")
        if #bare >= 7 and not seen[bare] then seen[bare] = true; k[#k + 1] = bare end   -- " xxxxx "
    end
    add(title(qid))
    for _, m in ipairs(objectiveMobs(qid)) do add(m) end
    keyCache[qid] = k
    return k
end

local function names(normText, qid)
    for _, key in ipairs(keys(qid)) do
        if normText:find(key, 1, true) then return true end
    end
    return false
end

----------------------------------------------------------------------
-- Chat lines (memory only)
----------------------------------------------------------------------
local lines = {}      -- { t, text, n (normalized), who (full name), short, chan }
local alerted = {}    -- [short .. "|" .. qid] = time()
local win             -- the window
local mine = {}       -- your elite quests in the log: { qid, ... } (rebuilt on quest log changes)

-- Same rule as VoidLFG's board: Blizzard's own channels, or a custom channel one of your chat
-- windows shows (addon data channels never).
local chanOK = {}
local function channelCounts(base)
    if type(base) ~= "string" or base == "" then return false end
    local c = chanOK[base]
    if c ~= nil then return c end
    local info = C_ChatInfo and C_ChatInfo.GetChannelInfoFromIdentifier and safe(C_ChatInfo.GetChannelInfoFromIdentifier, base)
    c = (info and info.channelType and info.channelType ~= 3) and true or false
    if not c then
        local want = base:lower()
        for i = 1, (NUM_CHAT_WINDOWS or 10) do
            local list = { GetChatWindowChannels(i) }
            for j = 1, #list, 2 do
                if type(list[j]) == "string" and list[j]:lower() == want then c = true end
            end
        end
    end
    chanOK[base] = c
    return c
end

local function rebuildMine()
    wipe(mine)
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        local q = info and not info.isHeader and info.questID
        if q and L:Offer(q) then mine[#mine + 1] = q end
    end
end

local function whisperLine(qid)
    local cls = UnitClass("player") or ""
    return ("Hi, I'm on %s too (%d %s). Group up?"):format(title(qid), UnitLevel("player") or 0, cls)
end

local function openWhisper(who, text)
    local line = "/w " .. who .. " " .. (text or "")
    if ChatFrameUtil and ChatFrameUtil.OpenChat then ChatFrameUtil.OpenChat(line)
    elseif ChatFrame_OpenChat then ChatFrame_OpenChat(line) end
end

local function alertFor(e)
    if VQ:Get("questLfgAlert") == false or InCombatLockdown() then return end
    if UnitInParty and safe(UnitInParty, e.short) then return end
    for _, q in ipairs(mine) do
        if names(e.n, q) and not (win and win:IsShown() and win.qid == q) then
            local k = e.short .. "|" .. q
            if not alerted[k] or time() - alerted[k] >= ALERT_GAP then
                alerted[k] = time()
                local msg = e.text
                if #msg > 120 then msg = msg:sub(1, 117) .. "..." end
                say(("|Hplayer:%s|h|cffffffff[%s]|r|h in %s is on |cffffd200%s|r: \"%s\" |cff888888(click the name to whisper, or LFG on the quest line)|r"):format(
                    e.who, e.short, e.chan, title(q), msg))
            end
            return
        end
    end
end

local function onChat(text, sender, base, guid)
    if secret(text) or secret(sender) or secret(base) or type(text) ~= "string" or type(sender) ~= "string" then return end
    if not channelCounts(base) then return end
    local short = Ambiguate(sender, "none")
    if short == "" or short == UnitName("player") then return end
    if guid and not secret(guid) and guid == UnitGUID("player") then return end
    local now = time()
    local e = { t = now, text = text, n = norm(text), who = sender, short = short, chan = base }
    -- the same post again replaces the earlier copy (people repeat every minute)
    for i = #lines, 1, -1 do
        if lines[i].short == short and lines[i].n == e.n then table.remove(lines, i); break end
    end
    lines[#lines + 1] = e
    while #lines > MAX_LINES or (lines[1] and now - lines[1].t > KEEP) do table.remove(lines, 1) end
    alertFor(e)
    if win and win:IsShown() and win.qid and names(e.n, win.qid) then L:Render() end
end

-- the chat lines naming a quest, newest first
function L:Lines(qid)
    local out, now = {}, time()
    for i = #lines, 1, -1 do
        local e = lines[i]
        if now - e.t <= KEEP and names(e.n, qid) then out[#out + 1] = e end
    end
    return out
end

----------------------------------------------------------------------
-- Your post
----------------------------------------------------------------------
local function chatChannels()
    local out = {}
    local raw = { GetChannelList() }
    local i = 1
    while i <= #raw do
        local name = raw[i + 1]
        if type(raw[i]) == "number" and type(name) == "string" then
            local info = C_ChatInfo and C_ChatInfo.GetChannelInfoFromIdentifier and safe(C_ChatInfo.GetChannelInfoFromIdentifier, name)
            if info and info.channelType and info.channelType ~= 3 and not raw[i + 2] then out[#out + 1] = name end
            i = i + 3
        else
            i = i + 1
        end
    end
    return out
end

local function curChannel()
    local list = chatChannels()
    local want = db().lfgChan
    for _, n in ipairs(list) do if n == want then return n, list end end
    for _, n in ipairs(list) do if n:lower():find("lookingforgroup") then return n, list end end
    for _, n in ipairs(list) do if n:lower():find("^general") then return n, list end end
    return list[1], list
end

function L:DefaultPost(qid)
    local where = zoneName(qid)
    local q = title(qid) .. (where and (" (" .. where .. ")") or "")
    if IsInGroup() and UnitIsGroupLeader("player") then
        local need = 5 - (GetNumGroupMembers() or 1)
        return ("LFM %s, need %d more, /w me"):format(q, need)
    end
    return ("LFG %s, %d %s, /w me"):format(q, UnitLevel("player") or 0, UnitClass("player") or "")
end

local edited = {}     -- [qid] = your own text for it (this session)
local lastPost = 0

-- must run inside the click: a channel post needs the hardware event
local function post()
    if not win or not win.qid then return end
    if GetTime() - lastPost < POST_GAP then
        say(("posted %d s ago, wait a little: people put spammers on ignore."):format(math.floor(GetTime() - lastPost)))
        return
    end
    local msg = (win.eb:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then say("Write something to post first."); return end
    if #msg > 255 then say("Your line is over 255 characters, shorten it."); return end
    local chan = curChannel()
    local idx = chan and GetChannelName(chan)
    if type(idx) ~= "number" or idx <= 0 then say("No chat channel to post in here (join LookingForGroup or General)."); return end
    SendChat(msg, "CHANNEL", nil, idx)
    lastPost = GetTime()
    win.postedAt, win.postedQ = time(), win.qid
    L:Render()
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
-- 1-pixel border that can't lose a side (VoidLFG's B.PixelBox, 2026-11-18)
local function PixelBox(f)
    local s = UIParent and UIParent:GetEffectiveScale()
    local px = ((s and s > 0 and PixelUtil and PixelUtil.GetPixelToUIUnitFactor) and (PixelUtil.GetPixelToUIUnitFactor() / s) or 1) * 1.01
    local function tex(layer)
        local t = f:CreateTexture(nil, layer, nil, -8)
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(true) end
        return t
    end
    local bg = tex("BACKGROUND")
    bg:SetPoint("TOPLEFT", f, "TOPLEFT", px, -px); bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -px, px)
    local top, bottom, left, right = tex("BORDER"), tex("BORDER"), tex("BORDER"), tex("BORDER")
    top:SetPoint("TOPLEFT", f, "TOPLEFT"); top:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, -px)
    bottom:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, px); bottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT")
    left:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -px); left:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", px, px)
    right:SetPoint("TOPLEFT", f, "TOPRIGHT", -px, -px); right:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, px)
    local edges = { top, bottom, left, right }
    f.SetBackdropColor = function(_, r, g, b, a) bg:SetVertexColor(r, g, b, a or 1) end
    f.SetBackdropBorderColor = function(_, r, g, b, a) for _, t in ipairs(edges) do t:SetVertexColor(r, g, b, a or 1) end end
    return f
end
VQ.PixelBox = PixelBox   -- shared: the guide panel's pick-up box (LevelCoach.lua) uses it at draw time

local function flatButton(parent, w, h, text)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    PixelBox(b)
    b.t = b:CreateFontString(nil, "OVERLAY"); VQ:SetFont(b.t, 11)
    b.t:SetPoint("CENTER"); b.t:SetText(text or "")
    local function paint(s)
        s:SetBackdropColor(0.11, 0.11, 0.15, 1)
        local on = s:IsEnabled()
        s:SetBackdropBorderColor(s.hover and on and 0 or 0.28, s.hover and on and 0.78 or 0.28, s.hover and on and 1 or 0.34, 1)
        local c = on and 0.9 or 0.45
        s.t:SetTextColor(c, c, c)
    end
    b.paint = paint
    b:SetScript("OnEnter", function(s) s.hover = true; paint(s); if s.tipText then
        GameTooltip:SetOwner(s, "ANCHOR_TOP"); GameTooltip:AddLine(s.tipTitle or "")
        GameTooltip:AddLine(s.tipText, .85, .85, .85, true); GameTooltip:Show() end end)
    b:SetScript("OnLeave", function(s) s.hover = false; paint(s); GameTooltip:Hide() end)
    b:HookScript("OnEnable", paint); b:HookScript("OnDisable", paint)
    paint(b)
    return b
end

local function ago(t)
    local s = time() - t
    if s < 60 then return "now" end
    return ("%dm"):format(math.floor(s / 60))
end

local W, ROW_H = 400, 18

local function Build()
    local f = CreateFrame("Frame", "VoidQuestLFG", UIParent)
    f:Hide()
    f:SetSize(W, 120 + ROWS * ROW_H + 96)
    f:SetPoint("CENTER", 0, 80)
    f:SetFrameStrata("HIGH"); f:SetToplevel(true)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    ns.Move(f, { db = function() return VoidQuestDB end, key = "questLfg" })   -- drag + kept after a restart (VoidMove.lua)
    PixelBox(f)
    local p = VQ.palette
    f:SetBackdropColor(p.bg[1], p.bg[2], p.bg[3], 0.95)
    f:SetBackdropBorderColor(p.accent[1], p.accent[2], p.accent[3], 0.5)
    tinsert(UISpecialFrames, "VoidQuestLFG")   -- Esc closes it

    f.title = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(f.title, 13)
    f.title:SetPoint("TOPLEFT", 10, -9); f.title:SetPoint("RIGHT", -28, 0); f.title:SetJustifyH("LEFT")
    f.title:SetWordWrap(false)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)
    f.sub = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(f.sub, 11)
    f.sub:SetPoint("TOPLEFT", 10, -28); f.sub:SetPoint("RIGHT", -10, 0); f.sub:SetJustifyH("LEFT")
    f.sub:SetTextColor(.7, .7, .7)

    local h1 = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(h1, 11)
    h1:SetPoint("TOPLEFT", 10, -50); h1:SetTextColor(.53, .8, 1); h1:SetText("In chat, last 30 minutes")
    f.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, f)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", 10, -66 - (i - 1) * ROW_H); r:SetPoint("RIGHT", f, "RIGHT", -10, 0)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.08)
        r.text = r:CreateFontString(nil, "OVERLAY"); VQ:SetFont(r.text, 11)
        r.text:SetAllPoints(); r.text:SetJustifyH("LEFT"); r.text:SetWordWrap(false)
        r:SetScript("OnClick", function(s, btn)
            if not s.e then return end
            openWhisper(s.e.who, btn ~= "RightButton" and whisperLine(f.qid) or nil)
        end)
        r:SetScript("OnEnter", function(s)
            if not s.e then return end
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:AddLine(("%s, %s, %s ago"):format(s.e.short, s.e.chan, ago(s.e.t)))
            GameTooltip:AddLine(s.e.text, 1, 1, 1, true)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click: whisper them (the chat box opens with a line, you press Enter)", .6, .6, .6, true)
            GameTooltip:AddLine("Right-click: whisper your own words", .6, .6, .6, true)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.rows[i] = r
    end
    f.none = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(f.none, 11)
    f.none:SetPoint("TOPLEFT", 10, -68); f.none:SetPoint("RIGHT", -10, 0); f.none:SetJustifyH("LEFT")
    f.none:SetTextColor(.6, .6, .6)
    f.none:SetText("Nobody in chat has named this quest yet. Post below; new lines show up here as they come.")

    local y = -70 - ROWS * ROW_H
    local h2 = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(h2, 11)
    h2:SetPoint("TOPLEFT", 10, y); h2:SetTextColor(.53, .8, 1); h2:SetText("Your post (edit it, then Post)")
    f.count = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(f.count, 10)
    f.count:SetPoint("TOPRIGHT", -10, y); f.count:SetTextColor(.5, .5, .5)

    local box = CreateFrame("Frame", nil, f)
    box:SetPoint("TOPLEFT", 10, y - 16); box:SetPoint("RIGHT", f, "RIGHT", -10, 0); box:SetHeight(24)
    PixelBox(box)
    box:SetBackdropColor(0.05, 0.05, 0.07, 1); box:SetBackdropBorderColor(0.28, 0.28, 0.34, 1)
    local eb = CreateFrame("EditBox", nil, box)
    eb:SetPoint("TOPLEFT", 6, -2); eb:SetPoint("BOTTOMRIGHT", -6, 2)
    eb:SetAutoFocus(false); eb:SetMaxLetters(255)
    eb:SetFont(VQ.font, 11, "")
    eb:SetTextColor(1, 1, 1)
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)   -- Post is a click, never Enter
    eb:SetScript("OnTextChanged", function(s, user)
        local n = #(s:GetText() or "")
        f.count:SetText(("%d/255"):format(n))
        if user and f.qid then edited[f.qid] = s:GetText() end
    end)
    f.eb = eb

    local by = y - 46
    f.chan = flatButton(f, 150, 22, "")
    f.chan:SetPoint("TOPLEFT", 10, by)
    f.chan.tipTitle, f.chan.tipText = "Channel", "Where Post sends your line. Click to switch."
    f.chan:SetScript("OnClick", function()
        local cur, list = curChannel()
        if #list == 0 then return end
        local nxt = list[1]
        for i, n in ipairs(list) do if n == cur then nxt = list[i % #list + 1] end end
        db().lfgChan = nxt
        L:Render()
    end)
    f.reset = flatButton(f, 60, 22, "Reset")
    f.reset:SetPoint("LEFT", f.chan, "RIGHT", 6, 0)
    f.reset.tipTitle, f.reset.tipText = "Reset", "Back to the line VoidQuest wrote."
    f.reset:SetScript("OnClick", function() if f.qid then edited[f.qid] = nil; eb:SetText(L:DefaultPost(f.qid)) end end)
    f.post = flatButton(f, 80, 22, "Post")
    f.post:SetPoint("TOPRIGHT", -10, by)
    f.post.tipTitle, f.post.tipText = "Post", "Sends the line above to the channel on the left. Nothing is sent before you click this."
    f.post:SetScript("OnClick", post)
    f.posted = f:CreateFontString(nil, "OVERLAY"); VQ:SetFont(f.posted, 10)
    f.posted:SetPoint("RIGHT", f.post, "LEFT", -6, 0); f.posted:SetTextColor(.5, .8, .5)

    local cy = by - 30
    f.ask = flatButton(f, 200, 22, "Ask VoidQuest players")
    f.ask:SetPoint("TOPLEFT", 10, cy)
    f.ask.tipTitle = "Ask VoidQuest players"
    f.ask.tipText = "Asks the VoidQuest players in your zone who are on this quest to group (the same as Ctrl-click on the quest line). They get a pop-up with Accept or No thanks."
    f.ask:SetScript("OnClick", function() if f.qid and VQ.GroupUp then VQ.GroupUp:Ask(f.qid) end end)
    f.board = flatButton(f, 100, 22, "LFG board")
    f.board:SetPoint("TOPRIGHT", -10, cy)
    f.board.tipTitle, f.board.tipText = "LFG board", "Opens VoidLFG's board: every LFG chat post and Group Finder listing."
    f.board:SetScript("OnClick", function() if VoidLFGF_Toggle then VoidLFGF_Toggle() end end)

    f:SetHeight(-(cy - 22) + 10)
    f:SetScript("OnHide", function() GameTooltip:Hide(); f.eb:ClearFocus() end)
    -- ages count up and lines past 30 minutes drop out while it stays open (Codex 11-19)
    local acc = 0
    f:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc >= 15 then acc = 0; L:Render() end
    end)
    return f
end

function L:Render()
    local f = win
    if not (f and f:IsShown() and f.qid) then return end
    local qid = f.qid
    local tag = VQ.Guide and VQ.Guide.LevelTag and VQ.Guide.LevelTag(qid) or ""
    f.title:SetText("Group for: |cffffd200" .. tag .. title(qid) .. "|r")
    local bits = {}
    local where = zoneName(qid)
    if where then bits[#bits + 1] = where end
    bits[#bits + 1] = "elite quest"
    local here = VQ.GroupUp and VQ.GroupUp:Here(qid) or 0
    if here > 0 then bits[#bits + 1] = ("%d VoidQuest player%s here on it"):format(here, here == 1 and "" or "s") end
    local mobs = objectiveMobs(qid)
    if #mobs > 0 then bits[#bits + 1] = "kill " .. table.concat(mobs, ", ") end
    f.sub:SetText(table.concat(bits, " · "))

    local list = self:Lines(qid)
    for i, row in ipairs(f.rows) do
        local e = list[i]
        row.e = e
        if e then
            row.text:SetText(("|cff888888%s|r |cffffffff%s:|r |cffcccccc%s|r"):format(ago(e.t), e.short, e.text))
            row:Show()
        else
            row:Hide()
        end
    end
    f.none:SetShown(#list == 0)

    local chan = curChannel()
    f.chan.t:SetText(chan and ("Channel: " .. chan:gsub(" %- .*", "")) or "No channel")
    f.post:SetEnabled(chan ~= nil)
    f.posted:SetText((f.postedQ == qid and f.postedAt) and ("posted " .. ago(f.postedAt)) or "")
    local can = VQ.GroupUp and VQ.GroupUp:CanOffer(qid)
    f.ask:SetEnabled(can and true or false)
    f.ask.t:SetText(here > 0 and ("Ask VoidQuest players (%d here)"):format(here) or "Ask VoidQuest players")
    f.board:SetShown(VoidLFGF_Toggle ~= nil)
end

function L:Open(qid)
    if not qid then return end
    if not self:IsElite(qid) then return end
    win = win or Build()
    if win.qid ~= qid then
        win.qid = qid
        keyCache[qid] = nil   -- objectives can name the elite only once the quest is in the log
        win.eb:SetText(edited[qid] or self:DefaultPost(qid))
        win.eb:SetCursorPosition(0)
    end
    win:Show()
    self:Render()
end

function L:Toggle(qid)
    if win and win:IsShown() and win.qid == qid then win:Hide() else self:Open(qid) end
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("CHAT_MSG_CHANNEL")
ev:RegisterEvent("QUEST_LOG_UPDATE")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHANNEL_UI_UPDATE")
ev:RegisterEvent("UPDATE_CHAT_WINDOWS")
local pending
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_CHANNEL" then
        local text, sender, _, _, _, _, _, _, base, _, _, guid = ...
        onChat(text, sender, base, guid)
    elseif event == "CHANNEL_UI_UPDATE" or event == "UPDATE_CHAT_WINDOWS" then
        wipe(chanOK)
        if win and win:IsShown() then L:Render() end
    else
        if pending then return end
        pending = true
        C_Timer.After(1, function()
            pending = nil
            rebuildMine()
            if win and win:IsShown() then
                if not L:IsElite(win.qid) then win:Hide() else L:Render() end
            end
        end)
    end
end)

-- test hooks (tools/cmd/vq-lfg-test)
L._onChat, L._norm, L._keys, L._rebuild = onChat, norm, keys, rebuildMine
