----------------------------------------------------------------------
-- VoidQuest — whose loot is this mob? (2026-11-13)
--
-- The user: "when you hover over a mob can we add a tooltip that shows whos loot it is".
-- One line on an attackable NPC's tooltip, from what the game tells an addon:
--   alive, tagged by someone outside your group (UnitIsTapDenied)  -> "Loot: someone else's"
--        + who, when the mob is fighting a player outside your group (the one who tagged it, most likely)
--   alive, in combat, not tagged by anyone outside your group      -> "Loot: yours" or "your group's" + the loot rule
--   alive, out of combat                                           -> "Loot: free, not tagged yet"
--   dead, with loot (CanLootUnit)                                  -> "Loot: yours, loot it" / "not yours"
-- The game doesn't say who tagged a mob, only that it isn't you or your group, hence "fighting X"
-- rather than "tagged by X". Settings > Guidance > "Whose loot on mob tooltips" turns it off.
----------------------------------------------------------------------
local VQ = VoidQuest
if not VQ then return end
-- WoW Forever only for now: seen working there (2026-11-16, "Loot: free, not tagged yet" on a live
-- mob); retail, where much of this is secret in instances and combat, isn't checked yet.
if (select(4, GetBuildInfo()) or 0) >= 100000 then return end

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end end
local function secret(v) return issecretvalue and issecretvalue(v) end
local function readable(...)
    for i = 1, select("#", ...) do if secret((select(i, ...))) then return false end end
    return true
end

local GREEN, RED, GREY, GOLD = "|cff55ff55", "|cffff6060", "|cffa0a0a0", "|cffffd200"

-- a unit is you, a group member, or one of your group's pets
local function ours(u)
    local exists = safe(UnitExists, u)
    if secret(exists) then return nil end
    if not exists then return false end
    local me = safe(UnitIsUnit, u, "player")
    if secret(me) or me == nil then return nil end
    if me then return true end
    local p = safe(UnitPlayerOrPetInParty, u)
    local r = safe(UnitPlayerOrPetInRaid, u)
    if secret(p) or secret(r) then return nil end
    return (p or r) and true or false
end

-- the group's loot rule, in words (nil solo or unknown)
local METHOD = { [0] = "free for all", [1] = "round robin", [3] = "group loot", [4] = "need before greed", [5] = "personal loot" }
local function rule()
    if not safe(IsInGroup) then return nil end
    local get = C_PartyInfo and C_PartyInfo.GetLootMethod or GetLootMethod
    local m, partyID, raidID = safe(get)
    if type(m) ~= "number" or secret(m) then return nil end
    if m == 2 then   -- master looter: name them
        local u = (raidID and "raid" .. raidID) or (partyID == 0 and "player") or (partyID and "party" .. partyID)
        local n = u and safe(UnitName, u)
        return (n and not secret(n)) and ("master looter: " .. n) or "master looter"
    end
    return METHOD[m]
end

local function line(unit)
    local player = safe(UnitIsPlayer, unit)
    if secret(player) or player then return end
    local dead = safe(UnitIsDead, unit)
    if secret(dead) then return end
    -- a corpse first: it may no longer count as attackable, and CanLootUnit decides it anyway
    if dead then
        local guid = safe(UnitGUID, unit)
        if secret(guid) or not guid then return end
        local has, can = safe(CanLootUnit, guid)
        if not readable(has, can) or not has then return end   -- nothing on it (or looted): say nothing
        if can then return GREEN .. "Loot: yours, loot it|r" end
        -- not yours: another player's turn, or not your group's mob at all (the game doesn't say which)
        return RED .. "Loot: not yours|r"
    end
    local attackable = safe(UnitCanAttack, "player", unit)
    if secret(attackable) or not attackable then return end   -- friendly NPCs: no loot line
    local denied = safe(UnitIsTapDenied, unit)
    if secret(denied) or denied == nil then return end
    local target = unit .. "target"
    if denied then
        local who
        local tp = safe(UnitIsPlayer, target)
        if not secret(tp) and tp and ours(target) == false then
            local n = safe(UnitName, target)
            if not secret(n) and n then who = n end
        end
        return RED .. "Loot: someone else's|r" .. (who and (GREY .. " (fighting " .. who .. ")|r") or "")
    end
    -- Not tap denied: nobody outside your group has tagged it, so it's yours (or your group's) to
    -- take, whoever it's hitting right now (Sol review: the mob's target doesn't prove who tagged it).
    local fighting = safe(UnitAffectingCombat, unit)
    if secret(fighting) then return end
    if not fighting then return GOLD .. "Loot: free, not tagged yet|r" end
    -- In combat alone doesn't make it yours: it may be fighting a guard or another NPC, or have run at
    -- you before anyone hit it (Sol review, 2026-11-16). "Yours" only while it fights you or your group.
    local onUs = ours(target)
    if onUs == nil then return end
    if not onUs then
        local n = safe(UnitName, target)
        if secret(n) then n = nil end
        return GOLD .. "Loot: open, not tagged by anyone else|r" .. (n and (GREY .. " (fighting " .. n .. ")|r") or "")
    end
    local r = rule()
    if not r then return GREEN .. "Loot: yours|r" end
    if r == "personal loot" then return GREEN .. "Loot: yours|r" .. GREY .. " (personal loot)|r" end
    return GREEN .. "Loot: your group's|r" .. GREY .. " (" .. r .. ")|r"
end

-- The line sits in its own small tag ON TOP of the tooltip, not at its bottom under every other
-- addon's lines (the user, 2026-11-13: "its working, wish it could go above the box though").
local function VoidPX()
    local s = UIParent and UIParent:GetEffectiveScale()
    if s and s > 0 and PixelUtil and PixelUtil.GetPixelToUIUnitFactor then return PixelUtil.GetPixelToUIUnitFactor() / s end
    return 1
end

local tag
local function Tag()
    if tag then return tag end
    -- a child of the tooltip: it fades out and hides with it (on UIParent it stayed solid while the
    -- tooltip faded, Sol review)
    tag = CreateFrame("Frame", "VoidQuestLootTag", GameTooltip, "BackdropTemplate")
    tag:SetFrameStrata("TOOLTIP")
    tag:SetClampedToScreen(true)
    tag:EnableMouse(false)
    tag:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = VoidPX() })
    tag:SetBackdropColor(0.04, 0.04, 0.07, 0.92)
    tag:SetBackdropBorderColor(0, 0.78, 1, 0.6)
    tag.text = tag:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tag.text:SetPoint("CENTER", 0, 0)
    tag:Hide()
    return tag
end

local function hideTag() if tag then tag:Hide() end end

local function onUnit(tt)
    if tt ~= GameTooltip then return end
    if VQ:Get("mobLoot") == false then hideTag() return end
    local _, unit = tt:GetUnit()
    if secret(unit) or not unit then hideTag() return end
    local l = line(unit)
    if not l then hideTag() return end
    local t = Tag()
    t.text:SetText(l)
    t:SetSize(t.text:GetStringWidth() + 14, t.text:GetStringHeight() + 8)
    t:ClearAllPoints()
    -- no room above (tooltip at the top of the screen): under it instead
    local top, screen = tt:GetTop(), UIParent:GetTop()
    if not readable(top, screen) then top = nil end   -- retail can hand back secret positions (Sol review)
    if top and screen and top + t:GetHeight() + 4 > screen then
        t:SetPoint("TOPLEFT", tt, "BOTTOMLEFT", 0, -2)
    else
        t:SetPoint("BOTTOMLEFT", tt, "TOPLEFT", 0, 2)
    end
    t:Show()
end

-- gone with the tooltip, and when it moves on to something that isn't a mob
if GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnHide", hideTag)
    GameTooltip:HookScript("OnTooltipCleared", hideTag)
end

VQ.MobLoot = { Line = line }   -- for the offline test

if TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt) pcall(onUnit, tt) end)
elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetUnit", function(tt) pcall(onUnit, tt) end)
end
