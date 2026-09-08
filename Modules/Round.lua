-- Modules/Round.lua
--
-- The host side of a round (spec 002): opening, validating submissions, keeping
-- every client in sync, closing and aborting.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the
-- `round` suite; the file creates no frame and calls no WoW API while loading.
-- The host is whoever holds master looter, re-derived on the loot-method and
-- roster events (spec 000 section 5).

local ADDON, ns = ...

ns.Round = {}
local Round = ns.Round

local C = ns.Constants
local Util = ns.Util
local Tiers = ns.Tiers
local Serialize = ns.Serialize

local function key(name)
    return type(name) == "string" and name:lower() or nil
end

--------------------------------------------------------------------------------
-- Pure: constructing a round (section 2)
--------------------------------------------------------------------------------

--- "<hostName>-<timestamp>": globally unique and readable in a log.
function Round.NewId(host, timestamp)
    return tostring(host) .. "-" .. tostring(math.floor(timestamp or 0))
end

--- Build the host-side round table. `items` are the 004 candidates; `lootSlot`
-- is kept here and never transmitted, because it goes stale on the client.
function Round.New(id, host, tierCount, endsAt, items)
    local round = {
        id = id, host = host, tierCount = tierCount, endsAt = endsAt,
        items = {}, entries = {}, submitted = {},
        state = C.ROUND_STATE.OPEN,
    }
    for i = 1, #items do
        local item = items[i]
        round.items[i] = {
            idx = item.idx or i,
            itemString = item.itemString,
            count = item.count or 1,
            lootSlot = item.lootSlot,
            -- Every slot this item occupies. Two loot slots of one drop collapse into one
            -- round item (spec 004 section 2) and the award step needs both of them.
            lootSlots = item.lootSlots,
            slotQuantities = item.slotQuantities,
            info = item.info,
        }
        round.entries[round.items[i].idx] = {}
    end
    return round
end

function Round.ItemByIdx(round, itemIdx)
    for i = 1, #round.items do
        if round.items[i].idx == itemIdx then return round.items[i] end
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
function Round.Validate(round, sender, entries, ctx)
    local accepted, rejected = {}, {}
    local seen = {}

    local roster = ctx.rosterOf and ctx.rosterOf(sender) or nil
    local order = roster and roster.order or {}
    local chars = roster and roster.chars or {}

    for i = 1, #entries do
        local e = entries[i]
        local reason

        local item = Round.ItemByIdx(round, e.itemIdx)
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
function Round.Apply(round, sender, accepted, now)
    local senderKey = key(sender)

    for _, list in pairs(round.entries) do
        for i = #list, 1, -1 do
            if key(list[i].owner) == senderKey then table.remove(list, i) end
        end
    end

    local record = round.submitted[sender]
    if record then
        record.revisedAt = now
    else
        record = { submittedAt = now }
        round.submitted[sender] = record
    end
    record.count = #accepted

    for i = 1, #accepted do
        local e = accepted[i]
        local list = round.entries[e.itemIdx]
        list[#list + 1] = {
            char = e.char, owner = e.owner, tier = e.tier,
            override = e.override, star = e.star,
            submittedAt = record.submittedAt, revisedAt = record.revisedAt,
        }
    end

    return round
end

--------------------------------------------------------------------------------
-- Pure: the STATE aggregate (section 7)
--------------------------------------------------------------------------------

function Round.SubmittedNames(round)
    local names = {}
    for name in pairs(round.submitted) do names[#names + 1] = name end
    table.sort(names)
    return names
end

--- Every accepted entry, in item order then submission order, for the wire.
function Round.StateEntries(round)
    local out = {}
    for i = 1, #round.items do
        local idx = round.items[i].idx
        for _, e in ipairs(round.entries[idx] or {}) do
            out[#out + 1] = { itemIdx = idx, char = e.char, owner = e.owner, tier = e.tier }
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Pure: resolution input and output (section 8)
--------------------------------------------------------------------------------

--- The entries map Core/Resolve.round expects, keyed by item index.
function Round.ResolveInput(round)
    local byItem = {}
    for i = 1, #round.items do
        local idx = round.items[i].idx
        local list = {}
        for _, e in ipairs(round.entries[idx] or {}) do
            list[#list + 1] = { char = e.char, owner = e.owner, tier = e.tier,
                                override = e.override }
        end
        byItem[idx] = list
    end
    return byItem
end

--- Which item each character starred, for spec 010 section 7. One per character;
-- the last star in item order wins, which is what the roll window's radio enforces.
function Round.Stars(round)
    local stars = {}
    for i = 1, #round.items do
        local idx = round.items[i].idx
        for _, e in ipairs(round.entries[idx] or {}) do
            if e.star then stars[e.char] = idx end
        end
    end
    return stars
end

--- RESULT rows: one per awarded copy, one UNCLAIMED row for an item nobody took.
function Round.ResultRows(results)
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
function Round.EntryCounts(round)
    local out = {}
    for i = 1, #round.items do
        local idx = round.items[i].idx
        out[i] = { idx = idx, count = #(round.entries[idx] or {}) }
    end
    return out
end

--- ROLLS rows: the complete record behind the table, entries that never rolled
-- included. An entry that vanished from the results is indistinguishable from a bug.
function Round.RollRows(results)
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

Round.current = nil        -- the open round, host side only
Round.peers = {}           -- player -> addon version, from HI (section 11)

local listeners = {}
local frame
local stateDirty, stateTimer = false, 0
local lastHost                            -- for detecting a master-looter change
local lastHi = 0                          -- HI is cheap, but roster events are not rare

function Round.RegisterListener(fn)
    listeners[#listeners + 1] = fn
end

local function fireChanged()
    for _, fn in ipairs(listeners) do fn(Round.current) end
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
function Round.HostName()
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

function Round.IsHost()
    local host = Round.HostName()
    local me = UnitName("player")
    return host ~= nil and me ~= nil and host:lower() == me:lower()
end

--- Is `sender` the client that is allowed to drive a round right now?
function Round.IsAuthoritative(sender)
    local host = Round.HostName()
    return host ~= nil and sender ~= nil and host:lower() == sender:lower()
end

--------------------------------------------------------------------------------
-- Opening (section 4)
--------------------------------------------------------------------------------

local function buildContext(round)
    local Roster = ns.Roster
    local filterEnabled = ns.Database.Settings().eligibilityFilter

    return {
        tierCount = round.tierCount,
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

--- Open a round over `items` (spec 004 supplies them).
-- @return true, or false plus a reason the host can show
function Round.Open(items)
    if not Round.IsHost() then
        return false, "you are not the master looter."
    end
    if Round.current and Round.current.state == C.ROUND_STATE.OPEN then
        return false, "a round is already open. Close or cancel it first."
    end
    if not items or #items == 0 then
        return false, "there is nothing in this loot worth rolling for."
    end

    local host = ns.Database.Host()
    local tierCount = Util.clamp(host.tierCount or 3, C.MIN_TIER_COUNT, C.MAX_TIER_COUNT)
    local seconds = Util.clamp(host.timerSeconds or 180,
        C.MIN_TIMER_SECONDS, C.MAX_TIMER_SECONDS)

    local me = UnitName("player")
    local round = Round.New(Round.NewId(me, time()), me, tierCount,
        GetTime() + seconds, items)
    round.openedAt = time()
    round.openedAtLocal = GetTime()      -- GetTime for elapsed, time() for history

    -- The loot mode and the priority list are frozen here, not at close (spec 010
    -- section 7): a round resolves against the list as it stood when it opened.
    round.lootMode, round.priority = Round.LootModeNow()
    round.priorityAtOpen = Util.deepCopy(ns.Database.Priority())
    if items[1].lootSlot then
        round.source = ns.LootDetect.sourceName      -- nil when no dead target (spec 008)
    else
        round.source = "Item link"
    end
    Round.current = round
    if ns.Award then ns.Award.Snapshot(round) end     -- spec 007: what the host already had

    local body, err = Serialize.encodeOpen(round.id, tierCount, seconds, round.items,
        round.lootMode)
    if not body then
        Round.current = nil
        return false, "this loot could not be encoded (" .. tostring(err) .. ")."
    end
    ns.Comms.Send(C.OPS.OPEN, body)
    -- The list follows OPEN, never inside it (spec 010 section 8).
    if round.lootMode == C.LOOT_MODE.SK and ns.Priority then ns.Priority.Broadcast() end

    local labels = {}
    for i, item in ipairs(round.items) do
        labels[i] = labelOf(item) .. (item.count > 1 and (" x" .. item.count) or "")
    end
    say("OPEN", { labels = labels, seconds = seconds })
    fireChanged()
    return true
end

--- Add time to the open round (spec 006 section 3, "Extend"). Clients learn the new
-- deadline from a same-id OPEN carrying the seconds left.
function Round.Extend(seconds)
    local round = Round.current
    if not round or round.state ~= C.ROUND_STATE.OPEN then
        return false, "there is no round open."
    end
    if not Round.IsHost() then return false, "you are not the master looter." end

    seconds = seconds or C.EXTEND_SECONDS
    local endsAt = round.endsAt + seconds
    local secondsLeft = math.max(0, endsAt - GetTime())
    local body, err = Serialize.encodeOpen(round.id, round.tierCount, secondsLeft,
        round.items, round.lootMode)
    if not body then
        -- Extending locally while the clients keep the old deadline would close their
        -- windows under an open round. Refuse, loudly.
        return false, "the extension could not be encoded (" .. tostring(err) .. "); "
            .. "the deadline is unchanged."
    end
    round.endsAt = endsAt
    ns.Comms.Send(C.OPS.OPEN, body)
    say("EXTEND", { seconds = seconds, left = secondsLeft })
    fireChanged()
    return true
end

--------------------------------------------------------------------------------
-- Losing loot under an open round (spec 004 section 3)
--------------------------------------------------------------------------------

--- Remove the copies sitting in `goneSlots` from the open round.
--
-- Called by LootDetect when a loot slot is emptied by someone other than our own award.
-- A round that loses every item aborts as LOOT_GONE; a round that loses some carries on
-- with the survivors and says what went (spec 004 section 3). Nothing is dropped quietly.
--
-- @param goneSlots set of loot slot -> true
-- @return true when the round changed
function Round.DropSlots(goneSlots)
    local round = Round.current
    if not round or round.state ~= C.ROUND_STATE.OPEN then return false end
    if not Round.IsHost() then return false end

    local kept, lost = ns.LootDetect.Prune(round.items,
        function(slot) return goneSlots[slot] == true end)
    if #lost == 0 then return false end

    round.items = kept

    -- A round that lost everything at once gets one abort message, not one line per item
    -- followed by the abort. The entries are dropped either way.
    if #kept == 0 then
        for _, entry in ipairs(lost) do
            round.entries[entry.item.idx] = nil
        end
        Round.Abort(C.ABORT_REASON.LOOT_GONE)
        return true
    end

    for _, entry in ipairs(lost) do
        local label = labelOf(entry.item)
        if Round.ItemByIdx(round, entry.item.idx) then
            say("LOOT_LOST", { label = label, count = entry.quantity or #entry.slots,
                               remaining = true })
        else
            round.entries[entry.item.idx] = nil
            say("LOOT_LOST", { label = label, remaining = false })
        end
    end

    -- Clients replace their item list on a same-id OPEN (spec 002 section 3), so the
    -- shrunken round reaches them the same way the original did.
    local secondsLeft = math.max(0, round.endsAt - GetTime())
    local body = Serialize.encodeOpen(round.id, round.tierCount, secondsLeft, round.items,
        round.lootMode)
    if body then ns.Comms.Send(C.OPS.OPEN, body) end
    stateDirty = true
    fireChanged()
    return true
end

--------------------------------------------------------------------------------
-- Submissions (sections 5 to 7)
--------------------------------------------------------------------------------

local function broadcastState()
    local round = Round.current
    if not round then return end
    local body, err = Serialize.encodeState(round.id,
        Round.SubmittedNames(round), Round.StateEntries(round))
    if not body then
        ns.Print("the round state could not be encoded (" .. tostring(err)
            .. "); ask everyone to resubmit.")
        return
    end
    ns.Comms.Send(C.OPS.STATE, body)
end

local function expectedPlayers()
    -- Raid members running a compatible version, i.e. who have sent HI this
    -- round. Players without the addon never block a close (section 8).
    local expected = {}
    for _, member in ipairs(ns.Roster.GroupMembers()) do
        if Round.peers[member.name] then expected[#expected + 1] = member.name end
    end
    return expected
end

local function allExpectedIn(round)
    local expected = expectedPlayers()
    if #expected == 0 then return false end
    for _, name in ipairs(expected) do
        if not round.submitted[name] then return false end
    end
    return true
end

--- Close early once every expected player is in, if the host asked for that.
-- Two things can make it true: the last expected submission arriving, and the
-- last player who had not submitted leaving the group.
local function maybeAutoClose(round)
    if round.state ~= C.ROUND_STATE.OPEN then return end
    if not ns.Database.Host().autoClose then return end
    if not allExpectedIn(round) then return end
    Round.Close()
end

local function onSubmit(sender, body)
    local round = Round.current
    if not Round.IsHost() then return end
    if not round then return end

    local msg, why = Serialize.decodeSubmit(body)
    if not msg then
        ns.Debug("unreadable SUBMIT from " .. tostring(sender) .. ": " .. tostring(why))
        return
    end
    -- A stale client, or one whose timer has not caught up: drop it whole. There is
    -- nothing useful to merge from a round that is no longer the round.
    if msg.roundId ~= round.id then return end
    if round.state ~= C.ROUND_STATE.OPEN then return end

    local accepted, rejected = Round.Validate(round, sender, msg.entries,
        buildContext(round))
    Round.Apply(round, sender, accepted, time())

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

    maybeAutoClose(round)
end

local function onSync(sender, body)
    if not Round.IsHost() then return end
    local round = Round.current
    if not round or round.state ~= C.ROUND_STATE.OPEN then return end

    local secondsLeft = math.max(0, round.endsAt - GetTime())
    local body2 = Serialize.encodeOpen(round.id, round.tierCount, secondsLeft,
        round.items, round.lootMode)
    if body2 then ns.Comms.Send(C.OPS.OPEN, body2) end
    -- SYNC resends OPEN, SKLIST and STATE (spec 010 section 8).
    if round.lootMode == C.LOOT_MODE.SK and ns.Priority then ns.Priority.Broadcast() end
    broadcastState()
    ns.Debug("resent the round to " .. tostring(sender))
end

local function onHi(sender, body)
    Round.peers[sender] = body
end

--------------------------------------------------------------------------------
-- Closing (section 8)
--------------------------------------------------------------------------------

--- The rng Resolve draws from. A field, so /rls simulate can script it (spec 009).
function Round.rng(low, high)
    return math.random(low, high)
end

--- The loot mode a round opened now would resolve under, and the name -> index map
-- of the priority list. SK needs a seeded list; without one this reads ROLL.
function Round.LootModeNow()
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
function Round.Close()
    local round = Round.current
    if not round or round.state ~= C.ROUND_STATE.OPEN then return false end
    if not Round.IsHost() then return false end

    round.state = C.ROUND_STATE.RESOLVING
    fireChanged()

    local lootMode, priority = round.lootMode or C.LOOT_MODE.ROLL, round.priority
    local ok, results = pcall(ns.Resolve.round, round.items, Round.ResolveInput(round),
        { rng = function(lo, hi) return Round.rng(lo, hi) end,
          lootMode = lootMode, priority = priority,
          stars = Round.Stars(round) })

    if not ok then
        -- Resolving on corrupt input is worse than not resolving (spec 003 section 3).
        ns.Print("the round could not be resolved: " .. tostring(results)
            .. ". It has been cancelled; nothing was awarded.")
        round.state = C.ROUND_STATE.OPEN      -- so Abort has something to abort
        Round.Abort(C.ABORT_REASON.RESOLVE_FAILED)
        return false
    end

    round.results = results
    round.closedAt = time()

    local resultBody = Serialize.encodeResult(round.id, Round.ResultRows(results))
    local rollBody = Serialize.encodeRolls(round.id, Round.RollRows(results))
    if resultBody then ns.Comms.Send(C.OPS.RESULT, resultBody) end
    if rollBody then ns.Comms.Send(C.OPS.ROLLS, rollBody) end

    round.state = C.ROUND_STATE.CLOSED

    if ns.Announce then
        local labelled = {}
        for i, item in ipairs(round.items) do
            labelled[i] = { idx = item.idx, itemString = item.itemString, label = labelOf(item) }
        end
        ns.Announce.SayAll(ns.Announce.RoundLines(labelled, results, {
            verbosity = ns.Database.Settings().verbosity,
            isSK = (lootMode == C.LOOT_MODE.SK),
            tierCount = round.tierCount,
        }))
    end

    -- Award records first, then the suicides they earn (spec 010 section 7), so the
    -- history record written last carries the prior indices.
    if ns.Award then ns.Award.Begin(round) end
    if ns.Priority then ns.Priority.ApplyAwards(round) end
    if ns.History then ns.History.Record(round) end
    -- These items have been rolled for; they stop being candidates for the next
    -- round (spec 006 section 3). Abort does not do this, so a retry still has them.
    if ns.LootDetect then ns.LootDetect.Consume(round.items) end

    fireChanged()
    return true
end

--------------------------------------------------------------------------------
-- Aborting (section 9)
--------------------------------------------------------------------------------

--- Cancel the open round. Aborted rounds are never migrated to a new host.
function Round.Abort(reason)
    local round = Round.current
    if not round or round.state ~= C.ROUND_STATE.OPEN then return false end

    round.state = C.ROUND_STATE.ABORTED
    round.abortReason = reason
    round.closedAt = time()

    -- A host that has just lost master looter is no longer authoritative, and every
    -- client hard-rejects ops from a non-ML sender (spec 000 section 5). So an
    -- ML_CHANGED abort is not broadcast at all: each client sees the same loot-method
    -- event and ends its own mirror (Client.lua), which needs no message to arrive.
    if reason ~= C.ABORT_REASON.ML_CHANGED and Round.IsHost() then
        ns.Comms.Send(C.OPS.ABORT, Serialize.encodeAbort(round.id, reason))
    end
    if Round.IsHost() then
        say("ABORT", { reason = reason, reasonText = C.ABORT_TEXT[reason] })
    end

    if ns.History then ns.History.Record(round) end
    fireChanged()
    return true
end

--------------------------------------------------------------------------------
-- Settings broadcast (section 4)
--------------------------------------------------------------------------------

--- Tier count is frozen at open, so this is refused mid-round rather than applied.
-- @return true, or false plus a reason
function Round.BroadcastConfig()
    if not Round.IsHost() then return false, "you are not the master looter." end
    if Round.current and Round.current.state == C.ROUND_STATE.OPEN then
        return false, "settings are frozen while a round is open; "
            .. "your change applies to the next one."
    end
    local host = ns.Database.Host()
    ns.Comms.Send(C.OPS.CFG,
        Serialize.encodeConfig(host.tierCount, host.timerSeconds, host.lootMode))
    return true
end

--- Change one host setting from the host panel (spec 006 section 3). Tier count,
-- timer and loot mode are frozen while a round is open, are broadcast as CFG, and are
-- announced: they change the rules everyone is playing by. The rest are local.
-- @return true, or false plus a reason
function Round.ChangeSetting(key, value)
    local host = ns.Database.Host()
    local settings = ns.Database.Settings()
    local shared = (key == "tierCount" or key == "timerSeconds" or key == "lootMode")

    if shared and Round.current and Round.current.state == C.ROUND_STATE.OPEN then
        return false, "frozen while a round is open; the change applies to the next one."
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
    if shared and Round.IsHost() then
        Round.BroadcastConfig()
        say(kind, { tierCount = value, seconds = value, lootMode = value })
    end
    if ns.HierarchyEditor then ns.HierarchyEditor.Refresh() end
    fireChanged()
    return true
end

--- Raid members running the addon who have not submitted, for the host panel.
function Round.OutstandingPlayers()
    local round = Round.current
    local out = {}
    if not round then return out end
    for _, name in ipairs(expectedPlayers()) do
        if not round.submitted[name] then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

--------------------------------------------------------------------------------
-- The pump: the round timer, coalesced STATE, and the expiry guard
--------------------------------------------------------------------------------

local function onUpdate(_, elapsed)
    if stateDirty then
        stateTimer = stateTimer + elapsed
        if stateTimer >= C.STATE_COALESCE then
            stateDirty, stateTimer = false, 0
            broadcastState()
        end
    end

    local round = Round.current
    if not round or round.state ~= C.ROUND_STATE.OPEN then return end
    if not Round.IsHost() then return end

    local now = GetTime()
    if now >= round.endsAt then
        if stateDirty then                 -- do not resolve on a state nobody has seen
            stateDirty, stateTimer = false, 0
            broadcastState()
        end
        Round.Close()
    elseif now - (round.openedAtLocal or now) > C.ROUND_EXPIRY then
        Round.Abort(C.ABORT_REASON.EXPIRED)
    end
end

--------------------------------------------------------------------------------
-- Events: the master looter changing under an open round
--------------------------------------------------------------------------------

--- Re-derive the host. Public so /rls simulate can change hands without an event.
function Round.CheckHost()
    local host = Round.HostName()
    if host ~= lastHost then
        lastHost = host
        local round = Round.current
        if round and round.state == C.ROUND_STATE.OPEN then
            -- Whoever was hosting can no longer speak for this round, and the new
            -- master looter never received its entries. It ends here (section 9).
            Round.Abort(C.ABORT_REASON.ML_CHANGED)
        end
    end
end

local function onGroupEvent()
    Round.CheckHost()

    -- Someone leaving can be what completes the set: they were expected and had
    -- not submitted, and now nobody outstanding is left to wait for.
    local round = Round.current
    if round and Round.IsHost() then maybeAutoClose(round) end

    -- Version handshake (section 11), throttled: roster events arrive in bursts.
    local now = GetTime()
    if now - lastHi > 5 then
        lastHi = now
        ns.Comms.Send(C.OPS.HI, C.VERSION)
    end
end

function Round.Init()
    if frame then return end

    ns.Comms.RegisterHandler(C.OPS.SUBMIT, onSubmit)
    ns.Comms.RegisterHandler(C.OPS.SYNC, onSync)
    ns.Comms.RegisterHandler(C.OPS.HI, onHi)

    frame = CreateFrame("Frame", "RaidLootSystemRoundFrame")
    frame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
    frame:RegisterEvent("RAID_ROSTER_UPDATE")
    frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
    frame:SetScript("OnEvent", onGroupEvent)
    frame:SetScript("OnUpdate", onUpdate)

    lastHost = Round.HostName()
end
