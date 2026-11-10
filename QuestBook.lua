----------------------------------------------------------------------
-- VoidQuest — Quest Book (WoW Forever): an achievements-style window for quests.
--
-- The user, 2026-11-10: "an achievements panel that also shows quests i have done, quests i can
-- do and a way to search items given from quests" (sparked by hunting bag quests online at 31).
--
--   left   categories: Summary; Kalimdor / Eastern Kingdoms / Dungeons & other, a progress bar per
--          zone (done / total for this character); Rewards: Bags
--   top    search (quest name, zone or REWARD ITEM name) and a filter: All / Done / Can do / Later / In log
--   right  the quests: status icon, title, level, zone, reward item icons (hover, shift-click to link);
--          click a quest = the way to its giver (or track it if it's in your log)
--   summary  your progress overall and per continent, then "can do now, closest to your level"
--
-- Data: ForeverQuests.lua (Blizzard's Game Data API), ForeverBags.lua (bag slots), VoidGPS's vendor
-- lists for bags you can buy. Status: done = the game's completed flag; can do = not done and not
-- too high for you (Available); later = 5+ levels above you, or not offered to you yet.
-- Quest levels load from the server a few at a time while the book is open and are saved
-- (VoidQuestDB.qlv), so the first open fills in over a few minutes and later opens are instant.
----------------------------------------------------------------------
if (select(4, GetBuildInfo()) or 0) >= 100000 then return end   -- WoW Forever only

local _, ns = ...
local VQ = VoidQuest
local B = {}
VQ.Book = B

local ACC = { 0, 0.78, 1 }
local W, H = 860, 560
local CAT_W, CAT_ROW, CAT_ROWS = 200, 18, 26
local ROW_H, ROWS = 28, 15
local MAX_ICONS = 6
local KALIMDOR, EASTERN = 1414, 1415

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end end
local function FZ() return VQ.Forever end

B.cat, B.filter, B.query = "summary", "all", nil

----------------------------------------------------------------------
-- Data
----------------------------------------------------------------------
local all, byZone, zoneCont, byId   -- built once per login (eligibility depends on the character)

local function continentsOfZones()
    local out = {}
    local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
    for _, cont in ipairs({ KALIMDOR, EASTERN }) do
        for _, z in ipairs(safe(C_Map.GetMapChildrenInfo, cont, zoneType, true) or {}) do
            if z.name then out[z.name] = cont end
        end
    end
    return out
end

-- Search text is matched loosely: "off-hand", "off hand" and "offhand" are the same word ("offhand"),
-- and so are main hand / one hand / two hand, so "off hand sword" is two words: offhand + sword.
local function Norm(s)
    s = (s or ""):lower():gsub("[^%w%s']", " ")   -- punctuation is a space ("plans: x", "off-hand")
    s = s:gsub("off%s+hand", "offhand"):gsub("main%s+hand", "mainhand"):gsub("one%s+hand", "onehand")
        :gsub("two%s+hand", "twohand")
    return s
end

local function Terms(q)
    local t = {}
    for w in Norm(q):gmatch("%S+") do t[#t + 1] = w end
    return t
end

-- every word must START a word in the text: "sword" finds "swords", but "wand" no longer finds
-- "Wanderlust" nor "shield" "Shielding" / "fist" "Hammerfist" (self-test, 2026-11-10)
-- Whole words first (plus plurals: "dagger" = "daggers"), so "wand" isn't "Wandering Boots"; only a
-- search that finds nothing that way falls back to word starts (half-typed words). B.prefix = fallback.
local function AllIn(text, terms)
    text = " " .. text:gsub("%s+", " ") .. " "
    for _, w in ipairs(terms) do
        if B.prefix then
            if not text:find(" " .. w, 1, true) then return false end
        elseif not (text:find(" " .. w .. " ", 1, true) or text:find(" " .. w .. "s ", 1, true)
            or text:find(" " .. w .. "es ", 1, true)
            or (w:sub(-1) == "s" and text:find(" " .. w:sub(1, -2) .. " ", 1, true))) then
            return false
        end
    end
    return true
end

----------------------------------------------------------------------
-- Can this character use it? Classic proficiencies (same tables as VoidGear's Forever panel);
-- a number = the level you learn it at (mail / plate at 40). Off-hand weapons need dual wield.
----------------------------------------------------------------------
local ARMOR = {
    WARRIOR = { [1] = 1, [2] = 1, [3] = 1, [4] = 40, [6] = 1 }, PALADIN = { [1] = 1, [2] = 1, [3] = 1, [4] = 40, [6] = 1 },
    HUNTER = { [1] = 1, [2] = 1, [3] = 40 }, SHAMAN = { [1] = 1, [2] = 1, [3] = 40, [6] = 1 },
    ROGUE = { [1] = 1, [2] = 1 }, DRUID = { [1] = 1, [2] = 1 },
    MAGE = { [1] = 1 }, PRIEST = { [1] = 1 }, WARLOCK = { [1] = 1 },
}
local function set(...) local t = {} for _, v in ipairs({ ... }) do t[v] = true end return t end
local WEAPON = {   -- 0/1 axe, 2 bow, 3 gun, 4/5 mace, 6 polearm, 7/8 sword, 10 staff, 13 fist, 15 dagger, 16 thrown, 18 crossbow, 19 wand
    WARRIOR = set(0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18), PALADIN = set(0, 1, 4, 5, 6, 7, 8),
    HUNTER = set(0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18), ROGUE = set(2, 3, 4, 7, 13, 15, 16, 18),
    SHAMAN = set(0, 1, 4, 5, 10, 13, 15), DRUID = set(4, 5, 10, 13, 15),
    MAGE = set(7, 10, 15, 19), PRIEST = set(4, 10, 15, 19), WARLOCK = set(7, 10, 15, 19),
}
local DUAL = set("WARRIOR", "ROGUE", "HUNTER")
local function CanDualWield()
    local _, cls = UnitClass("player")
    if not DUAL[cls] then return false end
    if IsPlayerSpell and IsPlayerSpell(674) then return true end
    return (UnitLevel("player") or 0) >= (cls == "ROGUE" and 10 or 20)
end
local function CanUse(id)
    local ok, _, _, _, equipLoc, _, classID, subID = pcall(C_Item.GetItemInfoInstant, id)
    if not ok or not equipLoc or equipLoc == "" then return true end   -- not gear: anyone
    local _, cls = UnitClass("player")
    if classID == 4 then
        if subID == 0 then return true end                       -- rings, necks, trinkets, held in off hand
        if subID == 6 then return ARMOR[cls] and ARMOR[cls][6] ~= nil or false end   -- shields
        local lv = ARMOR[cls] and ARMOR[cls][subID]
        -- mail / plate are learned at 40 (Codex: a level 31 warrior passed the plate filter)
        return lv ~= nil and lv <= (UnitLevel("player") or 1)
    elseif classID == 2 then
        if not (WEAPON[cls] and WEAPON[cls][subID]) then return false end
        if equipLoc == "INVTYPE_WEAPONOFFHAND" then return CanDualWield() end
        return true
    end
    return true
end

-- one-hand weapons count as "off hand" only for a character that can dual wield (Codex: a mage's
-- "off hand sword" listed one-hand swords)
local function OffhandCapable(id)
    local ok, _, _, _, equipLoc = pcall(C_Item.GetItemInfoInstant, id)
    return ok and equipLoc == "INVTYPE_WEAPON" and CanDualWield()
end
B.CanUse = CanUse

-- What a reward item IS, for the search (the user, 2026-11-10: "i just searched off hand and nothing
-- shows"): its slot (Off Hand, One-Hand, Held In Off-hand ...), type and sub type (Weapon, Daggers,
-- Leather ...), from the client at once (GetItemInfoInstant needs no server data). One-hand weapons
-- also say "off hand": dual wielders hold them there.
-- quality, item level, required level of a quest reward (ForeverRewardInfo.lua), or nil
function B.RewardInfo(id)
    local s = VQ.ForeverRewardInfo and VQ.ForeverRewardInfo[id]
    if not s then return nil end
    local q, il, rl = s:match("^(%d+),(%d+),(%d+)$")
    return tonumber(q), tonumber(il), tonumber(rl)
end

local itemWords = {}
local function ItemWords(id)
    local w = itemWords[id]
    if w then return w end
    -- all 7 returns (safe() keeps only 3, and the slot is the 4th: "off hand" found nothing)
    local ok, _, itemType, subType, equipLoc, _, classID = pcall(C_Item.GetItemInfoInstant, id)
    if not ok then itemType, subType, equipLoc, classID = nil, nil, nil, nil end
    local bits = { itemType or "", subType or "" }
    if equipLoc and equipLoc ~= "" then
        bits[#bits + 1] = _G[equipLoc] or ""
        if equipLoc == "INVTYPE_WEAPON" then bits[#bits + 1] = "one hand main hand weapon" end   -- + "off hand" when you dual wield (ItemMatches)
        if equipLoc == "INVTYPE_WEAPONOFFHAND" or equipLoc == "INVTYPE_HOLDABLE" or equipLoc == "INVTYPE_SHIELD" then
            bits[#bits + 1] = "off hand"
        end
        if equipLoc == "INVTYPE_WEAPONMAINHAND" then bits[#bits + 1] = "main hand weapon" end
        if equipLoc == "INVTYPE_2HWEAPON" then bits[#bits + 1] = "two hand weapon" end
        if equipLoc == "INVTYPE_HEAD" then bits[#bits + 1] = "helm helmet" end
        if equipLoc == "INVTYPE_SHOULDER" then bits[#bits + 1] = "shoulders" end
        if equipLoc == "INVTYPE_CHEST" or equipLoc == "INVTYPE_ROBE" then bits[#bits + 1] = "chest" end
        if equipLoc == "INVTYPE_WAIST" then bits[#bits + 1] = "belt" end
        if equipLoc == "INVTYPE_LEGS" then bits[#bits + 1] = "pants" end
        if equipLoc == "INVTYPE_FEET" then bits[#bits + 1] = "boots" end
        if equipLoc == "INVTYPE_WRIST" then bits[#bits + 1] = "bracers" end
        if equipLoc == "INVTYPE_HAND" then bits[#bits + 1] = "gloves" end
        if equipLoc == "INVTYPE_NECK" then bits[#bits + 1] = "necklace amulet" end
        if equipLoc == "INVTYPE_CLOAK" then bits[#bits + 1] = "cloak cape back" end
        if equipLoc == "INVTYPE_FINGER" then bits[#bits + 1] = "ring" end
    end
    if classID == 1 then bits[#bits + 1] = "bag" end
    -- quality, by its color too ("blue leather pants", the user 2026-11-10): ForeverRewardInfo.lua
    -- (Blizzard's item table), else the client's own value when it has the item
    local q = B.RewardInfo(id)
    if q == nil then q = safe(C_Item.GetItemQualityByID, id) end
    local QWORD = { [0] = "poor grey gray", [1] = "common white", [2] = "uncommon green", [3] = "rare blue",
        [4] = "epic purple", [5] = "legendary orange" }
    if q and QWORD[q] then bits[#bits + 1] = QWORD[q] end
    w = Norm(table.concat(bits, " "))
    itemWords[id] = w
    return w
end

-- one reward item fits every word (its kind + its name when the client has it); with "Only what I
-- can use" on, it must also be something this character can wear / wield
-- name: the reward's name from the quest data (the client may not have the item cached yet)
function B.ItemMatches(id, terms, name)
    if B.usable and not CanUse(id) then return false end
    local text = ItemWords(id) .. " " .. Norm(safe(C_Item.GetItemNameByID, id) or name or "")
    if OffhandCapable(id) then text = text .. " offhand" end
    return AllIn(text, terms)
end

-- The quest data lists reward names in the same order as their item IDs ("A, B" or "choose: A / B");
-- pair them when the counts agree
local function RewardNames(text, ids)
    local list = {}
    for tok in ids:gmatch("%d+") do list[#list + 1] = tonumber(tok) end
    if #list == 0 or text == "" then return nil end
    local s = text:gsub("^choose:%s*", ""):gsub(" / ", "\1"):gsub(", ", "\1")
    local names = {}
    for n in (s .. "\1"):gmatch("([^\1]*)\1") do names[#names + 1] = n end
    if #names ~= #list then return nil end
    local out = {}
    for i, id in ipairs(list) do out[id] = names[i] end
    return out
end

local function Build()
    if all then return end
    local F = FZ()
    all, byZone, byId = {}, {}, {}
    zoneCont = continentsOfZones()
    local names = VQ.ForeverNames or {}
    for id, r in pairs(VQ.ForeverQuests or {}) do
        local t = (r[1] or ""):lower()
        local dev = t:find("test quest", 1, true) or t:find("[dnt]", 1, true) or t:find("[ph]", 1, true) or t:find("deprecated", 1, true)
        if not dev and F:Eligible(r) then
            local zone = names[r[2]] or names[r[9]] or "Other"
            local e = { id = id, title = r[1], zone = zone, rewards = r[10] or "", ids = r[11] or "", flags = r[6] or "",
                xp = r[4] or 0, bag = F.BagOf and F:BagOf(r) or nil }
            e.tz = Norm(e.title .. " " .. zone)                 -- quest name + zone: always searchable
            e.names = RewardNames(e.rewards, e.ids)
            e.search = Norm(e.title .. " " .. zone .. " " .. e.rewards)
            all[#all + 1] = e; byId[id] = e
            local z = byZone[zone]
            if not z then z = {}; byZone[zone] = z end
            z[#z + 1] = e
        end
    end
end

-- status: done / log / can / later; e.low = grey (still doable); e.level (0 = not loaded yet)
-- Same rules as ForeverZone's Available, but with known levels only (no server requests here)
local RED = 5
local function Classify(e)
    local F = FZ()
    local st = F:Status(e.id)
    e.level = F:KnownLevel(e.id)
    e.low = nil
    -- level not loaded yet: estimate it from the rewards' required level (Blizzard's item table), so a
    -- level-60 Silithus quest isn't "can do now" at 31 while it loads (blue leather pants, 2026-11-10)
    e.est = nil
    if e.level == 0 then
        local best = 0
        for tok in e.ids:gmatch("%d+") do
            -- Forever's item table leaves RequiredLevel at 0 for many items; Classic gear is about
            -- 5 item levels above its required level (Cenarion Reservist's Leggings: 63 -> ~58)
            local _, il, req = B.RewardInfo(tonumber(tok))
            local est = math.min(60, math.max(req or 0, (il or 0) - 5))
            if est > best then best = est end
        end
        if best > 0 then e.est = best end
    end
    if st == "open" then
        local me = UnitLevel("player") or 0
        local b = VoidQuestCharDB and VoidQuestCharDB.blocked and VoidQuestCharDB.blocked[e.id]
        if b and me <= b then st = "later"
        elseif e.level > 0 and e.level >= me + RED then st = "later"
        elseif e.est and e.est >= me + RED then st = "later"
        else
            st = "can"
            local t = safe(C_QuestLog.IsQuestTrivial, e.id)
            if t and not (issecretvalue and issecretvalue(t)) then e.low = true end
        end
    end
    e.status = st
    return st
end

local function Counts(list)
    local c = { all = #list, done = 0, can = 0, later = 0, log = 0 }
    for _, e in ipairs(list) do
        local st = e.status or Classify(e)
        c[st] = (c[st] or 0) + 1
    end
    return c
end

-- background: ask the server for quest levels a few at a time while the book is open
local queue, qpos, loader = nil, 1, nil
local function StartLoader()
    if loader then return end
    queue, qpos = {}, 1
    for _, e in ipairs(all) do
        if (e.level or 0) == 0 and e.status ~= "done" then queue[#queue + 1] = e end
    end
    if #queue == 0 then return end
    loader = C_Timer.NewTicker(0.25, function()
        if not (B.win and B.win:IsShown()) or qpos > #queue then
            if loader then loader:Cancel(); loader = nil end
            return
        end
        for _ = 1, 10 do
            local e = queue[qpos]
            if not e then break end
            FZ():Level(e.id)
            qpos = qpos + 1
        end
    end)
end

----------------------------------------------------------------------
-- Categories (left)
----------------------------------------------------------------------
local cats   -- { { header = "Kalimdor" } | { key, label, list } }
local function Categories()
    Build()
    cats = { { key = "summary", label = "Summary" } }
    local groups = { { KALIMDOR, "Kalimdor" }, { EASTERN, "Eastern Kingdoms" }, { false, "Dungeons & other" } }
    for _, g in ipairs(groups) do
        local zs = {}
        for zone, list in pairs(byZone) do
            local c = zoneCont[zone]
            if (g[1] and c == g[1]) or (not g[1] and not c) then zs[#zs + 1] = { key = "zone:" .. zone, label = zone, list = list } end
        end
        table.sort(zs, function(a, b) return a.label < b.label end)
        if #zs > 0 then
            cats[#cats + 1] = { header = g[2] }
            for _, z in ipairs(zs) do cats[#cats + 1] = z end
        end
    end
    local bags = {}
    for _, e in ipairs(all) do if e.bag then bags[#bags + 1] = e end end
    cats[#cats + 1] = { header = "Rewards" }
    cats[#cats + 1] = { key = "bags", label = "Bags", list = bags, vendorBags = true }
    return cats
end

local function CatByKey(key)
    for _, c in ipairs(cats or Categories()) do if c.key == key then return c end end
end

----------------------------------------------------------------------
-- The list (right)
----------------------------------------------------------------------
local ORDER = { log = 1, can = 2, later = 3, done = 4 }
local function SortList(list)
    local me = UnitLevel("player") or 1
    table.sort(list, function(a, b)
        if a.vendor or b.vendor then
            if (a.vendor ~= nil) ~= (b.vendor ~= nil) then return b.vendor ~= nil end
            return false
        end
        if a.status ~= b.status then return ORDER[a.status] < ORDER[b.status] end
        local la = (a.level or 0) > 0 and a.level or (a.est or 0)
        local lb = (b.level or 0) > 0 and b.level or (b.est or 0)
        if (la > 0) ~= (lb > 0) then return la > 0 end
        if a.status == "can" and la > 0 then
            local da, db = math.abs(la - me), math.abs(lb - me)
            if da ~= db then return da < db end
        elseif la ~= lb then
            return la < lb
        end
        return a.title < b.title
    end)
end

local function Current()
    Build()
    if B.query then
        -- every word must fit the quest (title / zone / reward names) or ONE reward item ("off hand
        -- sword" = a reward that is a sword AND goes in the off hand); "Only what I can use" counts
        -- only rewards your class can wear or wield
        local terms, out = Terms(B.query), {}
        B.prefix = false
        for pass = 1, 2 do
        if pass == 2 then
            if #out > 0 then break end
            B.prefix = true          -- nothing as whole words: try word starts ("dag", "leathe")
        end
        for _, e in ipairs(all) do
            -- the quest's own name or zone always counts ("hatefury", "desolace" found nothing with
            -- "Only what I can use" on, self-test 2026-11-10)
            local hit = AllIn(e.tz, terms) or (not B.usable and AllIn(e.search, terms))
            if not hit then
                for tok in e.ids:gmatch("%d+") do
                    local id = tonumber(tok)
                    if B.ItemMatches(id, terms, e.names and e.names[id]) then hit = true; break end
                end
            end
            if hit then out[#out + 1] = e end
        end
        end
        return out, ("Search: \"%s\"%s"):format(B.query, B.usable and "  (only what you can use)" or "")
    end
    local c = CatByKey(B.cat) or CatByKey("summary")
    if c.key == "summary" then
        local out = {}
        for _, e in ipairs(all) do if (e.status or Classify(e)) == "can" or e.status == "log" then out[#out + 1] = e end end
        return out, "Can do now and in your log, closest to your level", true
    end
    return c.list, c.label, false, c.vendorBags
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local function VoidPX()
    local s = UIParent and UIParent:GetEffectiveScale()
    if s and s > 0 and PixelUtil and PixelUtil.GetPixelToUIUnitFactor then return PixelUtil.GetPixelToUIUnitFactor() / s end
    return 1
end

local function Bar(parent, w, h)
    local bar = CreateFrame("StatusBar", nil, parent, "BackdropTemplate")
    bar:SetSize(w, h)
    bar:SetStatusBarTexture(VQ.texture or "Interface\\Buttons\\WHITE8X8")
    bar:SetStatusBarColor(ACC[1], ACC[2], ACC[3], 0.8)
    bar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = VoidPX() })
    bar:SetBackdropColor(0.1, 0.1, 0.13, 0.9)
    bar:SetBackdropBorderColor(ACC[1], ACC[2], ACC[3], 0.35)
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER")
    return bar
end

local function SetBar(bar, done, total)
    bar:SetMinMaxValues(0, math.max(1, total))
    bar:SetValue(done)
    bar.text:SetText(("%d / %d"):format(done, total))
end

local STATUS_ICON = {
    done = "Interface\\RaidFrame\\ReadyCheck-Ready",
    log = "Interface\\GossipFrame\\ActiveQuestIcon",
    can = "Interface\\GossipFrame\\AvailableQuestIcon",
    later = "Interface\\GossipFrame\\AvailableQuestIcon",
}
local STATUS_TEXT = { done = "|cff66ff66done|r", log = "|cffffd200in your log|r", can = "|cffffffffcan do now|r",
    later = "|cff888888later|r" }

local function ItemLinkOf(id)
    local _, link = safe(C_Item.GetItemInfo, id)
    return link
end

local function MakeRow(parent, i)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(W - CAT_W - 52, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18); row.icon:SetPoint("LEFT", 4, 0)
    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.title:SetPoint("TOPLEFT", 28, -2); row.title:SetPoint("RIGHT", -(MAX_ICONS * 22 + 10), 0)
    row.title:SetJustifyH("LEFT"); row.title:SetWordWrap(false)
    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.sub:SetPoint("BOTTOMLEFT", 28, 2); row.sub:SetPoint("RIGHT", -(MAX_ICONS * 22 + 10), 0)
    row.sub:SetJustifyH("LEFT"); row.sub:SetWordWrap(false)
    row.items = {}
    for k = 1, MAX_ICONS do
        local b = CreateFrame("Button", nil, row)
        b:SetSize(20, 20)
        b:SetPoint("RIGHT", row, "RIGHT", -4 - (MAX_ICONS - k) * 22, 0)
        b.tex = b:CreateTexture(nil, "ARTWORK"); b.tex:SetAllPoints()
        b:SetScript("OnEnter", function(s)
            if not s.item then return end
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(s.item); GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", function(s)
            if not s.item then return end
            local link = ItemLinkOf(s.item)
            if IsModifiedClick("CHATLINK") and link then ChatEdit_InsertLink(link)
            elseif IsModifiedClick("DRESSUP") and link then DressUpItemLink(link) end
        end)
        row.items[k] = b
    end
    row:SetScript("OnClick", function(s)
        if s.e and s.e.vendor then
            if VoidGPS and VoidGPS.Goods then VoidGPS.Goods:GoVendor(s.e.v, s.e.name) end
        elseif s.e and s.e.id then
            FZ():Go(s.e.id)
        end
    end)
    row:SetScript("OnEnter", function(s)
        if not s.e then return end
        if s.e.vendor then
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(s.e.item)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Sold by " .. s.e.v.name, 0.6, 1, 0.6)
            GameTooltip:AddLine("Click: the way to the vendor (VoidGPS)", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        elseif FZ().QuestTooltip then
            FZ().QuestTooltip(s, s.e.id)
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local BAG_KIND = function(f) return (FZ().BAG_KIND and FZ().BAG_KIND[f]) or "special bag" end

local function FillRow(row, e)
    row.e = e
    for _, b in ipairs(row.items) do b.item = nil; b:Hide() end
    if e.header then
        row.icon:Hide()
        row.title:SetText("|cffffd200" .. e.header .. "|r"); row.sub:SetText("")
        row:Show()
        return
    end
    row.icon:Show()
    if e.vendor then
        row.icon:SetTexture(safe(C_Item.GetItemIconByID, e.item) or 134400)
        row.icon:SetDesaturated(false)
        local kind = e.family ~= 0 and (" |cff88ccff" .. BAG_KIND(e.family) .. "|r") or ""
        row.title:SetText(("|cffffffff%s|r  |cff66ff66%d slots|r%s"):format(e.name, e.slots, kind))
        local coin = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or _G.GetCoinTextureString
        row.sub:SetText(("Sold by %s%s%s"):format(e.v.name, e.v.yards and (" (%d yd)"):format(e.v.yards) or "",
            (e.buy and e.buy > 0 and coin) and ("  " .. coin(e.buy)) or ""))
        row:Show()
        return
    end
    local st = e.status or Classify(e)
    -- in your log: Blizzard's grey "?" while you're still on it, yellow "?" only when it's ready to
    -- turn in (the user, 2026-11-10: Stronger than Steel showed the yellow one, not finished yet)
    local ready = st == "log" and safe(C_QuestLog.IsComplete, e.id) and true or false
    row.icon:SetTexture(STATUS_ICON[st])
    row.icon:SetDesaturated(st == "later" or e.low or (st == "log" and not ready))   -- grey "?" = not finished
    local color = (st == "done" or st == "later") and "|cff999999" or st == "log" and "|cffffd200" or "|cffffffff"
    local lv = (e.level or 0) > 0 and ("[" .. e.level .. "] ") or (e.est and ("[~" .. e.est .. "] ")) or ""
    local bag = e.bag and ("  |cff66ff66%d-slot %s|r"):format(e.bag[1], e.bag[2] ~= 0 and BAG_KIND(e.bag[2]) or "bag") or ""
    row.title:SetText(color .. lv .. e.title .. "|r" .. bag)
    local bits = { e.zone, ready and "|cffffd200ready to turn in|r" or STATUS_TEXT[st] }
    if e.low then bits[#bits + 1] = "|cff888888low level|r" end
    if e.rewards:find("^choose:") then bits[#bits + 1] = "pick one reward" end
    row.sub:SetText(table.concat(bits, "  ·  "))
    -- reward icons, bags first: a "pick one" quest can have 7+ rewards and the bag was cut off
    -- and when searching, the rewards that match come first ("off hand": the dagger, not the boots)
    local ids, bags = {}, VQ.ForeverBags or {}
    local terms = B.query and Terms(B.query)
    local front = 0
    for tok in e.ids:gmatch("%d+") do
        local id = tonumber(tok)
        local hit = terms and B.ItemMatches(id, terms, e.names and e.names[id])
        if hit or (not terms and bags[id]) then front = front + 1; table.insert(ids, front, id) else ids[#ids + 1] = id end
    end
    for k = 1, math.min(MAX_ICONS, #ids) do
        local b, id = row.items[k], ids[k]
        b.item = id
        b.tex:SetTexture(safe(C_Item.GetItemIconByID, id) or 134400)
        b:Show()
    end
    row:Show()
end

local win
local function Render()
    if not (win and win:IsShown()) then return end
    Categories()
    local list, title, isSummary, vendorBags = Current()
    -- counts + filter
    local c = Counts(list)
    for key, btn in pairs(win.filters) do
        btn:SetText(("%s (%d)"):format(btn.label, c[key] or 0))
        btn:SetEnabled(B.filter ~= key)
    end
    local shown = {}
    for _, e in ipairs(list) do
        if B.filter == "all" or e.status == B.filter then shown[#shown + 1] = e end
    end
    SortList(shown)
    if isSummary then
        local me = UnitLevel("player") or 1
        local near = {}
        for _, e in ipairs(shown) do
            if e.status == "log" or (e.level or 0) == 0 or math.abs((e.level or 0) - me) <= 6 then near[#near + 1] = e end
        end
        shown = near
    end
    if vendorBags and B.filter ~= "done" and FZ().VendorBags then
        local vb = FZ():VendorBags()
        if #vb > 0 then
            shown[#shown + 1] = { header = "Bags you can buy (normal bags biggest first, then reagent bags)" }
            for _, v in ipairs(vb) do shown[#shown + 1] = v end
        end
    end
    win.listTitle:SetText(("%s  |cff888888%d|r"):format(title, #shown))

    -- summary block
    win.summary:SetShown(isSummary and not B.query)
    if isSummary and not B.query then
        local tot = Counts(all)
        SetBar(win.sumBars.all, tot.done, tot.all)
        for cont, bar in pairs(win.sumBars.cont) do
            local d, t = 0, 0
            for _, e in ipairs(all) do
                local zc = zoneCont[e.zone] or false
                if zc == cont then t = t + 1; if e.status == "done" then d = d + 1 end end
            end
            SetBar(bar, d, t)
        end
        win.sumText:SetText(("|cffffffff%d|r can do now  ·  |cffffd200%d|r in your log  ·  |cff888888%d|r later  ·  |cff66ff66%d|r done")
            :format(tot.can, tot.log, tot.later, tot.done))
    end
    local top = (isSummary and not B.query) and -150 or -64
    win.list:ClearAllPoints()
    win.list:SetPoint("TOPLEFT", win, "TOPLEFT", CAT_W + 20, top - 20)
    win.list:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -30, 12)
    win.listTitle:ClearAllPoints()
    win.listTitle:SetPoint("BOTTOMLEFT", win.list, "TOPLEFT", 2, 4)
    local rows = math.floor((win.list:GetHeight() > 0 and win.list:GetHeight() or (H + top - 32)) / ROW_H)
    rows = math.max(1, math.min(ROWS, rows))

    FauxScrollFrame_Update(win.scroll, #shown, rows, ROW_H)
    local off = FauxScrollFrame_GetOffset(win.scroll)
    for i = 1, ROWS do
        local row = win.rows[i]
        local e = i <= rows and shown[off + i]
        if e then FillRow(row, e) else row:Hide(); row.e = nil end
    end

    -- categories
    FauxScrollFrame_Update(win.catScroll, #cats, CAT_ROWS, CAT_ROW)
    local coff = FauxScrollFrame_GetOffset(win.catScroll)
    for i, b in ipairs(win.cats) do
        local c2 = cats[coff + i]
        b.cat = c2
        if c2 then
            if c2.header then
                b.text:SetText("|cffffd200" .. c2.header .. "|r"); b.count:SetText(""); b.bar:Hide()
            else
                local sel = (not B.query) and B.cat == c2.key
                b.text:SetText((sel and "|cff00c7ff" or "|cffffffff") .. "  " .. c2.label .. "|r")
                if c2.list then
                    local cc = Counts(c2.list)
                    b.count:SetText(("%d/%d"):format(cc.done, cc.all))
                    b.bar:SetMinMaxValues(0, math.max(1, cc.all)); b.bar:SetValue(cc.done); b.bar:Show()
                else
                    b.count:SetText(""); b.bar:Hide()
                end
            end
            b:Show()
        else
            b:Hide()
        end
    end
end
B.Render = Render

local function BuildWindow()
    local f = CreateFrame("Frame", "VoidQuestBook", UIParent, "BackdropTemplate")
    f:Hide()
    f:SetSize(W, H)
    f:SetPoint("CENTER", 0, 40)
    f:SetFrameStrata("HIGH"); f:SetToplevel(true)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    VQ:CreateBackdrop(f)
    tinsert(UISpecialFrames, "VoidQuestBook")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cff00c7ffQuest Book|r")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)

    -- search
    f.search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
    f.search:SetSize(260, 20); f.search:SetPoint("TOPRIGHT", -36, -10); f.search:SetAutoFocus(false)
    if f.search.Instructions then f.search.Instructions:SetText("Search quests, zones or reward items") end
    f.search:HookScript("OnTextChanged", function(b)
        local t = strtrim(b:GetText() or "")
        B.query = (#t >= 2) and t or nil
        FauxScrollFrame_SetOffset(f.scroll, 0); f.scroll:SetVerticalScroll(0)
        Render()
    end)

    -- never keep the keyboard: Enter / Esc / closing the book let go of it (2026-11-10: a "/reload"
    -- typed afterwards went into the search box instead of chat)
    f.search:HookScript("OnEnterPressed", function(b) b:ClearFocus() end)
    f.search:HookScript("OnEscapePressed", function(b) b:ClearFocus() end)
    f:HookScript("OnHide", function() f.search:ClearFocus() end)

    -- only rewards this character can wear / wield (on by default; saved)
    B.usable = VQ:Get("bookUsableOnly") ~= false
    f.usable = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.usable:SetSize(22, 22); f.usable:SetPoint("RIGHT", f.search, "LEFT", -150, 0)
    f.usable:SetChecked(B.usable)
    f.usable.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.usable.label:SetPoint("LEFT", f.usable, "RIGHT", 0, 1); f.usable.label:SetText("Only what I can use")
    f.usable:SetScript("OnClick", function(b)
        B.usable = b:GetChecked() and true or false
        VQ:Set("bookUsableOnly", B.usable)
        FauxScrollFrame_SetOffset(f.scroll, 0); f.scroll:SetVerticalScroll(0)
        Render()
    end)
    f.usable:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Only what I can use")
        GameTooltip:AddLine("When searching, count only rewards your class can wear or wield (armor type, weapon skills, dual wield).", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.usable:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- filters
    f.filters = {}
    local defs = { { "all", "All" }, { "can", "Can do" }, { "log", "In log" }, { "later", "Later" }, { "done", "Done" } }
    local prev
    for _, d in ipairs(defs) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(96, 20)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", CAT_W + 20, -38) end
        b.label = d[2]
        b:SetScript("OnClick", function()
            B.filter = d[1]
            FauxScrollFrame_SetOffset(f.scroll, 0); f.scroll:SetVerticalScroll(0)
            Render()
        end)
        f.filters[d[1]] = b
        prev = b
    end

    -- categories (left)
    f.catScroll = CreateFrame("ScrollFrame", nil, f, "FauxScrollFrameTemplate")
    f.catScroll:SetPoint("TOPLEFT", 10, -40); f.catScroll:SetSize(CAT_W - 16, CAT_ROW * CAT_ROWS)
    f.catScroll:SetScript("OnVerticalScroll", function(s, o) FauxScrollFrame_OnVerticalScroll(s, o, CAT_ROW, Render) end)
    f.cats = {}
    for i = 1, CAT_ROWS do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(CAT_W - 20, CAT_ROW)
        b:SetPoint("TOPLEFT", 10, -40 - (i - 1) * CAT_ROW)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", 2, 1); b.text:SetPoint("RIGHT", -46, 0); b.text:SetJustifyH("LEFT"); b.text:SetWordWrap(false)
        b.count = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        b.count:SetPoint("RIGHT", -2, 1)
        b.bar = CreateFrame("StatusBar", nil, b)
        b.bar:SetPoint("BOTTOMLEFT", 10, 1); b.bar:SetPoint("BOTTOMRIGHT", -2, 1); b.bar:SetHeight(2)
        b.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        b.bar:SetStatusBarColor(ACC[1], ACC[2], ACC[3], 0.7)
        b:SetScript("OnClick", function(s)
            if not (s.cat and s.cat.key) then return end
            B.cat = s.cat.key
            if B.query then f.search:SetText("") end
            FauxScrollFrame_SetOffset(f.scroll, 0); f.scroll:SetVerticalScroll(0)
            Render()
        end)
        f.cats[i] = b
    end

    -- summary block (bars)
    f.summary = CreateFrame("Frame", nil, f)
    f.summary:SetPoint("TOPLEFT", CAT_W + 20, -66); f.summary:SetSize(W - CAT_W - 50, 80)
    f.sumBars = { cont = {} }
    local function label(text, y)
        local l = f.summary:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        l:SetPoint("TOPLEFT", 0, y); l:SetText(text)
        return l
    end
    label("All quests you can do", 0)
    f.sumBars.all = Bar(f.summary, 380, 14); f.sumBars.all:SetPoint("TOPLEFT", 170, 0)
    label("Kalimdor", -20)
    f.sumBars.cont[KALIMDOR] = Bar(f.summary, 380, 14); f.sumBars.cont[KALIMDOR]:SetPoint("TOPLEFT", 170, -20)
    label("Eastern Kingdoms", -40)
    f.sumBars.cont[EASTERN] = Bar(f.summary, 380, 14); f.sumBars.cont[EASTERN]:SetPoint("TOPLEFT", 170, -40)
    f.sumText = f.summary:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.sumText:SetPoint("TOPLEFT", 0, -64)

    -- quest list (right)
    f.list = CreateFrame("Frame", nil, f)
    f.listTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.scroll = CreateFrame("ScrollFrame", nil, f, "FauxScrollFrameTemplate")
    f.scroll:SetPoint("TOPLEFT", f.list, "TOPLEFT"); f.scroll:SetPoint("BOTTOMRIGHT", f.list, "BOTTOMRIGHT")
    f.scroll:SetScript("OnVerticalScroll", function(s, o) FauxScrollFrame_OnVerticalScroll(s, o, ROW_H, Render) end)
    f.rows = {}
    for i = 1, ROWS do f.rows[i] = MakeRow(f.list, i) end

    f:SetScript("OnShow", function()
        if B.CheckStale then B:CheckStale() end   -- quests changed while closed
        Render()        -- classifies everything first, so the loader skips done quests
        StartLoader()
    end)
    return f
end

----------------------------------------------------------------------
-- Self-test (developer): run many realistic searches at once and save what each found to
-- VoidQuestDB.bookTest, so they can be checked from the SavedVariables file after a /reload instead
-- of typed one by one (the user, 2026-11-10: "it's so frustrating that I have to walk you through this").
--   /run VoidQuest.Book:SelfTest()   then /reload
----------------------------------------------------------------------
local TESTS = {
    "off hand", "offhand", "off-hand", "off hand sword", "sword off hand", "one hand", "two hand", "main hand",
    "dagger", "daggers", "swords", "mace", "fist", "axe", "staff", "bow", "gun", "wand", "shield",
    "cloth", "leather", "mail", "plate", "blue leather pants", "green leather boots", "green cloak", "blue ring",
    "necklace", "trinket", "helm", "shoulders", "chest", "belt", "pants", "boots", "gloves", "bracers",
    "purple", "epic", "rare", "bag", "pouch", "quiver",
    "dagger of deals", "hatefury", "desolace", "stronger than steel", "xyzzy",
    "reservist", "ruby blade", "leggings", "fist weapon", "wanderlust", "shadow shielding", "dag", "leathe", "wand", "ironforge", "darnassus", "stormwind", "teldrassil", "orgrimmar", "thunder bluff",
}
local NO_FILTER = { "shield", "plate", "staff", "wand", "axe", "off hand", "blue leather pants" }

function B:SelfTest()
    Build()
    local QN = { [0] = "grey", "white", "green", "blue", "purple", "orange" }
    local function run(q, usable)
        local keepQ, keepU = B.query, B.usable
        B.query, B.usable = q, usable
        local list = Current()
        local terms = Terms(q)
        local c = Counts(list)
        SortList(list)
        local top = {}
        for i = 1, math.min(4, #list) do
            local e = list[i]
            local item
            for tok in e.ids:gmatch("%d+") do
                local id = tonumber(tok)
                if B.ItemMatches(id, terms, e.names and e.names[id]) then
                    local qq, il, rl = B.RewardInfo(id)
                    item = ("%s [%s ilvl%s req%s %s]"):format(safe(C_Item.GetItemNameByID, id) or ("item " .. id),
                        QN[qq or -1] or "?", il or "?", rl or "?", ItemWords(id))
                    break
                end
            end
            top[i] = ("%s%s %s (%s) -> %s"):format(e.level > 0 and ("[" .. e.level .. "]") or "",
                e.est and ("[~" .. e.est .. "]") or "", e.title, e.status, item or "matched by quest text")
        end
        B.query, B.usable = keepQ, keepU
        return { q = q, usable = usable, n = #list, can = c.can, later = c.later, done = c.done, log = c.log, top = top }
    end
    local out = { at = date("%Y-%m-%d %H:%M"), level = UnitLevel("player"), class = select(2, UnitClass("player")), runs = {} }
    for _, q in ipairs(TESTS) do out.runs[#out.runs + 1] = run(q, true) end
    for _, q in ipairs(NO_FILTER) do out.runs[#out.runs + 1] = run(q, false) end
    -- the in-log icon: grey "?" unless ready to turn in
    out.inLog = {}
    for _, e in ipairs(all) do
        if (e.status or Classify(e)) == "log" then
            out.inLog[#out.inLog + 1] = ("%s ready=%s"):format(e.title, tostring(safe(C_QuestLog.IsComplete, e.id) and true or false))
        end
    end
    out.focus = win and win.search and tostring(win.search:HasFocus()) or "no window"
    VoidQuestDB = VoidQuestDB or {}
    VoidQuestDB.bookTest = out
    VQ:Print(("Quest Book self-test: %d searches saved; /reload to write them."):format(#out.runs))
end

function B:Toggle()
    if not (VQ.ForeverQuests and FZ()) then VQ:Print("the Quest Book is for WoW Forever."); return end
    win = win or BuildWindow()
    B.win = win
    win:SetShown(not win:IsShown())
end

-- redraw as levels arrive and quests are taken / turned in (once per burst)
-- Codex review (2026-11-10): statuses go stale when quests change while the book is closed (now: mark
-- everything stale, re-check on the next open); a level arriving re-checks only that quest, not every
-- quest still without one; QUEST_LOG_UPDATE turns the grey "?" yellow while the book is open.
local pending, staleAll
local ev = CreateFrame("Frame")
for _, e in ipairs({ "QUEST_DATA_LOAD_RESULT", "QUEST_TURNED_IN", "QUEST_ACCEPTED", "QUEST_REMOVED", "PLAYER_LEVEL_UP",
    "QUEST_LOG_UPDATE" }) do
    pcall(ev.RegisterEvent, ev, e)
end
local function Redraw()
    if pending or not (win and win:IsShown()) then return end
    pending = true
    C_Timer.After(0.5, function() pending = nil; Render() end)
end
ev:SetScript("OnEvent", function(_, e, qid)
    if not all then return end
    if e == "QUEST_DATA_LOAD_RESULT" then
        local x = qid and byId and byId[qid]
        if x then x.status = nil; Redraw() end
        return
    end
    if e == "QUEST_LOG_UPDATE" then Redraw() return end   -- readiness is read live when drawn
    -- accepted / turned in / abandoned / level: every status may change
    if win and win:IsShown() then
        for _, x in ipairs(all) do x.status = nil end
        Redraw()
    else
        staleAll = true
    end
end)
function B:CheckStale()
    if staleAll and all then
        staleAll = nil
        for _, x in ipairs(all) do x.status = nil end
    end
end

BINDING_HEADER_VOIDQUEST = BINDING_HEADER_VOIDQUEST or "VoidQuest"
BINDING_NAME_VOIDQUEST_BOOK = "Open the Quest Book"
function VoidQuest_ToggleBook() B:Toggle() end
