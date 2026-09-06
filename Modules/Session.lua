-- Modules/Session.lua
--
-- The host side of a batch (spec 002): opening, validating submissions, keeping
-- every client in sync, closing and aborting.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the
-- `session` suite; the file creates no frame and calls no WoW API while loading.
-- The host is whoever holds master looter, re-derived on the loot-method and
-- roster events (spec 000 section 5).

local ADDON, ns = ...

ns.Session = {}
local Session = ns.Session

local C = ns.Constants
local Util = ns.Util
local Tiers = ns.Tiers
local Serialize = ns.Serialize

local function key(name)
    return type(name) == "string" and name:lower() or nil
end

--------------------------------------------------------------------------------
-- Pure: constructing a batch (section 2)
--------------------------------------------------------------------------------

--- "<hostName>-<timestamp>": globally unique and readable in a log.
function Session.NewId(host, timestamp)
    return tostring(host) .. "-" .. tostring(math.floor(timestamp or 0))
end

--- Build the host-side session table. `items` are the 004 candidates; `lootSlot`
-- is kept here and never transmitted, because it goes stale on the client.
function Session.New(id, host, tierCount, endsAt, items)
    local session = {
        id = id, host = host, tierCount = tierCount, endsAt = endsAt,
        items = {}, entries = {}, submitted = {},
        state = C.SESSION_STATE.OPEN,
    }
    for i = 1, #items do
        local item = items[i]
        session.items[i] = {
            idx = item.idx or i,
            itemString = item.itemString,
            count = item.count or 1,
            lootSlot = item.lootSlot,
            -- Every slot this item occupies. Two loot slots of one drop collapse into one
            -- batch item (spec 004 section 2) and the award step needs both of them.
            lootSlots = item.lootSlots,
            slotQuantities = item.slotQuantities,
            info = item.info,
        }
        session.entries[session.items[i].idx] = {}
    end
    return session
end

function Session.ItemByIdx(session, itemIdx)
    for i = 1, #session.items do
        if session.items[i].idx == itemIdx then return session.items[i] end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Pure: submission validation (section 5)
--
-- Every check in the section 5 table, in its order. The host computes the tier
-- itself from the sender's published roster and the frozen tier count; a
-- client-supplied tier is never trusted, and is not even on the wire.
--
-- `ctx` injects everything the host knows about the raid, so this stays testable
-- without a raid:
--   ctx.tierCount              frozen at open
--   ctx.rosterOf(sender)       -> { order = {...}, chars = {...} } or nil
--   ctx.isContested(char)      -> boolean
--   ctx.isPresent(char)        -> boolean
--   ctx.eligible(item, char, class, override) -> boolean
--------------------------------------------------------------------------------

--- @return accepted array, rejected array of { itemIdx, char, reason }
function Session.Validate(session, sender, entries, ctx)
    local accepted, rejected = {}, {}
    local seen = {}

    local roster = ctx.rosterOf and ctx.rosterOf(sender) or nil
    local order = roster and roster.order or {}
    local chars = roster and roster.chars or {}

    for i = 1, #entries do
        local e = entries[i]
        local reason

        local item = Session.ItemByIdx(session, e.itemIdx)
        if not item then
            reason = C.REJECT.NO_SUCH_ITEM
        else
            local position = Util.indexOf(order, e.char)
            if not position then
                reason = C.REJECT.NOT_PUBLISHED
            elseif ctx.isContested and ctx.isContested(e.char) then
                reason = C.REJECT.CONTESTED
            elseif ctx.isPresent and not ctx.isPresent(e.char) then
                reason = C.REJECT.NOT_PRESENT
            else
                local stored = order[position]
                local class = chars[stored] and chars[stored].class or nil
                if ctx.eligible and not ctx.eligible(item, stored, class, e.override) then
                    reason = C.REJECT.INELIGIBLE
                else
                    local pair = tostring(e.itemIdx) .. "/" .. tostring(key(e.char))
                    if seen[pair] then
                        reason = C.REJECT.DUPLICATE       -- keep the first, drop the rest
                    else
                        seen[pair] = true
                        accepted[#accepted + 1] = {
                            itemIdx = e.itemIdx,
                            char = stored,
                            owner = sender,
                            tier = Tiers.forPosition(position, ctx.tierCount),
                            override = e.override and true or false,
                            star = e.star and true or false,
                        }
                    end
                end
            end
        end

        if reason then
            rejected[#rejected + 1] = { itemIdx = e.itemIdx, char = e.char, reason = reason }
        end
    end

    return accepted, rejected
end

--- Replace this sender's entries with `accepted` (section 5: submissions are
-- idempotent replacements, never deltas). The tier recorded here is a snapshot:
-- reordering a hierarchy afterwards does not move a pending entry (section 6).
function Session.Apply(session, sender, accepted, now)
    local senderKey = key(sender)

    for _, list in pairs(session.entries) do
        for i = #list, 1, -1 do
            if key(list[i].owner) == senderKey then table.remove(list, i) end
        end
    end

    local record = session.submitted[sender]
    if record then
        record.revisedAt = now
    else
        record = { submittedAt = now }
        session.submitted[sender] = record
    end
    record.count = #accepted

    for i = 1, #accepted do
        local e = accepted[i]
        local list = session.entries[e.itemIdx]
        list[#list + 1] = {
            char = e.char, owner = e.owner, tier = e.tier,
            override = e.override, star = e.star,
            submittedAt = record.submittedAt, revisedAt = record.revisedAt,
        }
    end

    return session
end

--------------------------------------------------------------------------------
-- Pure: the STATE aggregate (section 7)
--------------------------------------------------------------------------------

function Session.SubmittedNames(session)
    local names = {}
    for name in pairs(session.submitted) do names[#names + 1] = name end
    table.sort(names)
    return names
end

--- Every accepted entry, in item order then submission order, for the wire.
function Session.StateEntries(session)
    local out = {}
    for i = 1, #session.items do
        local idx = session.items[i].idx
        for _, e in ipairs(session.entries[idx] or {}) do
            out[#out + 1] = { itemIdx = idx, char = e.char, owner = e.owner, tier = e.tier }
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Pure: resolution input and output (section 8)
--------------------------------------------------------------------------------

--- The entries map Core/Resolve.batch expects, keyed by item index.
function Session.ResolveInput(session)
    local byItem = {}
    for i = 1, #session.items do
        local idx = session.items[i].idx
        local list = {}
        for _, e in ipairs(session.entries[idx] or {}) do
            list[#list + 1] = { char = e.char, owner = e.owner, tier = e.tier,
                                override = e.override }
        end
        byItem[idx] = list
    end
    return byItem
end

--- Which item each character starred, for spec 010 section 7. One per character;
-- the last star in item order wins, which is what the roll window's radio enforces.
function Session.Stars(session)
    local stars = {}
    for i = 1, #session.items do
        local idx = session.items[i].idx
        for _, e in ipairs(session.entries[idx] or {}) do
            if e.star then stars[e.char] = idx end
        end
    end
    return stars
end

--- RESULT rows: one per awarded copy, one UNCLAIMED row for an item nobody took.
function Session.ResultRows(results)
    local rows = {}
    for i = 1, #results do
        local r = results[i]
        if r.unclaimed then
            rows[#rows + 1] = { itemIdx = r.itemIdx, winner = "", tier = 0, roll = 0,
                                outcome = C.OUTCOME.UNCLAIMED }
        else
            for _, award in ipairs(r.awards) do
                rows[#rows + 1] = {
                    itemIdx = r.itemIdx, winner = award.char, tier = award.tier,
                    roll = award.roll or 0,
                    outcome = r.degraded and C.OUTCOME.DEGRADED or C.OUTCOME.WON,
                }
            end
        end
    end
    return rows
end

--- How many entries each item has, in item order. Drives the host panel's per-item
-- counts (spec 006 section 3), so "item 4 has nothing on it" is visible at a glance.
-- @return array of { idx, count }
function Session.EntryCounts(session)
    local out = {}
    for i = 1, #session.items do
        local idx = session.items[i].idx
        out[i] = { idx = idx, count = #(session.entries[idx] or {}) }
    end
    return out
end

--- ROLLS rows: the complete record behind the table, entries that never rolled
-- included. An entry that vanished from the results is indistinguishable from a bug.
function Session.RollRows(results)
    local rows = {}
    for i = 1, #results do
        local r = results[i]
        for _, e in ipairs(r.record or {}) do
            rows[#rows + 1] = {
                itemIdx = r.itemIdx, char = e.char, tier = e.tier,
                roll = e.roll or 0, listIdx = e.listIdx or 0,
                status = C.ROLL_STATUS_OF_REASON[e.reason or ""] or C.ROLL_STATUS.ROLLED,
                rerolled = e.rerolled or {},
            }
        end
    end
    return rows
end

--------------------------------------------------------------------------------
-- WoW-facing state. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

Session.current = nil        -- the open batch, host side only
Session.peers = {}           -- player -> addon version, from HI (section 11)

local listeners = {}
local frame
local stateDirty, stateTimer = false, 0
local lastHost                            -- for detecting a master-looter change
local lastHi = 0                          -- HI is cheap, but roster events are not rare

function Session.RegisterListener(fn)
    listeners[#listeners + 1] = fn
end

local function fireChanged()
    for _, fn in ipairs(listeners) do fn(Session.current) end
end

--- Only the host writes to raid chat (spec 000 section 5). Announce.lua owns the
-- formats and the verbosity levels (spec 006 section 4).
local function say(kind, args)
    if ns.Announce then ns.Announce.Emit(kind, args) end
end

local function labelOf(item)
    return ns.LootDetect.Label(item)
end

--------------------------------------------------------------------------------
-- Who is the host (section 3)
--------------------------------------------------------------------------------

--- The current master looter's name, or nil when the group is not on master loot.
function Session.HostName()
    local method, partyIndex, raidIndex = GetLootMethod()
    if method ~= "master" then return nil end

    if raidIndex and raidIndex > 0 then
        local name = GetRaidRosterInfo(raidIndex)
        return name
    end
    if partyIndex == 0 then return UnitName("player") end
    if partyIndex and partyIndex > 0 then return UnitName("party" .. partyIndex) end
    return nil
end

function Session.IsHost()
    local host = Session.HostName()
    local me = UnitName("player")
    return host ~= nil and me ~= nil and host:lower() == me:lower()
end

--- Is `sender` the client that is allowed to drive a batch right now?
function Session.IsAuthoritative(sender)
    local host = Session.HostName()
    return host ~= nil and sender ~= nil and host:lower() == sender:lower()
end

--------------------------------------------------------------------------------
-- Opening (section 4)
--------------------------------------------------------------------------------

local function buildContext(session)
    local Roster = ns.Roster
    local filterEnabled = ns.Database.Settings().eligibilityFilter

    return {
        tierCount = session.tierCount,
        rosterOf = function(sender) return Roster.published[sender] end,
        isContested = function(char) return Roster.IsContested(char) end,
        isPresent = function(char) return Roster.IsPresent(char) end,
        eligible = function(item, char, class, override)
            -- Without 004's classification there is nothing to judge the item on, so
            -- the entry stands. Presence and contest are checked above regardless.
            if not item.info then return true end
            local ok = ns.Eligibility.check(item.info,
                { name = char, class = class, present = true, contested = false },
                { filterEnabled = filterEnabled, override = override })
            return ok
        end,
    }
end

--- Open a batch over `items` (spec 004 supplies them).
-- @return true, or false plus a reason the host can show
function Session.Open(items)
    if not Session.IsHost() then
        return false, "you are not the master looter."
    end
    if Session.current and Session.current.state == C.SESSION_STATE.OPEN then
        return false, "a batch is already open. Close or cancel it first."
    end
    if not items or #items == 0 then
        return false, "there is nothing in this loot worth rolling for."
    end

    local host = ns.Database.Host()
    local tierCount = Util.clamp(host.tierCount or 3, C.MIN_TIER_COUNT, C.MAX_TIER_COUNT)
    local seconds = Util.clamp(host.timerSeconds or 180,
        C.MIN_TIMER_SECONDS, C.MAX_TIMER_SECONDS)

    local me = UnitName("player")
    local session = Session.New(Session.NewId(me, time()), me, tierCount,
        GetTime() + seconds, items)
    session.openedAt = time()
    session.openedAtLocal = GetTime()      -- GetTime for elapsed, time() for history

    -- The loot mode and the priority list are frozen here, not at close (spec 010
    -- section 7): a batch resolves against the list as it stood when it opened.
    session.lootMode, session.priority = Session.LootModeNow()
    session.priorityAtOpen = Util.deepCopy(ns.Database.Priority())
    if items[1].lootSlot then
        session.source = ns.LootDetect.sourceName      -- nil when no dead target (spec 008)
    else
        session.source = "Item link"
    end
    Session.current = session
    if ns.Award then ns.Award.Snapshot(session) end     -- spec 007: what the host already had

    local body, err = Serialize.encodeOpen(session.id, tierCount, seconds, session.items,
        session.lootMode)
    if not body then
        Session.current = nil
        return false, "this loot could not be encoded (" .. tostring(err) .. ")."
    end
    ns.Comms.Send(C.OPS.OPEN, body)
    -- The list follows OPEN, never inside it (spec 010 section 8).
    if session.lootMode == C.LOOT_MODE.SK and ns.Priority then ns.Priority.Broadcast() end

    local labels = {}
    for i, item in ipairs(session.items) do
        labels[i] = labelOf(item) .. (item.count > 1 and (" x" .. item.count) or "")
    end
    say("OPEN", { labels = labels, seconds = seconds })
    fireChanged()
    return true
end

--- Add time to the open batch (spec 006 section 3, "Extend"). Clients learn the new
-- deadline from a same-id OPEN carrying the seconds left.
function Session.Extend(seconds)
    local session = Session.current
    if not session or session.state ~= C.SESSION_STATE.OPEN then
        return false, "there is no batch open."
    end
    if not Session.IsHost() then return false, "you are not the master looter." end

    seconds = seconds or C.EXTEND_SECONDS
    local endsAt = session.endsAt + seconds
    local secondsLeft = math.max(0, endsAt - GetTime())
    local body, err = Serialize.encodeOpen(session.id, session.tierCount, secondsLeft,
        session.items, session.lootMode)
    if not body then
        -- Extending locally while the clients keep the old deadline would close their
        -- windows under an open batch. Refuse, loudly.
        return false, "the extension could not be encoded (" .. tostring(err) .. "); "
            .. "the deadline is unchanged."
    end
    session.endsAt = endsAt
    ns.Comms.Send(C.OPS.OPEN, body)
    say("EXTEND", { seconds = seconds, left = secondsLeft })
    fireChanged()
    return true
end

--------------------------------------------------------------------------------
-- Losing loot under an open batch (spec 004 section 3)
--------------------------------------------------------------------------------

--- Remove the copies sitting in `goneSlots` from the open batch.
--
-- Called by LootDetect when a loot slot is emptied by someone other than our own award.
-- A batch that loses every item aborts as LOOT_GONE; a batch that loses some carries on
-- with the survivors and says what went (spec 004 section 3). Nothing is dropped quietly.
--
-- @param goneSlots set of loot slot -> true
-- @return true when the batch changed
function Session.DropSlots(goneSlots)
    local session = Session.current
    if not session or session.state ~= C.SESSION_STATE.OPEN then return false end
    if not Session.IsHost() then return false end

    local kept, lost = ns.LootDetect.Prune(session.items,
        function(slot) return goneSlots[slot] == true end)
    if #lost == 0 then return false end

    session.items = kept

    -- A batch that lost everything at once gets one abort message, not one line per item
    -- followed by the abort. The entries are dropped either way.
    if #kept == 0 then
        for _, entry in ipairs(lost) do
            session.entries[entry.item.idx] = nil
        end
        Session.Abort(C.ABORT_REASON.LOOT_GONE)
        return true
    end

    for _, entry in ipairs(lost) do
        local label = labelOf(entry.item)
        if Session.ItemByIdx(session, entry.item.idx) then
            say("LOOT_LOST", { label = label, count = entry.quantity or #entry.slots,
                               remaining = true })
        else
            session.entries[entry.item.idx] = nil
            say("LOOT_LOST", { label = label, remaining = false })
        end
    end

    -- Clients replace their item list on a same-id OPEN (spec 002 section 3), so the
    -- shrunken batch reaches them the same way the original did.
    local secondsLeft = math.max(0, session.endsAt - GetTime())
    local body = Serialize.encodeOpen(session.id, session.tierCount, secondsLeft, session.items,
        session.lootMode)
    if body then ns.Comms.Send(C.OPS.OPEN, body) end
    stateDirty = true
    fireChanged()
    return true
end

--------------------------------------------------------------------------------
-- Submissions (sections 5 to 7)
--------------------------------------------------------------------------------

local function broadcastState()
    local session = Session.current
    if not session then return end
    local body, err = Serialize.encodeState(session.id,
        Session.SubmittedNames(session), Session.StateEntries(session))
    if not body then
        ns.Print("the batch state could not be encoded (" .. tostring(err)
            .. "); ask everyone to resubmit.")
        return
    end
    ns.Comms.Send(C.OPS.STATE, body)
end

local function expectedPlayers()
    -- Raid members running a compatible version, i.e. who have sent HI this
    -- session. Players without the addon never block a close (section 8).
    local expected = {}
    for _, member in ipairs(ns.Roster.GroupMembers()) do
        if Session.peers[member.name] then expected[#expected + 1] = member.name end
    end
    return expected
end

local function allExpectedIn(session)
    local expected = expectedPlayers()
    if #expected == 0 then return false end
    for _, name in ipairs(expected) do
        if not session.submitted[name] then return false end
    end
    return true
end

--- Close early once every expected player is in, if the host asked for that.
-- Two things can make it true: the last expected submission arriving, and the
-- last player who had not submitted leaving the group.
local function maybeAutoClose(session)
    if session.state ~= C.SESSION_STATE.OPEN then return end
    if not ns.Database.Host().autoClose then return end
    if not allExpectedIn(session) then return end
    Session.Close()
end

local function onSubmit(sender, body)
    local session = Session.current
    if not Session.IsHost() then return end
    if not session then return end

    local msg, why = Serialize.decodeSubmit(body)
    if not msg then
        ns.Debug("unreadable SUBMIT from " .. tostring(sender) .. ": " .. tostring(why))
        return
    end
    -- A stale client, or one whose timer has not caught up: drop it whole. There is
    -- nothing useful to merge from a batch that is no longer the batch.
    if msg.sessionId ~= session.id then return end
    if session.state ~= C.SESSION_STATE.OPEN then return end

    local accepted, rejected = Session.Validate(session, sender, msg.entries,
        buildContext(session))
    Session.Apply(session, sender, accepted, time())

    if #rejected > 0 then
        -- The submitting client compares the count it sees in STATE with what it
        -- sent and warns its player; the host logs the detail.
        for _, r in ipairs(rejected) do
            ns.Debug(string.format("rejected %s on item %s from %s: %s",
                tostring(r.char), tostring(r.itemIdx), tostring(sender), r.reason))
        end
    end

    stateDirty = true                      -- coalesced, section 7
    fireChanged()

    maybeAutoClose(session)
end

local function onSync(sender, body)
    if not Session.IsHost() then return end
    local session = Session.current
    if not session or session.state ~= C.SESSION_STATE.OPEN then return end

    local secondsLeft = math.max(0, session.endsAt - GetTime())
    local body2 = Serialize.encodeOpen(session.id, session.tierCount, secondsLeft,
        session.items, session.lootMode)
    if body2 then ns.Comms.Send(C.OPS.OPEN, body2) end
    -- SYNC resends OPEN, SKLIST and STATE (spec 010 section 8).
    if session.lootMode == C.LOOT_MODE.SK and ns.Priority then ns.Priority.Broadcast() end
    broadcastState()
    ns.Debug("resent the batch to " .. tostring(sender))
end

local function onHi(sender, body)
    Session.peers[sender] = body
end

--------------------------------------------------------------------------------
-- Closing (section 8)
--------------------------------------------------------------------------------

--- The rng Resolve draws from. A field, so /rls simulate can script it (spec 009).
function Session.rng(low, high)
    return math.random(low, high)
end

--- The loot mode a batch opened now would resolve under, and the name -> index map
-- of the priority list. SK needs a seeded list; without one this reads ROLL.
function Session.LootModeNow()
    local host = ns.Database.Host()
    local priority = ns.Database.Priority()
    if host.lootMode == C.LOOT_MODE.SK and #priority.order > 0 then
        local map = {}
        for i = 1, #priority.order do map[priority.order[i]] = i end
        return C.LOOT_MODE.SK, map
    end
    return C.LOOT_MODE.ROLL, nil
end

--- Resolve and broadcast. Called by the timer, by the host panel, or by autoClose.
function Session.Close()
    local session = Session.current
    if not session or session.state ~= C.SESSION_STATE.OPEN then return false end
    if not Session.IsHost() then return false end

    session.state = C.SESSION_STATE.RESOLVING
    fireChanged()

    local lootMode, priority = session.lootMode or C.LOOT_MODE.ROLL, session.priority
    local ok, results = pcall(ns.Resolve.batch, session.items, Session.ResolveInput(session),
        { rng = function(lo, hi) return Session.rng(lo, hi) end,
          lootMode = lootMode, priority = priority,
          stars = Session.Stars(session) })

    if not ok then
        -- Resolving on corrupt input is worse than not resolving (spec 003 section 3).
        ns.Print("the batch could not be resolved: " .. tostring(results)
            .. ". It has been cancelled; nothing was awarded.")
        session.state = C.SESSION_STATE.OPEN      -- so Abort has something to abort
        Session.Abort(C.ABORT_REASON.RESOLVE_FAILED)
        return false
    end

    session.results = results
    session.closedAt = time()

    local resultBody = Serialize.encodeResult(session.id, Session.ResultRows(results))
    local rollBody = Serialize.encodeRolls(session.id, Session.RollRows(results))
    if resultBody then ns.Comms.Send(C.OPS.RESULT, resultBody) end
    if rollBody then ns.Comms.Send(C.OPS.ROLLS, rollBody) end

    session.state = C.SESSION_STATE.CLOSED

    if ns.Announce then
        local labelled = {}
        for i, item in ipairs(session.items) do
            labelled[i] = { idx = item.idx, itemString = item.itemString, label = labelOf(item) }
        end
        ns.Announce.SayAll(ns.Announce.BatchLines(labelled, results, {
            verbosity = ns.Database.Settings().verbosity,
            isSK = (lootMode == C.LOOT_MODE.SK),
            tierCount = session.tierCount,
        }))
    end

    -- Award records first, then the suicides they earn (spec 010 section 7), so the
    -- history record written last carries the prior indices.
    if ns.Award then ns.Award.Begin(session) end
    if ns.Priority then ns.Priority.ApplyAwards(session) end
    if ns.History then ns.History.Record(session) end

    fireChanged()
    return true
end

--------------------------------------------------------------------------------
-- Aborting (section 9)
--------------------------------------------------------------------------------

--- Cancel the open batch. Aborted batches are never migrated to a new host.
function Session.Abort(reason)
    local session = Session.current
    if not session or session.state ~= C.SESSION_STATE.OPEN then return false end

    session.state = C.SESSION_STATE.ABORTED
    session.abortReason = reason
    session.closedAt = time()

    -- A host that has just lost master looter is no longer authoritative, and every
    -- client hard-rejects ops from a non-ML sender (spec 000 section 5). So an
    -- ML_CHANGED abort is not broadcast at all: each client sees the same loot-method
    -- event and ends its own mirror (Client.lua), which needs no message to arrive.
    if reason ~= C.ABORT_REASON.ML_CHANGED and Session.IsHost() then
        ns.Comms.Send(C.OPS.ABORT, Serialize.encodeAbort(session.id, reason))
    end
    if Session.IsHost() then
        say("ABORT", { reason = reason, reasonText = C.ABORT_TEXT[reason] })
    end

    if ns.History then ns.History.Record(session) end
    fireChanged()
    return true
end

--------------------------------------------------------------------------------
-- Settings broadcast (section 4)
--------------------------------------------------------------------------------

--- Tier count is frozen at open, so this is refused mid-batch rather than applied.
-- @return true, or false plus a reason
function Session.BroadcastConfig()
    if not Session.IsHost() then return false, "you are not the master looter." end
    if Session.current and Session.current.state == C.SESSION_STATE.OPEN then
        return false, "settings are frozen while a batch is open; "
            .. "your change applies to the next one."
    end
    local host = ns.Database.Host()
    ns.Comms.Send(C.OPS.CFG,
        Serialize.encodeConfig(host.tierCount, host.timerSeconds, host.lootMode))
    return true
end

--- Change one host setting from the host panel (spec 006 section 3). Tier count,
-- timer and loot mode are frozen while a batch is open, are broadcast as CFG, and are
-- announced: they change the rules everyone is playing by. The rest are local.
-- @return true, or false plus a reason
function Session.ChangeSetting(key, value)
    local host = ns.Database.Host()
    local settings = ns.Database.Settings()
    local shared = (key == "tierCount" or key == "timerSeconds" or key == "lootMode")

    if shared and Session.current and Session.current.state == C.SESSION_STATE.OPEN then
        return false, "frozen while a batch is open; the change applies to the next one."
    end

    local kind
    if key == "tierCount" then
        value = Util.clamp(math.floor(tonumber(value) or 3), C.MIN_TIER_COUNT, C.MAX_TIER_COUNT)
        kind = "TIER_COUNT"
    elseif key == "timerSeconds" then
        value = Util.clamp(math.floor(tonumber(value) or 180), C.MIN_TIMER_SECONDS,
            C.MAX_TIMER_SECONDS)
        kind = "TIMER"
    elseif key == "lootMode" then
        if value ~= C.LOOT_MODE.SK then value = C.LOOT_MODE.ROLL end
        if value == C.LOOT_MODE.SK and #ns.Database.Priority().order == 0 then
            return false, "seed the priority list to enable Suicide Kings."
        end
        kind = "LOOT_MODE"
    elseif key == "qualityThreshold" then
        value = tonumber(value)
        if value ~= 3 and value ~= 4 then
            return false, "the quality threshold is 3 (rare) or 4 (epic)."
        end
    elseif key == "autoClose" then
        value = value and true or false
    elseif key == "verbosity" then
        if not C.VERBOSITY[value] then return false, "unknown verbosity: " .. tostring(value) end
        if settings.verbosity ~= value then
            settings.verbosity = value
            fireChanged()
        end
        return true
    else
        return false, "unknown setting: " .. tostring(key)
    end

    if host[key] == value then return true end
    host[key] = value

    if key == "qualityThreshold" and ns.LootDetect.Rescan then ns.LootDetect.Rescan() end
    if shared and Session.IsHost() then
        Session.BroadcastConfig()
        say(kind, { tierCount = value, seconds = value, lootMode = value })
    end
    if ns.HierarchyEditor then ns.HierarchyEditor.Refresh() end
    fireChanged()
    return true
end

--- Raid members running the addon who have not submitted, for the host panel.
function Session.OutstandingPlayers()
    local session = Session.current
    local out = {}
    if not session then return out end
    for _, name in ipairs(expectedPlayers()) do
        if not session.submitted[name] then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

--------------------------------------------------------------------------------
-- The pump: the batch timer, coalesced STATE, and the expiry guard
--------------------------------------------------------------------------------

local function onUpdate(_, elapsed)
    if stateDirty then
        stateTimer = stateTimer + elapsed
        if stateTimer >= C.STATE_COALESCE then
            stateDirty, stateTimer = false, 0
            broadcastState()
        end
    end

    local session = Session.current
    if not session or session.state ~= C.SESSION_STATE.OPEN then return end
    if not Session.IsHost() then return end

    local now = GetTime()
    if now >= session.endsAt then
        if stateDirty then                 -- do not resolve on a state nobody has seen
            stateDirty, stateTimer = false, 0
            broadcastState()
        end
        Session.Close()
    elseif now - (session.openedAtLocal or now) > C.BATCH_EXPIRY then
        Session.Abort(C.ABORT_REASON.EXPIRED)
    end
end

--------------------------------------------------------------------------------
-- Events: the master looter changing under an open batch
--------------------------------------------------------------------------------

--- Re-derive the host. Public so /rls simulate can change hands without an event.
function Session.CheckHost()
    local host = Session.HostName()
    if host ~= lastHost then
        lastHost = host
        local session = Session.current
        if session and session.state == C.SESSION_STATE.OPEN then
            -- Whoever was hosting can no longer speak for this batch, and the new
            -- master looter never received its entries. It ends here (section 9).
            Session.Abort(C.ABORT_REASON.ML_CHANGED)
        end
    end
end

local function onGroupEvent()
    Session.CheckHost()

    -- Someone leaving can be what completes the set: they were expected and had
    -- not submitted, and now nobody outstanding is left to wait for.
    local session = Session.current
    if session and Session.IsHost() then maybeAutoClose(session) end

    -- Version handshake (section 11), throttled: roster events arrive in bursts.
    local now = GetTime()
    if now - lastHi > 5 then
        lastHi = now
        ns.Comms.Send(C.OPS.HI, C.VERSION)
    end
end

function Session.Init()
    if frame then return end

    ns.Comms.RegisterHandler(C.OPS.SUBMIT, onSubmit)
    ns.Comms.RegisterHandler(C.OPS.SYNC, onSync)
    ns.Comms.RegisterHandler(C.OPS.HI, onHi)

    frame = CreateFrame("Frame", "RaidLootSystemSessionFrame")
    frame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
    frame:RegisterEvent("RAID_ROSTER_UPDATE")
    frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
    frame:SetScript("OnEvent", onGroupEvent)
    frame:SetScript("OnUpdate", onUpdate)

    lastHost = Session.HostName()
end
