----------------------------------------------------------------------
-- VoidQuest — where the quest you're on wants you to go (WoW Forever)
-- The user, 2026-11-09: "if you're on a quest ... the quest shows the dot of the mobs that
-- you need to kill. It doesn't need to show every single dot on the whole map for every
-- single thing." Then, same day: "i didnt want the dots on the world map, i wanted them on
-- the minimap to find while questing." Then (2026-11-10): "i want to know before where they are,
-- not after and i dont want it to stay on the minimap". So: ONE minimap marker per unfinished
-- objective of the quest you're tracking, at its nearest spot: on the minimap's edge pointing
-- the way while it's out of range, at the spot once in range, gone within 25 yards. Red = mobs
-- to kill, yellow = mobs / objects that drop the item it asks for, blue = objects to use.
-- (Before, 2026-11-06: "id rather not have a bunch of dots all over the map" -- that was
-- every drop spot for everything; one quest's objectives is what's wanted.)
--
-- Data: ForeverMobs.lua (tools/cmd/forever-mobs, from NorgannonDB, which reads WoW
-- Forever's own tables). /vq dots turns them off.
----------------------------------------------------------------------
local VQ = VoidQuest
if not VQ or not VQ.ForeverMobs then return end   -- WoW Forever only

local M = {}
VQ.Mobs = M
local inView = {}   -- nameplate unit -> { name, quests = {...} or nil, rare = bool } (mobs in view)

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c, d = pcall(fn, ...) if ok then return a, b, c, d end end
local function secret(v) return issecretvalue and issecretvalue(v) end

local function Enabled() return VQ:Get("mobDots") ~= false end

-- The quest you're on: the one the arrow is tracking.
local function CurrentQuest()
    local q = C_SuperTrack and safe(C_SuperTrack.GetSuperTrackedQuestID)
    if type(q) == "number" and q > 0 and not secret(q) and safe(C_QuestLog.GetLogIndexForQuestID, q) then return q end
    return nil
end

local function ItemName(id)
    local n = safe(C_Item.GetItemNameByID, id)
    if type(n) == "string" and not secret(n) and n ~= "" then return n end
    safe(C_Item.RequestLoadItemDataByID, id)
    return nil
end

-- Each objective of a quest: text (lowercase), finished, have/need.
local function Objectives(qid)
    local out = {}
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
        local t = o.text
        if type(t) == "string" and not secret(t) then
            out[#out + 1] = { text = t:lower(), raw = t, finished = o.finished == true, type = o.type,
                              have = o.numFulfilled, need = o.numRequired }
        end
    end
    return out
end

-- The objective a ref belongs to (by the mob's / item's name in its text), or nil.
local function ObjectiveFor(objs, name)
    if not name then return nil end
    local n = name:lower()
    for _, o in ipairs(objs) do
        if o.text:find(n, 1, true) then return o end
    end
    return nil
end

-- The quests to show: the tracked one when the arrow is on a quest in your log; otherwise
-- (the arrow on a pick-up, or nothing tracked: seen live 2026-11-09, no dots at all) your
-- unfinished quests with spots on this map, at most MAX_QUESTS.
local MAX_QUESTS = 4

-- The game's own objective point per quest on this map ({ [questID] = { x, y } }, 0-1). Forever has
-- one for many Classic quests (seen 2026-11-10: Salt Flat Venom at 79.0, 69.4) but doesn't draw it on
-- the minimap the way retail does: it's the fallback where our spawn data has nothing.
local function GamePOIs(mapID)
    local out = {}
    for _, q in ipairs(safe(C_QuestLog.GetQuestsOnMap, mapID) or {}) do
        local id, x, y = q.questID, q.x, q.y
        if id and x and y and not secret(id) and not secret(x) and not secret(y) and x > 0 and y > 0 then
            out[id] = { x = x, y = y }
        end
    end
    return out
end
local function hasSpotsOn(qid, mapID)
    for _, r in ipairs(VQ.ForeverMobs[qid] or {}) do
        local s = VQ.ForeverSpawns[r[2]]
        if s and s[mapID] then return true end
    end
    return false
end
local function QuestsFor(mapID)
    local q = CurrentQuest()
    if q then
        if safe(C_QuestLog.IsComplete, q) then return {} end
        return { q }
    end
    local out, pois = {}, GamePOIs(mapID)
    local learned = {}   -- quest titles you've seen mobs for on this map
    for _, sm in pairs(VoidQuestDB and VoidQuestDB.seenMobs or {}) do
        if sm.m and sm.m[mapID] then for t in pairs(sm.q or {}) do learned[t] = true end end
    end
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        local qid = info and not info.isHeader and info.questID
        if qid and not secret(qid) and not safe(C_QuestLog.IsComplete, qid)
            and ((VQ.ForeverMobs[qid] and hasSpotsOn(qid, mapID)) or pois[qid] or (info.title and learned[info.title])) then
            out[#out + 1] = qid
            if #out >= MAX_QUESTS then break end
        end
    end
    return out
end

-- Dots for one map: { x, y, kind, name, quest, obj }.
function M:DotsFor(mapID)
    local out = {}
    if not (Enabled() and mapID) then return out end
    local pois
    for _, qid in ipairs(QuestsFor(mapID)) do
        local before = #out
        self:AddQuestDots(out, qid, mapID)
        if #out == before then   -- no spawn data here: the game's own objective point
            pois = pois or GamePOIs(mapID)
            local p = pois[qid]
            if p then
                local title = safe(C_QuestLog.GetTitleForQuestID, qid) or "your quest"
                out[#out + 1] = { x = p.x, y = p.y, kind = "q", name = title, quest = title }
            end
        end
    end
    return out
end

function M:AddQuestDots(out, qid, mapID)
    local refs = VQ.ForeverMobs[qid] or {}   -- none: learned mobs (below) can still mark it
    local title = safe(C_QuestLog.GetTitleForQuestID, qid) or ""
    local objs = Objectives(qid)
    local seen = VoidQuestDB and VoidQuestDB.seenMobs or {}
    local inRefs = {}
    for _, r in ipairs(refs) do
        local kind, key, item = r[1], r[2], r[3]
        inRefs[key] = true
        local name = VQ.ForeverMobNames and VQ.ForeverMobNames[key]
        local o = ObjectiveFor(objs, kind == "d" and ItemName(item) or name)
        if not (o and o.finished) then
            -- NorgannonDB's spots + the spots you've SEEN this mob at (its nameplate came up)
            local npc = tonumber(key:match("^n(%d+)$"))
            local learned = npc and seen[npc] and seen[npc].m and seen[npc].m[mapID] or ""
            local pts = ((VQ.ForeverSpawns[key] and VQ.ForeverSpawns[key][mapID]) or "") .. learned
            if pts ~= "" then
                for i = 1, #pts - 5, 6 do
                    local x, y = tonumber(pts:sub(i, i + 2)), tonumber(pts:sub(i + 3, i + 5))
                    if x and y then
                        out[#out + 1] = { x = x / 1000, y = y / 1000, kind = kind, name = name, item = item,
                                          quest = title, obj = o }
                    end
                end
            end
        end
    end
    -- Mobs our data doesn't link to this quest (Forever's own new ones) that you've seen counting
    -- for it: the game's tooltip said so when their nameplate came up.
    for npc, s in pairs(seen) do
        if s.q and s.q[title] and s.m and s.m[mapID] and not inRefs["n" .. npc] then
            local objText = type(s.q[title]) == "string" and s.q[title] or nil
            local o = ObjectiveFor(objs, objText or s.n)
            if not (o and o.finished) then
                local pts = s.m[mapID]
                for i = 1, #pts - 5, 6 do
                    local x, y = tonumber(pts:sub(i, i + 2)), tonumber(pts:sub(i + 3, i + 5))
                    if x and y then
                        -- an objective named after something else than the mob = it drops it
                        local drop = objText and objText:lower() ~= (s.n or ""):lower()
                        out[#out + 1] = { x = x / 1000, y = y / 1000, kind = drop and "d" or "k", name = s.n,
                                          quest = title, obj = o, objText = drop and objText or nil }
                    end
                end
            end
        end
    end
    return out
end

----------------------------------------------------------------------
-- Minimap dots: placed by hand (the minimap scrolls / rotates), same math as GiverPins.
-- The dot list is rebuilt only when the quest log, the arrow or the map changes.
----------------------------------------------------------------------
local COLOR = { k = { 1, 0.35, 0.25 }, d = { 1, 0.8, 0.15 }, o = { 0.35, 0.75, 1 }, q = { 1, 0.95, 0.55 } }
local SIZE = 7
local MAX_MARKERS = 4   -- objectives shown at once, nearest first
local ARRIVE = 25       -- yards: there, the marker goes (you can see them)
local pool, nActive = {}, 0
local cache = { mapID = nil, dots = {}, dirty = true }

local function onEnter(self)
    local d = self.d
    if not d then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(d.name or "?", 1, 0.82, 0)
    local what = (d.kind == "k" and "Kill for: ") or (d.kind == "o" and "Use for: ")

        or (d.kind == "q" and "Objective area (the game's own) for: ")
        or ("Drops " .. (ItemName(d.item) or d.objText or "the item") .. " for: ")
    GameTooltip:AddLine(what .. d.quest, 1, 1, 1, true)
    if d.obj and d.obj.have and d.obj.need and d.obj.need > 0 then
        GameTooltip:AddLine(("You: %d/%d"):format(d.obj.have, d.obj.need), 0.7, 0.9, 1)
    end
    if self.yards then
        GameTooltip:AddLine(("Nearest spot: %d yd%s"):format(math.floor(self.yards + 0.5),
            self.edge and ", that way" or ""), 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

local function acquire()
    nActive = nActive + 1
    local p = pool[nActive]
    if not p then
        p = CreateFrame("Frame", nil, Minimap)
        p:SetFrameLevel(Minimap:GetFrameLevel() + 4)   -- under GiverPins' "!" (+5)
        p:SetSize(SIZE, SIZE)
        p.dot = p:CreateTexture(nil, "ARTWORK")
        p.dot:SetTexture("Interface\\Buttons\\WHITE8X8")
        p.dot:SetAllPoints()
        local mask = p:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(p.dot)
        p.dot:AddMaskTexture(mask)
        p:EnableMouse(true)
        p:SetScript("OnEnter", onEnter)
        p:SetScript("OnLeave", function() GameTooltip:Hide() end)
        pool[nActive] = p
    end
    p:Show()
    return p
end

local function hideRest()
    for i = nActive + 1, #pool do pool[i]:Hide(); pool[i].d, pool[i].yards = nil, nil end
end

function M:UpdateMinimap()
    nActive = 0
    if not Enabled() then hideRest(); return end
    local mapID = C_Map.GetBestMapForUnit("player")
    local ppos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    local w, h
    if mapID then w, h = C_Map.GetMapWorldSize(mapID) end
    if not (ppos and w and h and w > 0 and h > 0) then hideRest(); return end
    if cache.dirty or cache.mapID ~= mapID then
        cache.mapID, cache.dots, cache.dirty = mapID, self:DotsFor(mapID), false
    end
    local px, py = ppos:GetXY()
    local radius = (C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()) or 133
    if radius <= 0 then radius = 133 end
    local half = Minimap:GetWidth() / 2
    local scale = half / radius
    local rotate = GetCVar("rotateMinimap") == "1"
        and not (C_Minimap and C_Minimap.IsRotateMinimapIgnored and C_Minimap.IsRotateMinimapIgnored())
    local facing = rotate and (GetPlayerFacing() or 0) or 0
    local sinF, cosF = math.sin(facing), math.cos(facing)
    -- One marker per objective, at its NEAREST spot: the user, 2026-11-10: "i want to know
    -- before where they are, not after and i dont want it to stay on the minimap, the intent is
    -- for it to help me find them". (Dots only inside the minimap's range showed up once you
    -- were already there, and stayed.) So:
    --   out of range: the marker sits on the minimap's EDGE, in the direction of the spot
    --   in range:     the marker is at the spot
    --   within ARRIVE yards: gone (you can see them now)
    local nearest = {}
    for _, d in ipairs(cache.dots) do
        -- per OBJECTIVE, not per mob: the three scorpid kinds that all drop Salty Scorpid Venom
        -- are one marker, at the nearest of them (seen live 2026-11-10: three markers for one item)
        -- by objective when known (several mob kinds for one objective = one marker; Sol), else item / mob
        local key = (d.quest or "") .. "|" .. ((d.obj and d.obj.raw) or (d.kind == "d" and d.item and ("item" .. d.item))
            or d.objText or d.name or "")
        local dx, dy = (d.x - px) * w, (d.y - py) * h
        local yd2 = dx * dx + dy * dy
        local n = nearest[key]
        if not n or yd2 < n.yd2 then nearest[key] = { d = d, dx = dx, dy = dy, yd2 = yd2 } end
    end
    local list = {}
    for _, n in pairs(nearest) do
        if n.yd2 > ARRIVE * ARRIVE then list[#list + 1] = n end   -- reached ones don't take a slot (Sol)
    end
    table.sort(list, function(a, b) return a.yd2 < b.yd2 end)
    local edge = half - 6
    for i = 1, math.min(MAX_MARKERS, #list) do
        local n = list[i]
        local yards = math.sqrt(n.yd2)
        if yards > ARRIVE then
            local sx, sy = n.dx * scale, -n.dy * scale
            if rotate then sx, sy = sx * cosF + sy * sinF, -sx * sinF + sy * cosF end
            local r = math.sqrt(sx * sx + sy * sy)
            local onEdge = r > edge
            if onEdge then sx, sy = sx / r * edge, sy / r * edge end
            local p = acquire()
            p.d, p.yards, p.edge = n.d, yards, onEdge
            local c = COLOR[n.d.kind] or COLOR.k
            p:SetSize(onEdge and SIZE + 3 or SIZE, onEdge and SIZE + 3 or SIZE)
            p.dot:SetVertexColor(c[1], c[2], c[3], onEdge and 1 or 0.9)
            p:ClearAllPoints()
            p:SetPoint("CENTER", Minimap, "CENTER", sx, sy)
        end
    end
    -- (No live dot per mob in view: WoW Forever gives an addon no position for a nameplate
    -- mob, like retail -- probed 2026-11-10, GetPlayerMapPosition and UnitPosition both nil. The
    -- nameplate icon marks them in view; these markers lead you there.)
    hideRest()
    -- What the markers show, saved every few seconds (VoidQuestCharDB.mobMarkers): the game's
    -- own minimap drawing can't be read by an addon, but our markers can, so a check after a
    -- /reload needs no screenshot (the user, 2026-11-10: "can an add-on not read what shows up
    -- in the minimap?")
    local now = GetTime()
    if not self._savedAt or now - self._savedAt > 3 then
        self._savedAt = now
        local shown = {}
        for i = 1, nActive do
            local p = pool[i]
            if p.d then
                shown[#shown + 1] = ("%s (%s) %d yd%s"):format(p.d.name or "?", p.d.quest or "?",
                    math.floor((p.yards or 0) + 0.5), p.edge and ", on the edge" or "")
            end
        end
        -- Does the game itself have an objective area for your quests here (what retail draws on
        -- its own)? GetQuestsOnMap = quests with a map marker; GetDistanceSqToQuest = an area to
        -- measure to. Answers "does Forever not do what retail does" (2026-11-10).
        local onMap = {}
        for _, q in ipairs(safe(C_QuestLog.GetQuestsOnMap, mapID) or {}) do
            if q.questID and not secret(q.questID) then onMap[#onMap + 1] = q.questID end
        end
        local areas = {}
        for _, qid in ipairs(QuestsFor(mapID)) do
            local d2 = safe(C_QuestLog.GetDistanceSqToQuest, qid)
            areas[#areas + 1] = ("%d: %s"):format(qid, (type(d2) == "number" and not secret(d2)) and
                ("%d yd"):format(math.floor(math.sqrt(d2) + 0.5)) or "no area")
        end
        VoidQuestCharDB = VoidQuestCharDB or {}
        VoidQuestCharDB.mobMarkers = { at = date("%Y-%m-%d %H:%M:%S"), map = mapID,
            pos = ("%.2f, %.2f"):format(px * 100, py * 100), shown = shown, candidates = #cache.dots,
            gameQuestsOnMap = onMap, gameQuestAreas = areas }
    end
end

function M:Refresh() cache.dirty = true end

function M:Toggle()
    VoidQuestDB = VoidQuestDB or {}
    VQ:Set("mobDots", not Enabled())
    VQ:Print(("quest mob markers (minimap + nameplate icons): %s"):format(Enabled() and "on" or "off"))
    self:Refresh()
    if self.RemarkAll then self.RemarkAll() end
end

----------------------------------------------------------------------
-- Quest mobs in view (nameplates). The user, 2026-11-10: "can we not read nameplates of mobs
-- in areas that's in our field of view?" Addons can't get a mob's map position (so no live
-- minimap dot per mob like retail's client draws), but a nameplate tells who it is and the
-- game's own tooltip data says whether it counts for YOUR unfinished objectives. So:
--   1. a quest icon over each such mob's nameplate (rares get one too)
--   2. where you saw it is learned (VoidQuestDB.seenMobs), so the minimap markers point at
--      where mobs really are on Forever, not only where NorgannonDB says
----------------------------------------------------------------------
local LT = Enum and Enum.TooltipDataLineType or {}
local L_OBJ, L_TITLE, L_PLAYER = LT.QuestObjective or 8, LT.QuestTitle or 17, LT.QuestPlayer or 18
local SEEN_MAX = 40          -- learned spots per mob per map
local SEEN_GRID = 10         -- 1% of the map: spots closer than this are one spot

-- Your unfinished objectives this unit counts for: { { quest = title, text = "Worn Stone Token 8/10" } }
-- or nil. In a group the tooltip lists each member (QuestPlayer lines): only yours count.
local function QuestInfo(unit)
    local data = C_TooltipInfo and safe(C_TooltipInfo.GetUnit, unit)
    if not (data and data.lines) then return nil end
    local me1, me2 = UnitName("player"), GetUnitName and GetUnitName("player", false)
    local title, mine, out = nil, true, nil
    for _, ln in ipairs(data.lines) do
        local t, txt = ln.type, ln.leftText
        if secret(t) or (txt ~= nil and secret(txt)) then return nil end
        if t == L_TITLE then
            title, mine = txt, true
        elseif t == L_PLAYER then
            mine = (txt == me1 or txt == me2)
        elseif t == L_OBJ and mine and title and not ln.completed then
            out = out or {}
            out[#out + 1] = { quest = title, text = txt }
        end
    end
    return out
end

local function NpcID(unit)
    local guid = UnitGUID(unit)
    if not guid or secret(guid) then return nil end
    return tonumber(guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-"))
end

-- 3: remember where you saw it (your own position: its nameplate is up, so it's near)
local function Learn(npc, name, quests)
    local map = C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    x, y = math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5)
    if x <= 0 or y <= 0 or x > 999 or y > 999 then return end
    VoidQuestDB = VoidQuestDB or {}
    VoidQuestDB.seenMobs = VoidQuestDB.seenMobs or {}
    local s = VoidQuestDB.seenMobs[npc]
    if not s then s = { n = name, q = {}, m = {} }; VoidQuestDB.seenMobs[npc] = s end
    -- per quest: the objective it counts for ("Salty Scorpid Venom"), so its marker clears with it
    local linked = false   -- a new quest link refreshes the markers even at a known spot (Sol)
    for _, q in ipairs(quests or {}) do
        local obj = (q.text or ""):gsub("%s*%d+%s*/%s*%d+%s*$", ""):gsub("^%s*%d+%s*/%s*%d+%s*", "")
        local v = obj ~= "" and obj or true
        if s.q[q.quest] ~= v then s.q[q.quest] = v; linked = true end
    end
    local pts = s.m[map] or ""
    for i = 1, #pts - 5, 6 do
        local px, py = tonumber(pts:sub(i, i + 2)), tonumber(pts:sub(i + 3, i + 5))
        if px and py and math.abs(px - x) < SEEN_GRID and math.abs(py - y) < SEEN_GRID then
            if linked then M:Refresh() end
            return
        end
    end
    if #pts >= SEEN_MAX * 6 then pts = pts:sub(7) end   -- oldest out
    s.m[map] = pts .. ("%03d%03d"):format(x, y)
    M:Refresh()   -- the markers use it from now on
end

-- (inView, the mobs in view, is declared near the top)

-- (A text line "In view: 3 ..." by the minimap was here; the user, 2026-11-10: "i dont like the
-- words and line, why cant it just be a dot on the minimap". A live dot per mob isn't possible: WoW
-- Forever gives addons no position for a nameplate mob, probed 2026-11-10.)
local function RefreshLabel() end

-- 1: the icon over the nameplate
local function Mark(unit)
    if not Enabled() or UnitIsPlayer(unit) then return end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate or (plate.IsForbidden and plate:IsForbidden()) then return end
    local quests = QuestInfo(unit)
    local cls = UnitClassification(unit)
    if cls and secret(cls) then cls = nil end
    local rare = cls == "rare" or cls == "rareelite" or cls == "worldboss"
    local name = UnitName(unit)
    if name and secret(name) then name = nil end
    local icon = plate.voidQuestMark
    if quests or rare then
        if not icon then
            icon = plate:CreateTexture(nil, "OVERLAY")
            icon:SetSize(18, 18)
            icon:SetPoint("BOTTOM", plate, "TOP", 0, -6)
            plate.voidQuestMark = icon
        end
        icon:SetTexture(quests and "Interface\\GossipFrame\\AvailableQuestIcon" or "Interface\\GossipFrame\\DailyQuestIcon")
        icon:SetVertexColor(1, 1, 1, 1)
        if not quests then icon:SetVertexColor(0.8, 0.8, 1, 1) end   -- a rare (not for a quest): silver-blue
        icon:Show()
        inView[unit] = { name = name or "?", quests = quests, rare = rare }
        local npc = NpcID(unit)
        if npc and name then Learn(npc, name, quests) end
    else
        if icon then icon:Hide() end
        inView[unit] = nil
    end
end

local function Unmark(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if plate and plate.voidQuestMark then plate.voidQuestMark:Hide() end
    inView[unit] = nil
end

-- every nameplate up again (quest progress changed: a finished objective's mobs lose the icon)
local plateQueued = false
local function RemarkAll()
    if plateQueued then return end
    plateQueued = true
    C_Timer.After(0.4, function()
        plateQueued = false
        wipe(inView)
        for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
            local unit = (plate.GetUnit and plate:GetUnit()) or plate.unitToken or plate.namePlateUnitToken   -- Forever: GetUnit (Sol)
            if unit then
                if Enabled() then Mark(unit) elseif plate.voidQuestMark then plate.voidQuestMark:Hide() end
            end
        end
        RefreshLabel()
    end)
end
M.RemarkAll = RemarkAll

local pev = CreateFrame("Frame")
for _, e in ipairs({ "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UNIT_QUEST_LOG_CHANGED" }) do
    pcall(pev.RegisterEvent, pev, e)
end
-- A nameplate that came up before the game had its quest info gets no icon from one check
-- (seen live: 1 of 5 tortoises in view marked): check every visible one again every 2 s.
C_Timer.NewTicker(2, function()
    if Enabled() and next(C_NamePlate.GetNamePlates() or {}) then RemarkAll() end
end)

pev:SetScript("OnEvent", function(_, e, unit)
    if e == "NAME_PLATE_UNIT_ADDED" then
        Mark(unit); RefreshLabel()
    elseif e == "NAME_PLATE_UNIT_REMOVED" then
        Unmark(unit); RefreshLabel()
    else
        RemarkAll()
    end
end)

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "QUEST_LOG_UPDATE", "SUPER_TRACKING_CHANGED", "GET_ITEM_INFO_RECEIVED",
    "ZONE_CHANGED_NEW_AREA" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, e)
    if e == "PLAYER_LOGIN" and not M.ticker then
        -- parented to the minimap: idle while it's hidden; ~20 updates a second is smooth enough
        M.ticker = CreateFrame("Frame", nil, Minimap)
        local acc = 0
        M.ticker:SetScript("OnUpdate", function(_, el)
            acc = acc + el
            if acc < 0.05 then return end
            acc = 0
            M:UpdateMinimap()
        end)
    end
    M:Refresh()
end)
