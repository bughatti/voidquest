----------------------------------------------------------------------
-- VoidQuest — companion quests (WoW Forever): for a quest in your log, the quests you haven't
-- picked up yet that go with it (the user, 2026-11-15: "companion quests for quests you may
-- already have" -> "yes": Raptor Mastery while you kill Lashtail Raptors for Headhunting).
--
-- A quest B goes with quest A (in your log) when B is open to you now (eligible, not done, not in
-- your log, offered at your level: ForeverZone's F:Available), its start is known, and either
--   same mobs : B asks for the same mobs / objects as A (ForeverMobs keys), or
--   same area : B's mobs / objects stand within SAME_AREA_YD of A's (ForeverSpawns, same map).
-- Grey quests (far below your level) don't count. At most 2 per quest: same mobs first, then the
-- nearest work, then the nearest giver.
--
-- Shown: a "Take along:" line in the quest's tooltip (the guide panel / tracker), and the giver's
-- "!" on the world map turns gold, even outside your Min / Mid / Max tier, with "Goes with <A>"
-- in its tooltip (ForeverZone.lua). Worked out when asked, kept until your quest log, level or
-- turn-ins change.
----------------------------------------------------------------------
local VQ = VoidQuest
if not VQ or (select(4, GetBuildInfo()) or 0) >= 100000 then return end   -- WoW Forever only

local C = {}
VQ.Companions = C

local SAME_AREA_YD = 120
local MAX_PTS = 80          -- spots per mob kept for the distance check (sampled evenly)
local GREY_BELOW = 7        -- a quest this many levels under you is grey: not worth taking along
local PER_QUEST = 2

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end end
local function secret(v) return issecretvalue and issecretvalue(v) end

-- yards across a map (C_Map.GetMapWorldSize), cached; a guess for maps that don't say
local sizes = {}
local function mapSize(m)
    local s = sizes[m]
    if s == nil then
        local w, h = safe(C_Map.GetMapWorldSize, m)
        s = (type(w) == "number" and w > 0 and type(h) == "number" and h > 0) and { w, h } or { 3000, 2000 }
        sizes[m] = s
    end
    return s[1], s[2]
end
local function yards(m, x1, y1, x2, y2)
    local w, h = mapSize(m)
    local dx, dy = (x1 - x2) * w, (y1 - y2) * h
    return math.sqrt(dx * dx + dy * dy)
end

-- where a quest's mobs / objects are: keys (ForeverMobs "n123" / "o456") and spots per map
local workCache = {}
local function work(qid)
    local w = workCache[qid]
    if w then return w end
    w = { keys = {}, maps = {}, box = {}, any = false, anyKey = false }
    for _, r in ipairs((VQ.ForeverMobs and VQ.ForeverMobs[qid]) or {}) do
        local key = r[2]
        if key then
            w.keys[key] = true
            w.anyKey = true
            for m, pts in pairs((VQ.ForeverSpawns and VQ.ForeverSpawns[key]) or {}) do
                local n = math.floor(#pts / 6)
                local step = math.max(1, math.ceil(n / MAX_PTS))   -- MAX_PTS at most (Codex: floor kept ~2x)
                local list = w.maps[m] or {}
                w.maps[m] = list
                local b = w.box[m] or { 1, 1, 0, 0 }
                w.box[m] = b
                for i = 0, n - 1, step do
                    local x, y = tonumber(pts:sub(i * 6 + 1, i * 6 + 3)), tonumber(pts:sub(i * 6 + 4, i * 6 + 6))
                    if x and y then
                        x, y = x / 1000, y / 1000
                        list[#list + 1] = { x, y }
                        w.any = true
                        if x < b[1] then b[1] = x end
                        if y < b[2] then b[2] = y end
                        if x > b[3] then b[3] = x end
                        if y > b[4] then b[4] = y end
                    end
                end
            end
        end
    end
    workCache[qid] = w
    return w
end

-- yards between two quests' work spots on a shared map, when within `limit` (else nil). Stops at
-- the first pair that close, and skips a map whose two boxes are farther apart than that (Codex: the
-- full every-pair search could stall the map refresh).
local function within(a, b, limit)
    local best
    for m, pa in pairs(a.maps) do
        local pb = b.maps[m]
        local ba, bb = a.box[m], b.box[m]
        if pb and ba and bb then
            local w, h = mapSize(m)
            local gx = math.max(0, bb[1] - ba[3], ba[1] - bb[3]) * w
            local gy = math.max(0, bb[2] - ba[4], ba[2] - bb[4]) * h
            if math.sqrt(gx * gx + gy * gy) <= limit then
                for _, p in ipairs(pa) do
                    for _, q in ipairs(pb) do
                        local d = yards(m, p[1], p[2], q[1], q[2])
                        if d <= limit then
                            if not best or d < best then best = d end
                            if d <= limit / 4 then return best end
                            break
                        end
                    end
                end
            end
        end
    end
    return best
end

local function playerPos()
    local m = safe(C_Map.GetBestMapForUnit, "player")
    if not m or secret(m) then return nil end
    local p = safe(C_Map.GetPlayerMapPosition, m, "player")
    if not p then return nil end
    local x, y = p:GetXY()
    if not x or secret(x) or secret(y) then return nil end
    return m, x, y
end

local cache, index = {}, nil   -- cache[A] = list; index[B] = { a = A, why = ... } (built from your log)

-- the companions of quest A (in your log): { { id, title, why, giver, yd }, ... }
function C:For(a)
    local hit = cache[a]
    if hit then return hit end
    local F = VQ.Forever
    local out = {}
    cache[a] = out
    if not (F and VQ.ForeverQuests and VQ.ForeverQuests[a]) then return out end
    local wa = work(a)
    if not wa.anyKey then return out end   -- no mobs / objects known for it: nothing to match
    local pm, px, py = playerPos()
    local lvl = UnitLevel("player") or 0
    -- the zones A's work is in, and the one you're in (a quest can be listed under another zone than
    -- its mobs' map, or have no spots known: Codex): their open quests
    local zones = {}
    for m in pairs(wa.maps) do
        local mi = safe(C_Map.GetMapInfo, m)
        if mi and mi.name then zones[mi.name] = true end
    end
    local here = F.PlayerZone and F:PlayerZone()
    if here then zones[here] = true end
    local seen = {}
    for z in pairs(zones) do
        for _, e in ipairs(F:ZoneList(z) or {}) do
            local b = e.id
            if b ~= a and not seen[b] and e.status == "open" and e.spot then
                seen[b] = true
                local bl = e.level or 0
                if not (bl > 0 and bl <= lvl - GREY_BELOW) then
                    local wb = work(b)
                    local same = false
                    for k in pairs(wb.keys) do if wa.keys[k] then same = true; break end end
                    local d = (not same and wa.any and wb.any) and within(wa, wb, SAME_AREA_YD) or nil
                    if same or (d and d <= SAME_AREA_YD) then
                        local giver = VQ.Starts and VQ.Starts.Giver and VQ.Starts:Giver(b)
                        local gyd = (pm and e.spot.m == pm) and yards(pm, px, py, e.spot.x, e.spot.y) or nil
                        out[#out + 1] = { id = b, title = e.title, why = same and "same mobs" or "same area",
                            giver = giver, yd = gyd, near = d or 0, same = same }
                    end
                end
            end
        end
    end
    table.sort(out, function(x, y)
        if x.same ~= y.same then return x.same end
        if x.near ~= y.near then return x.near < y.near end
        return (x.yd or 1e9) < (y.yd or 1e9)
    end)
    while #out > PER_QUEST do table.remove(out) end
    return out
end

-- which quest in your log a quest goes with (for the map "!"), or nil
local function logQuests()
    local out = {}
    local n = safe(C_QuestLog.GetNumQuestLogEntries) or 0
    for i = 1, n do
        local info = safe(C_QuestLog.GetInfo, i)
        if info and not info.isHeader and info.questID and not secret(info.questID) then out[#out + 1] = info.questID end
    end
    return out
end
function C:Of(b)
    if not index then
        index = {}
        for _, a in ipairs(logQuests()) do
            -- guarded: this runs inside the world map's pin refresh, which must never break
            local ok, list = pcall(self.For, self, a)
            for _, c in ipairs(ok and list or {}) do
                if not index[c.id] then index[c.id] = { a = a, why = c.why } end
            end
        end
    end
    return index[b]
end

local function title(q)
    local t = safe(C_QuestLog.GetTitleForQuestID, q)
    if type(t) == "string" and not secret(t) and t ~= "" then return t end
    local r = VQ.ForeverQuests and VQ.ForeverQuests[q]
    return r and r[1] or ("quest " .. q)
end

-- tooltip of a quest in your log: "Take along: Raptor Mastery (same mobs; Hemet Nesingwary, 120 yd)"
function C:AddTooltip(tt, a)
    if not (tt and a) then return end
    local F = VQ.Forever
    if not (F and F.Status and F:Status(a) == "log") then return end
    for _, c in ipairs(self:For(a)) do
        local where = {}
        if c.giver then where[#where + 1] = c.giver end
        if c.yd then where[#where + 1] = ("%d yd"):format(math.floor(c.yd / 10 + 0.5) * 10) end
        tt:AddLine(("Take along: |cffffd200%s|r (%s%s)"):format(c.title, c.why,
            #where > 0 and ("; " .. table.concat(where, ", ")) or ""), 0.85, 0.85, 0.85, true)
    end
end

-- tooltip of a map "!" that goes with a quest of yours
function C:AddPinLine(tt, b)
    local c = tt and self:Of(b)
    if c then tt:AddLine(("Goes with %s (%s): take it along"):format(title(c.a), c.why), 1, 0.82, 0.2, true) end
end

-- your log, level or turn-ins changed: work it out again when asked
local function forget() wipe(cache); index = nil end
C.Forget = forget
local ev = CreateFrame("Frame")
for _, e in ipairs({ "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "PLAYER_LEVEL_UP", "PLAYER_ENTERING_WORLD",
                        "ZONE_CHANGED_NEW_AREA" }) do   -- a new zone too: your zone is searched (Codex)
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", forget)
