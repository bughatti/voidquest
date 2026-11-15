----------------------------------------------------------------------
-- VoidSwarm — torrent-style data sharing between Void addon players (WoW Forever).
--
-- The user, 2026-11-15: "torrents had been created decades ago to solve a problem like this, how
-- do we make ours like a torrent". The old way pushed a find to 6 random players and stopped. Here
-- every player keeps PIECES (all that's known about one dungeon, one quest zone, ...) and now and
-- then compares them with ONE random player; only what differs moves. A fact reaches everyone in
-- about log2(players) rounds while each player's traffic stays the same at 50 or 50,000 players.
--
-- The game's limits (WoW Forever, measured / documented 2026-11-15): an addon message is at most
-- 255 bytes; each prefix may send a burst of 10 and then 1 a second; addon messages to a custom
-- channel are refused, so they go by WHISPER and the channel is only a member list.
--
-- TORRENT -> HERE
--   piece          kind + piece id, e.g. "m" (dungeon mobs) + "129" (Razorfen Downs)
--   piece hash     a 24-bit fingerprint of the piece, from 8 bucket fingerprints (keys by hash)
--   have           ZH: up to 20 "kind piece = fingerprint" to one random player each ROUND
--   request        ZW: "this piece differs: here are my 8 bucket fingerprints"
--   piece data     ZG: the entries of the buckets that differ (key ^ value, ~ between entries)
--   tracker        the host's member list (any few random players will do)
--   .torrent file  the data that ships with each release (the host seeds it as its own)
--
-- TRUST (no tokens travel; nothing to forge): each player counts WHO HANDED THEM a value: the game
-- names a whisper's sender, a hacked client can't fake that. A value is used and passed on once
-- `need` different players gave it (or it's your own find; your own always wins locally). So an
-- honest fact spreads through the whole swarm, while a fake needs `need` colluding characters to
-- go anywhere. Senders are counted by a salted one-way hash (the host's); no names are kept.
--
-- The core touches no game API: the host hands in io = { send(to, msg), members(k) -> names,
-- me() -> name, now() -> seconds, hash(name) -> short string }. The same code runs in the game and
-- in tools/cmd/vswarm-sim (thousands of players on a fake network).
--
--   local net = VoidSwarm.New(io)
--   net:Register("m", { need = 3, valid = function(piece, key, value) ... end,
--       store = SomeDB.swarm_m, onConfirmed = function(piece, key, value) end,
--       paused = function() return sharingOff end })   -- off: this PC only, nothing sent or taken
--   net:Report("m", "129", key, value)   your own first-hand find
--   net:Get("m", "129", key)            -> value, players, own   (nil = nothing usable)
--   net:Interest("m", "129")            entering that dungeon: ask 2 players for it now
--   net:Tick()                          about every second
--   net:OnMessage(msg, sender)          the host's inbound "Z..." messages
----------------------------------------------------------------------
local VERSION = 1
if _G.VoidSwarm and (_G.VoidSwarm.VERSION or 0) >= VERSION then return end
local S = {}
_G.VoidSwarm = S
S.VERSION = VERSION

local PROTO          = "1"
local MAX_LEN        = 250    -- SendAddonMessage takes 255
local BUCKETS        = 8
local ROUND          = 300    -- seconds between rounds (one random player)
local ROUND_JITTER   = 60
local ASK_PEERS      = 2      -- players asked when you show interest in a piece
local HAVE_MAX       = 20     -- pieces listed in one ZH
local WANT_PER_HAVE  = 2      -- pieces asked for per ZH heard
local GIVE_MAX       = 6      -- ZG messages per ZW answered
local SEND_EVERY     = 1.5    -- seconds between our whispers (the game allows 1 a second)
local QUEUE_MAX      = 60
local SENDER_WINDOW  = 60
local SENDER_MAX     = 40     -- messages taken per sender per window
local ANSWER_MAX     = 6      -- ZW answered per sender per window
local HOLDERS_KEPT   = 5      -- players remembered per value (more adds nothing)
local VALUES_KEPT    = 3      -- different values kept per key
local HAVE_PER_SENDER = 4     -- ZH answered per sender per window
-- key 60 + value 120 + the ZG head stays under MAX_LEN (a VoidSweep spot needs ~71, quest facts 120)
local KEY_MAX, VAL_MAX = 60, 120
local SEEN_FOR       = 1800   -- the same piece compared with the same player: not again for this long unless it changed
local PROBE_WAIT     = 180    -- an old-format sender who hasn't answered our ZP by then is an old client
local PROBE_AGAIN    = 3600   -- ZP / ZO at most this often per player
local KNOWN_MAX      = 3000   -- players whose answer we remember (this session)
local PENDING_MAX    = 50     -- old-format senders waiting for their answer
local OLD_DAYS       = 30     -- old formats stop going out this many days after the last old client
S.LIMITS = { MAX_LEN = MAX_LEN, ROUND = ROUND, SEND_EVERY = SEND_EVERY, HAVE_MAX = HAVE_MAX }

-- a cheap string hash, 0 .. 16777212 (exact in Lua's doubles)
local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 16777213 end
    return h
end
S.Hash = hash

-- the trust bar: a kind's `need`, or the test switch (two test PCs can't reach 3 players)
local function needOf(spec) return S.testNeed or spec.need end

-- what a key or value may hold: printable, none of the message's own separators
local function clean(s, max)
    return type(s) == "string" and s ~= "" and #s <= max and not s:find("[%c~%^:;=|]") and s or nil
end
S.Clean = clean
local function validKind(k) return type(k) == "string" and k:match("^%l$") ~= nil end
local function validPiece(p) return type(p) == "string" and #p <= 20 and p:match("^[%w%-]+$") ~= nil end
-- a kind whose addon has sharing switched off: kept on this PC only (not announced, asked, answered or taken)
local function live(spec) return spec ~= nil and not (spec.paused and spec.paused()) end
-- a player's name without a realm ("Name-Realm" and "Name" are one player to us)
local function base(n) return type(n) == "string" and (n:match("^([^%-]+)") or n) or nil end
S.Base = base

local Net = {}
Net.__index = Net

function S.New(io)
    local t = io.now()
    return setmetatable({
        io = io, kinds = {}, queue = {}, lastSend = -SEND_EVERY,
        nextRound = t + ROUND_JITTER * 0.5 + (io.rand and io.rand() or math.random()) * ROUND_JITTER,
        senders = {}, answers = {}, dirty = {}, cache = {}, compared = {},
        known = {}, knownN = 0, probed = {}, answered = {}, legacy = {}, haves = {},
        stats = { sent = 0, got = 0, bytesOut = 0, dropped = 0, confirmed = 0, rounds = 0, asks = 0 },
    }, Net)
end

----------------------------------------------------------------------
-- Data
-- store[piece] = { [key] = { own = value, vals = { [value] = { h = { [holder] = true }, n } } } }
----------------------------------------------------------------------
function Net:Register(kind, spec)
    assert(validKind(kind), "kind: one lowercase letter")
    spec.need = spec.need or 2
    spec.store = spec.store or {}
    spec.maxPieces = spec.maxPieces or 400
    spec.maxKeys = spec.maxKeys or 400
    self.kinds[kind] = spec
end

local function ckey(kind, piece) return kind .. piece end

-- the real date, for holds that must survive a reload (GetTime restarts with the game)
local function epoch() return (S.epoch and S.epoch()) or (time and time()) or 0 end
local function stamp(v) return tonumber(v:match("^(%d+)")) or 0 end

-- the value this player stands behind for a key. others = what may go to other players: your own
-- find waits out its hold (privacy: not while you're still there). Normally your own, else the one
-- most players gave (at least `need`); spec.newest (kill times): the newest such value, yours included.
local function relay(spec, rec, others)
    local own = rec.own
    if own and others and rec.hold and rec.hold > epoch() then own = nil end
    if own and not spec.newest then return own, nil, true end
    local best, bn, bt, isOwn = nil, nil, nil, false
    if own then best, bt, isOwn = own, stamp(own), true end
    for v, x in pairs(rec.vals or {}) do
        if x.n >= needOf(spec) then
            if spec.newest then
                local t = stamp(v)
                if not bt or t > bt then best, bn, bt, isOwn = v, x.n, t, false end
            elseif not bn or x.n > bn or (x.n == bn and v < best) then
                best, bn = v, x.n
            end
        end
    end
    return best, bn, isOwn
end

function Net:Get(kind, piece, key)
    local spec = self.kinds[kind]
    local p = spec and spec.store[piece]
    local rec = p and p[key]
    if not rec then return nil end
    local v, n, own = relay(spec, rec)
    return v, n, own
end

-- what other players handed you that isn't confirmed yet (for "unconfirmed" in a tooltip, never
-- used by itself): the value most players gave, how many, and how many are needed
function Net:Hint(kind, piece, key)
    local spec = self.kinds[kind]
    local p = spec and spec.store[piece]
    local rec = p and p[key]
    if not rec or not rec.vals then return nil end
    local best, bn
    for v, x in pairs(rec.vals) do
        if not bn or x.n > bn or (x.n == bn and v < best) then best, bn = v, x.n end
    end
    return best, bn, needOf(spec)
end

-- every key of a piece with the value usable now: { [key] = value }
function Net:Piece(kind, piece)
    local spec = self.kinds[kind]
    local p = spec and spec.store[piece]
    local out = {}
    for k, rec in pairs(p or {}) do
        local v = relay(spec, rec)
        if v then out[k] = v end
    end
    return out
end

local function countKeys(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

function Net:mark(kind, piece)
    local ck = ckey(kind, piece)
    self.dirty[ck] = true
    self.cache[ck] = nil
end

-- A full kind makes room (Codex review 2026-11-15: otherwise one sender could fill a kind with
-- believable junk and every later find, your own included, would be refused):
--   your own find (Report): drops something nobody vouches for (not yours, no value at the trust bar)
--   a find handed over (take, untrusted): drops only what ONE player alone gave, and only from the
--     player with the most such records, when that's more than the sender has: a fair share. One
--     spamming character gets at most one slot, the next honest find takes it back, and what two
--     players back, what's confirmed and your own are never pushed out (Codex second pass).
local function weakRec(spec, rec)
    if rec.own then return false end
    for _, x in pairs(rec.vals or {}) do if x.n >= needOf(spec) then return false end end
    return true
end
-- the one player behind a record nobody else vouches for ("" = an empty record); nil = keep it
local function soleHolder(spec, rec)
    if not weakRec(spec, rec) then return nil end
    local one
    for _, x in pairs(rec.vals or {}) do
        for h in pairs(x.h or {}) do
            if one and one ~= h then return nil end
            one = h
        end
    end
    return one or ""
end
-- the single-holder records of `list` (key -> rec, or piece -> its records) grouped by their holder;
-- returns the item to drop, or nil
local function pickSpam(items, sender, weight)
    local count, first = {}, {}
    for id, who in pairs(items) do
        count[who] = (count[who] or 0) + (weight and weight[id] or 1)   -- shares count records, not pieces (Codex)
        first[who] = first[who] or id
    end
    local top, tn = nil, 0
    for who, n in pairs(count) do if n > tn then top, tn = who, n end end
    if top and tn > (count[sender] or 0) then return first[top] end
    return nil
end
function Net:roomKey(kind, piece, sender)
    local spec, p = self.kinds[kind], self.kinds[kind].store[piece]
    local drop
    if sender then
        local items = {}
        for k, rec in pairs(p) do items[k] = soleHolder(spec, rec) end
        drop = pickSpam(items, sender)
    else
        for k, rec in pairs(p) do if weakRec(spec, rec) then drop = k; break end end
    end
    if not drop then return false end
    p[drop] = nil
    self:mark(kind, piece)
    return true
end
function Net:roomPiece(kind, sender)
    local spec = self.kinds[kind]
    local drop
    if sender then
        local items, weight = {}, {}
        for pc, p in pairs(spec.store) do
            -- a piece goes only when all of it is one player's (and nobody vouches for any of it)
            local who, mixed, n = nil, false, 0
            for _, rec in pairs(p) do
                local w = soleHolder(spec, rec)
                if w == nil or (who ~= nil and who ~= w) then mixed = true; break end
                who, n = w, n + 1
            end
            if not mixed then items[pc], weight[pc] = who or "", n end
        end
        drop = pickSpam(items, sender, weight)
    else
        for pc, p in pairs(spec.store) do
            local weak = true
            for _, rec in pairs(p) do if not weakRec(spec, rec) then weak = false; break end end
            if weak then drop = pc; break end
        end
    end
    if not drop then return false end
    spec.store[drop] = nil
    self.cache[ckey(kind, drop)], self.dirty[ckey(kind, drop)] = nil, nil
    return true
end

-- hold = seconds your own find waits before it goes to other players (privacy: not live where you
-- are); Release(kind, piece) lets a piece's held finds go at once (you left that map / dungeon)
function Net:Report(kind, piece, key, value, hold)
    local ok, changed = self:report(kind, piece, key, value)
    -- only a NEW or changed find waits: reporting what you already had (every login) keeps its state
    if ok and changed and hold and hold > 0 then
        local rec = self.kinds[kind].store[piece][key]
        rec.hold = epoch() + hold
        self:mark(kind, piece)
    end
    return ok
end

function Net:Release(kind, piece)
    local spec = self.kinds[kind]
    local p = spec and spec.store[piece]
    if not p then return end
    local any = false
    for _, rec in pairs(p) do
        if rec.hold then rec.hold = nil; any = true end
    end
    if any then self:mark(kind, piece) end
end

function Net:report(kind, piece, key, value)
    local spec = self.kinds[kind]
    if not spec or not validPiece(piece) or not clean(key, KEY_MAX) or not clean(value, VAL_MAX) then return false end
    if spec.valid and not spec.valid(piece, key, value) then return false end
    local st = spec.store
    if not st[piece] then
        if countKeys(st) >= spec.maxPieces and not self:roomPiece(kind) then return false end
        st[piece] = {}
    end
    local p = st[piece]
    if not p[key] then
        if countKeys(p) >= spec.maxKeys and not self:roomKey(kind, piece) then return false end
        p[key] = {}
    end
    if p[key].own == value then return true, false end
    p[key].own = value
    self:mark(kind, piece)
    return true, true
end

-- a value handed over by a player (one holder vote, counted once per player)
function Net:take(kind, piece, key, value, holder)
    local spec = self.kinds[kind]
    if not spec or not clean(key, KEY_MAX) or not clean(value, VAL_MAX) then return end
    if spec.valid and not spec.valid(piece, key, value) then self.stats.dropped = self.stats.dropped + 1 return end
    local st = spec.store
    if not validPiece(piece) then return end
    if not st[piece] then
        if countKeys(st) >= spec.maxPieces and not self:roomPiece(kind, holder) then return end
        st[piece] = {}
    end
    local p = st[piece]
    local rec = p[key]
    if not rec then
        if countKeys(p) >= spec.maxKeys and not self:roomKey(kind, piece, holder) then return end
        rec = {}
        p[key] = rec
    end
    rec.vals = rec.vals or {}
    local orig = value   -- what this player actually said (spec.onTake gets it: the addon averages real spots)
    -- spec.near(a, b): two players' spots for the same thing are never exactly equal; a value close
    -- to one already known (or to your own) counts as a vote for that one
    if spec.near and not rec.vals[value] then
        if rec.own and rec.own ~= value and spec.near(rec.own, value) then
            value = rec.own
        else
            for v in pairs(rec.vals) do
                if spec.near(v, value) then value = v; break end
            end
        end
    end
    local x = rec.vals[value]
    if not x then
        if countKeys(rec.vals) >= VALUES_KEPT then
            local worst, wn
            if spec.newest then
                -- kill times: the oldest goes (and a value older than all we keep isn't worth keeping)
                local wt
                for v, y in pairs(rec.vals) do local t = stamp(v); if not wt or t < wt then worst, wt = v, t end end
                if stamp(value) <= wt then return end
            else
                -- room for a new one: drop the weakest (a fake can't push out a value more players gave)
                for v, y in pairs(rec.vals) do if not wn or y.n < wn then worst, wn = v, y.n end end
                if wn and wn > 1 then return end
            end
            rec.vals[worst] = nil
        end
        x = { h = {}, n = 0 }
        rec.vals[value] = x
    end
    if x.h[holder] or x.n >= HOLDERS_KEPT then return end
    local before = relay(spec, rec, true)
    x.h[holder] = true
    x.n = x.n + 1
    -- the addon's own store learns of every accepted vote (VoidQuest's quest data keeps its own rules)
    if spec.onTake then pcall(spec.onTake, piece, key, value, holder, orig) end
    local after = relay(spec, rec, true)
    if after ~= before then
        self:mark(kind, piece)
        if after == value and x.n == needOf(spec) then
            self.stats.confirmed = self.stats.confirmed + 1
            if spec.onConfirmed then pcall(spec.onConfirmed, piece, key, value) end
        end
    end
end

----------------------------------------------------------------------
-- Fingerprints: 8 buckets (a key's bucket = its hash), each the sum of its entries' hashes
----------------------------------------------------------------------
local function hex(n, w) return ("%0" .. w .. "x"):format(n) end

function Net:digest(kind, piece)
    local ck = ckey(kind, piece)
    local c = self.cache[ck]
    -- a hold that ran out since (even across a reload) changes what others may see: build it again
    if c and not (c.until_ and epoch() >= c.until_) then return c end
    local spec = self.kinds[kind]
    local b, n, untilT = {}, 0, nil
    for i = 1, BUCKETS do b[i] = 0 end
    for k, rec in pairs(spec and spec.store[piece] or {}) do
        if rec.hold and rec.hold > epoch() and (not untilT or rec.hold < untilT) then untilT = rec.hold end
        local v = relay(spec, rec, true)
        if v then
            local i = hash(k) % BUCKETS + 1
            b[i] = (b[i] + hash(k .. "\1" .. v)) % 65521
            n = n + 1
        end
    end
    local parts = {}
    for i = 1, BUCKETS do parts[i] = hex(b[i], 4) end
    local buckets = table.concat(parts)
    c = { buckets = buckets, piece = n == 0 and "000000" or hex(hash(buckets), 6), n = n, until_ = untilT }
    self.cache[ck] = c
    return c
end

----------------------------------------------------------------------
-- Sending: one whisper per SEND_EVERY, queue capped
----------------------------------------------------------------------
function Net:queueSend(to, msg)
    if #msg > MAX_LEN or #self.queue >= QUEUE_MAX then
        self.stats.dropped = self.stats.dropped + 1
        local ty = msg:sub(1, 2) .. (msg:sub(1, 2) == "ZW" and msg:sub(4, 4) or "")
        self.stats.full = self.stats.full or {}
        self.stats.full[ty] = (self.stats.full[ty] or 0) + 1
        return
    end
    self.queue[#self.queue + 1] = { to = to, msg = msg }
end

function Net:peers(k)
    local me = self.io.me()
    local out = {}
    for _, n in ipairs(self.io.members(k + 1) or {}) do
        if n ~= me and #out < k then out[#out + 1] = n end
    end
    return out
end

-- the pieces worth announcing: changed lately first, then a random mix of the rest
function Net:haveList()
    local fresh, rest = {}, {}
    for kind, spec in pairs(self.kinds) do
        for piece in pairs(live(spec) and spec.store or {}) do
            local d = self:digest(kind, piece)
            if d.n > 0 then
                local item = kind .. piece .. "=" .. d.piece
                if self.dirty[ckey(kind, piece)] then fresh[#fresh + 1] = item else rest[#rest + 1] = item end
            end
        end
    end
    local rnd = self.io.rand or math.random
    for i = #rest, 2, -1 do local j = math.floor(rnd() * i) + 1; rest[i], rest[j] = rest[j], rest[i] end
    local out = {}
    for _, it in ipairs(fresh) do if #out < HAVE_MAX then out[#out + 1] = it end end
    for _, it in ipairs(rest) do if #out < HAVE_MAX then out[#out + 1] = it end end
    return out
end

-- ZH messages for a list of items, each under MAX_LEN
local function packList(head, items, sep)
    local msgs, cur = {}, head
    for _, it in ipairs(items) do
        local add = (cur == head and "" or sep) .. it
        if #cur + #add > MAX_LEN then
            msgs[#msgs + 1] = cur
            cur = head .. it
        else
            cur = cur .. add
        end
    end
    if cur ~= head then msgs[#msgs + 1] = cur end
    return msgs
end

function Net:round()
    self.stats.rounds = self.stats.rounds + 1
    -- still busy answering others: this round can wait (no new exchanges on a full queue)
    if #self.queue > QUEUE_MAX / 3 then self.stats.skipped = (self.stats.skipped or 0) + 1 return end
    local list = self:haveList()
    if #list == 0 then return end
    local to = self:peers(1)[1]
    if not to then return end
    for _, m in ipairs(packList("ZH" .. PROTO .. ":", list, ";")) do self:queueSend(to, m) end
    for k in pairs(self.dirty) do self.dirty[k] = nil end
end

function Net:want(to, kind, piece, flag, theirs)
    local d = self:digest(kind, piece)
    -- a have-message from a player we compared this piece with lately, and NEITHER side changed
    -- since (theirs = the fingerprint they just announced): nothing new to learn. A deliberate ask
    -- (Interest) and the answer-back (flag 1) always go.
    if theirs then
        local ck = to .. ":" .. kind .. piece
        local last = self.compared[ck]
        if last and last.d == d.buckets and last.theirs == theirs and self.io.now() - last.t < SEEN_FOR then return end
        self.compared[ck] = { d = d.buckets, theirs = theirs, t = self.io.now() }
    end
    self:queueSend(to, ("ZW%s%s:%s%s:%s"):format(PROTO, flag, kind, piece, d.buckets))
end

function Net:Interest(kind, piece, to)
    if not live(self.kinds[kind]) or not validPiece(piece) then return end
    self.stats.asks = self.stats.asks + 1
    -- to: one named player (a test, or a groupmate), else ASK_PEERS random ones
    for _, p in ipairs(to and { to } or self:peers(ASK_PEERS)) do self:want(p, kind, piece, "0") end
end

-- a queued message of a kind whose sharing was switched off since it was queued: not sent (from a
-- ZH, just those pieces are left out). Codex review 2026-11-15.
function Net:stillOK(m)
    if not m then return nil end
    local k = m.msg:match("^ZG" .. PROTO .. ":(%l)") or m.msg:match("^ZW" .. PROTO .. "[01]:(%l)")
    if k then return live(self.kinds[k]) and m or nil end
    local body = m.msg:match("^ZH" .. PROTO .. ":(.+)$")
    if not body then return m end
    local keep = {}
    for item in body:gmatch("[^;]+") do
        if live(self.kinds[item:sub(1, 1)]) then keep[#keep + 1] = item end
    end
    if #keep == 0 then return nil end
    m.msg = "ZH" .. PROTO .. ":" .. table.concat(keep, ";")
    return m
end

function Net:Tick()
    local now = self.io.now()
    if now >= self.nextRound then
        local rnd = self.io.rand or math.random
        self.nextRound = now + ROUND + (rnd() - 0.5) * ROUND_JITTER
        self:round()
    end
    for _, lg in pairs(self.legacy) do lg:check(now) end
    if #self.queue > 0 and now - self.lastSend >= SEND_EVERY then
        local m
        repeat m = self:stillOK(table.remove(self.queue, 1)) until m or #self.queue == 0
        if not m then return end
        self.lastSend = now
        self.stats.sent = self.stats.sent + 1
        self.stats.bytesOut = self.stats.bytesOut + #m.msg
        self.io.send(m.to, m.msg)
    end
end

----------------------------------------------------------------------
-- Receiving (every message is untrusted: strict patterns, per-sender limits)
----------------------------------------------------------------------
local function window(t, who, now, max)
    local w = t[who]
    if not w or now - w.t > SENDER_WINDOW then w = { t = now, n = 0 }; t[who] = w end
    w.n = w.n + 1
    return w.n <= max
end

-- the entries of a piece in the buckets whose fingerprint differs from `theirs`
function Net:giveFor(to, kind, piece, theirs)
    local spec = self.kinds[kind]
    local mine = self:digest(kind, piece).buckets
    local differ = {}
    for i = 1, BUCKETS do
        if mine:sub(i * 4 - 3, i * 4) ~= theirs:sub(i * 4 - 3, i * 4) then differ[i] = true end
    end
    local items = {}
    for k, rec in pairs(spec.store[piece] or {}) do
        local v = relay(spec, rec, true)   -- held finds of yours don't go out yet
        if v and differ[hash(k) % BUCKETS + 1] then items[#items + 1] = k .. "^" .. v end
    end
    table.sort(items)
    local msgs = packList(("ZG%s:%s%s:"):format(PROTO, kind, piece), items, "~")
    -- more than GIVE_MAX messages: a random run of them (wrapping), so asking again gets the rest
    -- instead of the same first ones every time (Codex review 2026-11-15)
    local start = 0
    if #msgs > GIVE_MAX then start = math.floor((self.io.rand or math.random)() * #msgs) end
    for i = 0, math.min(#msgs, GIVE_MAX) - 1 do self:queueSend(to, msgs[(start + i) % #msgs + 1]) end
    return next(differ) ~= nil
end

function Net:OnMessage(msg, sender)
    if type(msg) ~= "string" or type(sender) ~= "string" or sender == self.io.me() then return end
    local now = self.io.now()
    if not window(self.senders, sender, now, SENDER_MAX) then self.stats.dropped = self.stats.dropped + 1 return end
    self.stats.got = self.stats.got + 1
    local holder = self.io.hash and self.io.hash(sender) or tostring(hash(sender))

    -- "do you speak the swarm?" -> "yes, these kinds" (once per player per PROBE_AGAIN)
    if msg == "ZP" .. PROTO then
        local last = self.answered[sender]
        if not last or now - last > PROBE_AGAIN then
            self.answered[sender] = now
            self:queueSend(sender, "ZO" .. PROTO .. ":" .. self:KindList())
        end
        return
    end
    local ks = msg:match("^ZO" .. PROTO .. ":(%l*)$")
    if ks then
        local who = base(sender)
        if self.known[who] or self.knownN < KNOWN_MAX then
            if not self.known[who] then self.knownN = self.knownN + 1 end
            self.known[who] = ks
        end
        return
    end

    local body = msg:match("^ZH" .. PROTO .. ":(.+)$")
    if body then
        -- a player's round is one or two of these: more from one sender, or a queue already a third
        -- full, isn't answered (one sender could otherwise queue asks faster than we can send them)
        if not window(self.haves, sender, now, HAVE_PER_SENDER) or #self.queue > QUEUE_MAX / 3 then
            self.stats.busy = (self.stats.busy or 0) + 1
            return
        end
        local asked = 0
        for item in body:gmatch("[^;]+") do
            local kind, piece, dg = item:match("^(%l)([%w%-]+)=(%x%x%x%x%x%x)$")
            if kind and live(self.kinds[kind]) and validPiece(piece) and asked < WANT_PER_HAVE then
                if self:digest(kind, piece).piece ~= dg then
                    asked = asked + 1
                    self:want(sender, kind, piece, "0", dg)
                end
            end
        end
        return
    end

    local flag, kind, piece, theirs = msg:match("^ZW" .. PROTO .. "([01]):(%l)([%w%-]+):(" .. ("%x"):rep(BUCKETS * 4) .. ")$")
    if flag then
        if not live(self.kinds[kind]) or not validPiece(piece) then return end
        if not window(self.answers, sender, now, ANSWER_MAX) then self.stats.dropped = self.stats.dropped + 1 return end
        -- half a queue already waiting: answering more would only overflow it (they'll ask someone else)
        if #self.queue > QUEUE_MAX / 2 then self.stats.busy = (self.stats.busy or 0) + 1 return end
        local differs = self:giveFor(sender, kind, piece, theirs)
        -- the first ask also gets ours asked back, so what they have and we lack comes too
        if differs and flag == "0" then self:want(sender, kind, piece, "1") end
        return
    end

    local gk, gp, entries = msg:match("^ZG" .. PROTO .. ":(%l)([%w%-]+):(.+)$")
    if gk then
        if not live(self.kinds[gk]) or not validPiece(gp) then return end
        local n = 0
        for e in entries:gmatch("[^~]+") do
            n = n + 1
            if n > 40 then break end
            local k, v = e:match("^([^%^]+)%^([^%^]+)$")
            if k then self:take(gk, gp, k, v, holder) end
        end
    end
end

function Net:Stats() return self.stats end

-- the kinds this player's addons carry, e.g. "fmoqs" (the ZO answer)
function Net:KindList()
    local t = {}
    for k, spec in pairs(self.kinds) do if live(spec) then t[#t + 1] = k end end
    table.sort(t)
    return table.concat(t)
end

----------------------------------------------------------------------
-- Old clients (stage 6, 2026-11-15). Before the swarm each addon shared by its own whispers
-- (VoidQuest N/Q/B/M/F, VoidSweep N/Q/B). New clients keep sending those for players who haven't
-- updated, and stop once nobody needs them (the user: "after a certain period of time, say 30 days
-- of no one using the old channel and data paths, it will be removed completely").
--   - an old-format message from a player we don't know yet -> one ZP; a new client answers
--     ZO:<its kinds>. No answer within PROBE_WAIT, or one without the path's kind = an old client on
--     that path. Every mistake here (a lost probe, an offline player) only keeps old formats going
--     longer, never stops them early.
--   - the last day an old client was heard spreads over the swarm itself (kind "o", piece = path,
--     newest wins), so everyone goes by the whole network, not just by who happened to whisper them
--   - old formats go out until OLD_DAYS after the later of that day and the day this version first
--     ran here; an old client heard again turns them back on
-- Without a swarm host nothing is known, and old formats always go out.
--   local lg = VoidSwarm.Legacy("vq", "q", VoidQuestDB.legacy)   path, the kind new clients carry, saved table
--   lg:Heard(sender, "N")     every old-format message taken in
--   lg:Sending()              may old formats go out?
--   lg:Status()               for the addon's status line
----------------------------------------------------------------------
local function today() return math.floor(epoch() / 86400) end
S.Today, S.OLD_DAYS, S.PROBE_WAIT = today, OLD_DAYS, PROBE_WAIT

local Legacy = {}
Legacy.__index = Legacy
S.legacies = {}

local function validOld(piece, key, value)
    local d = tonumber(value)
    return key == "old" and piece:match("^%l%l?%l?$") ~= nil and value:match("^%d+$") ~= nil
        and d <= today() + 1 and d >= today() - 400
end

function S.Legacy(path, kind, db)
    if S.legacies[path] then return S.legacies[path] end
    db = type(db) == "table" and db or {}
    db.since = db.since or today()
    db.tags = db.tags or {}
    local lg = setmetatable({ path = path, kind = kind, db = db, pending = {}, pendingN = 0 }, Legacy)
    S.legacies[path] = lg
    if not S.oKind then   -- one "o" kind for every path (its store lives in the first path's saved table)
        S.oKind = true
        db.swarm = db.swarm or {}
        S.Want("o", { need = 1, newest = true, store = db.swarm, maxPieces = 10, maxKeys = 2, valid = validOld })
    end
    if S.net then lg:attach(S.net) end
    return lg
end

function Legacy:attach(net)
    self.net = net
    net.legacy[self.path] = self
end

-- an old-format message from `sender`; tag = its letter (kept per tag for the status line)
function Legacy:Heard(sender, tag)
    local net = self.net
    local who = base(sender)
    if not (net and who) or who == base(net.io.me()) then return end
    local ks = net.known[who]
    if ks then
        if not ks:find(self.kind, 1, true) then self:old(tag, who) end
        return
    end
    if self.pending[who] or self.pendingN >= PENDING_MAX then return end
    local now = net.io.now()
    self.pending[who] = { t = now, tag = tag }
    self.pendingN = self.pendingN + 1
    if not net.probed[who] or now - net.probed[who] > PROBE_AGAIN then
        net.probed[who] = now
        net:queueSend(who, "ZP" .. PROTO)
    end
end

function Legacy:check(now)
    if self.pendingN == 0 then return end
    local known = self.net.known
    for who, p in pairs(self.pending) do
        local ks = known[who]
        if ks or now - p.t >= PROBE_WAIT then
            self.pending[who] = nil
            self.pendingN = self.pendingN - 1
            if not (ks and ks:find(self.kind, 1, true)) then self:old(p.tag, who) end
        end
    end
end

-- who: the player, kept for this session only (never saved) so /vq net can say who to ask to update
function Legacy:old(tag, who)
    self.lastWho = who
    local d = today()
    self.db.old = d
    if type(tag) == "string" and tag:match("^%u$") then self.db.tags[tag] = d end
    local net = self.net
    if net and net.kinds.o then net:Report("o", self.path, "old", tostring(d)) end
end

-- the last day an old client was heard, here or anywhere in the swarm (nil = never)
function Legacy:Last()
    local last = self.db.old
    local net = self.net
    local sw = net and net.kinds.o and tonumber((net:Get("o", self.path, "old")))
    if sw and (not last or sw > last) then last = sw end
    return last
end

function Legacy:Sending()
    if not self.net then return true end
    return today() - math.max(self:Last() or 0, self.db.since or today()) < OLD_DAYS
end

-- { since, last, ownLast, sending, daysLeft, tags, pending } (days are day numbers: epoch / 86400)
function Legacy:Status()
    local last = self:Last()
    local from = math.max(last or 0, self.db.since or today())
    return { since = self.db.since, last = last, ownLast = self.db.old, sending = self:Sending(),
        daysLeft = math.max(0, OLD_DAYS - (today() - from)), tags = self.db.tags, pending = self.pendingN,
        hosted = self.net ~= nil }
end

-- one plain line for a status command
function Legacy:Line()
    local s = self:Status()
    if not s.hosted then return "Players on older versions: not known (no swarm connection yet), so the old messages still go out." end
    local d = today()
    local heard
    if not s.last then heard = "none heard yet"
    elseif d - s.last <= 0 then heard = "last heard today" .. (self.lastWho and (" (" .. self.lastWho .. ")") or "")
    else heard = ("last heard %d day%s ago"):format(d - s.last, d - s.last == 1 and "" or "s") end
    local what = s.sending
        and ("the old messages still go out for them (stop in %d day%s if none is heard)"):format(s.daysLeft, s.daysLeft == 1 and "" or "s")
        or ("the old messages have stopped (none for %d days; they start again if one shows up)"):format(OLD_DAYS)
    return ("Players on older versions: %s; %s."):format(heard, what)
end

----------------------------------------------------------------------
-- In the game: one network for all Void addons. The addon that can send (VoidQuest, with its
-- member list and whisper queue) calls VoidSwarm.Host(io); any addon calls VoidSwarm.Want(kind,
-- spec) for its data, before or after (load order doesn't matter). Without a host the data still
-- works on this PC alone (S.local: Report / Get / Hint, nothing sent).
----------------------------------------------------------------------
S.pending = {}
function S.Want(kind, spec)
    if S.net then S.net:Register(kind, spec) return S.net end
    S.pending[kind] = spec
    if not S.solo then
        S.solo = S.New({ now = function() return (GetTime and GetTime()) or 0 end, me = function() return "" end,
            members = function() return {} end, send = function() end })
    end
    S.solo:Register(kind, spec)
    return S.solo
end
function S.Host(io)
    if S.net then return S.net end
    S.net = S.New(io)
    for kind, spec in pairs(S.pending) do S.net:Register(kind, spec) end
    for _, lg in pairs(S.legacies) do lg:attach(S.net) end
    return S.net
end
-- the network to use right now (the hosted one, else this PC alone)
function S.Get() return S.net or S.solo end
