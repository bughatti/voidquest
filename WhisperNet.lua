----------------------------------------------------------------------
-- Void WhisperNet: the WoW Forever addon-message transport
--
-- Live WoW Forever (measured 2026-11-05) refuses addon messages sent to custom
-- chat channels: SendAddonMessage(..., "CHANNEL", idx) returns 0, the server
-- answers CHAT_MSG_CHANNEL_NOTICE NOT_ALLOWED_IN_CHANNEL and nothing is
-- delivered. Addon WHISPERS work, to the bare character name: Forever names are
-- "First Surname", unique per region, with no realm (RegionalUniqueNamesEnabled()
-- is true; GetNormalizedRealmName() is a hidden backing realm that must never be
-- appended). Channel MEMBER LISTS still work.
--
-- So on Forever the addon's hidden channel is only a member list (who runs the
-- addon right now) and the messages go by addon whisper to a few of its members.
-- Retail keeps sending on the channel, where it works.
--
-- Copied as-is into each addon that uses it (VoidGather, VoidSweep, VoidLayer; source of
-- truth: wow-addons/_shared/WhisperNet.lua). It uses the addon's private
-- namespace, so every addon has its own copy. The one thing they share is the global
-- VoidRosterTurnUntil (Net.Turn): only one channel can be selected for its member list
-- at a time. VoidQuest's ForeverShare.lua is the same design written inline and takes
-- turns through the same global.
----------------------------------------------------------------------
local _, ns = ...
local Net = {}
ns.WhisperNet = Net

local ROSTER_EVERY = 300   -- re-read the member list at most this often
local ROSTER_MAX   = 300   -- members read from it
local HIDE_FOR     = 30    -- seconds a whispered name's "No player named" line is hidden

-- Whisper transport on? Only where names are unique per region (WoW Forever):
-- there the bare name reaches the player. Retail has no such API.
function Net.Active()
    return RegionalUniqueNamesEnabled ~= nil and RegionalUniqueNamesEnabled() == true
end

-- One name per player, as the game gives it in Forever ("First Surname").
function Net.Canon(name)
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

function Net.Me()
    return Net.Canon(GetUnitName and GetUnitName("player") or UnitName("player"))
end

----------------------------------------------------------------------
-- net = Net.New(channelName, onRoster)
--   net:DisplayIndex()           the channel's row in the Channels list, or nil
--   net:RequestRoster(force)     ask the server for the member list (at most every 5 min)
--   net:OnRosterUpdate(i)        CHANNEL_ROSTER_UPDATE arg1; re-reads ours
--   net.roster / net.count       other members' names / member count incl. you (nil = unknown)
--   net:Others()                 other members online, or nil while unknown
--   net:Pick(k)                  up to k random other members
--   net:Noted(name)              call right before whispering name (hides the offline line)
--   net:Sent(name, result)       call right after, with SendAddonMessage's return value
--   net.bounces                  whispers that came back "No player named" this session
--   net.onBounce = fn(name)      optional: called on each of those
-- Net.New(channel, onRoster, store): store = a table for offline marks (session only)
----------------------------------------------------------------------
local Obj = {}
Obj.__index = Obj

-- A new day's channel: forget the old member list (offline marks stay, they're per player).
function Obj:SetChannel(channel)
    self.channel = channel
    self.count, self.roster, self.rosterAt = nil, {}, -ROSTER_EVERY
end

function Obj:DisplayIndex()
    if not (GetNumDisplayChannels and GetChannelDisplayInfo) then return nil end
    local want = self.channel:lower()
    for i = 1, GetNumDisplayChannels() or 0 do
        local name, header = GetChannelDisplayInfo(i)
        if not header and type(name) == "string" and name:lower() == want then return i end
    end
end

function Obj:ReadRoster()
    local i = self:DisplayIndex()
    if not i then return end
    local _, _, _, _, count = GetChannelDisplayInfo(i)
    count = tonumber(count)
    -- no count = another channel holds the selection (only the selected one has a list,
    -- live 11-07): keep what we had, never wipe the roster on an empty read
    if not count or count < 1 then return end
    self.count = count
    if C_ChatInfo and C_ChatInfo.GetChannelRosterInfo then
        local me, list = Net.Me(), {}
        -- a busy channel: read a random window of ROSTER_MAX members, a new one each time,
        -- so everyone can be picked (not just the first ROSTER_MAX)
        local total = count or 0
        local start = total > ROSTER_MAX and math.random(0, total - ROSTER_MAX) or 0
        local resolved = 0   -- rows that came back with a name (you included)
        for r = start + 1, start + math.min(total, ROSTER_MAX) do
            local ok, name = pcall(C_ChatInfo.GetChannelRosterInfo, i, r)
            name = ok and Net.Canon(name)
            if name then resolved = resolved + 1 end
            if name and name ~= me then list[#list + 1] = name end
        end
        -- an empty read while others are in the channel = not arrived yet: keep the old list
        if #list > 0 or (count or 0) <= 1 then
            self.roster = list
            -- the whole list was read: forget offline marks of players no longer on it
            -- (they're saved across reloads, so this keeps the saved table small). Only
            -- when every row had a name: a name still loading isn't "gone" (Sol review)
            if total <= ROSTER_MAX and resolved == total then
                local on = {}
                for _, n in ipairs(list) do on[n:lower()] = true end
                for k in pairs(self.unreach) do
                    if not on[k] then self.unreach[k] = nil end
                end
            end
        end
    end
    if self.onRoster then self.onRoster() end
end

-- Only ONE channel can be selected at a time, and only the selected one has a member list.
-- VoidGather, VoidQuest and VoidSweep all ask at login / zone change, so they take turns:
-- whoever selects holds the global VoidRosterTurnUntil for TURN_HOLD seconds (covers the
-- ~3 s wait for the list); the others wait for it to run out. Lua runs one handler at a
-- time, so check-and-set can't race.
local TURN_HOLD = 4
function Net.Turn(fn)
    local now, busy = GetTime(), _G.VoidRosterTurnUntil or 0
    if now >= busy then
        _G.VoidRosterTurnUntil = now + TURN_HOLD
        fn()
    else
        C_Timer.After(busy - now + 0.1 + math.random() * 0.5, function() Net.Turn(fn) end)
    end
end

-- The server sends the member list after the channel is selected (CHANNEL_ROSTER_UPDATE,
-- ~3 s on live 11-05). Left alone while the Channels window is open, so we never change
-- what the player is looking at.
function Obj:RequestRoster(force)
    if self.waitingTurn then return end
    if not force and GetTime() - self.rosterAt < ROSTER_EVERY then return end
    if not self:DisplayIndex() then return end   -- not in the channel yet: try again next time
    self.waitingTurn = true
    Net.Turn(function()
        self.waitingTurn = nil
        local i = self:DisplayIndex()
        if not i then return end
        -- the wait only starts once the list was really asked for (not while the window is open)
        if not (ChannelFrame and ChannelFrame:IsShown()) and SetSelectedDisplayChannel then
            self.rosterAt = GetTime()
            pcall(SetSelectedDisplayChannel, i)
        end
        self:ReadRoster()   -- may already be there
        C_Timer.After(3, function() self:ReadRoster() end)
    end)
end

function Obj:OnRosterUpdate(displayIndex)
    if displayIndex ~= nil and displayIndex == self:DisplayIndex() then self:ReadRoster() end
end

-- The member list also holds players who can't be whispered right now: logged off (the
-- server keeps them on the list for a while) or out of reach. The game's connected check
-- answers "unknown" for everyone but you (live 11-05), so learn it the honest way: a
-- whisper that comes back "No player named X is currently playing" marks X offline.
-- The mark stays until a later whisper to X goes through (no bounce within BOUNCE_WAIT):
-- a timed-out mark made logged-off players count as online again every 30 min, so the
-- players box popped up and down (live 11-07). After UNREACH_FOR, X may be picked again,
-- which is how we find out they're back.
-- Marks are timed with time(), not GetTime(). Since 2026-11-09 they're never saved (the user:
-- "get rid of the offline list"): the addons pass a fresh table, so after a /reload the count can
-- include logged-off members until their next bounce (5 -> 2 within a minute, live 11-07).
local UNREACH_FOR = 1800   -- a marked player may be whispered again after this
local BOUNCE_WAIT = 5      -- the "No player named" line comes back well within this
local STALE_MARK  = 7200   -- busy channel only: marks older than this stop being counted

function Obj:Marked(name) return self.unreach[name:lower()] ~= nil end

-- may be whispered: not marked, or marked long enough ago to try again
function Obj:Reachable(name)
    local t = self.unreach[name:lower()]
    return not t or time() - t >= UNREACH_FOR
end

-- Other members online (nil = unknown), less the ones known to be offline.
function Obj:Others()
    if not self.count then return nil end
    local gone = 0
    if self.count > ROSTER_MAX then
        -- only a window of the list is read: count the recent marks
        local now = time()
        for _, t in pairs(self.unreach) do
            if now - t < STALE_MARK then gone = gone + 1 end
        end
    else
        for _, name in ipairs(self.roster) do
            if self:Marked(name) then gone = gone + 1 end
        end
    end
    return math.max(0, self.count - 1 - gone)
end

function Obj:Pick(k)
    local live = {}
    for _, name in ipairs(self.roster) do
        if self:Reachable(name) then live[#live + 1] = name end
    end
    local n, out, used = #live, {}, {}
    while #out < math.min(k, n) do
        local j = math.random(n)
        if not used[j] then used[j] = true; out[#out + 1] = live[j] end
    end
    return out
end

function Obj:Noted(name)
    if type(name) == "string" then self.whispered[name:lower()] = GetTime() end
end

-- Call right after SendAddonMessage(..., "WHISPER", name) with what it returned
-- (Enum.SendAddonMessageResult: 0 = Success, 12 = TargetOffline; older clients: nil/true).
-- Only a send the game accepted can prove a marked player is back.
local SEND_OK, SEND_OFFLINE = 0, 12
function Obj:Sent(name, result)
    if type(name) ~= "string" then return end
    local key, at = name:lower(), time()
    if result == SEND_OFFLINE then
        self.unreach[key] = at
        if self.onRoster then self.onRoster() end
        return
    end
    if not (result == nil or result == true or result == SEND_OK) then return end
    -- a marked player we whispered again: no bounce = they're back online
    if self.unreach[key] then
        C_Timer.After(BOUNCE_WAIT, function()
            local t = self.unreach[key]
            if t and t < at then
                self.unreach[key] = nil
                if self.onRoster then self.onRoster() end   -- the count goes back up
            end
        end)
    end
end

-- "No player named X is currently playing." for a name we whispered in the last HIDE_FOR
-- seconds: returns that name (lowercased), else nil.
function Obj:NoticeName(text)
    -- system lines can arrive as secret text (12.x): never index those
    if type(text) ~= "string" or (issecretvalue and issecretvalue(text)) or not ERR_CHAT_PLAYER_NOT_FOUND_S then return nil end
    local now, lower = GetTime(), text:lower()
    for name, t in pairs(self.whispered) do
        if now - t > HIDE_FOR then
            self.whispered[name] = nil
        elseif lower == ERR_CHAT_PLAYER_NOT_FOUND_S:format(name):lower() then
            return name
        end
    end
end

-- Hide that line in chat (it's our hidden whisper, not something the player sent).
function Obj:HidesNotice(text) return self:NoticeName(text) ~= nil end

-- store: a table for offline marks (a fresh one: they are not saved); optional.
----------------------------------------------------------------------
-- Refused channels (live Forever, 2026-11-08). Anyone can /join an open channel, own it
-- once it empties and /ban players. A banned player's join is answered
-- CHAT_MSG_CHANNEL_NOTICE NOT_ALLOWED_IN_CHANNEL (with no channel name), and the game
-- then lists the channel as joined but DISABLED (GetChannelList), with no member list and
-- no way to leave it until you log out. That hit VoidQuestNet. So on Forever the addons
-- moved to new channels that they join with a password, and these tell a refused channel
-- apart from one that just isn't read yet:
--   Net.Blocked(channel)   true while the game lists it disabled (banned)
--   Net.Refused(channel)   "WRONG_PASSWORD" / "BANNED" if the last join got that answer
----------------------------------------------------------------------
----------------------------------------------------------------------
-- Daily channel (Forever, 2026-11-08). Every player of an addon works out the same channel
-- name and password from the server's UTC day, so everyone moves to a new channel together
-- at 00:00 UTC: a ban, or someone who took over the channel, lasts one day at most. Both
-- are built from numbers when the addon runs, so neither is written in the files as text.
--   name, pw, day = Net.DailyChannel(tag, salt)   tag = short letters, salt = the addon's number
--   Net.OldDailyChannels(tag, salt, day)          the ones to leave (yesterday's, both-factions)
----------------------------------------------------------------------
local CODE = "bcdfghjkmnpqrstvwxz23456789"   -- no vowels: no accidental words for the name filter
local function mix(h, n) return (h * 31 + n) % 2147483629 end
local function code(seed, len)
    local h, out = seed, {}
    for i = 1, len do
        h = mix(mix(h, i), 7919)
        local k = h % #CODE + 1
        out[i] = CODE:sub(k, k)
    end
    return table.concat(out)
end

function Net.Day()
    return math.floor(((GetServerTime and GetServerTime()) or time()) / 86400)
end

-- One channel PER FACTION (2026-11-10, as VoidQuest 0.3.20): a channel lists both factions,
-- but whispers don't cross them on Forever, so every whisper to an other-faction member
-- bounced ("No player named X is currently playing") and the players box counted them as
-- online (VoidLayer showed 8 while VoidQuest's own-faction count was 0). Hop groups can't
-- cross factions either. faction: 1 Horde, 2 Alliance, 3 none yet (a new Pandaren; once they
-- pick, the addons' 60 s day check sees a new name and moves them).
-- faction: nil = yours; false = the old both-factions channel of that day (only to leave it).
local FACTION_SALT = { Horde = 1, Alliance = 2 }
local knownFaction   -- the first real faction seen sticks: a moment of no answer (or a
                     -- battleground's other side) must not flip the channel on the 60 s check
function Net.Faction()
    if not knownFaction then
        local f = UnitFactionGroup and UnitFactionGroup("player")
        knownFaction = FACTION_SALT[f]
    end
    return knownFaction or 3
end

function Net.DailyChannel(tag, salt, day, faction)
    day = day or Net.Day()
    if faction == nil then faction = Net.Faction() end
    local s = mix(mix(salt, day), salt % 97)
    if faction then s = mix(s, faction) end
    return tag .. code(s, 6), code(mix(s, 104729), 8), day
end

-- Channels a /reload (or an older version) may have left us in, to leave: yesterday's of
-- our faction, the no-faction ones (a Pandaren who just picked), and the old both-factions
-- ones (before 2026-11-10), today's and yesterday's.
function Net.OldDailyChannels(tag, salt, today)
    today = today or Net.Day()
    local mine = Net.Faction()
    local out = { (Net.DailyChannel(tag, salt, today - 1)) }
    for _, day in ipairs({ today, today - 1 }) do
        out[#out + 1] = (Net.DailyChannel(tag, salt, day, false))
        if mine ~= 3 then out[#out + 1] = (Net.DailyChannel(tag, salt, day, 3)) end
    end
    return out
end

function Net.Blocked(channel)
    if not (GetChannelList and type(channel) == "string") then return false end
    local t, want = { GetChannelList() }, channel:lower()
    for i = 1, #t - 2, 3 do   -- id, name, disabled
        local name = t[i + 1]
        if type(name) == "string" and name:lower() == want then return t[i + 2] == true end
    end
    return false
end

local refused = {}   -- [lower(channel)] = notice
local REFUSALS = { WRONG_PASSWORD = true, BANNED = true }
local noticeFrame = CreateFrame("Frame")
noticeFrame:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
noticeFrame:SetScript("OnEvent", function(_, _, notice, _, _, full, _, _, _, _, base)
    if type(notice) ~= "string" or (issecretvalue and (issecretvalue(notice) or issecretvalue(full) or issecretvalue(base))) then return end
    local name = type(base) == "string" and base ~= "" and base
        or type(full) == "string" and full:match("^%d+%.%s*(.+)$") or full
    if type(name) ~= "string" or name == "" then return end
    if REFUSALS[notice] then
        refused[name:lower()] = notice
    elseif notice == "YOU_JOINED" or notice == "YOU_CHANGED" then
        refused[name:lower()] = nil
    end
end)

function Net.Refused(channel)
    return type(channel) == "string" and refused[channel:lower()] or nil
end

-- "blocked" for the players box while the game won't let us into the channel, else nil.
function Net.BlockNote(channel)
    if Net.Blocked(channel) or Net.Refused(channel) then return "blocked" end
end

-- One line saying why, for the addon's /net command (nil when nothing is wrong).
function Net.BlockReason(channel)
    if Net.Blocked(channel) then
        return ("the game won't let you into %s (its owner banned this character). Sharing can't count or reach players until that's lifted."):format(channel)
    end
    local r = Net.Refused(channel)
    if r == "WRONG_PASSWORD" then
        return ("%s has a different password (someone else set it). Sharing can't count or reach players there."):format(channel)
    elseif r == "BANNED" then
        return ("the game won't let you into %s (banned by its owner)."):format(channel)
    end
end

function Net.New(channel, onRoster, store)
    local o = setmetatable({ channel = channel, onRoster = onRoster, roster = {}, count = nil,
                             rosterAt = -ROSTER_EVERY, whispered = {}, bounces = 0,
                             unreach = type(store) == "table" and store or {} }, Obj)
    local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if addFilter then
        addFilter("CHAT_MSG_SYSTEM", function(_, _, text) return o:HidesNotice(text) end)
    end
    local f = CreateFrame("Frame")
    f:RegisterEvent("CHANNEL_ROSTER_UPDATE")
    f:RegisterEvent("CHAT_MSG_SYSTEM")
    f:SetScript("OnEvent", function(_, event, a1)
        if event == "CHANNEL_ROSTER_UPDATE" then
            o:OnRosterUpdate(a1)
        else
            local name = o:NoticeName(a1)   -- our whisper bounced: unreachable for a while
            if name then
                o.unreach[name] = time()
                -- counted (2026-11-10: whispers to the other faction bounced and nothing showed it)
                o.bounces = o.bounces + 1
                if o.onBounce then pcall(o.onBounce, name) end
                if o.onRoster then o.onRoster() end   -- the count drops
            end
        end
    end)
    return o
end
