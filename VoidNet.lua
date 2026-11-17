----------------------------------------------------------------------
-- VoidNet: ONE channel for every Void addon on WoW Forever, with its protection (2026-11-17).
--
-- The user: "build the one channel move" ... "we need to move them all over at once" ... "we also need to
-- think about the backup and security" -> hourly channel names, 3 backups, a saved backup slot, a 2-hour
-- memory of Void players, hostile marks shared with a 3-witness rule ("better safe than sorry").
--
-- THE CHANNEL. On Forever a channel is only a member list (the game refuses addon messages sent into
-- it); messages go by addon whisper. One hourly channel per faction ("Vn" + 6 letters, slot 0 = main,
-- 1..3 = backups) is the member list for every Void addon. Each addon keeps its own message prefix, so
-- each keeps the game's own budget per prefix (~10 at once, then ~1 a second).
--
-- THE PROTECTION (ported from VoidBounty 0.3.4/0.3.5, tested live 11-14 with two PCs). Anyone can work
-- out the name and password (the code is public); the first member owns a channel and an owner can ban.
--   * keep it: an owner leaving (logout / reload) hands ownership to a Void player who has talked on
--     the network; VoidNet never names moderators, so while one of ours owns it nobody can be banned.
--   * check it: everyone reads who owns the channel. An owner nobody has heard from gets up to 3 pings
--     30 s apart; a Void client answers. No answer, the game refusing us (banned / other password), or a
--     hostile owner = the channel was taken: everyone moves to this hour's next backup and tells the
--     others ("M"), so the network follows within about a minute. A /reload keeps the hour's backup.
--   * hostile: the game names who banned / kicked someone in our channel or changed its password (never
--     a VoidNet action). That character is marked hostile: never trusted, answered, whispered or handed
--     the channel, and a channel it owns is left. Witnesses tell the network ("H"); a mark from others
--     counts once 3 different Void players saw it, so one liar can't mark anyone. Marks last 24 hours.
--     No list is ever shown: net commands give counts; the raw notices stay in the saved log.
--   * keep sharing: the channel only FINDS players. Messages also reach Void players heard from in the
--     last hour, so a ban costs finding new players, not the network. The last 2 hours of them are saved
--     (names and time only, deleted after 2 hours, never shown or shared), so a /reload under attack
--     still reaches them.
--
-- OLD VERSIONS. Each addon's OLD channel (VoidQuest "Vq", VoidLayer "Vl", VoidSweep "Vs", VoidGather "Vg",
-- VoidBounty "Vb" hourly) is kept while players on an old version are on it (members of the old channel
-- who never show up on the one channel), and dropped 30 days after the last one. Messages are unchanged.
--
--   local vn = ns.VoidNet.New({ prefix = "VLAYER", legacy = { tag = "Vl", salt = 58313 [, hourly = true] },
--                               db = savedTable, onRoster = fn })
--   It answers like a WhisperNet object: vn.roster, vn:Pick(k), vn:Others(), vn:RequestRoster(force),
--   vn:Reachable(name), vn:Noted(name), vn:Sent(name, result), vn.bounces, vn.onBounce = fn(name)
--   vn:Heard(name)      a message with this prefix came from name: they run this addon (false = hostile:
--                       drop the message)
--   vn:Join(), vn:Day() (the 60 s check: true when the channel changed), vn:Void(), vn:Channel(),
--   vn:LegacyInfo(), vn:Hostile(name)
--   ns.VoidNet.Core():Report() -> lines for a /net command
--
-- Copied as-is into each addon that carries it (source: wow-addons/_shared/VoidNet.lua). The newest copy
-- loaded runs the one core (_G.VoidNetCore) for every addon on this PC.
----------------------------------------------------------------------
local _, ns = ...
local VN = {}
ns.VoidNet = VN
local VERSION = 2

VN.TAG, VN.SALT = "Vn", 52817        -- the one channel (hourly, per faction; salt + slot for the backups)
VN.PREFIX       = "VOIDNET"          -- the guard's own messages: O ping, o answer, M moved, H hostile seen
VN.OLD_DAYS     = 30                 -- an old channel stays this many days after its last old-version player
VN.HEARD_LIVE   = 7200               -- someone who sent us an addon's prefix counts as running it this long
VN.EXPLORE      = 0.25               -- chance a full pick trades one known user for one other member
VN.SEEN_LIVE    = 7200               -- a one-channel read older than this no longer proves "new version"
VN.MAX_SLOT     = 3
VN.PING_EVERY, VN.PING_TRIES, VN.PING_WAIT = 30, 3, 30
VN.PEER_FRESH   = 3600               -- a Void player heard from within this is trusted (owner, hand-over)
VN.REMEMBER     = 7200               -- saved memory of Void players: 2 hours, then deleted
VN.HOSTILE_FOR  = 86400              -- a hostile mark lasts 24 hours
VN.WITNESSES    = 3                  -- different Void players who must report the same hostile act
VN.TELL         = 12                 -- players told "we moved"
VN.SPREAD       = 12                 -- players told "hostile seen"
VN.SEND_EVERY   = 1.1                -- the game allows ~1 a second per prefix

local function secret(v) return issecretvalue and issecretvalue(v) or false end
local function hourNow()
    local t = GetServerTime and GetServerTime()
    if type(t) ~= "number" then t = time() end
    return math.floor(t / 3600)
end
VN.Hour = hourNow

local function chatLocked()
    if InCombatLockdown and InCombatLockdown() then return true end
    local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
    if not f then return false end
    local ok, v = pcall(f)
    if not ok or secret(v) then return true end
    return v == true
end
VN.ChatLocked = chatLocked

local function joinedTo(name) local id = name and GetChannelName(name); return id and id > 0 end

local function hideFromChat(name)
    C_Timer.After(2, function()
        if not joinedTo(name) or not ChatFrame_RemoveChannel then return end
        for i = 1, (NUM_CHAT_WINDOWS or 10) do
            local cf = _G["ChatFrame" .. i]
            if cf then ChatFrame_RemoveChannel(cf, name) end
        end
    end)
end

local function validName(n) return type(n) == "string" and n ~= "" and #n <= 48 and not n:find("[|:\n]") and not secret(n) end

----------------------------------------------------------------------
-- The core: one per PC, built by the newest copy loaded (all files are loaded before any addon asks)
----------------------------------------------------------------------
if type(rawget(_G, "VoidNetReg")) ~= "table" then rawset(_G, "VoidNetReg", { list = {} }) end
local REG = rawget(_G, "VoidNetReg")
table.insert(REG.list, { v = VERSION, ns = ns })

function VN.Core()
    local have = rawget(_G, "VoidNetCore")
    if have then return have end
    local best
    for _, c in ipairs(REG.list) do if not best or c.v > best.v then best = c end end
    rawset(_G, "VoidNetCore", best.ns.VoidNet.BuildCore())
    return rawget(_G, "VoidNetCore")
end

function VN.BuildCore()
    local Net = ns.WhisperNet
    local C = { version = VERSION, facades = {}, dbs = {}, owner = nil, pinged = {}, answered = {}, seen = {},
                witness = {}, queue = {}, G = {}, sentCount = 0 }
    -- saved state (one table, put in every attached addon's saved data; the newest one found is kept)
    C.state = { stamp = 0, peers = {}, hostile = {}, log = {} }
    C.me = Net.Me()

    local function log(kind, a, b)
        local l = C.state.log
        l[#l + 1] = { t = time(), k = kind, a = a, b = b, ch = C.channel }
        while #l > 50 do table.remove(l, 1) end
    end
    C.Log = log

    -- memory: Void players heard (time()), saved 2 h; hostile marks, 24 h
    function C:Prune()
        local now = time()
        for n, t in pairs(self.state.peers) do if type(t) ~= "number" or now - t > VN.REMEMBER then self.state.peers[n] = nil end end
        for n, h in pairs(self.state.hostile) do
            if type(h) ~= "table" or now - (tonumber(h.t) or 0) > VN.HOSTILE_FOR then self.state.hostile[n] = nil end
        end
        for n, w in pairs(self.witness) do
            for s, t in pairs(w) do if now - t > 3600 then w[s] = nil end end
            if not next(w) then self.witness[n] = nil end
        end
        self.state.stamp = now
    end
    function C:Hostile(name) local h = name and self.state.hostile[name]; return h and (time() - (tonumber(h.t) or 0) <= VN.HOSTILE_FOR) or false end
    function C:Fresh(name, within)
        local t = name and not self:Hostile(name) and self.state.peers[name]
        return t and time() - t < (within or VN.PEER_FRESH) or false
    end
    -- a member: on the one channel's list now, or seen there at a read in the last hour (a whisper alone
    -- never makes a stranger trusted: Sol-style rule, the tests' "stranger is ignored")
    function C:IsMember(name)
        if not validName(name) then return false end
        local t = self.seen[name]
        if t and time() - t < VN.PEER_FRESH then return true end
        for _, n in ipairs(self.main.roster or {}) do if n == name then return true end end
        return false
    end
    function C:Peer(name, member)
        if not validName(name) or name == self.me then return end
        if not (member or self:IsMember(name)) then return end
        local new = not self:Fresh(name)
        self.state.peers[name] = time()
        if name == self.owner then self.pinged[name] = nil end
        if new then self:Notify() end
    end
    -- Void players heard within `within` (default 1 h), reachable, not hostile
    function C:FreshList(within)
        local out = {}
        for n, t in pairs(self.state.peers) do
            if time() - t < (within or VN.PEER_FRESH) and not self:Hostile(n) and self.main:Reachable(n) then out[#out + 1] = n end
        end
        return out
    end

    function C:Attach(f, db)
        self.facades[#self.facades + 1] = f
        if type(db) == "table" then
            -- every Void addon's account data holds a copy (the last save wrote the same table to all of them,
            -- but an addon that was off last session has an older one): MERGE them, never pick one, because
            -- Prune moves the stamp to now and a newer copy loading later must still count (Sol, 2026-11-17)
            local saved, st = db.vnetCore, self.state
            if type(saved) == "table" and saved ~= st then
                local stamp = tonumber(saved.stamp) or 0
                for n, t in pairs(type(saved.peers) == "table" and saved.peers or {}) do
                    if type(t) == "number" and t > (tonumber(st.peers[n]) or 0) then st.peers[n] = t end
                end
                for n, h in pairs(type(saved.hostile) == "table" and saved.hostile or {}) do
                    local cur = st.hostile[n]
                    if type(h) == "table" and (tonumber(h.t) or 0) > (type(cur) == "table" and tonumber(cur.t) or 0) then st.hostile[n] = h end
                end
                if saved.helpPopup then st.helpPopup = true end
                if stamp > (self.newest or 0) then   -- the newest save's backup slot and log
                    self.newest = stamp
                    st.slot = type(saved.slot) == "table" and saved.slot or nil   -- the newest save's, even "none"
                    st.log = type(saved.log) == "table" and saved.log or st.log
                end
            end
            self.dbs[#self.dbs + 1] = db
            for _, d in ipairs(self.dbs) do d.vnetCore = self.state end
            self:Prune()
        end
    end

    function C:Notify()
        for _, f in ipairs(self.facades) do
            pcall(f.CheckLegacy, f)
            if f.spec.onRoster then pcall(f.spec.onRoster) end
        end
    end

    -- the channel of (hour, slot)
    local function channelFor(hour, s) return Net.DailyChannel(VN.TAG, VN.SALT + (s or 0), hour) end
    C.ChannelFor = channelFor
    local hour = hourNow()
    -- the backup of this hour we were on (a /reload); attached dbs may load later, so re-checked in Start
    C.hour, C.slot = hour, 0
    C.channel, C.pw = channelFor(hour, 0)

    -- the member list of the one channel, shared by every addon on this PC (one read, one set of
    -- offline marks); the owner flag is read only inside a real read of OUR list
    C.main = Net.New(C.channel, function()
        if C.reading then
            local now = time()
            for _, n in ipairs(C.main.roster or {}) do C.seen[n] = now end
            for _, f in ipairs(C.facades) do pcall(f.NoteShared, f) end
            local o = C:RosterOwner()
            if o then C:SetOwner(o) else C:Guard() end
            -- the list's owner flag can be stale: not sure who owns it? ask the game (its answer comes back as
            -- a CHANNEL_OWNER notice, see the notice handler), at most once a minute
            if not C.ownerSure and DisplayChannelOwner and time() - (C.askedOwner or 0) >= 60 then
                C.askedOwner = time()
                pcall(DisplayChannelOwner, C.channel)
            end
            C:ReadySuccessor()
        else
            C:Guard()
        end
        C:Notify()
    end, {})
    -- a bounce belongs to the addon(s) that whispered that name in the last 30 s, counted once each (live 11-17:
    -- VoidLayer showed every Void addon's bounces, twice: the shared list and its old channel both counted)
    C.main.onBounce = function(n)
        local now = GetTime()
        for _, f in ipairs(C.facades) do
            local t = f.noted and f.noted[n]
            if t and now - t <= 30 then
                f.bounceCount = (f.bounceCount or 0) + 1
                if f.onBounce then pcall(f.onBounce, n) end
            end
        end
    end
    local readRoster = C.main.ReadRoster
    C.main.ReadRoster = function(self, ...)
        C.reading = true
        local ok, err = pcall(readRoster, self, ...)
        C.reading = false
        if not ok then error(err, 0) end
    end

    function C:RosterOwner()
        local i = self.main:DisplayIndex()
        if not (i and C_ChatInfo and C_ChatInfo.GetChannelRosterInfo) then return nil end
        local _, _, _, _, count = GetChannelDisplayInfo(i)
        for r = 1, math.min(tonumber(count) or 0, 300) do
            local ok, name, isOwner = pcall(C_ChatInfo.GetChannelRosterInfo, i, r)
            if ok and isOwner == true and not secret(name) then return Net.Canon(name) end
        end
    end

    -- channels to leave: the other slots of this hour and every slot of the last
    function C:OldChannels()
        local out = {}
        for s = 0, VN.MAX_SLOT do
            local a = channelFor(self.hour, s); if a ~= self.channel then out[#out + 1] = a end
            out[#out + 1] = (channelFor(self.hour - 1, s))
        end
        for _, o in ipairs(Net.OldDailyChannels(VN.TAG, VN.SALT, self.hour)) do out[#out + 1] = o end
        return out
    end
    function C:Ours(name)
        if type(name) ~= "string" or secret(name) then return false end
        name = name:lower()
        for s = 0, VN.MAX_SLOT do
            if name == channelFor(self.hour, s):lower() or name == channelFor(self.hour - 1, s):lower() then return true end
        end
        return false
    end

    C.retry = CreateFrame("Frame")
    -- a second after the event, never inside it (the game reports "not restricted" while dispatching a
    -- restriction change, even one about to start)
    C.retry:SetScript("OnEvent", function(fr)
        if C.retryWaiting then return end
        C.retryWaiting = true
        C_Timer.After(1, function()
            C.retryWaiting = false
            if chatLocked() then return end
            fr:UnregisterAllEvents()
            C:Join()
            -- and each addon's old channel, skipped while locked (Sol, 2026-11-17: it waited for the next day otherwise)
            for _, f in ipairs(C.facades) do pcall(f.JoinLegacy, f) end
        end)
    end)
    function C:Join()
        if chatLocked() then
            for _, ev in ipairs({ "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "ENCOUNTER_END" }) do self.retry:RegisterEvent(ev) end
            -- the lockdown can also end with no fight or zone change (Sol): the restriction event says so
            pcall(self.retry.RegisterEvent, self.retry, "ADDON_RESTRICTION_STATE_CHANGED")
            return
        end
        for _, old in ipairs(self:OldChannels()) do
            if joinedTo(old) then LeaveChannelByName(old) end
        end
        if not joinedTo(self.channel) then JoinTemporaryChannel(self.channel, self.pw) end
        hideFromChat(self.channel)
    end

    -- the guard's own whispers (VOIDNET prefix): paced, guard traffic first, held through a lockdown
    function C:Send(to, msg)
        if not validName(to) or self:Hostile(to) or to == self.me then return end
        table.insert(self.queue, 1, { to = to, msg = msg })
        if self.pumping then return end
        self.pumping = true
        local function step()
            local job = table.remove(self.queue)
            while job and self:Hostile(job.to) do job = table.remove(self.queue) end
            if not job then self.pumping = false return end
            if chatLocked() then
                table.insert(self.queue, job)
                C_Timer.After(5, step)
                return
            end
            self.main:Noted(job.to)
            local ok, res = pcall(C_ChatInfo.SendAddonMessage, VN.PREFIX, job.msg, "WHISPER", job.to)
            self.main:Sent(job.to, ok and res or nil)
            self.sentCount = self.sentCount + 1
            C_Timer.After(VN.SEND_EVERY, step)
        end
        step()
    end

    -- go to channel (hour, s): leave the one we're in, forget its owner, join, read its members
    function C:SwitchTo(h, s)
        local name, pw = channelFor(h, s)
        if name == self.channel then return end
        self.channel, self.pw, self.hour, self.slot = name, pw, h, s
        self.owner, self.ownerSure, self.pinged = nil, nil, {}
        self.state.slot = s > 0 and { hour = h, slot = s } or nil
        self.main:SetChannel(name)
        -- join once the queued "we moved" whispers are out (receivers check we were a member)
        C_Timer.After(2 + #self.queue * VN.SEND_EVERY, function()
            self:Join()
            C_Timer.After(3, function() self.main:RequestRoster(true) end)
        end)
        self:Notify()
    end

    -- "we moved to backup s": the owner first, then channel-mates heard from, then other fresh peers;
    -- each client passes it on once (it moves once per slot, so it can't echo)
    function C:TellMoved(s)
        local told, n = {}, 0
        local function tell(name)
            if n < VN.TELL and name and name ~= self.me and not told[name] and self:Fresh(name) then
                told[name] = true; n = n + 1; self:Send(name, ("M:%d:%d"):format(s, self.hour))
            end
        end
        tell(self.owner)
        local list = self.main.roster or {}
        local start = #list > 0 and math.random(#list) or 1
        for k = 0, #list - 1 do tell(list[(start - 1 + k) % #list + 1]) end
        for name in pairs(self.state.peers) do tell(name) end
    end

    function C:Move(reason)
        if self.slot >= VN.MAX_SLOT then
            if not self.G.stuck then self.G.stuck = true; log("NO_BACKUP_LEFT", reason) end
            return
        end
        log("MOVED", reason)
        local to = self.slot + 1
        self:TellMoved(to)
        self:SwitchTo(self.hour, to)
        self.G.moves = (self.G.moves or 0) + 1
    end

    function C:Guard()
        if not self.channel then return end
        if Net.Blocked(self.channel) or Net.Refused(self.channel) then return self:Move("refused") end
        local o = self.owner
        if o and self:Hostile(o) then return self:Move("owner is hostile") end
        if not o or o == self.me or self:Fresh(o) then return end
        local p = self.pinged[o] or { n = 0, at = -VN.PING_EVERY }
        self.pinged[o] = p
        local now = time()
        -- while the game holds whispers back (some fights) neither a ping nor its answer gets through
        if chatLocked() then
            if p.n > 0 then p.at = now end
            if not self.G.lockWait then
                self.G.lockWait = true
                C_Timer.After(VN.PING_WAIT, function() self.G.lockWait = nil; self:Guard() end)
            end
            return
        end
        if p.n >= VN.PING_TRIES then
            if now - p.at >= VN.PING_WAIT then return self:Move("owner never answered") end
            return
        end
        if now - p.at < VN.PING_EVERY then return end
        p.n, p.at = p.n + 1, now
        log("PING", o, tostring(p.n))
        self:Send(o, "O:" .. p.n)
        C_Timer.After(VN.PING_EVERY + 1, function() self:Guard() end)
    end

    -- sure = learned from the game's own notice or the old owner's word. The member list's owner flag is often STALE
    -- (live 11-17: it still named a player who had left, and the new owner never saw itself flagged), so it only
    -- fills in an owner we don't know yet and never overrides a sure one.
    -- a full "First Surname" for a first name the game gave, when exactly one member (or we) has it
    function C:ByFirstName(first)
        if type(first) ~= "string" or first == "" or secret(first) then return nil end
        if first:find(" ") then return Net.Canon(first) end
        local hit
        local function try(n)
            if type(n) == "string" and (n == first or n:match("^(%S+) ") == first) and n ~= hit then
                if hit then hit = false else hit = n end
            end
        end
        try(self.me)
        for _, n in ipairs(self.main.roster or {}) do if hit == false then break end try(n) end
        return hit or nil
    end

    function C:SetOwner(name, sure)
        name = Net.Canon(name)
        if not name or secret(name) then return end
        if not sure and self.ownerSure then return end
        self.owner = name
        if sure then self.ownerSure = true end
        self:Guard()
    end

    -- an owner keeps a successor ready: pings up to 2 members it hasn't heard from (each every 10 min)
    C.successorAsked = {}
    function C:ReadySuccessor()
        if not (self.owner and self.owner == self.me) then return end
        local now, n = time(), 0
        for _, name in ipairs(self.main.roster or {}) do
            if n >= 2 then return end
            if name ~= self.me and not self:Hostile(name) and not self:Fresh(name)
                and now - (self.successorAsked[name] or -600) >= 600 then
                self.successorAsked[name] = now
                n = n + 1
                self:Send(name, "O:0")
            end
        end
    end

    -- logging out while we own the channel: hand it to a Void player in it. NOT on a /reload (the owner keeps the
    -- channel through a reload, live 11-17; handing it over each reload left nobody knowing who owned it). The game
    -- tells everyone but the NEW owner, so we tell them ourselves first ("W"), straight out (no queue: we're leaving).
    function C:HandOver()
        if self.reloading or not (self.owner and self.owner == self.me) then return end
        -- members on the list first; else a Void player seen on the channel this hour (the list may predate them:
        -- live 11-17 the owner read it alone, the next player joined a minute later)
        local cands = {}
        for _, name in ipairs(self.main.roster or {}) do cands[#cands + 1] = name end
        for _, name in ipairs(self:FreshList()) do if self:IsMember(name) then cands[#cands + 1] = name end end
        for _, name in ipairs(cands) do
            if name ~= self.me and self:Fresh(name) then
                if C_ChatInfo and C_ChatInfo.SendAddonMessage then
                    pcall(C_ChatInfo.SendAddonMessage, VN.PREFIX, ("W:%d:%d"):format(self.slot, self.hour), "WHISPER", name)
                end
                pcall(SetChannelOwner, self.channel, name)
                self.owner, self.ownerSure = name, true
                return name
            end
        end
    end
    -- a /reload keeps the channel: no hand-over then (PLAYER_LOGOUT fires for both)
    local function reloading() C.reloading = true end
    if hooksecurefunc then
        if ReloadUI then pcall(hooksecurefunc, "ReloadUI", reloading) end
        if C_UI and C_UI.Reload then pcall(hooksecurefunc, C_UI, "Reload", reloading) end
    end

    -- a hostile act we saw ourselves (the game names who): marked at once, and the network is told
    function C:Witness(kind, a2, a5)
        local who, why
        if kind == "PLAYER_BANNED" or kind == "PLAYER_KICKED" then
            who, why = a5, kind == "PLAYER_BANNED" and "banned a player" or "kicked a player"
        elseif kind == "PASSWORD_CHANGED" then
            who, why = a2, "changed the password"
        end
        -- NOT SET_MODERATOR: the server names a moderator itself when an owner leaves (VoidBounty 0.3.5)
        who = Net.Canon(who)
        if not validName(who) or who == self.me or self:Hostile(who) then return end
        self.state.hostile[who] = { t = time(), why = why, own = true }
        log("HOSTILE", who, why)
        local told = {}
        for _, n in ipairs(self:FreshList()) do
            if #told >= VN.SPREAD then break end
            told[#told + 1] = n
        end
        for _, n in ipairs(told) do self:Send(n, ("H:%s:%s:%d"):format(who, kind, self.hour)) end
        C_Timer.After(1, function() self:Guard() end)
    end

    -- another Void player saw it: counts once VN.WITNESSES different ones did (within the hour)
    function C:OnHostileReport(sender, who, kind, h)
        if not (validName(who) and kind and (kind == "PLAYER_BANNED" or kind == "PLAYER_KICKED" or kind == "PASSWORD_CHANGED")) then return end
        if tonumber(h) ~= self.hour and tonumber(h) ~= self.hour - 1 then return end
        if who == self.me or self:Hostile(who) then return end
        local w = self.witness[who] or {}
        self.witness[who] = w
        w[sender] = time()
        local n = 0
        for _ in pairs(w) do n = n + 1 end
        if n >= VN.WITNESSES then
            self.state.hostile[who] = { t = time(), why = "reported by " .. n .. " Void players" }
            log("HOSTILE_REPORTED", who, tostring(n))
            self:Guard()
        end
    end

    function C:OnMessage(msg, sender)
        local knew = self:Fresh(sender)
        local tag = msg:match("^(%a):")
        if not tag and msg ~= "o" then return end
        self:Peer(sender)
        if tag == "O" then
            -- "are you a Void client?": answer, at most every 30 s each
            local now = time()
            if self.answered[sender] and now - self.answered[sender] < 30 then return end
            self.answered[sender] = now
            self:Send(sender, "o")
        elseif tag == "M" then
            local s, h = msg:match("^M:(%d):(%d+)$")
            s, h = tonumber(s), tonumber(h)
            if not (s and h) or h ~= self.hour or s <= self.slot or s > VN.MAX_SLOT then return end
            -- only from a player heard from before this message who was in our channel at the last read
            if not knew then return end
            local mate = false
            for _, n in ipairs(self.main.roster or {}) do if n == sender then mate = true break end end
            if not mate then return end
            -- and only with proof (Sol, 2026-11-17: one griefer running the addon could otherwise push everyone
            -- to the last backup and use them all up): our own guard already doubts the owner (pinged and
            -- not answered, or marked hostile), or 2 different Void players say so. Every client sees a ban or
            -- a silent owner itself, so this only makes the network follow faster, never slower.
            local o = self.owner
            local doubt = o and o ~= self.me and ((self.pinged[o] and self.pinged[o].n > 0) or self:Hostile(o))
            if not (doubt and s == self.slot + 1) then   -- one voice moves us one step at most (Sol re-check)
                self.votes = (self.votes and self.votes.h == h and self.votes.s0 == self.slot) and self.votes
                    or { h = h, s0 = self.slot, by = {} }
                self.votes.by[sender] = s
                local n = 0
                for _, vs in pairs(self.votes.by) do if vs >= s then n = n + 1 end end
                if n < 2 then return end
            end
            log("FOLLOWED", sender, tostring(s))
            self:TellMoved(s)
            self:SwitchTo(self.hour, s)
        elseif tag == "W" then
            -- "you own the channel now": only from the player we know owns it, for this channel (a griefer can't
            -- make us think we own it; the game never tells the new owner itself, live 11-17)
            local s, h = msg:match("^W:(%d):(%d+)$")
            if sender ~= self.owner or tonumber(s) ~= self.slot or tonumber(h) ~= self.hour then return end
            log("GOT_OWNER", sender)
            self.owner, self.ownerSure = self.me, true
            self:ReadySuccessor()
        elseif tag == "H" then
            local who, kind, h = msg:match("^H:([^:]+):(%u[%u_]+):(%d+)$")
            if not knew then return end   -- only Void players we already knew can vouch
            self:OnHostileReport(sender, who, kind, h)
        end
    end

    -- counts and state for a /net command (never names a hostile player)
    function C:Report()
        local lines = {}
        local hostile = 0
        for n in pairs(self.state.hostile) do if self:Hostile(n) then hostile = hostile + 1 end end
        lines[#lines + 1] = ("VoidNet: %s%s, owner %s; %d Void player%s heard in the last hour; %d hostile marked (24 h)."):format(
            self.slot > 0 and "backup " or "main channel", self.slot > 0 and tostring(self.slot) or "",
            self.owner and (self.owner == self.me and "you" or (self:Fresh(self.owner) and "a Void player" or "not heard from yet")) or "not seen yet",
            #self:FreshList(), #self:FreshList() == 1 and "" or "s", hostile)
        if self.G.stuck then lines[#lines + 1] = "VoidNet: every backup of this hour was taken; still sharing with players heard from." end
        local why = Net.BlockReason(self.channel)
        if why then lines[#lines + 1] = why end
        return lines
    end

    -- the game's notices on our channels, our own messages, logout, the hour
    local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    local function hideNotice(_, _, notice, _, _, full, _, _, _, _, base)
        if secret(notice) or secret(full) or secret(base) then return false end
        local name = type(base) == "string" and base ~= "" and base or type(full) == "string" and full:match("^%d+%.%s*(.+)$") or full
        return C:Ours(name)
    end
    if addFilter then
        addFilter("CHAT_MSG_CHANNEL_NOTICE", hideNotice)
        addFilter("CHAT_MSG_CHANNEL_NOTICE_USER", hideNotice)
    end
    local ev = CreateFrame("Frame")
    for _, e in ipairs({ "PLAYER_LOGOUT", "CHAT_MSG_ADDON", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER" }) do
        pcall(ev.RegisterEvent, ev, e)
    end
    ev:SetScript("OnEvent", function(_, e, a1, a2, a3, a4, a5, _, _, _, a9)
        if e == "CHAT_MSG_CHANNEL_NOTICE_USER" then
            -- arg1 = what, arg2 = the player it names, arg5 = the second one ("x banned y"), arg9 = the channel
            if secret(a1) or secret(a2) or secret(a5) or secret(a9) or type(a1) ~= "string" or not C:Ours(a9) then return end
            log(a1, type(a2) == "string" and a2 or nil, type(a5) == "string" and a5 ~= "" and a5 or nil)
            if type(a9) == "string" and a9:lower() == C.channel:lower() then
                if a1 == "OWNER_CHANGED" then C:SetOwner(a2, true)
                elseif a1 == "CHANNEL_OWNER" then
                    -- "Channel owner is X" names only the FIRST name (live 11-17: "Ana", not "Ana Brightwood"):
                    -- taken only when exactly one member of our list has it, else a /owner typed by anyone could
                    -- make us chase a player who doesn't exist and move to a backup for nothing
                    local full = C:ByFirstName(a2)
                    if full then C:SetOwner(full, true) end
                end
                C:Witness(a1, type(a2) == "string" and a2 or nil, type(a5) == "string" and a5 ~= "" and a5 or nil)
            end
        elseif e == "CHAT_MSG_CHANNEL_NOTICE" then
            -- refused at the door (banned / other password): on to the backup
            if secret(a1) or secret(a9) then return end
            if a1 == "NOT_ALLOWED_IN_CHANNEL" then C_Timer.After(2, function() C:Guard() end) return end
            if type(a9) == "string" and a9:lower() == C.channel:lower() and (a1 == "WRONG_PASSWORD" or a1 == "BANNED") then
                C_Timer.After(1, function() C:Guard() end)
            end
        elseif e == "PLAYER_LOGOUT" then
            C:HandOver()
            C:Prune()
        elseif e == "CHAT_MSG_ADDON" then
            if a1 ~= VN.PREFIX or a3 ~= "WHISPER" or type(a2) ~= "string" or secret(a2) or #a2 > 255 then return end
            local who = Net.Canon(a4)
            if not validName(who) or who == C.me or C:Hostile(who) then return end
            pcall(C.OnMessage, C, a2, who)
        end
    end)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(VN.PREFIX) end

    -- start: the hour's saved backup (after a /reload), join a little after login, read members
    function C:Start()
        if self.started then return end
        self.started = true
        C_Timer.After(9, function()
            -- the hour's saved backup (after a /reload), read now: every Void addon's saved copy has merged by
            -- then (Sol release review: at the first addon's start a newer copy could still be on its way)
            local k = self.state.slot
            local s0 = type(k) == "table" and tonumber(k.hour) == self.hour and tonumber(k.slot) or 0
            if s0 ~= math.floor(s0) or s0 < 0 or s0 > VN.MAX_SLOT then s0 = 0 end
            if s0 > 0 and self.slot == 0 and hourNow() == self.hour then
                self.slot = s0
                self.channel, self.pw = channelFor(self.hour, s0)
                self.main:SetChannel(self.channel)
            end
            self:Join()
            C_Timer.After(3, function() self.main:RequestRoster(true) end)
        end)
        -- on the hour (server time) everyone moves to the new hour's main channel together; every 15 s
        C_Timer.NewTicker(15, function()
            local h = hourNow()
            if h ~= self.hour then self.G.stuck = nil; self:SwitchTo(h, 0) end
        end)
        C_Timer.NewTicker(300, function() self.main:RequestRoster(false); self:Prune() end)
        -- the owner re-reads members every minute: it must know who can take the channel when it logs out
        C_Timer.NewTicker(60, function() if self.owner == self.me then self.main:RequestRoster(true) end end)
    end
    return C
end

----------------------------------------------------------------------
-- The per-addon side: its prefix, its old channel, who runs it
----------------------------------------------------------------------
local Obj = {}
-- vn.roster is worked out each time it's read (both lists merged), so it's never stale between reads
Obj.__index = function(t, k)
    if k == "roster" then return t:Merge() end
    if k == "bounces" then return t.bounceCount or 0 end   -- this addon's own (see C.main.onBounce)
    return Obj[k]
end

local function legacyName(spec)
    local Net = ns.WhisperNet
    local l = spec.legacy
    if l.hourly then return Net.DailyChannel(l.tag, l.salt, hourNow()) end
    return Net.DailyChannel(l.tag, l.salt)
end

function VN.New(spec)
    local Net = ns.WhisperNet
    local core = VN.Core()
    local o = setmetatable({ prefix = spec.prefix, spec = spec, heard = {}, sharedSeen = {}, sharedReads = {},
                             core = core }, Obj)
    o.db = type(spec.db) == "table" and spec.db or {}
    o.db.vnet = type(o.db.vnet) == "table" and o.db.vnet or {}
    local today = Net.Day()
    local lt = spec.legacy and spec.legacy.tag
    if lt then
        local rec = type(o.db.vnet[lt]) == "table" and o.db.vnet[lt] or {}
        rec.since = tonumber(rec.since) or today
        o.db.vnet[lt] = rec
        o.leg = rec
        o.lname, o.lpw = legacyName(spec)
        o.legacy = Net.New(o.lname, function()
            o:CheckLegacy()
            if spec.onRoster then pcall(spec.onRoster) end
        end, {})
        -- (no onBounce here: every whisper is noted on the shared list too, which counts it once)
    end
    core:Attach(o, o.db)
    o.lastChannel = core.channel
    core:Start()
    return o
end

-- the one channel's members, read by the core: remembered here to tell old versions from new
function Obj:NoteShared()
    local now = GetTime()
    for _, n in ipairs(self.core.main.roster or {}) do self.sharedSeen[n] = now end
    self.sharedReads[#self.sharedReads + 1] = now
    while #self.sharedReads > 20 do table.remove(self.sharedReads, 1) end
end

function Obj:LegacyKept()
    if not self.legacy then return false end
    local Net = ns.WhisperNet
    local from = math.max(tonumber(self.leg.lastOld) or 0, tonumber(self.leg.since) or Net.Day())
    return Net.Day() - from < VN.OLD_DAYS
end

function Obj:LegacyInfo()
    if not self.legacy then return nil end
    local Net = ns.WhisperNet
    local from = math.max(tonumber(self.leg.lastOld) or 0, tonumber(self.leg.since) or Net.Day())
    return { channel = self.lname, kept = self:LegacyKept(), lastOld = self.leg.lastOld,
             daysLeft = math.max(0, VN.OLD_DAYS - (Net.Day() - from)), old = self.oldNow }
end

-- An old-version player = on the old channel, never on the one channel. Only decided when the one
-- channel's list is known well enough: read whole (up to 300), or in windows 3+ times in the last hour.
function Obj:CheckLegacy()
    if not (self.legacy and self:LegacyKept()) then return end
    local sh = self.core.main
    if not sh.count or not self.legacy.count then return end
    local now = GetTime()
    local whole = sh.count <= 300 and #(sh.roster or {}) >= sh.count - 1
    local recent = 0
    for _, t in ipairs(self.sharedReads) do if now - t <= 3600 then recent = recent + 1 end end
    if not whole and recent < 3 then return end
    local old = 0
    for _, n in ipairs(self.legacy.roster or {}) do
        local seen = self.sharedSeen[n]
        if not (seen and now - seen <= VN.SEEN_LIVE) and self:Reachable(n) then old = old + 1 end
    end
    self.oldNow = old
    if old > 0 then self.leg.lastOld = ns.WhisperNet.Day() end
end

function Obj:Hostile(name) return self.core:Hostile(name) end

-- runs this addon: on the old channel (everyone there does), or heard from lately
function Obj:Runs(name)
    local t = self.heard[name]
    if t and GetTime() - t <= VN.HEARD_LIVE then return true end
    if self.legacy and self:LegacyKept() then
        for _, n in ipairs(self.legacy.roster or {}) do if n == name then return true end end
    end
    return false
end

-- false = a hostile sender: drop its message
function Obj:Heard(name)
    if not validName(name) then return nil end
    if self.core:Hostile(name) then return false end
    local member = self.core:IsMember(name)
    if not member and self.legacy and self:LegacyKept() then
        for _, n in ipairs(self.legacy.roster or {}) do if n == name then member = true break end end
    end
    if not member then return nil end   -- not on our lists: the addon's own sender check decides
    self.heard[name] = GetTime()
    self.core:Peer(name, true)
    return true
end

-- everyone on either list (the addons check senders against this), less hostile ones
function Obj:Merge()
    local out, used = {}, {}
    local core = self.core
    local function add(list)
        for _, n in ipairs(list or {}) do
            if not used[n] and not core:Hostile(n) then used[n] = true; out[#out + 1] = n end
        end
    end
    if self.legacy and self:LegacyKept() then add(self.legacy.roster) end
    add(core.main.roster)
    return out
end

function Obj:Reachable(name)
    if self.core:Hostile(name) or not self.core.main:Reachable(name) then return false end
    return not self.legacy or self.legacy:Reachable(name)
end

-- k recipients: players known to run this addon, filled up (or, now and then, mixed) with other members
function Obj:Pick(k)
    local known, other, used = {}, {}, {}
    local now = GetTime()
    local function consider(n)
        if used[n] or not self:Reachable(n) then return end
        used[n] = true
        if self:Runs(n) then known[#known + 1] = n else other[#other + 1] = n end
    end
    for _, n in ipairs(self:Merge()) do consider(n) end
    -- sharing without the channel: Void players heard in the last hour can still be sent to
    for _, n in ipairs(self.core:FreshList()) do consider(n) end
    -- heard lately but outside the window read this time: still online, still a user
    for n, t in pairs(self.heard) do
        if now - t <= VN.HEARD_LIVE then consider(n) else self.heard[n] = nil end
    end
    local function take(list, m, out)
        for _ = 1, m do
            if #list == 0 then return end
            out[#out + 1] = table.remove(list, math.random(#list))
        end
    end
    local out = {}
    take(known, k, out)
    if #out < k then
        take(other, k - #out, out)
    elseif #other > 0 and k > 1 and math.random() < VN.EXPLORE then
        out[#out] = table.remove(other, math.random(#other))
    end
    return out
end

-- players running this addon online: the old channel's count while it's kept, or the users heard lately
function Obj:Others()
    local n = 0
    local now = GetTime()
    for name, t in pairs(self.heard) do if now - t <= VN.HEARD_LIVE and self:Reachable(name) then n = n + 1 end end
    if self.legacy and self:LegacyKept() then
        local lo = self.legacy:Others()
        if lo then return math.max(lo, n) end
    end
    if self.core.main.count == nil and n == 0 then return nil end
    return n
end

-- other Void players online, each ONCE: the one channel's members, every Void addon's old channel while it's kept
-- (players on older versions), and the Void players heard this hour (the user, 11-17: "it is suppose to be all 5
-- addons merged into 1"; it showed 7 = only the new channel + players heard). Offline-marked and hostile players
-- don't count. A list read only in part (a big channel) never counts below that channel's own number.
function Obj:Void()
    local core = self.core
    local seen, n, floor, known = {}, 0, 0, false
    local function add(list, net)
        for _, name in ipairs(list or {}) do
            if not seen[name] and name ~= core.me and not core:Hostile(name) and core.main:Reachable(name)
                and (not net or net:Reachable(name)) then
                seen[name] = true
                n = n + 1
            end
        end
    end
    if core.main.count then
        known = true
        add(core.main.roster)
        floor = math.max(floor, core.main:Others() or 0)
    end
    for _, f in ipairs(core.facades) do
        local l = f.legacy
        if l and l.count and f:LegacyKept() then
            known = true
            add(l.roster, l)
            floor = math.max(floor, l:Others() or 0)
        end
    end
    add(core:FreshList())
    if not known and n == 0 then return nil end
    return math.max(n, floor)
end
function Obj:Channel() return self.core.channel end

function Obj:RequestRoster(force)
    self.core.main:RequestRoster(force)
    if self.legacy and self:LegacyKept() then self.legacy:RequestRoster(force) end
end

function Obj:Noted(name)
    if type(name) == "string" then
        local now = GetTime()
        self.noted = self.noted or {}
        self.noted[name:lower()] = now
        self.notedN = (self.notedN or 0) + 1
        if self.notedN % 200 == 0 then for k, t in pairs(self.noted) do if now - t > 60 then self.noted[k] = nil end end end
    end
    self.core.main:Noted(name)
    if self.legacy then self.legacy:Noted(name) end
end

function Obj:Sent(name, result)
    self.core.main:Sent(name, result)
    if self.legacy then self.legacy:Sent(name, result) end
end

function Obj:Join()
    self.core:Join()
    self:JoinLegacy()
end

-- this addon's old channel: joined while it's kept, left after 30 days with nobody old on it
function Obj:JoinLegacy()
    if not self.legacy then return end
    if chatLocked() then return end   -- the core's retry (after the lockdown) calls this again
    local Net = ns.WhisperNet
    local l = self.spec.legacy
    for _, old in ipairs(l.hourly and Net.OldDailyChannels(l.tag, l.salt, hourNow()) or Net.OldDailyChannels(l.tag, l.salt)) do
        if joinedTo(old) then LeaveChannelByName(old) end
    end
    if self:LegacyKept() then
        if not joinedTo(self.lname) then JoinTemporaryChannel(self.lname, self.lpw) end
        hideFromChat(self.lname)
    elseif joinedTo(self.lname) then
        LeaveChannelByName(self.lname)   -- 30 days with nobody old: the old channel goes
    end
end

-- the 60 s check: true when this addon's channels changed (the one channel's hour / backup, the old
-- channel's day or hour); the old channel is left once it's no longer needed
function Obj:Day()
    local changedNow = false
    if self.core.channel ~= self.lastChannel then
        -- (not wiping sharedSeen / sharedReads: the new channel's list may already be read into them, and a
        -- player seen on the one channel within 2 h is a new version either way; Sol release review)
        self.lastChannel = self.core.channel
        changedNow = true
    end
    if self.legacy then
        local l2, lp2 = legacyName(self.spec)
        if l2 ~= self.lname then
            if not chatLocked() and joinedTo(self.lname) then LeaveChannelByName(self.lname) end
            self.lname, self.lpw = l2, lp2
            self.legacy:SetChannel(l2)
            changedNow = true
            C_Timer.After(5 + math.random() * 5, function()
                self:Join()
                C_Timer.After(4, function() self:RequestRoster(true) end)
            end)
        elseif not self:LegacyKept() and joinedTo(self.lname) and not chatLocked() then
            LeaveChannelByName(self.lname)
        end
    end
    return changedNow
end
