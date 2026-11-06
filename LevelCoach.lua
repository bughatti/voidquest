----------------------------------------------------------------------
-- VoidQuest — Leveling Coach
--
-- For the player who hasn't played in a while and wants max level fast: a strip
-- at the top of the VoidQuest panel that always says the NEXT thing to do, with a pin,
-- and moves on by itself as you play.
--   1. Pick an era      -- not in Chromie Time: talk to Chromie and pick an era.
--                          Or the reverse: in Chromie Time but questing outside its era
--                          (past 70, or another expansion's zone) -> return to the present.
--                          (Blizzard's recommended one when the game says).
--   2. Get the intro    -- the era's "<Expansion>: ..." quest from your capital's
--                          Warchief's Command Board / Hero's Call Board.
--   3. Follow the intro -- the quest's own arrow takes you there.
--   4. Level there      -- the zone that fits your level, walked step by step by
--                          the zone guide. Outlevel the era -> back to Chromie.
-- Eras that start at home (Cataclysm) and life after Chromie Time go straight to 4.
-- Once you've reached an era's continent the intro counts as done for good, so
-- hearthing home doesn't send you back to step 2. Chromie's spot is learned the
-- first time you talk to her (the game has no API for it); the board's comes from
-- its own quest marker on the city map -- pins are never guesses.
----------------------------------------------------------------------
local VQ = VoidQuest
local mod = VQ:NewModule("LevelCoach")
VQ.Coach = mod

local function safe(fn, ...) if not fn then return nil end local ok, a, b, c = pcall(fn, ...) if ok then return a, b, c end end

local CAPITAL = { Horde = 85, Alliance = 84 }   -- Orgrimmar, Stormwind (uiMapID)
local BOARD = { Horde = "Warchief's Command Board", Alliance = "Hero's Call Board" }

local function Faction() return (UnitFactionGroup("player")) or "Horde" end
local function CharState()
    VoidQuestCharDB.coach = VoidQuestCharDB.coach or {}
    local s = VoidQuestCharDB.coach
    s.arrived = s.arrived or {}   -- [era id] = true once you've reached that era's continent
    return s
end

-- player's map + position (nil x/y inside instances)
local function Here()
    local m = safe(C_Map.GetBestMapForUnit, "player")
    local pos = m and safe(C_Map.GetPlayerMapPosition, m, "player")
    if pos then
        local ok, x, y = pcall(pos.GetXY, pos)
        if ok and x and y and x > 0 and y > 0 then return m, x, y end
    end
    return m
end

local function MapName(m)
    local mi = m and safe(C_Map.GetMapInfo, m)
    return mi and mi.name or "?"
end

local function OnEraContinent(era, map)
    local cont = VQ.Guide and VQ.Guide.ContinentOf and VQ.Guide:ContinentOf(map)
    for _, c in ipairs(era and era.conts or {}) do
        if cont and cont.mapID == c then return true end
    end
    return false
end

----------------------------------------------------------------------
-- Remembered spots (account-wide: Chromie and the boards never move)
----------------------------------------------------------------------
local function Learn(kind, m, x, y)
    if not (m and x and y) then return end
    VoidQuestDB.coachSpots = VoidQuestDB.coachSpots or {}
    VoidQuestDB.coachSpots[kind .. ":" .. m] = { m = m, x = x, y = y }
end

local function Spot(kind, m)
    local s = VoidQuestDB.coachSpots and VoidQuestDB.coachSpots[kind .. ":" .. m]
    if s then return s.m, s.x, s.y end
end

----------------------------------------------------------------------
-- Era intro quests: the capital boards offer "<Expansion>: <title>"
----------------------------------------------------------------------
-- "<Expansion>: <title>", or just "<Expansion>" (The War Within's intro is titled exactly
-- "The War Within", 78713 on Orgrimmar's map).
local function IsEraQuest(era, title)
    if not (era and type(title) == "string") then return false end
    local t, l = title:lower(), era.label:lower()
    return t == l or t:sub(1, #l + 1) == l .. ":"
end

local function EraQuestInLog(era)
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        if info and not info.isHeader and IsEraQuest(era, info.title) then return info.questID, info.title end
    end
end

-- Quest-line data for a map loads asynchronously: ask at most every 30s per map, so the
-- QUESTLINE_UPDATE it fires can't turn into a request loop.
local asked = {}
local function WarmQuestLines(m)
    local now = GetTime()
    if not asked[m] or now - asked[m] > 30 then
        asked[m] = now
        safe(C_QuestLine.RequestQuestLinesForMap, m)
    end
end

-- The board's offer for this era, straight off the capital map (its "!" marker).
local function EraQuestOnBoard(era, capital)
    WarmQuestLines(capital)
    for _, q in ipairs(safe(C_QuestLine.GetAvailableQuestLines, capital) or {}) do
        if IsEraQuest(era, q.questName) and q.x and q.y and q.x > 0 then
            -- the marker is the GIVER (Thrall for The War Within), usually by the board
            Learn("board", capital, q.x, q.y)
            return q.questName, capital, q.x, q.y, q.questID
        end
    end
end

----------------------------------------------------------------------
-- After Chromie Time (it covers 10-70): The War Within 70-79, Midnight from 80.
-- Matched by continent NAME (as CampaignGuide's PLACE_RULES), not hard-coded map IDs.
-- Before this, a 76 still in a Dragonflight era got "You've outgrown Dragonflight --
-- talk to Chromie", and Chromie has nothing past 70 (2026-10-24).
----------------------------------------------------------------------
local CHROMIE_MAX = 70
local AFTER = {
    { id = "tww", label = "The War Within", min = 70, places = { "khaz algar" }, hub = "Dornogal",
      how = "Orgrimmar's portal room (Stormwind's for Alliance) has a portal to Dornogal." },
    { id = "mid", label = "Midnight", min = 80, places = { "quel'thalas" }, hub = "Silvermoon City",
      how = "The Midnight intro quest takes you to Silvermoon City." },
}
local function StageFor(lvl)
    local s
    for _, a in ipairs(AFTER) do if lvl >= a.min then s = a end end
    return s
end
local function OnStage(stage, map)
    local cont = VQ.Guide and VQ.Guide.ContinentOf and VQ.Guide:ContinentOf(map)
    local name = cont and cont.name and cont.name:lower() or ""
    for _, p in ipairs(stage.places) do
        if name:find(p, 1, true) then return true end
    end
    return false
end

-- The stage expansion's campaign to follow: one in progress first, then one the game
-- offers you (state 0 alone is "Invalid", not "startable" -- later-patch campaigns can be
-- locked); earliest ID within a tier (the main story comes before side ones). Stalled
-- (gated) campaigns are skipped. Uses CampaignGuide's campaign list and classification.
local function StageCampaign(stage)
    local G = VQ.Guide
    if not (G and G.AllCampaigns and G.CampaignExpansion) then return nil end
    local offered = {}
    for _, c in ipairs((C_CampaignInfo and C_CampaignInfo.GetAvailableCampaigns
        and C_CampaignInfo.GetAvailableCampaigns()) or {}) do offered[c] = true end
    local map, order = G:AllCampaigns()
    local best, bestTier
    for _, id in ipairs(order or {}) do
        local c = map[id]
        -- the campaign named after the expansion is the MAIN one (The War Within = intro +
        -- every zone chapter); "Isle of Dorn" etc. are slices of it and skip the intro
        local main = c and c.name == stage.label and (c.state == 2 or offered[id])
        local tier = c and ((main and -1) or (c.state == 2 and 0) or (c.state == 0 and offered[id] and 1)) or nil
        if tier and G:CampaignExpansion(c.name, id) == stage.label
            and (not best or tier < bestTier or (tier == bestTier and id < best)) then
            best, bestTier = id, tier
        end
    end
    return best, best and map[best].name
end

-- Max level: the expansion's story campaigns in patch order, so finishing one points at
-- the next (it used to stop at "the coach is done", and nothing led to the Season 2 story).
-- IDs read live on this account: 270 Midnight (leveling), 284 The War of Light and Shadow,
-- 324 The Curse of Ula'tek (12.1, Season 2; opens the Coiled Isle partway through, needs the
-- main campaign done on the account), 349 The Promise of Tomorrow (12.1.5, after Ula'tek).
local STORY = {
    { id = 270 },
    { id = 284 },
    { id = 324, note = "Season 2 story (patch 12.1). The Coiled Isle opens partway through it." },
    { id = 349, note = "Patch 12.1.5 story, after the Curse of Ula'tek." },
}
function mod:StoryStep()
    local done = { n = 0, title = "You're max level -- the coach is done." }
    local G = VQ.Guide
    if not (G and C_CampaignInfo) then return done end
    local offered = {}
    for _, c in ipairs(safe(C_CampaignInfo.GetAvailableCampaigns) or {}) do offered[c] = true end
    local following = G:LockedCampID() or (G.ActiveCampaign and select(1, G:ActiveCampaign()))
    local prev
    for _, s in ipairs(STORY) do
        local state = safe(C_CampaignInfo.GetState, s.id)
        local info = safe(C_CampaignInfo.GetCampaignInfo, s.id)
        local name = info and info.name ~= "" and info.name
        -- no info = this client doesn't have that campaign (older patch, other game): skip it
        if name and state ~= 1 then   -- 1 = Complete; the first unfinished one is next
            -- already on it: the panel below shows its steps, nothing to add here
            if following == s.id then return done end
            local open = state == 2 or offered[s.id]
            local detail
            if open then
                detail = (s.note and (s.note .. " ") or "") .. "Its steps show below once you follow it, from the first pickup on."
            elseif state == 3 then
                detail = "The game has it on hold (stalled) -- usually a weekly unlock, renown or raid step. Follow it to see what it waits on."
            else
                detail = ("Not offered to this character yet%s. Follow it anyway to see its first pickup."):format(
                    prev and (" -- it comes after " .. prev) or "")
            end
            return { n = 5, head = "Max level -- next story:", title = name, detail = detail, lockCamp = s.id }
        end
        prev = name
    end
    return done
end

-- Diagnostic (`/vq stage`): everything the game says about the current expansion's
-- campaigns for THIS character -- states, offered or not, every chapter's quests (done /
-- in log / title / start location), board offers in your capital and here, your log.
-- Saved to VoidQuestCharDB.diag (read from SavedVariables after /reload) + copy box.
function mod:Diagnose()
    local out = {}
    local function add(fmt, ...) out[#out + 1] = select("#", ...) > 0 and fmt:format(...) or fmt end
    local lvl = UnitLevel("player") or 0
    local stage = StageFor(lvl) or AFTER[1]
    local ct = VQ.Zones and VQ.Zones:Chromie() or {}
    local here = safe(C_Map.GetBestMapForUnit, "player")
    add("%s level %d, map %s (%s), chromie on=%s can=%s, stage=%s", date("%Y-%m-%d %H:%M"), lvl,
        tostring(here), MapName(here), tostring(ct.on), tostring(ct.can), stage.label)
    local offered = {}
    for _, c in ipairs(safe(C_CampaignInfo.GetAvailableCampaigns) or {}) do offered[c] = true end
    local G = VQ.Guide
    local map, order = G:AllCampaigns()
    for _, id in ipairs(order or {}) do
        local c = map[id]
        if c and G:CampaignExpansion(c.name, id) == stage.label then
            add("CAMPAIGN %d %s state=%s offered=%s locked=%s current=%s", id, c.name, tostring(c.state),
                tostring(offered[id] or false), tostring(G:LockedCampID() == id),
                tostring(safe(C_CampaignInfo.GetCurrentChapterID, id)))
            for _, chID in ipairs(safe(C_CampaignInfo.GetChapterIDs, id) or {}) do
                local chi = safe(C_CampaignInfo.GetCampaignChapterInfo, chID)
                local chain = safe(C_QuestLine.GetQuestLineQuests, chID) or {}
                add("  chapter %d %s (%d quests)", chID, (chi and chi.name) or "?", #chain)
                for i, q in ipairs(chain) do
                    safe(C_QuestLog.RequestLoadQuestByID, q)
                    local li = safe(C_QuestLine.GetQuestLineInfo, q, here)
                    add("    %2d %-7d %s%s %s%s", i, q,
                        safe(C_QuestLog.IsQuestFlaggedCompleted, q) and "DONE" or "todo",
                        safe(C_QuestLog.GetLogIndexForQuestID, q) and " INLOG" or "",
                        safe(C_QuestLog.GetTitleForQuestID, q) or "?",
                        (li and li.x and li.x > 0) and (" @%s %.1f,%.1f"):format(tostring(li.startMapID), li.x * 100, li.y * 100) or "")
                end
            end
        end
    end
    for _, m in ipairs({ CAPITAL[Faction()], here }) do
        safe(C_QuestLine.RequestQuestLinesForMap, m)
        add("OFFERS on %s (%d):", MapName(m), m or 0)
        for _, q in ipairs(safe(C_QuestLine.GetAvailableQuestLines, m) or {}) do
            add("  %d %s [%s] campaign=%s important=%s local=%s hidden=%s @%.1f,%.1f", q.questID or 0, q.questName or "?",
                q.questLineName or "?", tostring(q.isCampaign), tostring(q.isImportant), tostring(q.isLocalStory), tostring(q.isHidden),
                (q.x or 0) * 100, (q.y or 0) * 100)
        end
    end
    add("LOG:")
    for i = 1, (safe(C_QuestLog.GetNumQuestLogEntries) or 0) do
        local info = safe(C_QuestLog.GetInfo, i)
        if info and not info.isHeader then add("  %d %s", info.questID or 0, info.title or "?") end
    end
    VoidQuestCharDB.diag = out
    VQ:ShowCopy("VoidQuest — stage diagnostic (saved; /reload so Claude can read it)", table.concat(out, "\n"))
end

----------------------------------------------------------------------
-- The plan: which step you're on, what to do, where (pin)
----------------------------------------------------------------------
-- Is the zone guide you're already following still right for you (level + era)?
local function CurrentStillFits(Z, era, lvl)
    local cur = Z:Current()
    if not cur then return nil end
    local lo, hi = Z:Levels(cur.map)
    if not (lo and lvl >= lo and lvl <= (hi or lo)) then return nil end
    if era then
        local inEra = cur.ach and era.exp[Z:ExpansionOf(cur.ach)] or OnEraContinent(era, cur.map)
        if not inEra then return nil end
    end
    return cur
end

-- WoW Forever has none of retail's leveling path (no Chromie Time, eras, city boards or
-- expansion campaigns: it's the Classic world). There the coach points at the zone you're
-- in, from Forever's own quest list (ForeverZone.lua): quests to finish, and the next one
-- you can pick up whose giver is known, pinned.
local function ForeverStep()
    local F = VQ.Forever
    local zone = F:PlayerZone()
    if not zone then
        return { n = 4, head = "Next:", title = "Quest where you are", detail = "Open the zone list (/vq fz) to see every quest in a zone." }
    end
    local inLog, open, known, pick = 0, 0, 0, nil
    for _, e in ipairs(F:ZoneList(zone)) do
        if e.status == "log" then
            inLog = inLog + 1
        elseif e.status == "open" then
            open = open + 1
            if e.spot then
                known = known + 1
                pick = pick or e   -- ZoneList sorts open quests with a known start first, lowest level first
            end
        end
    end
    local detail = ("%d in your log here, %d more you can pick up (%d with a known giver). The zone list (/vq fz) has them all.")
        :format(inLog, open, known)
    if pick then
        local who = VQ.Starts and VQ.Starts:Giver(pick.id)
        return { n = 4, head = "Next:", title = ("Pick up '%s'%s"):format(pick.title, who and (" from " .. who) or ""),
            detail = detail, pin = { m = pick.spot.m, x = pick.spot.x, y = pick.spot.y } }
    end
    return { n = 4, head = "Next:", title = ("Quest in %s"):format(zone), detail = detail }
end

-- returns { n = 0..4, title, detail, pin = {m,x,y}?, follow = zone?, questID? }
function mod:Step()
    if VQ.Forever and VQ.Forever:Active() then return ForeverStep() end
    local Z = VQ.Zones
    if not Z then return { n = 0, title = "" } end
    local lvl = UnitLevel("player") or 0
    local maxLvl = (GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion()) or 90
    if lvl >= maxLvl then return self:StoryStep() end

    local capital = CAPITAL[Faction()]
    local ct = Z:Chromie()
    local era = ct.on and ct.era or nil
    local st = CharState()
    if era and OnEraContinent(era, (Here())) then st.arrived[era.id] = true end

    -- Past Chromie Time: get to the current expansion's continent (intro quest or portal),
    -- then step 4 walks its campaign / zones as for any era.
    local stage = (lvl >= CHROMIE_MAX) and StageFor(lvl) or nil

    -- Still in Chromie Time but questing outside its era (past 70, or following a zone
    -- from another expansion): step one is back to Chromie to return to the present
    -- (the player, 2026-10-24: "if they are starting a zone not through chromie the first
    -- step is to send them to chromie to return to present").
    if ct.on then
        local outside
        if stage then
            outside = stage.label
        elseif era then
            local cur = Z:Current()
            local inEra = cur and ((cur.ach and era.exp[Z:ExpansionOf(cur.ach)]) or OnEraContinent(era, cur.map))
            if cur and not inEra then outside = cur.name end
        end
        if outside then
            local m, x, y = Spot("chromie", capital)
            return {
                n = 1, title = "Return to the present (talk to Chromie)",
                detail = ("You're still in Chromie Time%s, and %s isn't part of it. Talk to Chromie in %s and choose to return to the present%s."):format(
                    ct.name and (" (" .. ct.name .. ")") or "", outside, MapName(capital),
                    m and "" or " (I'll remember her spot once you've talked to her)"),
                pin = m and { m = m, x = x, y = y } or nil,
            }
        end
    end

    if stage then
        era = nil   -- a Chromie era you've outgrown no longer decides anything
        local zg = Z:Current()
        local qid, qtitle = EraQuestInLog(stage)
        if qid then
            -- a lock on the previous expansion's campaign kept the panel on it (TWW at 80
            -- while the Midnight intro was in the log): the button returns to Auto
            local locked = VQ.Guide and VQ.Guide:LockedCampID()
            local qc = safe(C_CampaignInfo.GetCampaignID, qid)
            return { n = 3, title = ("Follow '%s'"):format(qtitle),
                detail = "The quest's own arrow takes you there. Open your map (M) if you lose it.",
                questID = qid, stopZone = zg ~= nil, unlock = locked ~= nil and locked ~= qc }
        end
        local G = VQ.Guide
        local cid, cname = StageCampaign(stage)
        -- The intro quest on the city board / capital map comes first, even when the game
        -- hides it as low level ("The War Within" at Orgrimmar 49.6, 77.2 for a 76).
        local cstate = cid and safe(C_CampaignInfo.GetState, cid)
        if cstate ~= 2 then
            local name, m, x, y, qid = EraQuestOnBoard(stage, capital)
            if name then
                -- WHO gives it (learned / seed): "Thrall", not "the board" -- the player went to
                -- the command board, and the giver stands next to it (2026-10-24)
                local who = VQ.Starts and VQ.Starts:Giver(qid)
                return { n = 2, title = ("Pick up the intro quest '%s'%s"):format(name, who and (" from " .. who) or ""),
                    detail = ("%s %s at %.1f, %.1f (the game hides it on the map as low level -- turn on "
                        .. "Low-Level Quests in your minimap tracking to see its gray \"!\")."):format(
                        who and ("Talk to " .. who .. " in") or "The quest giver is in", MapName(m), x * 100, y * 100)
                        .. (zg and " Your old zone guide stops." or ""),
                    pin = { m = m, x = x, y = y }, stopZone = zg ~= nil,
                    -- a campaign lock (e.g. a slice like "Isle of Dorn") would hide the intro
                    -- chain once accepted: back to Auto, which follows the quest in your log
                    unlock = G and G:LockedCampID() ~= nil }
            end
        end
        -- The expansion's own campaign is the fastest route and its steps guide every pickup
        -- (the zone-story list had no Khaz Algar zone and fell back to the old Dragonflight
        -- campaign, 2026-10-24). Not following it yet -> offer it.
        if cid and G and G:LockedCampID() ~= cid then
            return { n = 2, title = ("Start the %s campaign: %s"):format(stage.label, cname),
                detail = "Its steps show below once you follow it, from the first pickup on. "
                    .. stage.how .. (zg and " Your old zone guide stops." or ""),
                lockCamp = cid }
        end
        -- Where you are NOW (not "ever arrived": a quick visit made it skip this step).
        if not cid and not OnStage(stage, (Here())) then
            local name, m, x, y, qid = EraQuestOnBoard(stage, capital)
            local who = VQ.Starts and VQ.Starts:Giver(qid)
            return {
                n = 2, title = ("Go to %s (%s, level %d+)"):format(stage.hub, stage.label, stage.min),
                detail = (name and ("Take '%s' from %s in %s. "):format(name, who or "the quest giver at the marker", MapName(capital)) or "")
                    .. stage.how .. (zg and " Your old zone guide stops when you press the button." or ""),
                pin = m and { m = m, x = x, y = y } or nil,
                stopZone = zg ~= nil,
            }
        end
    end

    -- 1) not in Chromie Time but could be
    if not stage and ct.can and not ct.on then
        local m, x, y = Spot("chromie", capital)
        return {
            n = 1, title = "Talk to Chromie and pick an era",
            detail = ("Chromie is in %s%s. Every old expansion then scales to your level.%s"):format(
                MapName(capital), m and "" or " (I'll remember her spot once you've talked to her)",
                ct.recommended and (" Blizzard recommends |cffffd200" .. ct.recommended .. "|r.") or ""),
            pin = m and { m = m, x = x, y = y } or nil,
        }
    end

    -- 2 + 3) in an era with an intro you haven't finished (never reached its continent)
    if era and #era.conts > 0 and not st.arrived[era.id] then
        local qid, qtitle = EraQuestInLog(era)
        if qid or (st.intro and st.intro.era == era.id) then
            return {
                n = 3, title = ("Follow '%s'"):format(qtitle or "your intro quest"),
                detail = "The quest's own arrow and objective take you there -- portal, ship or boat. "
                    .. "Open your map (M) if you lose it.",
                questID = qid,
            }
        end
        local name, m, x, y, bq = EraQuestOnBoard(era, capital)
        if not m then m, x, y = Spot("board", capital) end
        return {
            n = 2, title = ("Get the %s intro quest"):format(era.label),
            detail = ("Take '%s' from %s in %s."):format(name or (era.label .. ": ..."),
                (VQ.Starts and VQ.Starts:Giver(bq)) or ("the " .. BOARD[Faction()]), MapName(capital))
                .. (m and "" or " Its quest marker shows on the city map once you're in town."),
            pin = m and { m = m, x = x, y = y } or nil,
        }
    end

    -- 4) level here. Say what the panel below is actually walking: when the campaign has a
    -- step here it comes before a followed zone guide (CampaignGuide:Resolve), and the strip
    -- kept naming the zone ("Quest in The Waking Shores" over Ohn'ahran Plains campaign
    -- steps, 2026-10-24).
    local r = VQ.Guide and VQ.Guide.Resolve and VQ.Guide:Resolve()
    if r and r.g and r.primary and not r.g.zoneGuide and not r.questOnly and not r.isZone then
        return { n = 4, title = ("Follow the campaign: %s"):format(r.g.campName or "?"),
            detail = "The steps for it are below." }
    end
    -- campaign waiting on a level: the panel ranks zones by the XP left in them, so name
    -- that zone here too (this strip said "Quest in Eversong Woods" over a panel sending
    -- you to Zul'Aman, 2026-10-26)
    if r and r.levelGate and r.zoneRank and r.zoneRank[1] then
        return { n = 4, title = ("Side quests for XP: %s"):format(r.zoneRank[1].name),
            -- the zone LevelPool sticks with: where you are while it has quests, else the
            -- zone it sent you to, until that runs low
            detail = (r.primary and r.primary.status ~= "pickup")
                and "Finish the quests you carry here first; the steps are below."
                or "It stays on this zone until it runs low. The steps are below." }
    end
    -- Past Chromie Time only the current expansion's zones count: old-world zones report
    -- ranges up to the cap (Hillsbrad "7-81" was suggested at 76) but level you far slower.
    local cur = CurrentStillFits(Z, era, lvl)
    if cur and stage and not OnStage(stage, cur.map) then cur = nil end
    if cur then
        return { n = 4, title = ("Quest in %s"):format(cur.name or "?"),
            detail = "The steps for it are below." }
    end
    for _, s in ipairs(Z:Suggestions(stage and 60 or 6)) do
        if (not era or s.inEra) and (not stage or OnStage(stage, s.z.map)) then
            return { n = 4, title = ("Quest in %s"):format(s.z.name),
                detail = ("Fits your level (%d-%d). Press Start and its steps show below."):format(s.lo, s.hi),
                follow = s.z }
        end
    end
    if era then
        return { n = 4, title = ("You've outgrown %s"):format(ct.name or era.label),
            detail = "Talk to Chromie again and pick the next era." }
    end
    return { n = 4, title = "Follow your campaign",
        detail = "No zone story fits right now -- your campaign and quests are below." }
end

----------------------------------------------------------------------
-- In the guide panel: the coach is a strip at the top of the VoidQuest panel
-- (one box, not two). CampaignGuide calls RenderStrip; this module owns the step.
----------------------------------------------------------------------
local TIP = "|cff888888Faster: queue Dungeon Finder while you quest; War Mode on = bonus XP.|r"

-- Current step, cached briefly: the panel refreshes on every quest event and the
-- step walks every zone; coach events (Invalidate) drop the cache right away.
function mod:Current()
    if not self:IsOn() then return nil end
    local now = GetTime()
    if not self.step or not self.stepAt or now - self.stepAt > 5 then
        self.step, self.stepAt = self:Step(), now
    end
    if self.step.n == 0 then return nil end
    return self.step
end
function mod:Invalidate() self.stepAt = nil end

-- The strip's button: start the zone guide / set the pin / track the quest.
function mod:Go()
    local s = self.step
    if not s then return end
    -- a click here takes the arrow back from a manual hold (not TakeTrack: re-firing the
    -- guide's own step would replace the pin this button is about to set -- Codex review)
    if VQ.Guide then VQ.Guide._manual, VQ.Guide._heldType = nil, nil end
    if s.stopZone and VQ.Zones and VQ.Zones:Active() then
        VQ.Zones:Stop()   -- the outgrown era's zone guide
        VQ:Print("stopped your old zone guide.")
    end
    if s.unlock and VQ.Guide then
        VQ.Guide:LockCampaign(nil)   -- Auto: follow the campaign quest in your log
    end
    if s.lockCamp and VQ.Guide then
        VQ.Guide:LockCampaign(s.lockCamp)   -- also clears a followed zone guide
        VQ:Print("following the campaign -- its steps are in the panel.")
    elseif s.follow and VQ.Zones then
        VQ.Zones:Follow(s.follow)
        VQ:Print(("following %s -- the panel walks you through it."):format(s.follow.name or "?"))
    elseif s.pin and VQ.Guide then
        if VQ.Guide:SetOurWaypoint(s.pin.m, s.pin.x, s.pin.y) then
            if VQ.Guide._wp then VQ.Guide._wp.coach = true end   -- quest-list refreshes keep it
            local last = VoidQuestCharDB and VoidQuestCharDB.lastWp
            if last then last.coach = true end                    -- ...and so does a reload
            VQ:Print(("pin set in %s -- follow the arrow."):format(MapName(s.pin.m)))
        else
            VQ:Print("couldn't set a pin there.")
        end
    elseif s.questID and C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
        if VQ.Guide and VQ.Guide.OwnTrack then
            VQ.Guide:OwnTrack(C_SuperTrack.SetSuperTrackedQuestID, s.questID)
        else
            C_SuperTrack.SetSuperTrackedQuestID(s.questID)
        end
        VQ:Print("tracking the quest -- follow the arrow.")
    end
    self:Refresh()
end

function mod:IsOn() return not (VoidQuestCharDB.coach and VoidQuestCharDB.coach.hidden) end
function mod:SetShown(on)
    CharState().hidden = not on
    self:Refresh()
end
function mod:Toggle() self:SetShown(not self:IsOn()) end
function mod:Refresh()
    self:Invalidate()
    if VQ.Guide then VQ.Guide:Refresh() end
end

-- Draw the strip into the guide panel `f`, `top` px below the title row. Returns the
-- height used (0 = hidden: max level, or switched off with the panel's Level button).
function mod:RenderStrip(f, top)
    local s = self:Current()
    local c = f.coach
    if not s then
        if c then c:Hide() end
        return 0
    end
    if not c then
        c = CreateFrame("Frame", nil, f)
        c:SetWidth(284)
        c.title = c:CreateFontString(nil, "OVERLAY"); VQ:SetFont(c.title, 11)
        c.title:SetPoint("TOPLEFT", 0, 0); c.title:SetWidth(284); c.title:SetJustifyH("LEFT")
        c.detail = c:CreateFontString(nil, "OVERLAY"); VQ:SetFont(c.detail, 10)
        c.detail:SetPoint("TOPLEFT", c.title, "BOTTOMLEFT", 0, -2); c.detail:SetWidth(284); c.detail:SetJustifyH("LEFT")
        c.detail:SetTextColor(.8, .8, .8)
        c.go = CreateFrame("Button", nil, c, "UIPanelButtonTemplate"); c.go:SetSize(70, 18)
        c.go:SetScript("OnClick", function() mod:Go() end)
        c.zones = CreateFrame("Button", nil, c, "UIPanelButtonTemplate"); c.zones:SetSize(80, 18)
        c.zones:SetText("All zones...")
        c.zones:SetScript("OnClick", function() if VQ.Zones then VQ.Zones:ToggleWindow() end end)
        -- The panel has a fixed height now (quest lines fill the rest), so the general tip and
        -- the max-level story's explainer live in a tooltip on the title instead of taking
        -- two or three lines. Leveling steps keep their detail line: it's the instruction.
        c.hover = CreateFrame("Button", nil, c)
        c.hover:SetAllPoints(c.title)
        c.hover:SetScript("OnEnter", function(b)
            local st = mod.step
            GameTooltip:SetOwner(b, "ANCHOR_LEFT")
            GameTooltip:SetText(st and st.title or "Leveling Coach")
            if b.detail and b.detail ~= "" then GameTooltip:AddLine(b.detail, .85, .85, .85, true) end
            GameTooltip:AddLine(TIP, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        c.hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
        c.line = c:CreateTexture(nil, "ARTWORK"); c.line:SetHeight(1)
        c.line:SetColorTexture(0, .78, 1, .35)
        f.coach = c
    end
    c:ClearAllPoints(); c:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -27 - top)
    c.title:SetText(("|cff00c7ff%s|r |cff55ff55%s|r"):format(s.head or ("Step %d of 4:"):format(s.n), s.title))
    -- once a zone guide is walking you (step 4, nothing to start), one line is enough:
    -- the panel below shows the actual step
    local compact = s.n == 4 and not s.follow
    -- max-level story (n = 5): its detail only explains the button -> tooltip
    local detailLine = not compact and s.n ~= 5 and (s.detail or "") ~= ""
    c.detail:SetText(detailLine and s.detail or "")
    c.detail:SetShown(detailLine)
    c.hover.detail = s.detail
    local label = (s.lockCamp and "Follow it") or s.follow and "Start" or (s.pin and "Pin it") or (s.questID and "Track it")
        or (s.stopZone and "Stop old guide") or nil
    local h = c.title:GetStringHeight() or 13
    if detailLine then h = h + 2 + (c.detail:GetStringHeight() or 12) end
    c.go:SetShown(label ~= nil); c.zones:SetShown(not compact)
    if not compact then
        c.go:ClearAllPoints(); c.go:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -h - 4)
        if label then
            c.go:SetText(label)
            c.go:SetWidth(math.max(70, (c.go:GetFontString():GetStringWidth() or 50) + 20))
        end
        c.zones:ClearAllPoints()
        if label then c.zones:SetPoint("LEFT", c.go, "RIGHT", 6, 0) else c.zones:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -h - 4) end
        h = h + 4 + 18
    end
    c.line:ClearAllPoints()
    c.line:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -h - 4); c.line:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, -h - 4)
    c:SetHeight(h + 5)
    c:Show()
    return h + 10
end
----------------------------------------------------------------------
-- Events: refresh as you play; learn Chromie's spot; track the intro
----------------------------------------------------------------------
local pending
local function Soon()
    if pending then return end
    pending = true
    C_Timer.After(0.5, function() pending = nil; mod:Refresh() end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "QUEST_ACCEPTED", "QUEST_TURNED_IN",
    "QUEST_REMOVED", "PLAYER_LEVEL_UP", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
    "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "QUESTLINE_UPDATE" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, arg)
    if not (VoidQuestDB and VoidQuestCharDB) then return end
    if event == "QUESTLINE_UPDATE" and arg then return end   -- requestRequired: nothing new yet
    if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" and Enum.PlayerInteractionType
        and arg == Enum.PlayerInteractionType.ChromieTime then
        Learn("chromie", Here())   -- you're standing at Chromie
    elseif event == "QUEST_ACCEPTED" then
        local era = VQ.Zones and VQ.Zones:Chromie().era
        if IsEraQuest(era, safe(C_QuestLog.GetTitleForQuestID, arg)) then
            CharState().intro = { q = arg, era = era.id }
        end
    elseif event == "QUEST_REMOVED" then
        local st = CharState()
        if st.intro and st.intro.q == arg and not safe(C_QuestLog.IsQuestFlaggedCompleted, arg) then
            st.intro = nil   -- abandoned: back to "get the intro quest"
        end
    end
    Soon()
end)
