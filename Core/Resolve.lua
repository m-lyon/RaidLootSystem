-- Core/Resolve.lua
--
-- The resolution algorithm (spec 003). Given the entries for one item, produce the
-- winner or winners and a complete, auditable record of how they were chosen.
--
-- Pure Lua, no WoW API. Randomness is injected as `opts.rng` so the whole engine is
-- fixture-testable outside WoW (spec 009). Nothing here knows what a roster is:
-- entries arrive already validated and eligible (spec 002 section 5).

local ADDON, ns = ...

ns.Resolve = {}
local Resolve = ns.Resolve

--------------------------------------------------------------------------------
-- Preconditions (spec 003 section 3)
--------------------------------------------------------------------------------
-- These raise. In production the host catches, aborts the batch with a visible error
-- and writes the failure to history. Resolving a loot roll on corrupt input is worse
-- than not resolving it.

local function check(ok, message)
    if not ok then error("Resolve: " .. message, 0) end
end

local function validate(item, entries, opts)
    check(type(item) == "table", "item must be a table")
    check(type(entries) == "table", "entries must be a table")
    check(type(opts) == "table", "opts must be a table")
    check(type(opts.rng) == "function", "opts.rng must be a function")

    local count = item.count or 1
    check(type(count) == "number" and count >= 1 and count % 1 == 0,
        "item.count must be an integer >= 1")

    local seen = {}
    for i = 1, #entries do
        local e = entries[i]
        check(type(e) == "table", "entry " .. i .. " is not a table")
        check(type(e.char) == "string" and e.char ~= "", "entry " .. i .. " has no char")
        check(type(e.tier) == "number" and e.tier >= 1 and e.tier % 1 == 0,
            "entry " .. tostring(e.char) .. " has a non-integer tier")
        local key = e.char:lower()
        check(not seen[key], "duplicate entry for " .. e.char
            .. " on item " .. tostring(item.idx))
        seen[key] = true
    end
    return count
end

--------------------------------------------------------------------------------
-- Determinism (spec 003 section 4)
--------------------------------------------------------------------------------
-- Entries are sorted by (tier asc, owner asc, char asc) before anything random
-- happens. That fixes the sequence of rng calls for a given input, which is what lets
-- a fixture assert an exact outcome against a scripted rng. Under SK there is nothing
-- to sequence, but the sort is kept so both modes share one code path.

local function deterministicOrder(a, b)
    if a.tier ~= b.tier then return a.tier < b.tier end
    local ao, bo = a.owner or "", b.owner or ""
    if ao ~= bo then return ao < bo end
    return a.char < b.char
end

--------------------------------------------------------------------------------
-- Boundary ties (spec 003 section 6)
--------------------------------------------------------------------------------
-- A tie only matters when it changes who gets an award: when the tie group contains
-- both position k and position k+1 of the sorted bucket. Ties entirely above the
-- boundary (all win) or entirely below it (none win) are left alone.

--- The contiguous run of equal current rolls straddling the boundary, or nil.
local function boundaryTie(bucket, k)
    local value = bucket[k].cur
    if bucket[k + 1].cur ~= value then return nil end
    local first, last = k, k + 1
    while first > 1 and bucket[first - 1].cur == value do first = first - 1 end
    while last < #bucket and bucket[last + 1].cur == value do last = last + 1 end
    return first, last
end

local function byCurrentRoll(a, b)
    if a.cur ~= b.cur then return a.cur > b.cur end
    return a.ord < b.ord            -- section 4 ordering, as the sort tiebreak only
end

--- Re-roll the straddling tie group until the boundary is unambiguous.
-- The group keeps its own slot range in the bucket: a re-roll decides the order
-- inside the group, it never lets a member overtake an entry that already beat it.
-- @return degraded -- true when maxReroll elapsed and the deterministic order stood in.
local function resolveBoundaryTies(bucket, k, rng, maxReroll, rollMin, rollMax)
    local rounds = 0
    while true do
        local first, last = boundaryTie(bucket, k)
        if not first then return false end

        local group = {}
        for i = first, last do group[#group + 1] = bucket[i] end

        if rounds >= maxReroll then
            -- Guard against a pathological rng, not an expected path. It must be
            -- visible if it ever fires, so the result is marked degraded.
            table.sort(group, function(a, b) return a.ord < b.ord end)
            for i = 1, #group do bucket[first + i - 1] = group[i] end
            return true
        end

        rounds = rounds + 1
        for i = 1, #group do
            local e = group[i]
            local roll = rng(rollMin, rollMax)
            e.rerolled[#e.rerolled + 1] = roll
            e.cur = roll
        end
        table.sort(group, byCurrentRoll)
        for i = 1, #group do bucket[first + i - 1] = group[i] end
    end
end

--------------------------------------------------------------------------------
-- One item (spec 003 section 5)
--------------------------------------------------------------------------------

--- Resolve one item.
-- @param item     { idx, itemString, count }
-- @param entries  { { char, owner, tier, override, withdrawn }, ... }
--                 `withdrawn` is set by Resolve.batch under SK only (spec 010 section 7).
-- @param opts     { rng, tierCount, maxReroll, lootMode, priority, stars }
-- @return result  { itemIdx, unclaimed, degraded, awards, record, tiersConsulted }
function Resolve.item(item, entries, opts)
    local C = ns.Constants
    local count = validate(item, entries, opts)

    local mode = opts.lootMode or C.LOOT_MODE.ROLL
    local isSK = (mode == C.LOOT_MODE.SK)
    local maxReroll = opts.maxReroll or C.MAX_REROLL

    -- Working copies. The caller's entries are never mutated.
    local work = {}
    for i = 1, #entries do
        local e = entries[i]
        local listIdx = 0
        if isSK then
            listIdx = opts.priority and opts.priority[e.char]
            check(type(listIdx) == "number",
                "SK mode: no priority list index for " .. tostring(e.char))
        end
        work[i] = {
            char = e.char, owner = e.owner, tier = e.tier,
            listIdx = listIdx, withdrawn = e.withdrawn and true or false,
            rolled = false, roll = 0, cur = 0, rerolled = {}, reason = nil,
        }
    end
    table.sort(work, deterministicOrder)
    for i = 1, #work do work[i].ord = i end

    -- Buckets, keyed by tier, walked in ascending tier order.
    local buckets, tiers = {}, {}
    for i = 1, #work do
        local e = work[i]
        if e.withdrawn then
            -- Withdrawn under SK rule 1: still recorded, so the results table can say why.
            e.reason = C.NOT_ROLLED.WITHDRAWN
        else
            local tier = e.tier
            if not buckets[tier] then
                buckets[tier] = {}
                tiers[#tiers + 1] = tier
            end
            local b = buckets[tier]
            b[#b + 1] = e
        end
    end
    table.sort(tiers)

    local remaining = count
    local awards, degraded, tiersConsulted = {}, false, 0

    for t = 1, #tiers do
        local bucket = buckets[tiers[t]]

        if remaining == 0 then
            -- A lower tier is never consulted while a higher one can still supply a
            -- winner. Recorded honestly rather than omitted.
            for i = 1, #bucket do bucket[i].reason = C.NOT_ROLLED.NOT_CONSULTED end
        else
            if isSK then
                -- List indices are unique, so this order is total and tie-free.
                table.sort(bucket, function(a, b) return a.listIdx < b.listIdx end)
            else
                for i = 1, #bucket do
                    local e = bucket[i]
                    e.roll = opts.rng(C.ROLL_MIN, C.ROLL_MAX)
                    e.cur = e.roll
                end
                table.sort(bucket, byCurrentRoll)
            end

            local k = remaining
            if k > #bucket then k = #bucket end

            if k < #bucket then
                if isSK then
                    -- Unreachable by construction. Asserted rather than left as dead
                    -- code somebody later "fixes" (spec 003 section 6).
                    check(bucket[k].listIdx ~= bucket[k + 1].listIdx,
                        "SK mode: duplicate list index " .. tostring(bucket[k].listIdx))
                else
                    if resolveBoundaryTies(bucket, k, opts.rng, maxReroll,
                        C.ROLL_MIN, C.ROLL_MAX) then
                        degraded = true
                    end
                end
            end

            for i = 1, #bucket do bucket[i].rolled = true end
            for i = 1, k do
                local e = bucket[i]
                awards[#awards + 1] =
                    { char = e.char, owner = e.owner, tier = e.tier, roll = e.roll }
            end
            remaining = remaining - k
            tiersConsulted = tiersConsulted + 1
        end
    end

    -- The record is emitted in the section 4 order, so identical input gives identical
    -- output regardless of how the buckets were shuffled during resolution.
    local record = {}
    for i = 1, #work do
        local e = work[i]
        record[i] = {
            char = e.char, owner = e.owner, tier = e.tier, listIdx = e.listIdx,
            rolled = e.rolled, roll = e.roll, rerolled = e.rerolled, reason = e.reason,
        }
    end

    return {
        itemIdx = item.idx,
        unclaimed = (#awards == 0),
        degraded = degraded,
        awards = awards,
        record = record,
        tiersConsulted = tiersConsulted,
    }
end

--------------------------------------------------------------------------------
-- A batch (spec 003 section 7, spec 010 section 7)
--------------------------------------------------------------------------------

local function keyOf(name) return name:lower() end

--- Resolve a whole batch.
-- @param items         array of item tables, in loot-slot order
-- @param entriesByItem item.idx -> entries array
-- @param opts          as Resolve.item
-- @return array of results, parallel to `items`
--
-- Under ROLL the items are fully independent -- there is no cross-item interaction of
-- any kind. Under SK they are coupled by two rules (spec 010 section 7):
--   1. a character that wins is withdrawn from the batch's remaining items;
--   2. its starred item decides which one it takes if it would win several.
-- That is computed as a bounded fixed point over the whole batch, not a sequential
-- pass, so loot-slot order does not decide who wins what.
function Resolve.batch(items, entriesByItem, opts)
    local C = ns.Constants
    items = items or {}
    entriesByItem = entriesByItem or {}
    opts = opts or {}

    local isSK = (opts.lootMode == C.LOOT_MODE.SK)

    -- Working entry copies. Under SK the fixed point sets `withdrawn` on them.
    local work, total = {}, 0
    for i = 1, #items do
        local src = entriesByItem[items[i].idx] or {}
        local list = {}
        for j = 1, #src do
            local e = src[j]
            list[j] = { char = e.char, owner = e.owner, tier = e.tier,
                        override = e.override, withdrawn = e.withdrawn and true or false }
            total = total + 1
        end
        work[i] = list
    end

    local function resolveAll()
        local out = {}
        for i = 1, #items do out[i] = Resolve.item(items[i], work[i], opts) end
        return out
    end

    if not isSK then return resolveAll() end

    -- Stars are per character, one item index each. A star is consulted only when a
    -- character would genuinely have won several items, so it can never cost an item.
    local star = {}
    for name, itemIdx in pairs(opts.stars or {}) do star[keyOf(name)] = itemIdx end

    -- Each round strictly removes entries, so the fixed point terminates. The bound is
    -- the entry count; exceeding it is a bug, not a slow convergence.
    for _ = 1, total + 1 do
        local results = resolveAll()

        -- Which items did each character win, and which items did it enter?
        local wonBy, names = {}, {}
        for i = 1, #results do
            for _, award in ipairs(results[i].awards) do
                local key = keyOf(award.char)
                if not wonBy[key] then
                    wonBy[key] = {}
                    names[#names + 1] = key
                end
                local w = wonBy[key]
                w[#w + 1] = items[i].idx
            end
        end
        table.sort(names)                     -- deterministic withdrawal order

        local changed = false
        for _, key in ipairs(names) do
            local won = wonBy[key]

            -- Rule 2: keep the starred item when it is among the wins, else the lowest
            -- item index. Rule 1: withdraw from everything else in the batch.
            local keep = won[1]
            for _, idx in ipairs(won) do
                if idx < keep then keep = idx end
            end
            local starred = star[key]
            if starred then
                for _, idx in ipairs(won) do
                    if idx == starred then keep = starred break end
                end
            end

            for i = 1, #items do
                if items[i].idx ~= keep then
                    for _, e in ipairs(work[i]) do
                        if not e.withdrawn and keyOf(e.char) == key then
                            e.withdrawn = true
                            changed = true
                        end
                    end
                end
            end
        end

        if not changed then return results end
    end

    check(false, "SK batch resolution did not reach a fixed point")
end
