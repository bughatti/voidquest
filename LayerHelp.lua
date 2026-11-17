----------------------------------------------------------------------
-- LayerHelp: "Help others change layer", ONE switch for every Void addon (WoW Forever, 2026-11-17).
--
-- The user: helping is ON for everyone (more helpers = more swaps), with a short pop-up the first time
-- (VoidLayerCore.lua, once per account); the off switch lives in each addon's own settings (VoidQuest,
-- VoidBounty, VoidLayer's gear) and the hub has ONE all-in switch, "Help Void layer hopping". VoidGather and
-- VoidDungeon have no settings window of their own (their settings are the hub's switches), so for them the
-- hub switch is the one. Flip it anywhere and it changes for every Void addon you have.
--
-- Also registers the layer engine (VoidLayerCore.lua) for the addons that newly carry it, each with its own
-- per-character table (VoidLayer and VoidSweep register themselves, with higher priority).
--
-- Copied as-is into each addon that carries it (source: wow-addons/_shared/LayerHelp.lua).
----------------------------------------------------------------------
local ADDON, ns = ...
local H = {}
ns.LayerHelp = H

local function forever() return RegionalUniqueNamesEnabled ~= nil and RegionalUniqueNamesEnabled() == true end

H.LABEL = "Help others change layer"
H.TIP = "WoW Forever: when a Void player on your layer asks, you send them a quick group invite (only while you're solo and out of combat; the group ends on its own). The same switch in every Void addon and in the hub."

function H.On()
    local c = rawget(_G, "VoidLayerCore")
    return c and c:HostingOn() or false
end
function H.Set(on)
    local c = rawget(_G, "VoidLayerCore")
    if c then c:SetHosting(on and true or false) end
end

-- where the off switch is, per addon running the engine (the pop-up names it)
H.WHERE = {
    VoidLayer   = "the VoidLayer window's gear",
    VoidSweep   = "the Void hub (Help Void layer hopping)",
    VoidQuest   = "VoidQuest's settings",
    VoidBounty  = "VoidBounty's Settings tab",
    VoidGather  = "the Void hub (Help Void layer hopping)",
    VoidDungeon = "the Void hub (Help Void layer hopping)",
}

-- the engine for the addons that newly carry it: below VoidLayer (2) and VoidSweep (1), so their settings
-- win when installed; each gets a small table in its own per-character saved data
local REG = {
    VoidQuest   = { prio = 0.4, db = "VoidQuestCharDB" },
    VoidGather  = { prio = 0.3, db = "VoidGatherCharDB" },
    VoidBounty  = { prio = 0.2, db = "VoidBountyCharDB" },
    VoidDungeon = { prio = 0.1, db = "VoidDungeonCharDB" },
}
local r = REG[ADDON]
if r and ns.LayerCoreSettings then
    ns.LayerCoreSettings(r.prio, ADDON, function()
        local g = rawget(_G, r.db)
        if type(g) ~= "table" then g = {}; rawset(_G, r.db, g) end
        if type(g.layer) ~= "table" then g.layer = {} end
        return g.layer
    end)
end

-- every copy offers the same functions; the first one wins the global (they're identical)
if rawget(_G, "VoidLayerHelp") == nil then rawset(_G, "VoidLayerHelp", H) end

-- the hub's one switch, added once by whichever Void addon loads first
if forever() then
    VoidHubToggles = VoidHubToggles or {}
    local have = false
    for _, t in ipairs(VoidHubToggles) do if t.id == "VoidLayer.host" then have = true break end end
    if not have then
        table.insert(VoidHubToggles, {
            -- id "VoidLayer.host": the hub files it under Layers (next to Rare alerts), even without VoidLayer installed
            id = "VoidLayer.host", group = "Layers", label = "Help Void layer hopping",
            tip = H.TIP,
            get = function() local h = rawget(_G, "VoidLayerHelp"); return h and h.On() or false end,
            set = function(on) local h = rawget(_G, "VoidLayerHelp"); if h then h.Set(on) end end,
        })
    end
end
