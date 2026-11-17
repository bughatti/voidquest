----------------------------------------------------------------------
-- Group quest progress in a mob's tooltip, organized.
--
-- The user, 2026-11-14: "the tooltip with who all has what on shared quests, it needs to be
-- organized better". In a group the game lists each quest, then each member, then that member's
-- objective, one per line: 4 quests in a 4-player group is ~30 lines. Here the game's quest lines
-- are hidden and replaced by one line per objective with everyone's count on it:
--
--   Bloodscalp Ears
--     Bloodscalp Ear /15          You 7 · Elementrix 10 · Poptimus 8 · Mokiya 9
--   [check] Hunt for Yenniku                                         everyone done
--
-- Quests you still need come first, then ones a groupmate still needs, then the finished ones
-- (one dim line each). Only when the whole quest block is readable (nothing secret) and has player
-- lines; otherwise the game's own lines stay (solo tooltips are already short).
----------------------------------------------------------------------
local _, ns = ...
local VQ = VoidQuest

local G = {}
ns.GroupQuestTip = G
if VQ then VQ.GroupQuestTip = G end

local LT = Enum and Enum.TooltipDataLineType or {}
local L_OBJ, L_TITLE, L_PLAYER = LT.QuestObjective or 8, LT.QuestTitle or 17, LT.QuestPlayer or 18
local QUEST_LINE = { [L_OBJ] = true, [L_TITLE] = true, [L_PLAYER] = true }
G.QUEST_LINE = QUEST_LINE

local MAX_NAMES = 5          -- more groupmates on one objective (a raid): "+N"
local ME = "\001me"          -- objective lines before any player line are yours
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"

local function secret(v) return issecretvalue and issecretvalue(v) end

-- "7/15 Bloodscalp Ear", "Bloodscalp Ear: 7/15", "- Hatefury Rogue slain 3/7" -> 7, 15, name
function G.ParseCount(txt)
    local have, need = txt:match("(%d+)%s*/%s*(%d+)")
    local name = txt:gsub("%d+%s*/%s*%d+", "")
    name = name:gsub("^[%s%-:]+", ""):gsub("[%s%-:]+$", "")
    return tonumber(have), tonumber(need), name
end

-- The quest block of a unit tooltip: { { title, players = {names in order}, objs = {...} } } or nil.
-- nil = leave the tooltip alone (no group lines, something secret, or a shape we don't know).
function G.Parse(lines)
    if type(lines) ~= "table" then return nil end
    local quests, byTitle, cur, who, hasPlayer = {}, {}, nil, nil, false
    for _, ln in ipairs(lines) do
        local t = ln.type
        if secret(t) then return nil end
        if QUEST_LINE[t] then
            local txt = ln.leftText
            if type(txt) ~= "string" or secret(txt) then return nil end
            if t == L_TITLE then
                cur = byTitle[txt]
                if not cur then
                    cur = { title = txt, players = {}, seen = {}, objs = {}, byName = {} }
                    byTitle[txt] = cur
                    quests[#quests + 1] = cur
                end
                who = nil
            elseif t == L_PLAYER then
                if not cur then return nil end
                who, hasPlayer = txt, true
                if not cur.seen[txt] then cur.seen[txt] = true; cur.players[#cur.players + 1] = txt end
            else
                if not cur then return nil end
                local done = ln.completed
                if secret(done) then return nil end
                local have, need, name = G.ParseCount(txt)
                if name == "" then name = txt end
                local o = cur.byName[name]
                if not o then
                    o = { name = name, need = need, by = {} }
                    cur.byName[name] = o
                    cur.objs[#cur.objs + 1] = o
                end
                o.need = o.need or need
                local key = who or ME
                if not who and not cur.seen[ME] then cur.seen[ME] = true; table.insert(cur.players, 1, ME) end
                o.by[key] = { have = have, need = need,
                    done = done == true or (have ~= nil and need ~= nil and have >= need) }
            end
        end
    end
    if not hasPlayer or #quests == 0 then return nil end
    return quests
end

-- me = { full = "Ana Brightwood", short = "Ana" } (either may be nil); classOf(name) -> "ROGUE"
-- groupSize = members in the group (incl. you) for "everyone"; colorOf(class) -> "ffrrggbb" or nil.
-- Returns lines { left, right, lr, lg, lb } for AddDoubleLine / AddLine (right nil).
function G.Build(quests, me, classOf, groupSize, colorOf)
    local function isMe(n) return n == ME or (me and (n == me.full or n == me.short)) end
    local firsts = {}
    for _, q in ipairs(quests) do
        for _, n in ipairs(q.players) do
            if not isMe(n) then
                local f = n:match("^(%S+)") or n
                firsts[f] = (firsts[f] and firsts[f] ~= n) and "clash" or n
            end
        end
    end
    local function label(n)
        if isMe(n) then return "You" end
        local f = n:match("^(%S+)") or n
        local shown = firsts[f] == "clash" and n or f
        local cls = classOf and classOf(n)
        local hex = cls and colorOf and colorOf(cls)
        return hex and ("|c" .. hex .. shown .. "|r") or shown
    end

    -- rank: 1 you still need something, 2 a groupmate does, 3 everyone listed is done
    for i, q in ipairs(quests) do
        local meNeed, anyNeed = false, false
        for _, o in ipairs(q.objs) do
            for n, p in pairs(o.by) do
                if not p.done then
                    anyNeed = true
                    if isMe(n) then meNeed = true end
                end
            end
        end
        q.i, q.rank = i, meNeed and 1 or anyNeed and 2 or 3
    end
    table.sort(quests, function(a, b) if a.rank ~= b.rank then return a.rank < b.rank end return a.i < b.i end)

    local out = {}
    for _, q in ipairs(quests) do
        if q.rank == 3 then
            local who
            if groupSize and #q.players >= groupSize then
                who = "everyone done"
            else
                local names = {}
                for _, n in ipairs(q.players) do names[#names + 1] = label(n) end
                who = table.concat(names, ", ") .. " done"
            end
            out[#out + 1] = { CHECK .. " " .. q.title, who, 0.45, 0.75, 0.45, 0.55, 0.55, 0.55 }
        else
            out[#out + 1] = { q.title, nil, 1, 0.82, 0 }
            for _, o in ipairs(q.objs) do
                local parts, shown = {}, 0
                for _, n in ipairs(q.players) do
                    local p = o.by[n]
                    if p then
                        shown = shown + 1
                        if shown <= MAX_NAMES then
                            local v
                            if p.done then v = CHECK
                            elseif p.have then v = "|cffffffff" .. p.have .. "|r"
                            else v = "|cff909090-|r" end
                            parts[#parts + 1] = label(n) .. " " .. v
                        end
                    end
                end
                if shown > MAX_NAMES then parts[#parts + 1] = "+" .. (shown - MAX_NAMES) end
                local left = "  " .. o.name .. (o.need and ("|cff909090 /" .. o.need .. "|r") or "")
                out[#out + 1] = { left, table.concat(parts, " · "), 0.85, 0.85, 0.85, 0.75, 0.75, 0.75 }
            end
        end
    end
    return out
end

----------------------------------------------------------------------
-- In game
----------------------------------------------------------------------
local function Enabled() return not VQ or not VQ.Get or VQ:Get("groupQuestTip") ~= false end

local function Me()
    local full = GetUnitName and GetUnitName("player", false)
    local short = UnitName and UnitName("player")
    if secret(full) then full = nil end
    if secret(short) then short = nil end
    return { full = full, short = short }
end

-- name (as the tooltip writes it) -> class file, for everyone in your group
local function ClassMap()
    local map = {}
    local function add(u)
        if not UnitExists(u) then return end
        local _, cls = UnitClass(u)
        if not cls or secret(cls) then return end
        local full = GetUnitName and GetUnitName(u, false)
        local short = UnitName(u)
        if full and not secret(full) then map[full] = cls end
        if short and not secret(short) then map[short] = cls end
    end
    add("player")
    if IsInRaid and IsInRaid() then
        for i = 1, 40 do add("raid" .. i) end
    else
        for i = 1, 4 do add("party" .. i) end
    end
    return map
end

local function ColorOf(cls)
    local c = C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(cls)
    if c and c.GenerateHexColor then return c:GenerateHexColor() end
    c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
    return c and c.colorStr
end

local active = {}   -- tooltip -> parsed block, from the pre-call to the post-call (same frame)

local function Render(tt, quests)
    local map = ClassMap()
    local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
    local lines = G.Build(quests, Me(), function(name) return map[name] end, n > 0 and n or nil, ColorOf)
    for _, l in ipairs(lines) do
        if l[2] then tt:AddDoubleLine(l[1], l[2], l[3], l[4], l[5], l[6], l[7], l[8])
        else tt:AddLine(l[1], l[3], l[4], l[5]) end
    end
end

-- if Render fails after the game's lines were hidden, put them back plainly
local function Raw(tt, lines)
    for _, ln in ipairs(lines) do
        if QUEST_LINE[ln.type] and type(ln.leftText) == "string" then tt:AddLine(ln.leftText, 1, 1, 1) end
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddLinePreCall and Enum and Enum.TooltipDataType
    and Enum.TooltipDataType.Unit then
    local UNIT = Enum.TooltipDataType.Unit
    TooltipDataProcessor.AddTooltipPreCall(UNIT, function(tt, data)
        active[tt] = nil
        if not Enabled() or not data then return end
        local ok, q = pcall(G.Parse, data.lines)
        if ok and q then
            -- only these exact line tables get hidden: if this tooltip is cut short (another
            -- addon's pre-call ends it), a later tooltip on the same frame keeps its quest lines
            local own = {}
            for _, ln in ipairs(data.lines) do if QUEST_LINE[ln.type] then own[ln] = true end end
            active[tt] = { q = q, lines = data.lines, own = own, ate = false }
        end
    end)
    for t in pairs(QUEST_LINE) do
        TooltipDataProcessor.AddLinePreCall(t, function(tt, ln)
            local a = active[tt]
            if a and a.own[ln] then a.ate = true; return true end
        end)
    end
    TooltipDataProcessor.AddTooltipPostCall(UNIT, function(tt)
        local a = active[tt]
        active[tt] = nil
        -- nothing hidden (the game handed us copies of the lines?): the game's own lines are up
        if not (a and a.ate) then return end
        if not pcall(Render, tt, a.q) then pcall(Raw, tt, a.lines) end
    end)
end
