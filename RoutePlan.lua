----------------------------------------------------------------------
-- VoidQuest — RoutePlan: the best order for the quests you have (WoW Forever)
--
-- The user, 2026-11-11: "start the route planner" (the "better than Questie" list: "here's the
-- best order for the quests you have: 6 quests, ~40 min, 14k XP, batch these turn-ins, then
-- fly"). Questie only shows dots; fixed-script guides follow someone else's order. This plans
-- YOUR log, now, and plans again when it changes.
--
-- Stops: each quest you can do solo gets a "do it" stop where its objectives are (the mobs'
-- spawn spots VoidQuest knows, else the game's own next waypoint) and a "turn in" stop at its
-- turn-in NPC (VoidGPS's places, else where that NPC gives quests, else the game's waypoint);
-- a finished quest only has its turn-in. The work at a stop: how long players took (QuestTime,
-- scaled to what's left), else a guess from what's left to do. The way between two stops:
-- VoidGPS:TravelTime (walking, flight paths, zeppelins; rough, no path search), else a
-- straight line. The order: every quest put in where it costs least (its "do it" before its
-- "turn in"), then single stops moved while that saves time.
--
-- Quests you could pick up on the way are added when they're worth it: the giver stands in a
-- zone the route goes through (or yours), you can take it now, and its XP for the extra time is
-- at least the plan's own XP per hour; at most PICK_MAX.
--
-- Left out, listed under the plan: dungeon / raid / elite quests (bring a group), PvP quests,
-- grey quests (little XP), and quests with no known place yet.
--
-- /vq route, or the panel's Route button. Click a step: VoidGPS guides you there and the
-- quest is tracked.
----------------------------------------------------------------------
local _, ns = ...   -- ns.Move (VoidMove.lua)
local VQ = VoidQuest
if not VQ.ForeverQuests then return end   -- WoW Forever only

local P = {}
VQ.Route = P

local MAX_QUESTS = 25
local TURNIN_SEC = 15      -- talking to the turn-in NPC
local SAME_SPOT  = 0.02    -- map units: stops this close are one place
local RUN        = 7       -- yd/s, the fallback without VoidGPS
local PICK_TRY   = 30      -- quests to pick up that are tried (your zone first, then most XP)
local PICK_MAX   = 10      -- at most this many added to a plan
local PICK_RATE  = 1.0     -- kept when its XP per extra hour is at least the plan's own
local HERE_RATE  = 0.5     -- ...half that for a quest whose giver is in the zone you're in (you're there)
local PICK_WORK  = 480     -- seconds to do a quest nobody has timed yet
-- Level gap (the user, 2026-11-11: "why is it picking lvl 36/37 stuff for me to do, would it not be
-- quicker for me to do lvl 31/32 stuff"): a quest above you takes longer (tougher mobs, more misses,
-- more deaths), one below you less; players' times are at-level times, so they're scaled too. And
-- a quest UP_LEVEL or more above you waits in the plan until the turn-ins before it put you within a
-- level of it, like a leveling guide does.
local PER_LEVEL_UP   = 0.20  -- +20% time per level the quest is above you
local PER_LEVEL_DOWN = 0.08  -- -8% per level below you
local MIN_FACTOR     = 0.67
local UP_LEVEL       = 2
local EXPLORE_MAX    = 6   -- areas to discover added at most
local EXPLORE_DETOUR = 90  -- seconds of extra travel an area may cost
local FOLLOW_MAX  = 6      -- follow-ups (the next quest in a chain) added at most
local FOLLOW_RATE = 0.5    -- a follow-up is kept at half the plan's XP per hour: chains lead somewhere

local function safe(fn, ...)
    if not fn then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
end
local function secret(v) return issecretvalue and issecretvalue(v) end

----------------------------------------------------------------------
-- Where things are
----------------------------------------------------------------------
-- Objectives: where most of the quest's mobs are. All its mobs' spawn spots (shipped), plus the
-- spots you saw them at (VoidQuestDB.seenMobs) and the ones 3+ players confirmed (ForeverShare),
-- those two counting triple: they're where the mobs really are on Forever. The busiest 5% x 5%
-- patch of the map (with its neighbours) wins, and the spot is the middle of that patch, not
-- the middle of every spawn (the user, 2026-11-11: a quest's mobs were somewhere else than the
-- plan said; mobs in two camps put the average in the empty ground between them).
local CELL = 50   -- 5% of the map, in the spawn data's 0..999 units
local function busiest(refs)
    local maps = {}   -- [mapID] = { cells = { [key] = { w, sx, sy } } }
    local function add(mapID, pts, weight)
        if not (pts and pts ~= "") then return end
        local m = maps[mapID]
        if not m then m = { cells = {} }; maps[mapID] = m end
        for i = 1, #pts - 5, 6 do
            local x, y = tonumber(pts:sub(i, i + 2)), tonumber(pts:sub(i + 3, i + 5))
            if x and y then
                local cx, cy = math.floor(x / CELL), math.floor(y / CELL)
                local key = cx * 100 + cy
                local c = m.cells[key]
                if not c then c = { w = 0, sx = 0, sy = 0, cx = cx, cy = cy }; m.cells[key] = c end
                c.w, c.sx, c.sy = c.w + weight, c.sx + x * weight, c.sy + y * weight
            end
        end
    end
    local seen = VoidQuestDB and VoidQuestDB.seenMobs or {}
    for _, r in ipairs(refs) do
        for mapID, pts in pairs(VQ.ForeverSpawns and VQ.ForeverSpawns[r[2]] or {}) do add(mapID, pts, 1) end
        local id = r[2]:match("^n(%d+)$")   -- nil for objects ("o123")
        local npc = id and tonumber(id)
        if npc then
            for mapID, pts in pairs(seen[npc] and seen[npc].m or {}) do add(mapID, pts, 3) end
            if VQ.Share and VQ.Share.MobPts then
                for mapID in pairs(maps) do add(mapID, VQ.Share:MobPts(npc, mapID), 3) end
            end
        end
    end
    local best, bestW
    for mapID, m in pairs(maps) do
        for _, c in pairs(m.cells) do
            local w, sx, sy = 0, 0, 0
            for dx = -1, 1 do
                for dy = -1, 1 do
                    local n = m.cells[(c.cx + dx) * 100 + (c.cy + dy)]
                    if n then w, sx, sy = w + n.w, sx + n.sx, sy + n.sy end
                end
            end
            if not bestW or w > bestW then best, bestW = { map = mapID, x = sx / w / 1000, y = sy / w / 1000 }, w end
        end
    end
    return best
end

-- Where to go for a quest's objectives: one spot per PLACE (the user, 2026-11-11, Helcular's Revenge
-- part 2: two flames in Hillsbrad and the third in Alterac Mountains; one stop sent you to two).
-- Each objective is its own need: an object or a mob to kill is one need; an item that drops from
-- several mobs is one need (any of them will do). Needs already done are left out. Needs whose
-- spots are close (same map, within NEAR_SPOT) share a stop. -> { { map, x, y, what }, ... } (may be empty)
local NEAR_SPOT = 0.08
local function objectiveSpots(qid)
    local objs = safe(C_QuestLog.GetQuestObjectives, qid) or {}
    local function finished(name)
        if not name then return false end
        for _, o in ipairs(objs) do
            if o.finished and type(o.text) == "string" and o.text:find(name, 1, true) then return true end
        end
        return false
    end
    local needs, order = {}, {}
    for _, r in ipairs(VQ.ForeverMobs and VQ.ForeverMobs[qid] or {}) do
        local key = (r[1] == "d" and (r[3] or 0) ~= 0) and ("i" .. r[3]) or r[2]
        local nd = needs[key]
        if not nd then
            local name = r[1] == "d" and (C_Item and C_Item.GetItemNameByID and safe(C_Item.GetItemNameByID, r[3]))
                or (VQ.ForeverMobNames and VQ.ForeverMobNames[r[2]])
            nd = { refs = {}, name = name }
            needs[key] = nd
            order[#order + 1] = key
        end
        nd.refs[#nd.refs + 1] = r
    end
    local out = {}
    for _, key in ipairs(order) do
        local nd = needs[key]
        if not finished(nd.name) then
            local sp = busiest(nd.refs)
            if sp then
                local joined
                for _, o in ipairs(out) do
                    if o.map == sp.map and math.abs(o.x - sp.x) < NEAR_SPOT and math.abs(o.y - sp.y) < NEAR_SPOT then
                        joined = o
                        break
                    end
                end
                if joined then
                    if nd.name then joined.what = joined.what and (joined.what .. ", " .. nd.name) or nd.name end
                else
                    out[#out + 1] = { map = sp.map, x = sp.x, y = sp.y, what = nd.name }
                end
            end
        end
    end
    -- an item another quest hands out (the user, 2026-11-12, Catch of the Day: the fish come from
    -- Jinar'Zillen's "Fish in a Bucket"): the stop is that quest's giver, and the step says so
    local placed = {}
    for _, key in ipairs(order) do
        local nd = needs[key]
        if nd.name and busiest(nd.refs) then placed[nd.name:lower()] = true end
    end
    for _, s in ipairs(VQ.Forever and VQ.Forever.ItemSources and VQ.Forever:ItemSources(qid) or {}) do
        if s.spot and not placed[s.item:lower()] then
            out[#out + 1] = { map = s.spot.m, x = s.spot.x, y = s.spot.y,
                what = ("%s (take '%s'%s)"):format(s.item, s.title or "?", s.giver and (" from " .. s.giver) or ""),
                always = true }   -- the step says where the item comes from even when it is the only stop
        end
    end
    if #out == 0 then
        local m, x, y = safe(C_QuestLog.GetNextWaypoint, qid)
        if m and m > 0 and x and y and x > 0 then out[1] = { map = m, x = x, y = y } end
    end
    -- nearest-first order between the places (the planner can still move each one)
    for i = 2, #out do
        local prev, bi, bd = out[i - 1], nil, nil
        for j = i, #out do
            local d = (out[j].map == prev.map) and ((out[j].x - prev.x) ^ 2 + (out[j].y - prev.y) ^ 2) or 99
            if not bd or d < bd then bi, bd = j, d end
        end
        out[i], out[bi] = out[bi], out[i]
    end
    return out
end
-- one spot (kept for callers that only need where a quest's work is)
local function objectiveSpot(qid)
    local list = objectiveSpots(qid)
    return list[1]
end

-- An NPC's spot by name: VoidGPS's places, else where that NPC gives a quest.
local npcSpots = {}
local function npcSpot(name)
    if not name then return nil end
    if npcSpots[name] ~= nil then return npcSpots[name] or nil end
    local at = VoidGPS and VoidGPS.FindNPC and safe(VoidGPS.FindNPC, VoidGPS, name)
    local spot = at and at.map and { map = at.map, x = at.x, y = at.y } or nil
    if not spot and VQ.Starts then
        for q in pairs(VQ.ForeverQuests) do
            if VQ.Starts:Giver(q) == name then
                local s = VQ.Starts:Get(q)
                if s and s.m and s.x and s.x > 0 then spot = { map = s.m, x = s.x, y = s.y }; break end
            end
        end
    end
    npcSpots[name] = spot or false
    return spot
end

-- -> spot, who, guessed. Turn-in NPC unknown (the user, 2026-11-11: "Helcular's Revenge" part 2
-- has a giver but no known turn-in, so the plan dropped it): most quests go back to whoever gave
-- them, so the giver is assumed and the plan says "probably".
local function turninSpot(qid)
    local who = VQ.Starts and VQ.Starts:Turnin(qid)
    -- where it's really handed in: your own turn-in, else NorgannonDB's finisher (objects too)
    local ts = VQ.Starts and VQ.Starts.TurninSpot and VQ.Starts:TurninSpot(qid)
    if ts then return { map = ts.m, x = ts.x, y = ts.y }, who end
    local s = npcSpot(who)
    if s then return s, who end
    if safe(C_QuestLog.IsComplete, qid) then
        local m, x, y = safe(C_QuestLog.GetNextWaypoint, qid)
        if m and m > 0 and x and y and x > 0 then return { map = m, x = x, y = y }, who end
    end
    if not who and VQ.Starts then
        local giver = VQ.Starts:Giver(qid)
        local g = npcSpot(giver)
        if not g then
            local st = VQ.Starts:Get(qid)
            if st and st.m and st.x and st.x > 0 then g = { map = st.m, x = st.x, y = st.y } end
        end
        if g then return g, giver, true end
    end
    return nil, who
end

-- Seconds of work left on a quest: what players took (QuestTime, scaled to what's left), else a
-- guess by what's left to do. Drops are luck (the user, 2026-11-11: "took longer than 2 min" for
-- a 0/1 drop): ~75 s per item still needed, a kill ~30 s, an object ~40 s, plus 2 minutes to get
-- going.
local PER = { d = 75, k = 30, o = 40 }
local function guessPer(qid)
    local per = 30
    for _, r in ipairs(VQ.ForeverMobs and VQ.ForeverMobs[qid] or {}) do
        if (PER[r[1]] or 0) > per then per = PER[r[1]] end
    end
    return per
end
local function workLeft(qid)
    local have, need = 0, 0
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
        local r = tonumber(o.numRequired) or 1
        need = need + r
        have = have + math.min(r, tonumber(o.numFulfilled) or (o.finished and r or 0))
    end
    local left = need > 0 and (need - have) / need or 1
    local m = VQ.QuestTime and VQ.QuestTime:Minutes(qid)
    if m then return math.max(60, m * 60 * left) end
    return math.min(1800, 120 + (need - have) * guessPer(qid))
end

----------------------------------------------------------------------
-- Travel
----------------------------------------------------------------------
local function worldPos(s)
    local ok, cont, wp = pcall(C_Map.GetWorldPosFromMapPos, s.map, CreateVector2D(s.x, s.y))
    if ok and cont and wp then return cont, wp.x, wp.y end
end
local links
local function travel(a, b)
    if a.map == b.map and math.abs(a.x - b.x) < SAME_SPOT and math.abs(a.y - b.y) < SAME_SPOT then return 0 end
    if VoidGPS and VoidGPS.TravelTime then
        local from = nil   -- nil = where you stand (the start)
        if not a.here then from = a end
        local sec = safe(VoidGPS.TravelTime, VoidGPS, from, b, links)
        if sec then return sec end
    end
    local c1, x1, y1 = worldPos(a)
    local c2, x2, y2 = worldPos(b)
    if c1 and c2 and c1 == c2 then return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2) * 1.3 / RUN end
    return 1800   -- another continent with no known way: put it last
end

----------------------------------------------------------------------
-- Planning
----------------------------------------------------------------------
local function questLevel(qid)
    local lvl = safe(C_QuestLog.GetQuestDifficultyLevel, qid)
    return (lvl and not secret(lvl)) and lvl or 0
end

-- -> plan = { steps = { stop... }, sec, travel, work, xp, quests, skipped = { group, grey, unknown } }
-- The next quests after one: quests whose earlier-quest rule names it (ForeverRules pa / py) and
-- confirmed chain links (Chains.lua, NorgannonDB + learned live).
local rulesNext, rulesFrom
local function followersOf(x)
    if not rulesNext or rulesFrom ~= VQ.ForeverRules then   -- built once per rule table
        rulesNext, rulesFrom = {}, VQ.ForeverRules
        for y, rr in pairs(VQ.ForeverRules or {}) do
            for _, lst in ipairs({ rr.pa or {}, rr.py or {} }) do
                for _, a in ipairs(lst) do
                    rulesNext[a] = rulesNext[a] or {}
                    table.insert(rulesNext[a], y)
                end
            end
        end
    end
    local out, seen = {}, {}
    for _, y in ipairs(rulesNext[x] or {}) do
        if not seen[y] then seen[y] = true; out[#out + 1] = y end
    end
    local nx = VQ.Chains and VQ.Chains.NextOf and VQ.Chains.NextOf(x)
    for y, v in pairs(nx or {}) do
        if (tonumber(v) or 0) >= 2 and not seen[y] then seen[y] = true; out[#out + 1] = y end
    end
    return out
end

-- the zone a map belongs to (towns, caves and floors roll up)
local function zoneOf(mapID)
    local ZONE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
    local info, hops = mapID and safe(C_Map.GetMapInfo, mapID), 0
    while info and info.mapType and info.mapType > ZONE and info.parentMapID and hops < 6 do
        info, hops = safe(C_Map.GetMapInfo, info.parentMapID), hops + 1
    end
    return info and info.mapID or mapID
end

-- -> plan = { steps = { stop... }, sec, travel, work, xp, quests, picks, skipped = { group, grey, unknown, pvp } }
-- A stop = { kind = "pickup" | "do" | "turnin", q, who, map, x, y, work, travel }; q.seq = its stops in order.
function P:Build()
    local me = UnitLevel("player") or 1
    -- the game's grey line, as QuestStarts uses (Codex 11-12: GetQuestGreenRange isn't on WoW Forever, so
    -- the fallback 5 called a level 30's level 24 quests grey; the real range there is 8)
    local green = safe(UnitQuestTrivialLevelRange, "player") or (GetQuestGreenRange and safe(GetQuestGreenRange)) or 5
    local stops, skipped = {}, { group = {}, grey = {}, unknown = {}, pvp = {}, here = {} }
    local quests, xp = 0, 0
    local hereMap = safe(C_Map.GetBestMapForUnit, "player")
    local hp = hereMap and safe(C_Map.GetPlayerMapPosition, hereMap, "player")
    local hx, hy
    if hp and hp.GetXY then hx, hy = hp:GetXY() end
    if not (hereMap and hx) or secret(hx) then return nil, "can't see where you are (in an instance or a loading screen?)" end
    local start = { map = hereMap, x = hx, y = hy, here = true }
    local function levelFactor(lvl)
        if not lvl or lvl <= 0 then return 1 end
        local d = lvl - me
        if d > 0 then return 1 + PER_LEVEL_UP * d end
        return math.max(MIN_FACTOR, 1 + PER_LEVEL_DOWN * d)
    end
    local xpNow, xpMax = UnitXP and UnitXP("player") or 0, UnitXPMax and UnitXPMax("player") or 0
    -- XP still to earn before a quest this far above you comes up (nil = no wait)
    local function minXPFor(lvl)
        if not lvl or lvl - me < UP_LEVEL or xpMax <= 0 then return nil end
        local need = (lvl - 1 - me) * xpMax - xpNow
        return need > 0 and need or nil
    end
    links = VoidGPS and VoidGPS.TravelLinks and safe(VoidGPS.TravelLinks, VoidGPS) or nil
    wipe(npcSpots)
    local function addStop(q, st)
        st.q = q
        stops[#stops + 1] = st
        q.seq[#q.seq + 1] = #stops
    end

    -- the quests in your log
    local logQ = {}
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        local qid = info and not info.isHeader and info.questID
        local r = qid and VQ.ForeverQuests[qid]
        if r and quests < MAX_QUESTS then
            local title = info.title or r[1]
            local flags = r[6] or ""
            local lvl = questLevel(qid)
            local done = safe(C_QuestLog.IsComplete, qid)
            if flags:find("P") then
                skipped.pvp[#skipped.pvp + 1] = title   -- Conflict at Darkspear Islands: no place to walk to
            elseif flags:find("[DRE]") then
                skipped.group[#skipped.group + 1] = title
            elseif lvl > 0 and lvl < me - green and not done then
                skipped.grey[#skipped.grey + 1] = title
            else
                local tin, who, guessed = turninSpot(qid)
                local objs = not done and objectiveSpots(qid) or {}
                if not tin or (not done and #objs == 0) then
                    skipped.unknown[#skipped.unknown + 1] = title
                else
                    quests = quests + 1
                    xp = xp + (tonumber(r[4]) or 0)
                    local q = { qid = qid, title = title, lvl = lvl, seq = {}, xp = tonumber(r[4]) or 0, minXP = minXPFor(lvl) }
                    local w = workLeft(qid) * levelFactor(lvl) / math.max(1, #objs)
                    for _, o in ipairs(objs) do addStop(q, { kind = "do", map = o.map, x = o.x, y = o.y, what = (#objs > 1 or o.always) and o.what or nil, work = w }) end
                    addStop(q, { kind = "turnin", who = who, map = tin.map, x = tin.x, y = tin.y, work = TURNIN_SEC, guessed = guessed })
                    logQ[#logQ + 1] = q
                end
            end
        end
    end

    -- quests you could pick up: their giver in a zone the route goes through (or yours), you can
    -- take them now, not grey / group / PvP / repeatable, and every place known (the user,
    -- 2026-11-11: "should it not include quests i could pick up")
    local candQ = {}
    local F = VQ.Forever
    if F and F.Spot and F.Status and F.Available then
        local zones = { [zoneOf(hereMap)] = true }
        for _, st in ipairs(stops) do zones[zoneOf(st.map)] = true end
        local inLog = {}
        for _, q in ipairs(logQ) do inLog[q.qid] = true end
        -- quests in the zone you're in come first and get a lower bar (the user, 2026-11-11, in Tarren
        -- Mill: "there are 4 other quests here, why would it not suggest to get those"); the ones
        -- left out are listed with why (skipped.here)
        local hereZone = zoneOf(hereMap)
        local found = {}
        local function leftOut(r, why) skipped.here[#skipped.here + 1] = ("%s (%s)"):format(r[1], why) end
        for qid, r in pairs(VQ.ForeverQuests) do
            if not inLog[qid] then
                local sp = safe(F.Spot, F, qid)
                local z = sp and sp.m and sp.x and zoneOf(sp.m)
                if z and zones[z] and F:Status(qid) == "open" and F:Available(qid) then
                    local here = z == hereZone
                    local flags = r[6] or ""
                    local lvl = (F.Level and safe(F.Level, F, qid)) or 0
                    if flags:find("[DRE]") then
                        if here then leftOut(r, "bring a group") end
                    elseif flags:find("[Pdwr]") then
                        -- PvP / daily / weekly / repeatable: not part of a leveling plan
                    elseif lvl > 0 and lvl < me - green then
                        if here then leftOut(r, "grey") end
                    elseif lvl > me + 2 then
                        if here then leftOut(r, "level " .. lvl) end
                    else
                        found[#found + 1] = { qid = qid, r = r, sp = sp, lvl = lvl, here = here }
                    end
                end
            end
        end
        table.sort(found, function(a, b)
            if a.here ~= b.here then return a.here end
            return (tonumber(a.r[4]) or 0) > (tonumber(b.r[4]) or 0)
        end)
        for _, c in ipairs(found) do
            if #candQ >= PICK_TRY then break end
            local objs = objectiveSpots(c.qid)
            local tin, who, guessed = turninSpot(c.qid)
            if not (#objs > 0 and tin) then
                if c.here then leftOut(c.r, "no known place yet") end
            else
                local q = { qid = c.qid, title = c.r[1], lvl = c.lvl, seq = {}, xp = tonumber(c.r[4]) or 0, pick = true, here = c.here, minXP = minXPFor(c.lvl) }
                local m = VQ.QuestTime and VQ.QuestTime:Minutes(c.qid)
                addStop(q, { kind = "pickup", who = VQ.Starts and VQ.Starts:Giver(c.qid), map = c.sp.m, x = c.sp.x, y = c.sp.y, work = TURNIN_SEC })
                local w = (m and m * 60 or (PICK_WORK * guessPer(c.qid) / 30)) * levelFactor(c.lvl) / #objs
                for _, o in ipairs(objs) do addStop(q, { kind = "do", map = o.map, x = o.x, y = o.y, what = (#objs > 1 or o.always) and o.what or nil, work = w }) end
                addStop(q, { kind = "turnin", who = who, map = tin.map, x = tin.x, y = tin.y, work = TURNIN_SEC, guessed = guessed })
                candQ[#candQ + 1] = q
            end
        end
    end

    -- travel times, asked once per pair (0 = you)
    local n = #stops
    local pts = { [0] = start }
    for i = 1, n do pts[i] = stops[i] end
    local memo = {}
    local function T(a, b)
        local k = a * 1000 + b
        local v = memo[k]
        if not v then v = travel(pts[a], pts[b]); memo[k] = v end
        return v
    end
    local function cost(route)
        local c, prev = 0, 0
        for _, s1 in ipairs(route) do c = c + T(prev, s1); prev = s1 end
        return c
    end
    local function valid(route)
        local pos = {}
        for i, s1 in ipairs(route) do pos[s1] = i end
        for _, s1 in ipairs(route) do
            local q = stops[s1].q
            local seq = q.seq
            for k = 2, #seq do
                if pos[seq[k - 1]] and pos[seq[k]] and pos[seq[k - 1]] > pos[seq[k]] then return false end
            end
            if q.after and pos[q.after] and pos[seq[1]] and pos[q.after] > pos[seq[1]] then return false end
            for _, a in ipairs(q.afterAll or {}) do
                if pos[a] and pos[seq[1]] and pos[a] > pos[seq[1]] then return false end
            end
        end
        -- up-level quests: enough XP turned in before their first stop, or nothing else after it
        local lastPlain = 0
        for i, s1 in ipairs(route) do if not stops[s1].q.minXP then lastPlain = i end end
        local cum = 0
        for i, s1 in ipairs(route) do
            local st = stops[s1]
            local q = st.q
            if q.minXP and s1 == q.seq[1] and cum < q.minXP and i < lastPlain then return false end
            if st.kind == "turnin" then cum = cum + (q.xp or 0) end
        end
        return true
    end
    -- where an up-level quest may start: once the turn-ins before it reach its XP, else after
    -- every other quest's stops
    local function fromFor(route, q)
        if not q.minXP then return 0 end
        local cum, lastPlain = 0, 0
        for i, s1 in ipairs(route) do
            local st = stops[s1]
            if st.kind == "turnin" then cum = cum + (st.q.xp or 0) end
            if cum >= q.minXP then return i end
            if not st.q.minXP then lastPlain = i end
        end
        return lastPlain
    end

    -- Put a quest's stops in where they cost least, in their order. Only the added time is worked
    -- out. -> the new route, the time it adds
    local function insertQuest(route, q, from)
        from = math.max(from or 0, fromFor(route, q))   -- after route[from]: its opener, its level
        local function at(k) return k == 0 and 0 or route[k] end
        local function added(k, s1)   -- s1 between route[k] and route[k + 1]
            local nx = route[k + 1]
            if not nx then return T(at(k), s1) end
            return T(at(k), s1) + T(s1, nx) - T(at(k), nx)
        end
        local seq, L = q.seq, #route
        local r = {}
        for k = 1, L do r[k] = route[k] end
        if #seq == 1 then
            local bp, bc
            for p = from, L do
                local c = added(p, seq[1])
                if not bc or c < bc then bp, bc = p, c end
            end
            table.insert(r, bp + 1, seq[1])
            return r, bc
        end
        -- the first two as a pair: a after route[p], b after route[t] (t >= p)
        local a, b = seq[1], seq[2]
        local bp, bt, bc
        for p = from, L do
            local da = added(p, a)
            for t = p, L do
                local c
                if t == p then
                    local nx = route[p + 1]
                    c = T(at(p), a) + T(a, b) + (nx and (T(b, nx) - T(at(p), nx)) or 0)
                else
                    c = da + added(t, b)
                end
                if not bc or c < bc then bp, bt, bc = p, t, c end
            end
        end
        table.insert(r, bt + 1, b)
        table.insert(r, bp + 1, a)
        -- every further stop (more places to do it, then the turn-in): anywhere after the one before
        local total = bc
        for i = 3, #seq do
            local posPrev
            for k, s1 in ipairs(r) do if s1 == seq[i - 1] then posPrev = k end end
            local before = cost(r)
            local best, bestC
            for p = posPrev, #r do
                local t2 = {}
                for k = 1, #r do t2[k] = r[k] end
                table.insert(t2, p + 1, seq[i])
                local c = cost(t2)
                if not bestC or c < bestC then best, bestC = t2, c end
            end
            r, total = best, total + (bestC - before)
        end
        return r, total
    end

    local route = {}
    for _, q in ipairs(logQ) do if not q.minXP then route = insertQuest(route, q) end end
    for _, q in ipairs(logQ) do if q.minXP then route = insertQuest(route, q) end end
    local function workOf(q) local w = 0 for _, s1 in ipairs(q.seq) do w = w + stops[s1].work end return w end
    local function rateNow()
        local w = 0
        for _, s1 in ipairs(route) do w = w + stops[s1].work end
        return (#route > 0 and xp > 0) and xp / math.max(60, cost(route) + w) or 0
    end

    -- Follow-ups: the next quest in a chain opens when the plan turns in the one before (the user,
    -- 2026-11-11: "there is a second quest to hercules revenge, why does the route not tell me to
    -- get it"). For each quest the plan turns in: could you take its follow-up once that's done
    -- (F.assumeDone)? Then pick it up right after, do it, turn it in; up to 3 links deep.
    local follows = 0
    if F and F.Available and F.Spot then
        local planned, turned, frontier = {}, {}, {}
        for _, q in ipairs(logQ) do planned[q.qid], turned[q.qid] = q, true; frontier[#frontier + 1] = q end
        for _ = 1, 3 do
            local nextFrontier = {}
            for _, x in ipairs(frontier) do
                for _, y in ipairs(followersOf(x.qid)) do
                    local r = VQ.ForeverQuests[y]
                    if r and follows < FOLLOW_MAX and not planned[y] and not (r[6] or ""):find("[DREPdwr]")
                        and not safe(C_QuestLog.IsQuestFlaggedCompleted, y) and not safe(C_QuestLog.GetLogIndexForQuestID, y) then
                        F.assumeDone = turned
                        local ok = safe(F.Available, F, y)
                        F.assumeDone = nil
                        local sp = ok and safe(F.Spot, F, y)
                        local tin, who, guessed = turninSpot(y)
                        local objs = (sp and tin) and objectiveSpots(y) or {}
                        -- objectives with no known place: its work can't be planned, so it isn't free XP
                        -- (a talk / delivery follow-up has no objectives at all and stays; Codex 11-12)
                        local needs = VQ.ForeverMobs and VQ.ForeverMobs[y]
                        if sp and tin and not (#objs == 0 and needs and #needs > 0) then
                            local m = VQ.QuestTime and VQ.QuestTime:Minutes(y)
                            local q = { qid = y, title = r[1], lvl = (F.Level and safe(F.Level, F, y)) or 0, seq = {},
                                xp = tonumber(r[4]) or 0, pick = true, follow = true, after = x.seq[#x.seq] }
                            q.minXP = minXPFor(q.lvl)
                            -- needs ALL of several earlier quests (rules pa): after every one the plan turns in
                            -- (Codex 11-12: only the one it was found from was waited for)
                            local rr = VQ.ForeverRules and VQ.ForeverRules[y]
                            q.afterAll = {}
                            for _, a in ipairs(rr and rr.pa or {}) do
                                local pq = planned[a]
                                if pq and pq.seq[#pq.seq] then q.afterAll[#q.afterAll + 1] = pq.seq[#pq.seq] end
                            end
                            addStop(q, { kind = "pickup", who = VQ.Starts and VQ.Starts:Giver(y), map = sp.m, x = sp.x, y = sp.y, work = TURNIN_SEC })
                            local w = (m and m * 60 or (PICK_WORK * guessPer(y) / 30)) * levelFactor(q.lvl) / math.max(1, #objs)
                            for _, o in ipairs(objs) do addStop(q, { kind = "do", map = o.map, x = o.x, y = o.y, what = (#objs > 1 or o.always) and o.what or nil, work = w }) end
                            addStop(q, { kind = "turnin", who = who, map = tin.map, x = tin.x, y = tin.y, work = TURNIN_SEC, guessed = guessed })
                            for k = #pts + 1, #stops do pts[k] = stops[k] end
                            local posAfter
                            local waitFor = { [q.after] = true }
                            for _, a in ipairs(q.afterAll) do waitFor[a] = true end
                            for i, s1 in ipairs(route) do if waitFor[s1] then posAfter = i end end   -- the last of them
                            if posAfter then
                                local r2, add = insertQuest(route, q, posAfter)
                                if q.xp / math.max(60, add + workOf(q)) >= rateNow() * FOLLOW_RATE then
                                    route, xp, follows = r2, xp + q.xp, follows + 1
                                    planned[y], turned[y] = q, true
                                    nextFrontier[#nextFrontier + 1] = q
                                end
                            end
                        end
                    end
                end
            end
            frontier = nextFrontier
            if #frontier == 0 then break end
        end
    end

    -- quests to pick up: kept when their XP for the extra time is at least as good as the plan's
    -- own XP per hour (any, when the log has nothing to plan), best first, at most PICK_MAX
    local baseWork = 0
    for _, s1 in ipairs(route) do baseWork = baseWork + stops[s1].work end
    local baseRate = (#route > 0 and xp > 0) and xp / (cost(route) + baseWork) or 0
    local tries = {}
    for _, q in ipairs(candQ) do
        local _, add = insertQuest(route, q)
        local extra = add + workOf(q)
        tries[#tries + 1] = { q = q, rate = q.xp / math.max(60, extra) }
    end
    table.sort(tries, function(a, b) return a.rate > b.rate end)
    local picks = 0
    for _, t in ipairs(tries) do
        if picks >= PICK_MAX then
            if t.q.here then skipped.here[#skipped.here + 1] = ("%s (plan full)"):format(t.q.title) end
        else
        t.tried = true
        local r, add = insertQuest(route, t.q)
        local rate = t.q.xp / math.max(60, add + workOf(t.q))
        if rate >= baseRate * (t.q.here and HERE_RATE or PICK_RATE) then
            route, picks = r, picks + 1
            xp = xp + t.q.xp
            -- the bar rises with each pick: the next one has to match the plan as it is now
            local w = 0
            for _, s1 in ipairs(route) do w = w + stops[s1].work end
            baseRate = xp / math.max(60, cost(route) + w)
        elseif t.q.here then
            skipped.here[#skipped.here + 1] = ("%s (little XP for the time)"):format(t.q.title)
        end
        end
    end

    -- Areas to discover on the way (the user, 2026-11-11: "explore on the route"; Explore Azeroth is
    -- a Legacy point): an area you haven't discovered in a zone the route goes through, kept when
    -- going there adds at most EXPLORE_DETOUR of travel; cheapest first, at most EXPLORE_MAX.
    local explores = 0
    local XP = _G.VoidExplore
    if XP and XP.Undiscovered then
        local zl = { [zoneOf(hereMap)] = true }
        for _, s1 in ipairs(route) do zl[zoneOf(stops[s1].map)] = true end
        local tries2 = {}
        for z in pairs(zl) do
            for _, a in ipairs(safe(XP.Undiscovered, XP, z) or {}) do
                local q = { title = a.name, zone = a.zone, seq = {}, explore = true }
                addStop(q, { kind = "explore", map = a.map, x = a.x, y = a.y, work = 10 })
                for k = #pts + 1, #stops do pts[k] = stops[k] end
                local _, add = insertQuest(route, q)
                tries2[#tries2 + 1] = { q = q, add = add }
            end
        end
        table.sort(tries2, function(a, b) return a.add < b.add end)
        for _, t in ipairs(tries2) do
            if explores >= EXPLORE_MAX then break end
            local r2, add = insertQuest(route, t.q)
            if add <= EXPLORE_DETOUR then route, explores = r2, explores + 1 end
        end
    end

    -- move single stops while that saves time (a few passes)
    local cur = cost(route)
    for _ = 1, 4 do
        local improved = false
        for i = 1, #route do
            for j = 1, #route do
                if i ~= j then
                    local r = {}
                    for k = 1, #route do if k ~= i then r[#r + 1] = route[k] end end
                    table.insert(r, math.min(j, #r + 1), route[i])
                    if valid(r) then
                        local c = cost(r)
                        if c < cur - 1 then route, cur, improved = r, c, true end
                    end
                end
            end
        end
        if not improved then break end
    end

    local steps, work, prev = {}, 0, 0
    for _, s1 in ipairs(route) do
        local st = stops[s1]
        st.travel = T(prev, s1)
        work = work + st.work
        steps[#steps + 1] = st
        prev = s1
    end
    local tr = cost(route)
    return { steps = steps, sec = tr + work, travel = tr, work = work, xp = xp, quests = quests, picks = picks, follows = follows, explores = explores,
        skipped = skipped, at = time() }
end

----------------------------------------------------------------------
-- The window
----------------------------------------------------------------------
local W, rows = nil, {}
local ROW_H = 16

local function mins(sec)
    local m = math.floor(sec / 60 + 0.5)
    if m >= 60 then return ("%d h %d min"):format(math.floor(m / 60), m % 60) end
    return ("%d min"):format(math.max(1, m))
end
local function zoneName(map)
    local i = map and safe(C_Map.GetMapInfo, map)
    return i and i.name or "?"
end
local function num(n) return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n) end

local function go(st)
    if not st then return end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID and safe(C_QuestLog.GetLogIndexForQuestID, st.q.qid) then
        if C_QuestLog.AddQuestWatch then pcall(C_QuestLog.AddQuestWatch, st.q.qid) end
        pcall(C_SuperTrack.SetSuperTrackedQuestID, st.q.qid)
    end
    if VoidGPS and VoidGPS.RouteTo then
        VoidGPS:RouteTo({ name = st.kind == "turnin" and (st.who or st.q.title) or st.q.title,
            sub = (st.kind == "turnin" and ("turn in " .. st.q.title)) or (st.kind == "explore" and "discover") or "quest", map = st.map, x = st.x, y = st.y })
    end
end

local function row(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, W.child)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r:SetPoint("RIGHT", W.child, "RIGHT", 0, 0)
    r.text = r:CreateFontString(nil, "OVERLAY"); VQ:SetFont(r.text, 11)
    r.text:SetPoint("LEFT", 2, 0); r.text:SetPoint("RIGHT", -2, 0); r.text:SetJustifyH("LEFT"); r.text:SetWordWrap(false)
    local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.08)
    r:SetScript("OnClick", function(s) go(s.st) end)
    r:SetScript("OnEnter", function(s)
        if not s.st then return end
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        GameTooltip:AddLine(s.st.q.title, 1, 0.82, 0)
        if s.st.kind == "explore" then
            GameTooltip:AddLine("Discover this area: it counts toward Explore " .. (s.st.q.zone or "") .. ", and Explore Azeroth is a Legacy point. It's on your way.", 1, 1, 1, true)
        elseif s.st.kind == "pickup" then
            GameTooltip:AddLine("Pick up" .. (s.st.who and (" from " .. s.st.who) or "") .. ": on your way, worth the detour", 1, 1, 1, true)
        elseif s.st.kind == "turnin" then
            GameTooltip:AddLine("Turn in" .. (s.st.who and (" to " .. s.st.who) or ""), 1, 1, 1)
            if s.st.guessed then GameTooltip:AddLine("Where it's handed in isn't known yet: most quests go back to whoever gave them.", .7, .7, .7, true) end
        else
            GameTooltip:AddLine(("Do it: about %s%s"):format(mins(s.st.work),
                (VQ.QuestTime and VQ.QuestTime:Minutes(s.st.q.qid)) and " (players' time)" or " (a guess from what's left)"), 1, 1, 1)
        end
        GameTooltip:AddLine(zoneName(s.st.map) .. (s.st.travel > 20 and (" · ~%s to get there"):format(mins(s.st.travel)) or ""), .53, .8, 1)
        GameTooltip:AddLine("Click: guide me there (VoidGPS) and track the quest", .6, .6, .6)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rows[i] = r
    return r
end

local function render()
    if not (W and W:IsShown()) then return end
    for _, r in ipairs(rows) do r:Hide(); r.st = nil end
    local plan, why = P:Build()
    if not plan then W.summary:SetText("|cffff8040" .. (why or "No plan") .. "|r"); W.foot:SetText(""); return end
    if #plan.steps == 0 then
        W.summary:SetText("Nothing to plan: no quests you can do solo with a known place.")
    else
        local per = plan.sec > 0 and math.floor(plan.xp * 3600 / plan.sec / 100 + 0.5) * 100 or 0
        local np = (plan.picks or 0) + (plan.follows or 0)
        local picks = (np > 0 and (" + %d to pick up"):format(np) or "")
            .. ((plan.explores or 0) > 0 and (" + %d area%s to discover"):format(plan.explores, plan.explores == 1 and "" or "s") or "")
        W.summary:SetText(("|cffffd200%d quests%s|r · about %s (%s on the way) · %s XP · ~%s XP/hour"):format(
            plan.quests, picks, mins(plan.sec), mins(plan.travel), num(plan.xp), num(per)))
    end
    local lastZone
    local i = 0
    for n, st in ipairs(plan.steps) do
        local z = zoneName(st.map)
        local tag = (VQ.Guide and VQ.Guide.LevelTag) and VQ.Guide.LevelTag(st.q.qid) or ""
        local who = st.who and (" |cff999999(" .. (st.guessed and "probably " or "") .. st.who .. ")|r") or ""
        local verb = (st.kind == "explore" and ("|cff88ccffDiscover|r " .. st.q.title .. " |cff999999(Explore " .. (st.q.zone or "") .. ")|r"))
            or (st.kind == "turnin" and ("|cff55ff55Turn in|r " .. tag .. st.q.title .. who))
            or (st.kind == "pickup" and ("|cffffd200Pick up|r " .. (st.q.follow and "|cff88ccff(next in chain)|r " or "") .. tag .. st.q.title .. who))
            or ("Do " .. tag .. st.q.title .. (st.what and (": " .. st.what) or "") .. (" |cff999999~%s|r"):format(mins(st.work)))
        local way = st.travel > 20 and ("|cff88ccff[%s%s]|r "):format(z ~= lastZone and (z .. ", ") or "", mins(st.travel)) or ""
        i = i + 1
        local r = row(i)
        r.st = st
        r.text:SetText(("%d. %s%s"):format(n, way, verb))
        r:Show()
        lastZone = z
    end
    W.child:SetHeight(math.max(1, i * ROW_H))
    local foot = {}
    local sk = plan.skipped
    if #sk.group > 0 then foot[#foot + 1] = "|cffff8040Bring a group:|r " .. table.concat(sk.group, ", ") end
    if #sk.here > 0 then foot[#foot + 1] = "|cffffd200Here, left out:|r " .. table.concat(sk.here, ", ") end
    if #sk.pvp > 0 then foot[#foot + 1] = "|cffff5050PvP:|r " .. table.concat(sk.pvp, ", ") end
    if #sk.unknown > 0 then foot[#foot + 1] = "|cffaaaaaaNo known place yet:|r " .. table.concat(sk.unknown, ", ") end
    if #sk.grey > 0 then foot[#foot + 1] = "|cff999999Grey, left out:|r " .. table.concat(sk.grey, ", ") end
    if not (VoidGPS and VoidGPS.TravelTime) then foot[#foot + 1] = "|cffaaaaaaWith VoidGPS the way between stops counts flight paths and zeppelins.|r" end
    W.foot:SetText(table.concat(foot, "\n"))
    -- tall enough for every step (the first plan with pick-ups hid its last steps under the notes,
    -- the user's screen 2026-11-11), up to most of the screen; the rest scrolls
    local want = 36 + (W.summary:GetStringHeight() or 14) + 6 + i * ROW_H + 6 + (W.foot:GetStringHeight() or 0) + 36
    local maxH = (UIParent:GetHeight() or 800) * 0.85
    W:SetHeight(math.max(200, math.min(maxH, want)))
    W.scroll:SetVerticalScroll(0)
end
P.Render = render

local function build()
    if W then return W end
    W = CreateFrame("Frame", "VoidQuestRouteFrame", UIParent, "BackdropTemplate")
    W:SetSize(520, 420)
    W:SetPoint("CENTER", 180, 40)
    VQ:CreateBackdrop(W, 0.94)
    W:SetFrameStrata("HIGH")
    W:SetMovable(true); W:EnableMouse(true); W:RegisterForDrag("LeftButton")
    W:SetScript("OnDragStart", W.StartMoving); W:SetScript("OnDragStop", W.StopMovingOrSizing)
    ns.Move(W, { db = function() return VoidQuestDB end, key = "route" })   -- drag + kept after a restart (VoidMove.lua)
    W:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "VoidQuestRouteFrame")
    local title = W:CreateFontString(nil, "OVERLAY"); VQ:SetFont(title, 13, "OUTLINE")
    title:SetPoint("TOPLEFT", 10, -8); title:SetText("|cff00c7ffVoidQuest|r Route: the best order for your quests")
    local close = CreateFrame("Button", nil, W, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    W.summary = W:CreateFontString(nil, "OVERLAY"); VQ:SetFont(W.summary, 11)
    W.summary:SetPoint("TOPLEFT", 10, -28); W.summary:SetPoint("RIGHT", -10, 0); W.summary:SetJustifyH("LEFT")
    local refresh = CreateFrame("Button", nil, W, "UIPanelButtonTemplate")
    refresh:SetSize(70, 18); refresh:SetPoint("BOTTOMRIGHT", -8, 8); refresh:SetText("Plan again")
    refresh:SetScript("OnClick", render)
    W.foot = W:CreateFontString(nil, "OVERLAY"); VQ:SetFont(W.foot, 10)
    W.foot:SetPoint("BOTTOMLEFT", 10, 30); W.foot:SetPoint("RIGHT", -10, 0); W.foot:SetJustifyH("LEFT"); W.foot:SetJustifyV("BOTTOM")
    W.foot:SetMaxLines(6)
    local scroll = CreateFrame("ScrollFrame", nil, W)
    -- between the summary (one or two lines) and the notes (their height changes with what's left out)
    scroll:SetPoint("TOPLEFT", W.summary, "BOTTOMLEFT", -2, -6)
    scroll:SetPoint("BOTTOMRIGHT", W.foot, "TOPRIGHT", 0, 6)
    W.scroll = scroll
    W.child = CreateFrame("Frame", nil, scroll)
    W.child:SetSize(500, 1)
    scroll:SetScrollChild(W.child)
    scroll:SetScript("OnSizeChanged", function(s, w) W.child:SetWidth(w) end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(s, d)
        local max = math.max(0, W.child:GetHeight() - s:GetHeight())
        s:SetVerticalScroll(math.max(0, math.min(max, s:GetVerticalScroll() - d * 3 * ROW_H)))
    end)
    local hint = W:CreateFontString(nil, "OVERLAY"); VQ:SetFont(hint, 9)
    hint:SetPoint("BOTTOMLEFT", 10, 12); hint:SetTextColor(.6, .6, .6)
    hint:SetText("Click a step: the way there. Plans again when your quest log changes.")
    W:SetScript("OnShow", render)
    W:Hide()
    return W
end

function P:Toggle()
    build()
    W:SetShown(not W:IsShown())
end

-- plan again when the log changes while the window is open: right away when a quest is taken,
-- turned in or dropped; for progress (every kill) at most every PROGRESS_GAP, since planning a
-- full log takes a moment
local PROGRESS_GAP = 30
local queued, lastProgress = false, 0
local ev = CreateFrame("Frame")
-- TAXIMAP_CLOSED: VoidGPS just learned this character's flight paths from that map, and the plan's
-- flights should follow (the user, 2026-11-11: "i opened the flight map over here, if it was
-- collected, it should have already")
for _, e in ipairs({ "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_LOG_UPDATE", "TAXIMAP_CLOSED" }) do ev:RegisterEvent(e) end
ev:SetScript("OnEvent", function(_, e)
    if not (W and W:IsShown()) or queued then return end
    if e == "QUEST_LOG_UPDATE" then
        if GetTime() - lastProgress < PROGRESS_GAP then return end
        lastProgress = GetTime()
    end
    queued = true
    C_Timer.After(1.5, function() queued = false; pcall(render) end)
end)
