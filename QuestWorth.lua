-- VoidQuest: is this quest worth it for THIS character? (WoW Forever)
--
-- The user, 2026-11-09, after a Ravenholdt rogue quest: "how can we do tooltips ... to help
-- a player know what they might get later or endgame from doing these things", and "if a
-- faction with high rep only gives caster stuff, there is no reason for me to do it on my
-- rogue, but a faction giving rogue or melee stuff might be important".
--
-- Two tooltip lines on a quest, each only when it has something to say:
--   Chain:  "Rest of the chain: 4 quests, 11,050 XP. Leads to: Summon Succubus"
--           (abilities, blue+ items you can use, mounts, keys found down the known chain;
--           "nothing lasting after it" when the chain is known and has none)
--   Faction (per faction it gives reputation with, at most 2):
--           "Timbermaw Hold: 3 for you, best <item> at Revered (you: Friendly)"
--           "Cenarion Circle: nothing for your Rogue (caster gear)"
--           "Ravenholdt: nothing to buy, reputation only"
-- What a faction sells comes from ForeverRep.lua (the game's own item tooltips, scanned on
-- the author's machine); quests that need a standing come from ForeverQuests.lua.
--
-- "For you": gear your class can wear or wield, not built only for the other kind of
-- class (a caster-only item on a rogue, a melee-only one on a mage); hybrids take both.
-- Gear with neither (stamina, armor) counts, so does any recipe for one of your
-- professions and any mount. Consumables and cosmetics don't count either way.
local VQ = VoidQuest
if not VQ or (select(4, GetBuildInfo()) or 0) >= 100000 then return end   -- WoW Forever only

local W = {}
VQ.Worth = W

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c, d = pcall(fn, ...) if ok then return a, b, c, d end end
local function secret(v) return issecretvalue and issecretvalue(v) end

----------------------------------------------------------------------
-- What this character can use
----------------------------------------------------------------------
local _, CLASS = UnitClass("player")
local PHYS   = { WARRIOR = true, ROGUE = true, HUNTER = true }
local CASTER = { MAGE = true, PRIEST = true, WARLOCK = true }

-- heaviest armor (Classic rules, at max level): 1 cloth, 2 leather, 3 mail, 4 plate
local ARMOR = { WARRIOR = 4, PALADIN = 4, HUNTER = 3, SHAMAN = 3, ROGUE = 2, DRUID = 2, MAGE = 1, PRIEST = 1, WARLOCK = 1 }
local ARMOR_NAME = { "cloth", "leather", "mail", "plate" }
-- armor subclasses 6 shield, 7 libram, 8 idol, 9 totem
local ARMOR_SPECIAL = { [6] = { WARRIOR = 1, PALADIN = 1, SHAMAN = 1 }, [7] = { PALADIN = 1 }, [8] = { DRUID = 1 }, [9] = { SHAMAN = 1 } }
-- weapon subclasses: 0 1H axe, 1 2H axe, 2 bow, 3 gun, 4 1H mace, 5 2H mace, 6 polearm,
-- 7 1H sword, 8 2H sword, 10 staff, 13 fist, 15 dagger, 16 thrown, 18 crossbow, 19 wand
local function set(...) local t = {} for _, v in ipairs({ ... }) do t[v] = true end return t end
local WEAPON = {
    WARRIOR = set(0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18),
    PALADIN = set(0, 1, 4, 5, 6, 7, 8),
    HUNTER  = set(0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18),
    ROGUE   = set(2, 3, 4, 7, 13, 15, 16, 18),
    PRIEST  = set(4, 10, 15, 19),
    SHAMAN  = set(0, 1, 4, 5, 10, 13, 15),
    MAGE    = set(7, 10, 15, 19),
    WARLOCK = set(7, 10, 15, 19),
    DRUID   = set(4, 5, 10, 13, 15),
}
-- recipe subclass -> profession skill line
local RECIPE_SKILL = { [1] = 165, [2] = 197, [3] = 202, [4] = 164, [5] = 185, [6] = 171, [7] = 129, [8] = 333, [9] = 356, [10] = 755 }

local myProfs
local function MyProfs()
    if myProfs then return myProfs end
    myProfs = {}
    if GetProfessions then
        for _, idx in pairs({ GetProfessions() }) do
            -- the skill line is the 7th return (safe() keeps only 4: Codex review)
            local ok, _, _, _, _, _, _, line = pcall(GetProfessionInfo, idx)
            if ok and type(line) == "number" then myProfs[line] = true end
        end
    end
    return myProfs
end

-- The stat lines of an item's tooltip, read as text (Classic items keep spell damage,
-- healing and attack power in "Equip:" lines, not in GetItemStats). Returns phys, cast,
-- otherClass (a "Classes:" line without yours); nil when the tooltip isn't there yet.
local MY_CLASS_NAME = UnitClass("player")
local function StatKinds(id)
    local data = safe(C_TooltipInfo.GetItemByID, id)
    if not (data and data.lines and #data.lines > 1) then return nil end
    local phys, cast, otherClass = false, false, false
    for i, l in ipairs(data.lines) do
        local t = l.leftText
        if i > 1 and type(t) == "string" and not secret(t) and t:find("^Classes:") then
            if MY_CLASS_NAME and not t:find(MY_CLASS_NAME, 1, true) then otherClass = true end
        elseif i > 1 and type(t) == "string" and not secret(t) and t:sub(1, 1) ~= '"' and not t:find("^Requires") then
            if t:find("Agility") or t:find("Strength") or t:find("[Aa]ttack [Pp]ower")
                or (t:find("chance to hit") and not t:find("spell")) or (t:find("critical strike") and not t:find("spell")) then
                phys = true
            end
            if t:find("Intellect") or t:find("Spirit") or t:find("spell") or t:find("[Hh]ealing")
                or t:find("mana per 5") or t:find("mana every 5") then
                cast = true
            end
        end
    end
    return phys, cast, otherClass
end

-- "mine" | "no", reason | "other" (consumable, cosmetic: doesn't count) | nil (item not loaded yet)
local kindCache = {}
local function Kind(id)
    local c = kindCache[id]
    if c then return c[1], c[2] end
    local _, _, _, equipLoc, _, classID, subID = C_Item.GetItemInfoInstant(id)
    if not classID then return nil end
    local k, why
    if classID == 9 then          -- recipe
        local skill = RECIPE_SKILL[subID]
        if skill then k, why = (MyProfs()[skill] and "mine" or "no"), "recipes for other professions" else k = "other" end
    elseif classID == 15 and subID == 5 then
        k = "mine"                -- mount
    elseif classID == 13 then
        k = "mine"                -- key
    elseif classID == 4 or classID == 2 then
        if equipLoc == "INVTYPE_TABARD" or equipLoc == "INVTYPE_BODY" or equipLoc == "" then
            k = "other"
        elseif classID == 2 and not (WEAPON[CLASS] or {})[subID] then
            k, why = "no", "weapons you can't use"
            if subID == 19 then why = "caster gear" end
        elseif classID == 4 and subID >= 1 and subID <= 4 and equipLoc ~= "INVTYPE_CLOAK" and subID > (ARMOR[CLASS] or 4) then
            k, why = "no", ARMOR_NAME[subID]
        elseif classID == 4 and ARMOR_SPECIAL[subID] and not ARMOR_SPECIAL[subID][CLASS] then
            k, why = "no", (subID == 6) and "shields" or "caster gear"
        else
            if not C_Item.IsItemDataCachedByID(id) then
                C_Item.RequestLoadItemDataByID(id)
                return nil
            end
            local phys, cast, otherClass = StatKinds(id)
            if phys == nil then return nil end   -- tooltip not ready: ask again later, don't cache
            if otherClass then
                k, why = "no", "other classes' gear"
            elseif PHYS[CLASS] and cast and not phys then
                k, why = "no", "caster gear"
            elseif CASTER[CLASS] and phys and not cast then
                k, why = "no", "melee gear"
            else
                k = "mine"
            end
        end
    else
        k = "other"
    end
    kindCache[id] = { k, why }
    return k, why
end
W.Kind = Kind

local function Quality(id)
    local q = safe(C_Item.GetItemQualityByID, id)
    return (type(q) == "number" and not secret(q)) and q or 0
end

local function ItemName(id)
    local n = safe(C_Item.GetItemNameByID, id)
    if type(n) == "string" and not secret(n) and n ~= "" then
        local q = Quality(id)
        local col = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
        return col and (col.hex .. n .. "|r") or n
    end
end

----------------------------------------------------------------------
-- Factions
----------------------------------------------------------------------
local STANDING_NAME = {}
for i = 1, 8 do STANDING_NAME[i] = _G["FACTION_STANDING_LABEL" .. i] or tostring(i) end

local function StandingOfRaw(v)   -- raw reputation (from quest requirements) -> standing
    if v >= 42000 then return 8 elseif v >= 21000 then return 7 elseif v >= 9000 then return 6
    elseif v >= 3000 then return 5 end
    return 4
end

local function MyStanding(fid)
    local d = fid and safe(C_Reputation.GetFactionDataByID, fid)
    local r = d and d.reaction
    return (type(r) == "number" and not secret(r)) and r or nil
end

-- quests that need a standing, by faction ID: { qid, standing, ... } (built once)
local gated
local function Gated()
    if gated then return gated end
    gated = {}
    for qid, r in pairs(VQ.ForeverQuests or {}) do
        local need = r[14]
        if need and need ~= "" then
            for f, v in need:gmatch("(%d+):(%d+)") do
                f = tonumber(f)
                gated[f] = gated[f] or {}
                table.insert(gated[f], { qid, StandingOfRaw(tonumber(v)) })
            end
        end
    end
    return gated
end

-- What a faction has for you: mine, best {id, standing}, notMine, why, total, pending
local facCache = {}
local function Faction(fid)
    local c = facCache[fid]
    if c then return c end
    local name = VQ.ForeverFactions and VQ.ForeverFactions[fid]
    local list = name and VQ.ForeverRep and VQ.ForeverRep[name]
    local s = { mine = 0, no = 0, total = 0, pending = 0, why = {} }
    local function consider(id, st)
        local k, why = Kind(id)
        if k == nil then s.pending = s.pending + 1; return end
        if k == "other" then return end
        s.total = s.total + 1
        if k == "mine" then
            s.mine = s.mine + 1
            local q = Quality(id)
            s.items = s.items or {}
            s.items[#s.items + 1] = { id, st, q }
            if not s.best or q > s.bestQ or (q == s.bestQ and st > s.best[2]) then s.best, s.bestQ = { id, st }, q end
        else
            s.no = s.no + 1
            s.why[why] = (s.why[why] or 0) + 1
        end
    end
    if list then
        for i = 1, #list - 1, 2 do consider(list[i], list[i + 1]) end
    end
    -- quests that open up at a standing: their rewards (and abilities) count too
    local F = VQ.Forever
    for _, g in ipairs(Gated()[fid] or {}) do
        local r = VQ.ForeverQuests[g[1]]
        -- skip ones you've done (unless repeatable): they're nothing left to earn (Codex review)
        local done = not (r and (r[6] or ""):find("[dwr]")) and safe(C_QuestLog.IsQuestFlaggedCompleted, g[1])
        if r and not done and (not F or F:Eligible(r)) then
            for id in (r[11] or ""):gmatch("%d+") do consider(tonumber(id), g[2]) end
            if (r[13] or 0) > 0 then   -- an ability counts as something for you
                s.total, s.mine = s.total + 1, s.mine + 1
                s.spells = s.spells or {}
                s.spells[#s.spells + 1] = { r[13], g[2] }
            end
        end
    end
    if s.pending == 0 then facCache[fid] = s end
    return s
end

local function MainWhy(s)
    local best, n = nil, 0
    for w, c in pairs(s.why) do if c > n then best, n = w, c end end
    return best
end

-- One line for a faction a quest gives reputation with, or nil.
-- Home factions (your capitals, Horde / Alliance): on most quests and they sell nothing
-- that needs a standing, so a "nothing for you" line about them is only noise.
local HOME = { [67] = 1, [469] = 1, [76] = 1, [530] = 1, [68] = 1, [81] = 1, [911] = 1,
               [72] = 1, [47] = 1, [69] = 1, [54] = 1, [930] = 1 }

-- What an item is, in a few words: "one-handed sword", "leather shoulders", "ring",
-- "Alchemy recipe", "mount"; plus its required level when it's above yours.
local function WhatItIs(id)
    local _, _, _, _, minLevel, _, subType, _, equipLoc, _, _, classID, subID = C_Item.GetItemInfo(id)
    local what
    if classID == 15 and subID == 5 then
        what = "mount"
    elseif classID == 9 then
        what = (type(subType) == "string" and subType or "profession") .. " recipe"
    elseif classID == 2 then
        what = type(subType) == "string" and subType:lower():gsub("s$", "") or "weapon"
    elseif classID == 4 then
        local plain = { INVTYPE_FINGER = "ring", INVTYPE_NECK = "necklace", INVTYPE_CLOAK = "cloak",
                        INVTYPE_HOLDABLE = "off-hand", INVTYPE_SHIELD = "shield", INVTYPE_TRINKET = "trinket" }
        local slot = equipLoc and (plain[equipLoc] or _G[equipLoc])
        slot = type(slot) == "string" and slot:lower() or nil
        if subID and subID >= 1 and subID <= 4 and equipLoc ~= "INVTYPE_CLOAK" then
            what = ARMOR_NAME[subID] .. (slot and (" " .. slot) or "")
        else
            what = slot or (type(subType) == "string" and subType:lower()) or "armor"
        end
    end
    local me = UnitLevel("player") or 0
    if type(minLevel) == "number" and minLevel > me then
        what = (what and (what .. ", ") or "") .. "level " .. minLevel
    end
    return what
end

-- The box's faction block: a header, then up to 4 things for you, next standing first.
local MAX_ITEMS = 4
function W:FactionDetail(name, s, mine, you)
    local rows = {}
    for _, it in ipairs(s.items or {}) do rows[#rows + 1] = { st = it[2], q = it[3], id = it[1] } end
    for _, sp in ipairs(s.spells or {}) do rows[#rows + 1] = { st = sp[2], q = 5, spell = sp[1] } end
    table.sort(rows, function(a, b)
        if a.st ~= b.st then return a.st < b.st end
        return a.q > b.q
    end)
    local out = { ("|cff3ddc84%s|r%s, for you:"):format(name, you) }
    local shown = 0
    for _, r in ipairs(rows) do
        if shown >= MAX_ITEMS then break end
        local at = (mine and r.st <= mine) and "now" or STANDING_NAME[r.st]
        local text
        if r.spell then
            local n = C_Spell and C_Spell.GetSpellName and safe(C_Spell.GetSpellName, r.spell)
            if type(n) == "string" and not secret(n) then text = "learn " .. n end
        else
            local n = ItemName(r.id)
            if n then
                local what = WhatItIs(r.id)
                text = n .. (what and (" |cffaaaaaa(" .. what .. ")|r") or "")
            end
        end
        if text then
            out[#out + 1] = ("   |cffffd100%s:|r %s"):format(at, text)
            shown = shown + 1
        end
    end
    if #rows > shown then out[#out + 1] = ("   |cffaaaaaa+%d more|r"):format(#rows - shown) end
    return table.concat(out, "\n")
end

-- Reputation discount (measured on WoW Forever 2026-11-09, Classic rule): Honored = 10% off
-- that faction's vendors and trainers (Kor'geld, Orgrimmar: every item 0.900 of base);
-- Friendly = full price (Hogor Thunderhoof, Thunder Bluff: 1.000). The user: "that would be
-- something important for people to know". Your race's capital also trains your riding skill
-- and sells your mount, the biggest purchase while leveling.
local VENDOR_TOWNS = { [76] = 1, [530] = 1, [68] = 1, [81] = 1, [72] = 1, [47] = 1, [69] = 1, [54] = 1,
                       [21] = 1, [470] = 1, [369] = 1, [577] = 1 }   -- capitals + goblin towns
local RACE_CAPITAL = { Orc = 76, Troll = 530, Tauren = 81, Scourge = 68, Human = 72, Dwarf = 47, Gnome = 54, NightElf = 69 }
local function DiscountText(fid, name, mine)
    if not mine or mine >= 6 then return nil end   -- unknown, or you have it already
    if not (VENDOR_TOWNS[fid] or (VQ.ForeverRep and VQ.ForeverRep[name])) then return nil end
    local _, race = UnitRace("player")
    if RACE_CAPITAL[race] == fid and (UnitLevel("player") or 0) < 60 then
        return "10% off its vendors and trainers, your riding skill and mount too"
    end
    return "10% off its vendors"
end

-- negatives: also say when a faction has nothing for you (the quest-giver box only;
-- tooltips show only what's for you).
function W:FactionLine(fid, negatives, gain)
    if not VQ.ForeverRepScanned then return nil end   -- no scan shipped: don't guess
    local name = VQ.ForeverFactions and VQ.ForeverFactions[fid]
    if not name then return nil end
    local mine = MyStanding(fid)
    if mine and mine >= 8 then return nil end         -- already Exalted: nothing more to earn
    local s = Faction(fid)
    local you = mine and (" (you: " .. STANDING_NAME[mine] .. ")") or ""
    local disc = negatives and DiscountText(fid, name, mine)
    -- the box names the amount: the faction is the quest's reward, not the giver's own
    -- (the user, 2026-11-09: "why does it say undercity when this npc is ogrimar")
    local label = (negatives and gain) and (name .. " +" .. gain) or name
    if s.mine > 0 and negatives then
        -- the quest-giver box: the items themselves, next standing first (the user,
        -- 2026-11-09: "if i ... get revered, they may have a melee weapon i can buy")
        local d = self:FactionDetail(label, s, mine, you)
        if disc then d = d .. "\n   |cffffd100Honored:|r " .. disc end
        return d, true
    end
    if disc and s.pending == 0 then
        return ("|cffffd100%s|r%s: at Honored, %s"):format(label, you, disc)
    end
    if s.mine > 0 then
        local best = s.best and ItemName(s.best[1])
        if best then
            return ("|cff3ddc84%s:|r %d for you, best %s at %s%s"):format(name, s.mine, best, STANDING_NAME[s.best[2]], you), true
        end
        return ("|cff3ddc84%s:|r %d items for you%s"):format(name, s.mine, you), true
    end
    if s.pending > 0 then return nil, false, true end                  -- still loading
    if not negatives or HOME[fid] then return nil end                   -- tooltip / capital
    if s.total > 0 then
        local why = MainWhy(s)
        return ("|cff999999%s: nothing for your %s%s|r"):format(label, UnitClass("player") or "class",
            why and (" (" .. why .. ")") or "")
    end
    return ("|cff999999%s: nothing to buy, reputation only|r"):format(label)
end

----------------------------------------------------------------------
-- The rest of the chain
----------------------------------------------------------------------
local chainCache = {}

-- Dungeon or out in the world? (the user, 2026-11-09: "whether a quest or questline i am
-- doing is for regular quests or for a dungeon"). Blizzard's data tags dungeon / raid
-- quests, but not all of them (Wailing Caverns' Waking Naralex is only "Elite"), so a zone
-- where most quests are dungeon quests counts as a dungeon too (not Stormwind City, which
-- has a few dungeon quests among hundreds).
local dungeonZones
local function DungeonZones()
    if dungeonZones then return dungeonZones end
    local tot, dr = {}, {}
    for _, r in pairs(VQ.ForeverQuests or {}) do
        local z = r[2]
        if z and z > 0 then
            tot[z] = (tot[z] or 0) + 1
            if (r[6] or ""):find("[DR]") then dr[z] = (dr[z] or 0) + 1 end
        end
    end
    dungeonZones = {}
    -- 60%: Wailing Caverns 9/12 and Shadowfang Keep 3/5 are in; Orgrimmar 69/133 and
    -- Ironforge 69/124 (war-effort / attunement quests) are not (checked on the data, 2026-11-09)
    for z, n in pairs(dr) do
        if n >= 2 and n * 5 >= tot[z] * 3 then dungeonZones[z] = true end
    end
    return dungeonZones
end

-- "raid" | "dungeon" | "elite" | nil (regular), and the dungeon's name when known.
-- The zone rule only turns an ELITE quest into a dungeon quest (Waking Naralex).
local function QuestKind(r)
    local f = r[6] or ""
    local inDungeonZone = DungeonZones()[r[2]]
    local zname = inDungeonZone and VQ.ForeverNames and VQ.ForeverNames[r[2]] or nil
    if f:find("R") then return "raid", zname end
    if f:find("D") or (inDungeonZone and f:find("E")) then return "dungeon", zname end
    if f:find("E") then return "elite" end
    return nil
end
W.QuestKind = QuestKind
local MAX_NODES = 200

-- Payoffs of one quest for you: adds short texts to out. Returns true while some reward's
-- item data is still loading (then the answer isn't final).
local function Payoffs(qid, out)
    local r = VQ.ForeverQuests and VQ.ForeverQuests[qid]
    if not r then return false end
    local pending = false
    local spell = r[13]
    if spell and spell > 0 then
        local n = (C_Spell and C_Spell.GetSpellName and safe(C_Spell.GetSpellName, spell)) or (GetSpellInfo and safe(GetSpellInfo, spell))
        if type(n) == "string" and not secret(n) then out[#out + 1] = n else pending = true end
    end
    -- no rewards in Blizzard's data: what you saw yourself, or what other players confirmed
    local ids = r[11] or ""
    if ids == "" and VQ.Share and VQ.Share.FactItems then ids = VQ.Share:FactItems(qid) or "" end
    for s in ids:gmatch("%d+") do
        local id = tonumber(s)
        if not C_Item.IsItemDataCachedByID(id) then
            C_Item.RequestLoadItemDataByID(id)
            pending = true
        else
            local _, _, _, _, _, classID, subID = C_Item.GetItemInfoInstant(id)
            local special = classID == 13 or (classID == 15 and subID == 5)
            if special or Quality(id) >= 3 then
                local k = Kind(id)
                local n = ItemName(id)
                if k == nil then pending = true elseif k == "mine" and n then out[#out + 1] = n end
            end
        end
    end
    return pending
end

-- Rest of the chain line, or nil (no known follow-up); true when it leads to something for you.
function W:ChainLine(qid)
    local c = chainCache[qid]
    if c ~= nil then
        if c then return c[1], c[2] end
        return nil
    end
    local C, F = VQ.Chains, VQ.Forever
    if not (C and C.NextOf) then return nil end
    local seen, queue, head = { [qid] = true }, { qid }, 1
    local n, xp, pay, pending, probable, cut = 0, 0, {}, false, false, false
    local into, intoSeen = {}, {}   -- dungeons / raids further down the chain
    while head <= #queue and not cut do
        local a = queue[head]
        head = head + 1
        for b, v in pairs(C.NextOf(a)) do
            local r = VQ.ForeverQuests and VQ.ForeverQuests[b]
            -- dailies / repeatables (Syndicate Emblems after The Manor, Ravenholdt) aren't the chain
            if not seen[b] and r and not (r[6] or ""):find("[dwr]") and (not F or F:Eligible(r))
                and not safe(C_QuestLog.IsQuestFlaggedCompleted, b) then
                if n >= MAX_NODES then cut = true; break end
                seen[b] = true
                n = n + 1
                if (v or 0) < 2 then probable = true end   -- a link only guessed from quest history
                xp = xp + (r[4] or 0)
                if Payoffs(b, pay) then pending = true end
                local k, place = QuestKind(r)
                if k == "dungeon" or k == "raid" then
                    place = place or (k == "raid" and "a raid" or "a dungeon")
                    if not intoSeen[place] then intoSeen[place] = true; into[#into + 1] = place end
                end
                queue[#queue + 1] = b
            end
        end
    end
    local line
    if n > 0 then
        local num = BreakUpLargeNumbers and BreakUpLargeNumbers(xp) or tostring(xp)
        line = ("%s: %d quest%s%s"):format(probable and "Probably still in the chain" or "Rest of the chain",
            n, n == 1 and "" or "s", xp > 0 and (", " .. num .. " XP") or "")
        if #into > 0 then
            line = line .. ". |cffff8040Goes into:|r " .. table.concat(into, ", ", 1, math.min(2, #into))
        end
        if #pay > 0 then
            local shown = {}
            for i = 1, math.min(3, #pay) do shown[i] = pay[i] end
            line = line .. ". |cff3ddc84Leads to:|r " .. table.concat(shown, ", ") .. (#pay > 3 and (" +" .. (#pay - 3)) or "")
        elseif not pending and not cut then
            line = line .. ". Nothing lasting after it."
        end
    end
    local good = #pay > 0
    if not pending then chainCache[qid] = line and { line, good } or false end
    return line, line and good, pending
end

----------------------------------------------------------------------
-- The lines for a quest (at most 3: the user's tooltip rule), and whether anything in
-- them (or the quest's own ability / blue reward) is for you.
----------------------------------------------------------------------
function W:Lines(qid, negatives)
    local lines, good = {}, false
    if not qid or not (VQ.ForeverQuests and VQ.ForeverQuests[qid]) then return lines, false, {}, false end
    local own = {}
    local pending = Payoffs(qid, own)
    if #own > 0 then good = true end
    local chain, cgood, cpend = self:ChainLine(qid)
    if cpend then pending = true end
    if chain then lines[#lines + 1] = chain; good = good or cgood end
    local r = VQ.ForeverQuests[qid]
    local gains = {}
    for f, v in (r[12] or ""):gmatch("(%d+):(%-?%d+)") do
        v = tonumber(v)
        if v > 0 then gains[#gains + 1] = { tonumber(f), v } end
    end
    table.sort(gains, function(a, b) return a[2] > b[2] end)
    for _, g in ipairs(gains) do
        if #lines >= 3 then break end
        local l, fgood, fpend = self:FactionLine(g[1], negatives, g[2])
        if fpend then pending = true end
        if l then lines[#lines + 1] = l; good = good or fgood end
    end
    return lines, good, own, pending
end

function W:AddTooltip(tt, qid)
    if not (tt and qid) then return end
    local lines = self:Lines(qid)
    for _, l in ipairs(lines) do tt:AddLine(l, 0.85, 0.85, 0.85, true) end
    -- how long it really takes, from players (QuestTime.lua)
    if VQ.QuestTime then VQ.QuestTime:AddTooltip(tt, qid) end
end

----------------------------------------------------------------------
-- At the quest giver: a box beside the quest window (the user, 2026-11-09: "when i get it
-- ... i can make a decision if its worth it, thats when i need to see it most").
-- Offer (QUEST_DETAIL), progress and turn-in. Hidden when there's nothing to say.
----------------------------------------------------------------------
local box
local function Box()
    if box then return box end
    box = CreateFrame("Frame", "VoidQuestWorthBox", QuestFrame or UIParent, "BackdropTemplate")
    box:SetWidth(340)
    VQ:CreateBackdrop(box, 0.92)
    box:SetFrameStrata("HIGH")
    box.title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    box.title:SetPoint("TOPLEFT", 10, -9)
    box.title:SetPoint("RIGHT", -10, 0)
    box.title:SetJustifyH("LEFT")
    box.text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    box.text:SetPoint("TOPLEFT", box.title, "BOTTOMLEFT", 0, -6)
    box.text:SetPoint("RIGHT", -10, 0)
    box.text:SetJustifyH("LEFT")
    box.text:SetSpacing(3)
    box:Hide()
    return box
end

local function ShowBox()
    local qid = GetQuestID and GetQuestID()
    if not (QuestFrame and QuestFrame:IsShown()) or not qid or qid == 0 then
        if box then box:Hide() end
        return
    end
    local r = VQ.ForeverQuests and VQ.ForeverQuests[qid]
    if not r then   -- not a WoW Forever quest we know: nothing to judge
        if box then box:Hide() end
        return
    end
    local lines, good, own, pending = W:Lines(qid, true)
    -- The rewards the quest window shows (the game's own list): Blizzard's quest data has none
    -- for many quests (A Vengeful Fate: Berylline Pads / Stonefist Girdle, the user 2026-11-09).
    local forMe, notWhy, liveN = {}, {}, 0
    for _, kind in ipairs({ "reward", "choice" }) do
        local n = (kind == "reward" and GetNumQuestRewards and GetNumQuestRewards())
            or (kind == "choice" and GetNumQuestChoices and GetNumQuestChoices()) or 0
        for i = 1, n do
            local link = GetQuestItemLink and GetQuestItemLink(kind, i)
            local id = link and C_Item.GetItemInfoInstant(link)
            if id then
                local k, why = Kind(id)
                if k == nil then
                    pending = true
                elseif k ~= "other" then
                    liveN = liveN + 1
                    if k == "mine" then
                        forMe[#forMe + 1] = ItemName(id) or link
                        if Quality(id) >= 3 then good = true end
                    elseif why then
                        notWhy[why] = true
                    end
                end
            end
        end
    end
    if liveN > 0 then
        own = {}   -- the window's own list replaces the data's guess
        if #forMe > 0 then
            lines[#lines + 1] = "|cff3ddc84Rewards for you:|r " .. table.concat(forMe, ", ")
        else
            local w = {}
            for k in pairs(notWhy) do w[#w + 1] = k end
            table.sort(w)
            lines[#lines + 1] = ("|cffaaaaaaRewards: none for your %s%s|r"):format(UnitClass("player") or "class",
                #w > 0 and (" (" .. table.concat(w, ", ") .. ")") or "")
        end
    end
    if #lines == 0 and #own == 0 and not pending then
        -- nothing beyond the quest itself: say that too (the user, 2026-11-09: a blue "?"
        -- repeatable showed no box at all)
        local f = r[6] or ""
        local kind = f:find("d") and "Daily. " or f:find("w") and "Weekly. " or f:find("r") and "Repeatable. " or ""
        local rt = VQ.Forever and VQ.Forever.RewardText and VQ.Forever:RewardText(qid)
        local rew = rt and (" (" .. rt .. ")") or ""
        -- it may give capital reputation you're already Honored with: that buys nothing more
        local rep = (r[12] and r[12]:find("%d+:%d")) and "no reputation that gets you anything more" or "no reputation"
        lines = { ("|cffaaaaaa%sNo follow-up quest and %s: only its own reward%s.|r"):format(kind, rep, rew) }
    end
    local b = Box()
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", QuestFrame, "TOPRIGHT", 4, -2)
    if good then
        b.title:SetText("|cff00c7ffVoidQuest:|r |cff3ddc84worth it for you|r")
    elseif pending then
        -- item data still on its way: no verdict yet (refreshed when it arrives)
        b.title:SetText("|cff00c7ffVoidQuest:|r |cffbbbbbbchecking the rewards...|r")
    else
        b.title:SetText("|cff00c7ffVoidQuest:|r |cffbbbbbbnothing lasting for you|r")
    end
    local body = {}
    -- first: dungeon / raid / elite / regular
    local k, place = QuestKind(r)
    if k == "raid" then
        body[1] = "|cffff4040Raid quest|r" .. (place and (": " .. place) or "")
    elseif k == "dungeon" then
        body[1] = "|cffff8040Dungeon quest|r" .. (place and (": " .. place) or "") .. " |cffaaaaaa(bring a group)|r"
    elseif k == "elite" then
        body[1] = "|cffffd100Elite quest:|r |cffaaaaaahard to solo, bring a group|r"
    else
        body[1] = "|cffaaaaaaRegular quest, out in the world (solo)|r"
    end
    -- how long it really takes and the XP/hour, from players (QuestTime.lua)
    local tl = VQ.QuestTime and VQ.QuestTime:Line(qid)
    if tl then body[#body + 1] = tl end
    if #own > 0 then body[#body + 1] = "|cff3ddc84This quest:|r " .. table.concat(own, ", ") end
    for _, l in ipairs(lines) do body[#body + 1] = l end
    b.text:SetText(table.concat(body, "\n"))
    b:SetHeight(b.title:GetStringHeight() + b.text:GetStringHeight() + 25)
    b:Show()
end
W.ShowBox = ShowBox

----------------------------------------------------------------------
-- Upkeep: preload faction items, forget answers when things change
----------------------------------------------------------------------
local function Forget()
    facCache, chainCache = {}, {}
end
local function ForgetAll()
    myProfs, kindCache = nil, {}
    Forget()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("SKILL_LINES_CHANGED")
ev:RegisterEvent("QUEST_TURNED_IN")
ev:RegisterEvent("UPDATE_FACTION")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:RegisterEvent("QUEST_DETAIL")
ev:RegisterEvent("QUEST_PROGRESS")
ev:RegisterEvent("QUEST_COMPLETE")
ev:RegisterEvent("QUEST_FINISHED")
local forgetQueued = false
ev:SetScript("OnEvent", function(_, e)
    if e == "PLAYER_LOGIN" then
        -- ask for the faction items' data in the background so tooltips have it
        C_Timer.After(15, function()
            local ids = {}
            for _, list in pairs(VQ.ForeverRep or {}) do
                for i = 1, #list - 1, 2 do ids[#ids + 1] = list[i] end
            end
            local i = 0
            local t
            t = C_Timer.NewTicker(0.2, function()
                for _ = 1, 10 do
                    i = i + 1
                    local id = ids[i]
                    if not id then t:Cancel(); return end
                    if not C_Item.IsItemDataCachedByID(id) then C_Item.RequestLoadItemDataByID(id) end
                end
            end)
        end)
    elseif e == "QUEST_DETAIL" or e == "QUEST_PROGRESS" or e == "QUEST_COMPLETE" then
        C_Timer.After(0, ShowBox)
        C_Timer.After(1.5, ShowBox)   -- reward item data arriving late
    elseif e == "QUEST_FINISHED" then
        if box then box:Hide() end
    elseif e == "SKILL_LINES_CHANGED" then
        ForgetAll()
    elseif not forgetQueued then
        -- item data arriving comes in bursts: forget once per second at most
        forgetQueued = true
        C_Timer.After(1, function()
            forgetQueued = false
            Forget()
            if QuestFrame and QuestFrame:IsShown() then ShowBox() end   -- late data can open it too
        end)
    end
end)
