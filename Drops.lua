----------------------------------------------------------------------
-- VoidQuest — where quest items come from (step 1: your own characters)
-- WoW Forever's Classic quests give the game no objective areas, so "Witching Talon:
-- 0/8" never said where to go (the user, 2026-11-06). Every time you loot a quest item,
-- this records what it came from (the mob or object) and where you were:
--
--   VoidQuestDB.drops[itemID] = {
--     name = "Witching Talon",
--     quests  = { [questID] = true },                 -- quests whose objective asks for it
--     sources = { ["npc:3276"] = { kind = "npc", id = 3276, name = "Witchwing Harpy", n = 14 } },
--     spots   = { [uiMapID] = { ["34:12"] = 5, ... } } -- 1% map cells -> times looted there
--   }
--
-- Shown: a line per item objective in the quest-line tooltip ("drops from Witchwing
-- Harpy (14)"). World map dots exist but are OFF (VQ "dropDots" = true turns them on): the
-- user doesn't want the map covered in drop dots. Spots are still recorded, for quests in your log
-- still missing it. /vq drops lists it. Account-wide (every character learns).
-- Step 2 (later): share with other VoidQuest players like quest givers.
----------------------------------------------------------------------
local VQ = VoidQuest
local function safe(fn, ...) if not fn then return nil end local ok, a, b, c, d = pcall(fn, ...) if ok then return a, b, c, d end end
local function secret(v) return issecretvalue and issecretvalue(v) end

local MAX_CELLS = 80          -- per item per map: the least-seen cells go first
local D = {}
VQ.Drops = D

local function DB()
    VoidQuestDB = VoidQuestDB or {}
    VoidQuestDB.drops = VoidQuestDB.drops or {}
    return VoidQuestDB.drops
end

-- Item names the quests in your log ask for in ITEM objectives, exactly:
-- lowercased name -> { questID, ... } (same parsing as Leftovers.lua).
local function ObjectiveItemQuests()
    local out = {}
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        local qid = info and not info.isHeader and info.questID
        if qid then
            for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
                local t = o.text
                if o.type == "item" and type(t) == "string" and not secret(t) then
                    t = t:gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub("%s*:%s*%d+%s*/%s*%d+%s*$", ""):lower()
                    out[t] = out[t] or {}
                    table.insert(out[t], qid)
                end
            end
        end
    end
    return out
end

-- "Creature-0-1234-1-5678-3276-0000ABCD" -> "npc", 3276
local function ParseGUID(guid)
    if type(guid) ~= "string" or secret(guid) then return nil end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    id = tonumber(id)
    if not id then return nil end
    if kind == "Creature" or kind == "Vehicle" then return "npc", id end
    if kind == "GameObject" then return "object", id end
    return nil
end

-- Mob names by NPC ID, from every mob the game shows you (nameplates, target,
-- mouseover): a corpse you loot is rarely still your target or under the mouse, so the
-- first live recording had "NPC 5756" for Deviate Hide's source (2026-11-06). Recorded
-- sources still missing a name are filled in as soon as that mob is seen.
local npcNames, npcCount = {}, 0
-- Recorded sources still missing a name, by NPC ID: built once, then kept up as sources
-- are recorded, so a new nameplate is one table lookup, not a scan (Codex review).
local unnamed
local function Unnamed()
    if unnamed then return unnamed end
    unnamed = {}
    for _, rec in pairs((VoidQuestDB and VoidQuestDB.drops) or {}) do
        for _, s in pairs(rec.sources or {}) do
            if s.kind == "npc" and not s.name then
                unnamed[s.id] = unnamed[s.id] or {}
                table.insert(unnamed[s.id], s)
            end
        end
    end
    return unnamed
end

local function RememberUnit(unit)
    local g = UnitGUID(unit)
    local kind, id = ParseGUID(g)
    if kind ~= "npc" or npcNames[id] then return end
    local n = UnitName(unit)
    if not n or secret(n) or n == "" then return end
    npcCount = npcCount + 1
    if npcCount > 500 then npcNames, npcCount = {}, 1 end   -- session cache, kept small
    npcNames[id] = n
    local waiting = Unnamed()[id]
    if waiting then
        for _, s in ipairs(waiting) do s.name = s.name or n end
        unnamed[id] = nil
    end
end

-- A name for the loot source: the corpse itself if it's your target / mouseover, else
-- the name seen for that NPC ID.
local function SourceName(guid)
    for _, unit in ipairs({ "target", "mouseover" }) do
        local g = UnitGUID(unit)
        if g and not secret(g) and g == guid then
            local n = UnitName(unit)
            if n and not secret(n) then return n end
        end
    end
    local kind, id = ParseGUID(guid)
    return kind == "npc" and npcNames[id] or nil
end

local function AddCell(rec, mapID, x, y)
    rec.spots = rec.spots or {}
    local cells = rec.spots[mapID] or {}
    rec.spots[mapID] = cells
    local key = ("%d:%d"):format(math.floor(x * 100), math.floor(y * 100))
    cells[key] = (cells[key] or 0) + 1
    -- keep the map light: drop the least-seen cell past the cap
    local n, low, lowKey = 0, nil, nil
    for k, c in pairs(cells) do
        n = n + 1
        if k ~= key and (not low or c < low) then low, lowKey = c, k end
    end
    if n > MAX_CELLS and lowKey then cells[lowKey] = nil end
end

-- Each corpse / object counts once per item, however often its loot window opens or
-- refreshes (Codex review: a time window both dropped real loots and double-counted a
-- reopened corpse). Spawn GUIDs are unique, so a pair seen once is never counted again;
-- kept 30 min, then pruned.
local counted, countedN = {}, 0
local function FirstTime(guid, itemID)
    local key = guid .. "|" .. itemID
    if counted[key] then return false end
    counted[key] = GetTime()
    countedN = countedN + 1
    if countedN > 400 then
        local now = GetTime()
        for k, t in pairs(counted) do if now - t > 1800 then counted[k] = nil; countedN = countedN - 1 end end
    end
    return true
end

-- Every source of one loot slot: GetLootSourceInfo returns guid, qty pairs (area loot
-- puts several corpses in one window).
local function SlotSources(slot)
    if not GetLootSourceInfo then return {} end
    local r = { pcall(GetLootSourceInfo, slot) }
    local out = {}
    if not r[1] then return out end
    for i = 2, #r, 2 do
        if type(r[i]) == "string" and not secret(r[i]) then out[#out + 1] = r[i] end
    end
    return out
end

-- A loot window: each quest item, from each mob / object in it. Only real sources count:
-- a container opened from your bags (a clam, a supply crate) has no place in the world,
-- so it never adds a map spot (Codex review).
local function OnLoot()
    if IsFishingLoot and IsFishingLoot() then return end
    local wanted
    local mapID = safe(C_Map.GetBestMapForUnit, "player")
    local pos = mapID and safe(C_Map.GetPlayerMapPosition, mapID, "player")
    local x, y
    if pos and pos.GetXY then x, y = pos:GetXY() end
    if x and (secret(x) or x <= 0 or y <= 0) then x, y = nil, nil end
    for slot = 1, (GetNumLootItems and GetNumLootItems() or 0) do
        local link = GetLootSlotLink(slot)
        local ok, _, name, _, currencyID, _, _, isQuestItem = pcall(GetLootSlotInfo, slot)
        if ok and link and name and not currencyID and not secret(link) and not secret(name) then
            local id = tonumber(link:match("item:(%d+)"))
            wanted = wanted or ObjectiveItemQuests()
            local quests = id and wanted[name:lower()]
            if id and (quests or isQuestItem == true) then
                for _, guid in ipairs(SlotSources(slot)) do
                    local kind, sid = ParseGUID(guid)
                    if kind and FirstTime(guid, id) then
                        local db = DB()
                        local rec = db[id] or { name = name }
                        db[id] = rec
                        rec.name = name
                        rec.quests = rec.quests or {}
                        for _, q in ipairs(quests or {}) do rec.quests[q] = true end
                        rec.sources = rec.sources or {}
                        local key = kind .. ":" .. sid
                        local s = rec.sources[key]
                        if not s then
                            s = { kind = kind, id = sid, n = 0 }
                            rec.sources[key] = s
                        end
                        s.n = s.n + 1
                        s.name = SourceName(guid) or s.name
                        if kind == "npc" and not s.name then
                            local u = Unnamed()
                            u[sid] = u[sid] or {}
                            table.insert(u[sid], s)
                        end
                        if mapID and x then AddCell(rec, mapID, x, y) end
                        D.dirty = true
                    end
                end
            end
        end
    end
    if D.dirty and D.Refresh then D:Refresh() end
end

----------------------------------------------------------------------
-- Reading it back
----------------------------------------------------------------------
-- An NPC's name from its ID, through the game's own unit tooltip (works for any creature
-- the client has seen, without it being near): "NPC 5762" became "Deviate Moccasin".
-- Saved on the source once found.
local function LookupNPCName(id)
    if npcNames[id] then return npcNames[id] end
    if not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then return nil end
    local ok, data = pcall(C_TooltipInfo.GetHyperlink, ("unit:Creature-0-0-0-0-%d-0000000000"):format(id))
    local line = ok and data and data.lines and data.lines[1]
    local n = line and line.leftText
    if type(n) == "string" and not secret(n) and n ~= "" then
        npcNames[id] = n
        return n
    end
    return nil
end

-- "Witchwing Harpy (14), Witchwing Slayer (3)", most first.
local function SourcesText(rec, max)
    local list = {}
    for _, s in pairs(rec.sources or {}) do list[#list + 1] = s end
    table.sort(list, function(a, b) return a.n > b.n end)
    local parts = {}
    for i = 1, math.min(#list, max or 3) do
        local s = list[i]
        if not s.name and s.kind == "npc" then s.name = LookupNPCName(s.id) end
        parts[#parts + 1] = ("%s (%d)"):format(s.name or (s.kind == "object" and "an object" or ("NPC " .. s.id)), s.n)
    end
    return table.concat(parts, ", ")
end

-- The recorded item for an objective name, preferring one tied to this quest.
local function RecordFor(name, qid)
    local lname, best = name:lower(), nil
    for _, rec in pairs(DB()) do
        if rec.name and rec.name:lower() == lname then
            if rec.quests and rec.quests[qid] then return rec end
            best = best or rec
        end
    end
    return best
end

-- Lines for a quest's tooltip: one per unfinished item objective we know about.
function D:AddQuestLines(tt, qid)
    if not qid then return end
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
        local t = o.text
        if o.type == "item" and not o.finished and type(t) == "string" and not secret(t) then
            local name = t:gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub("%s*:%s*%d+%s*/%s*%d+%s*$", "")
            local rec = RecordFor(name, qid)
            if rec and next(rec.sources or {}) then
                tt:AddLine(("%s: from %s"):format(name, SourcesText(rec)), 1, 0.65, 0.2, true)
            end
        end
    end
end

-- Map cells to draw on a map: { x, y, n, name, quest } for items quests in your log
-- still need.
function D:CellsFor(mapID)
    local out = {}
    if not mapID then return out end
    local need = {}
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        local qid = info and not info.isHeader and info.questID
        if qid then
            for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
                local t = o.text
                if o.type == "item" and not o.finished and type(t) == "string" and not secret(t) then
                    local name = t:gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub("%s*:%s*%d+%s*/%s*%d+%s*$", "")
                    need[name:lower()] = need[name:lower()] or { title = info.title, qid = qid, name = name }
                end
            end
        end
    end
    for _, rec in pairs(DB()) do
        local n = rec.name and need[rec.name:lower()]
        local cells = n and rec.spots and rec.spots[mapID]
        for key, c in pairs(cells or {}) do
            local cx, cy = key:match("^(%d+):(%d+)$")
            cx, cy = tonumber(cx), tonumber(cy)
            if cx then
                out[#out + 1] = { x = (cx + 0.5) / 100, y = (cy + 0.5) / 100, n = c, name = rec.name,
                                  quest = n.title, sources = SourcesText(rec, 2) }
            end
        end
    end
    return out
end

----------------------------------------------------------------------
-- World map dots
----------------------------------------------------------------------
local PIN = "VoidQuestDropPinTemplate"
VoidQuestDropPinMixin = CreateFromMixins(MapCanvasPinMixin)

function VoidQuestDropPinMixin:OnLoad()
    self:SetScalingLimits(1, 0.6, 1.0)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_DIG_SITE")   -- below Blizzard's quest pins
    self.dot:SetTexture("Interface\\Buttons\\WHITE8X8")
    local mask = self:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(self.dot)
    self.dot:AddMaskTexture(mask)
end

function VoidQuestDropPinMixin:OnAcquired(c)
    self.cell = c
    self:SetPosition(c.x, c.y)
    -- more loots here = bigger and stronger
    local s = math.min(14, 7 + c.n)
    self:SetSize(s, s)
    self.dot:SetVertexColor(1, 0.55, 0.1, math.min(0.9, 0.35 + c.n * 0.1))
    self:Show()
end

function VoidQuestDropPinMixin:OnMouseEnter()
    local c = self.cell
    if not c then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(c.name, 1, 0.65, 0.2)
    if c.quest then GameTooltip:AddLine(c.quest, 1, 0.82, 0) end
    GameTooltip:AddLine(("You looted it here %d time%s"):format(c.n, c.n == 1 and "" or "s"), 1, 1, 1)
    if c.sources ~= "" then GameTooltip:AddLine("From " .. c.sources, 0.8, 0.8, 0.8, true) end
    GameTooltip:Show()
end
function VoidQuestDropPinMixin:OnMouseLeave() GameTooltip:Hide() end

VoidQuestDropProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)
function VoidQuestDropProviderMixin:RemoveAllData()
    if self:GetMap() then self:GetMap():RemoveAllPinsByTemplate(PIN) end
end
function VoidQuestDropProviderMixin:RefreshAllData()
    self:RemoveAllData()
    if InCombatLockdown() then return end
    -- off unless turned on: the user doesn't want the map covered in drop dots (2026-11-06,
    -- "i saw that in [another quest addon] and hated it"). The data still feeds the
    -- quest-line tooltip and /vq drops.
    if VQ:Get("dropDots") ~= true then return end
    local map = self:GetMap()
    for _, c in ipairs(D:CellsFor(map and map:GetMapID())) do map:AcquirePin(PIN, c) end
end

function D:Refresh()
    self.dirty = false
    if self.provider and WorldMapFrame and WorldMapFrame:IsShown() then self.provider:RefreshAllData() end
end

-- /vq drops: what's recorded for the quests in your log.
function D:List()
    local p = "|cff00c7ffVoidQuest|r "
    local any = false
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        local qid = info and not info.isHeader and info.questID
        if qid then
            for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
                local t = o.text
                if o.type == "item" and type(t) == "string" and not secret(t) then
                    local name = t:gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub("%s*:%s*%d+%s*/%s*%d+%s*$", "")
                    local rec = RecordFor(name, qid)
                    local spots = 0
                    for _, cells in pairs((rec and rec.spots) or {}) do for _ in pairs(cells) do spots = spots + 1 end end
                    if rec then
                        any = true
                        print(p .. ("%s (%s): from %s; %d map spot%s"):format(name, info.title or qid,
                            next(rec.sources or {}) and SourcesText(rec) or "?", spots, spots == 1 and "" or "s"))
                    end
                end
            end
        end
    end
    if not any then print(p .. "no quest item drops recorded yet for your quests; they're saved as you loot them") end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "LOOT_READY", "LOOT_OPENED", "QUEST_LOG_UPDATE", "PLAYER_REGEN_ENABLED",
                     "NAME_PLATE_UNIT_ADDED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_TARGET_CHANGED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, e, unit)
    if e == "NAME_PLATE_UNIT_ADDED" then RememberUnit(unit); return end
    if e == "UPDATE_MOUSEOVER_UNIT" then RememberUnit("mouseover"); return end
    if e == "PLAYER_TARGET_CHANGED" then RememberUnit("target"); return end
    if e == "PLAYER_LOGIN" then
        if WorldMapFrame and not D.provider then
            D.provider = CreateFromMixins(VoidQuestDropProviderMixin)
            WorldMapFrame:AddDataProvider(D.provider)
        end
    elseif e == "LOOT_READY" or e == "LOOT_OPENED" then
        OnLoot()
        return
    end
    D:Refresh()
end)
