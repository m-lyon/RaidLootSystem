-- tests/fixtures/resolve.lua
--
-- Spec 003 sections 5 to 7, plus the SK resolution cases of spec 010 section 12.
-- The rng is scripted, so every expectation below is an exact outcome, not a range.

local ns = ...

--------------------------------------------------------------------------------
-- Scripted rng
--------------------------------------------------------------------------------
-- Consumes `rolls` in order. Running off the end is a fixture bug and says so
-- rather than falling back to something plausible.

local function scripted(rolls)
    local calls, n = 0, 0
    local rng = function()
        n = n + 1
        calls = n
        local v = rolls[n]
        if v == nil then error("scripted rng exhausted after " .. (n - 1) .. " calls", 0) end
        return v
    end
    return rng, function() return calls end
end

--------------------------------------------------------------------------------
-- Projections
--------------------------------------------------------------------------------
-- The full result table is large. Most cases assert a compact projection of it;
-- the "raw" case below pins the exact section 7 shape.

local function awardLine(a)
    return a.char .. "=" .. tostring(a.roll)
end

local function recordLine(r)
    return string.format("%s t%d L%d %s roll=%d rr=[%s] %s",
        r.char, r.tier, r.listIdx, r.rolled and "rolled" or "no", r.roll,
        table.concat(r.rerolled, ","), r.reason or "-")
end

local function project(result, rngCalls)
    local awards, record = {}, {}
    for i, a in ipairs(result.awards) do awards[i] = awardLine(a) end
    for i, r in ipairs(result.record) do record[i] = recordLine(r) end
    return {
        itemIdx = result.itemIdx,
        unclaimed = result.unclaimed,
        degraded = result.degraded,
        tiersConsulted = result.tiersConsulted,
        rngCalls = rngCalls,
        awards = awards,
        record = record,
    }
end

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------

local function optsFor(input, rng)
    return {
        rng = rng,
        tierCount = input.tierCount,
        maxReroll = input.maxReroll,
        lootMode = input.lootMode,
        priority = input.priority,
        stars = input.stars,
    }
end

local function run(input, ns)
    local Resolve = ns.Resolve

    if input.kind == "item" or input.kind == "raw" then
        local rng, calls = scripted(input.rolls or {})
        local item = { idx = input.idx or 1, itemString = "item:49623", count = input.count or 1 }
        local result = Resolve.item(item, input.entries, optsFor(input, rng))
        if input.kind == "raw" then return result end
        return project(result, calls())

    elseif input.kind == "batch" then
        local rng, calls = scripted(input.rolls or {})
        local items, entriesByItem = {}, {}
        for i, spec in ipairs(input.items) do
            items[i] = { idx = spec.idx, itemString = "item:" .. spec.idx, count = spec.count or 1 }
            entriesByItem[spec.idx] = spec.entries
        end
        local results = Resolve.batch(items, entriesByItem, optsFor(input, rng))

        local out = { rngCalls = calls() }
        for i, result in ipairs(results) do
            local winners, withdrawn = {}, {}
            for _, a in ipairs(result.awards) do winners[#winners + 1] = a.char end
            for _, r in ipairs(result.record) do
                if r.reason == "withdrawn" then withdrawn[#withdrawn + 1] = r.char end
            end
            out[i] = {
                idx = result.itemIdx,
                unclaimed = result.unclaimed,
                winners = table.concat(winners, ","),
                withdrawn = table.concat(withdrawn, ","),
            }
        end
        return out

    elseif input.kind == "error" then
        local rng = scripted(input.rolls or {})
        local item = { idx = 1, itemString = "item:1", count = input.count or 1 }
        local ok, err = pcall(Resolve.item, item, input.entries, optsFor(input, rng))
        return { ok = ok, err = tostring(err) }

    elseif input.kind == "repeatable" then
        -- The same input with the same scripted rng, twice.
        local first
        for _ = 1, 2 do
            local rng, calls = scripted(input.rolls)
            local item = { idx = 1, itemString = "item:1", count = input.count or 1 }
            local result = project(Resolve.item(item, input.entries, optsFor(input, rng)), calls())
            local text = table.concat(result.awards, "|") .. "//" .. table.concat(result.record, "|")
            if first == nil then first = text
            elseif first ~= text then return { identical = false } end
        end
        return { identical = true }
    end
    return nil
end

--------------------------------------------------------------------------------
-- Entry sets
--------------------------------------------------------------------------------

local function entry(char, owner, tier) return { char = char, owner = owner, tier = tier } end

-- One T1 entry against twenty Rest entries, tierCount 3 so Rest is tier 4.
local ONE_VS_TWENTY = { entry("Bonk", "Dave", 1) }
for i = 1, 20 do
    ONE_VS_TWENTY[#ONE_VS_TWENTY + 1] =
        entry(string.format("Rest%02d", i), string.format("Owner%02d", i), 4)
end

local ONE_VS_TWENTY_RECORD = { "Bonk t1 L0 rolled roll=5 rr=[] -" }
for i = 1, 20 do
    ONE_VS_TWENTY_RECORD[#ONE_VS_TWENTY_RECORD + 1] =
        string.format("Rest%02d t4 L0 no roll=0 rr=[] not consulted", i)
end

-- Six items, six characters, everyone entered on everything. Used for the SK
-- fixed point. List order is Ann < Bob < Cat < Dan < Eve < Fay.
local SIX_BY_SIX = {}
for idx = 1, 6 do
    local entries = {}
    for i, name in ipairs({ "Ann", "Bob", "Cat", "Dan", "Eve", "Fay" }) do
        entries[i] = entry(name, name .. "Owner", 1)
    end
    SIX_BY_SIX[idx] = { idx = idx, entries = entries }
end

local SK_LIST = { Ann = 1, Bob = 2, Cat = 3, Dan = 4, Eve = 5, Fay = 6 }

return {
    name = "resolve",
    run = run,
    cases = {
        ------------------------------------------------------------------------
        -- Tier gating (section 5)
        ------------------------------------------------------------------------
        {
            name = "one T1 entry beats twenty Rest entries",
            input = { kind = "item", tierCount = 3, entries = ONE_VS_TWENTY, rolls = { 5 } },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = false,
                tiersConsulted = 1, rngCalls = 1,
                awards = { "Bonk=5" },
                record = ONE_VS_TWENTY_RECORD,
            },
        },
        {
            name = "two copies, one T1 and three T2: the copy spills into T2",
            input = {
                kind = "item", tierCount = 3, count = 2,
                entries = {
                    entry("Bonk", "Dave", 1),
                    entry("Ash", "Ann", 2), entry("Bee", "Bob", 2), entry("Cid", "Cat", 2),
                },
                rolls = { 10, 40, 90, 20 },
            },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = false,
                tiersConsulted = 2, rngCalls = 4,
                awards = { "Bonk=10", "Bee=90" },
                record = {
                    "Bonk t1 L0 rolled roll=10 rr=[] -",
                    "Ash t2 L0 rolled roll=40 rr=[] -",
                    "Bee t2 L0 rolled roll=90 rr=[] -",
                    "Cid t2 L0 rolled roll=20 rr=[] -",
                },
            },
        },
        {
            name = "two copies and five T1 entries: the top two win, no lower tier is consulted",
            input = {
                kind = "item", tierCount = 3, count = 2,
                entries = {
                    entry("Ann", "A", 1), entry("Bob", "B", 1), entry("Cat", "C", 1),
                    entry("Dan", "D", 1), entry("Eve", "E", 1),
                    entry("Low", "Z", 2),
                },
                rolls = { 10, 80, 50, 90, 30 },
            },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = false,
                tiersConsulted = 1, rngCalls = 5,
                awards = { "Dan=90", "Bob=80" },
                record = {
                    "Ann t1 L0 rolled roll=10 rr=[] -",
                    "Bob t1 L0 rolled roll=80 rr=[] -",
                    "Cat t1 L0 rolled roll=50 rr=[] -",
                    "Dan t1 L0 rolled roll=90 rr=[] -",
                    "Eve t1 L0 rolled roll=30 rr=[] -",
                    "Low t2 L0 no roll=0 rr=[] not consulted",
                },
            },
        },
        {
            name = "tierCount 0 degenerates to a flat roll",
            input = {
                kind = "item", tierCount = 0,
                entries = { entry("Ann", "A", 1), entry("Bob", "B", 1) },
                rolls = { 30, 70 },
            },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = false,
                tiersConsulted = 1, rngCalls = 2,
                awards = { "Bob=70" },
                record = {
                    "Ann t1 L0 rolled roll=30 rr=[] -",
                    "Bob t1 L0 rolled roll=70 rr=[] -",
                },
            },
        },
        {
            name = "zero entries leaves the item unclaimed",
            input = { kind = "item", tierCount = 3, entries = {} },
            expected = {
                itemIdx = 1, unclaimed = true, degraded = false,
                tiersConsulted = 0, rngCalls = 0,
                awards = {}, record = {},
            },
        },

        ------------------------------------------------------------------------
        -- Ties (section 6)
        ------------------------------------------------------------------------
        {
            name = "a boundary tie re-rolls only the tied pair",
            input = {
                kind = "item", tierCount = 3,
                entries = { entry("Ann", "A", 1), entry("Bob", "B", 1), entry("Cat", "C", 1) },
                rolls = { 83, 83, 20, 60, 95 },
            },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = false,
                tiersConsulted = 1, rngCalls = 5,
                awards = { "Bob=83" },
                record = {
                    "Ann t1 L0 rolled roll=83 rr=[60] -",
                    "Bob t1 L0 rolled roll=83 rr=[95] -",
                    "Cat t1 L0 rolled roll=20 rr=[] -",
                },
            },
        },
        {
            name = "a tie below the boundary is left alone",
            input = {
                kind = "item", tierCount = 3,
                entries = { entry("Ann", "A", 1), entry("Bob", "B", 1), entry("Cat", "C", 1) },
                rolls = { 90, 50, 50 },
            },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = false,
                tiersConsulted = 1, rngCalls = 3,
                awards = { "Ann=90" },
                record = {
                    "Ann t1 L0 rolled roll=90 rr=[] -",
                    "Bob t1 L0 rolled roll=50 rr=[] -",
                    "Cat t1 L0 rolled roll=50 rr=[] -",
                },
            },
        },
        {
            name = "a tie above the boundary is left alone",
            input = {
                kind = "item", tierCount = 3, count = 2,
                entries = { entry("Ann", "A", 1), entry("Bob", "B", 1), entry("Cat", "C", 1) },
                rolls = { 70, 70, 20 },
            },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = false,
                tiersConsulted = 1, rngCalls = 3,
                awards = { "Ann=70", "Bob=70" },
                record = {
                    "Ann t1 L0 rolled roll=70 rr=[] -",
                    "Bob t1 L0 rolled roll=70 rr=[] -",
                    "Cat t1 L0 rolled roll=20 rr=[] -",
                },
            },
        },
        {
            name = "an rng that always ties exhausts maxReroll and degrades",
            input = {
                kind = "item", tierCount = 3, maxReroll = 3,
                entries = { entry("Ann", "A", 1), entry("Bob", "B", 1) },
                rolls = { 50, 50, 50, 50, 50, 50, 50, 50 },
            },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = true,
                tiersConsulted = 1, rngCalls = 8,
                awards = { "Ann=50" },
                record = {
                    "Ann t1 L0 rolled roll=50 rr=[50,50,50] -",
                    "Bob t1 L0 rolled roll=50 rr=[50,50,50] -",
                },
            },
        },

        ------------------------------------------------------------------------
        -- Output shape (section 7) and determinism (section 4)
        ------------------------------------------------------------------------
        {
            name = "the result carries the full section 7 shape",
            input = {
                kind = "raw", tierCount = 3,
                entries = { entry("Bonk", "Dave", 1), entry("Sneaky", "Steve", 2) },
                rolls = { 91 },
            },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = false, tiersConsulted = 1,
                awards = { { char = "Bonk", owner = "Dave", tier = 1, roll = 91 } },
                record = {
                    { char = "Bonk", owner = "Dave", tier = 1, listIdx = 0,
                      rolled = true, roll = 91, rerolled = {} },
                    { char = "Sneaky", owner = "Steve", tier = 2, listIdx = 0,
                      rolled = false, roll = 0, rerolled = {}, reason = "not consulted" },
                },
            },
        },
        {
            name = "the same input and the same scripted rng give identical output",
            input = {
                kind = "repeatable", tierCount = 3, count = 2,
                entries = {
                    entry("Ann", "A", 1), entry("Bob", "B", 1), entry("Cat", "C", 1),
                    entry("Dan", "D", 2), entry("Eve", "E", 2),
                },
                rolls = { 83, 83, 20, 60, 95 },
            },
            expected = { identical = true },
        },
        {
            name = "an explicit ROLL mode matches an absent one",
            input = {
                kind = "item", tierCount = 3, count = 2, lootMode = "ROLL",
                entries = {
                    entry("Bonk", "Dave", 1),
                    entry("Ash", "Ann", 2), entry("Bee", "Bob", 2), entry("Cid", "Cat", 2),
                },
                rolls = { 10, 40, 90, 20 },
            },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = false,
                tiersConsulted = 2, rngCalls = 4,
                awards = { "Bonk=10", "Bee=90" },
                record = {
                    "Bonk t1 L0 rolled roll=10 rr=[] -",
                    "Ash t2 L0 rolled roll=40 rr=[] -",
                    "Bee t2 L0 rolled roll=90 rr=[] -",
                    "Cid t2 L0 rolled roll=20 rr=[] -",
                },
            },
        },

        ------------------------------------------------------------------------
        -- Preconditions (section 3)
        ------------------------------------------------------------------------
        {
            name = "a duplicate char raises rather than double-awarding",
            input = {
                kind = "error",
                entries = { entry("Ann", "A", 1), entry("Ann", "A", 2) },
                rolls = { 50, 50 },
            },
            expected = { ok = false, err = "Resolve: duplicate entry for Ann on item 1" },
        },
        {
            name = "a tier below 1 raises",
            input = { kind = "error", entries = { entry("Ann", "A", 0) }, rolls = { 50 } },
            expected = { ok = false, err = "Resolve: entry Ann has a non-integer tier" },
        },

        ------------------------------------------------------------------------
        -- Suicide Kings (spec 010 section 7 and 12)
        ------------------------------------------------------------------------
        {
            name = "SK never calls the rng and the lowest list index wins the bucket",
            input = {
                kind = "item", tierCount = 3, lootMode = "SK", priority = SK_LIST,
                entries = { entry("Cat", "C", 1), entry("Ann", "A", 1), entry("Eve", "E", 1) },
                rolls = {},
            },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = false,
                tiersConsulted = 1, rngCalls = 0,
                awards = { "Ann=0" },
                record = {
                    "Ann t1 L1 rolled roll=0 rr=[] -",
                    "Cat t1 L3 rolled roll=0 rr=[] -",
                    "Eve t1 L5 rolled roll=0 rr=[] -",
                },
            },
        },
        {
            name = "SK tier gating: a T1 entry low on the list beats a Rest entry at the top",
            input = {
                kind = "item", tierCount = 3, lootMode = "SK",
                priority = { Ann = 1, Fay = 25 },
                entries = { entry("Fay", "F", 1), entry("Ann", "A", 4) },
                rolls = {},
            },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = false,
                tiersConsulted = 1, rngCalls = 0,
                awards = { "Fay=0" },
                record = {
                    "Fay t1 L25 rolled roll=0 rr=[] -",
                    "Ann t4 L1 no roll=0 rr=[] not consulted",
                },
            },
        },
        {
            name = "SK two copies go to the two lowest list indices, in order",
            input = {
                kind = "item", tierCount = 3, count = 2, lootMode = "SK", priority = SK_LIST,
                entries = { entry("Dan", "D", 1), entry("Bob", "B", 1), entry("Fay", "F", 1) },
                rolls = {},
            },
            expected = {
                itemIdx = 1, unclaimed = false, degraded = false,
                tiersConsulted = 1, rngCalls = 0,
                awards = { "Bob=0", "Dan=0" },
                record = {
                    "Bob t1 L2 rolled roll=0 rr=[] -",
                    "Dan t1 L4 rolled roll=0 rr=[] -",
                    "Fay t1 L6 rolled roll=0 rr=[] -",
                },
            },
        },
        {
            name = "SK batch: a winner is withdrawn from the rest of the batch",
            input = {
                kind = "batch", tierCount = 3, lootMode = "SK", priority = SK_LIST,
                items = SIX_BY_SIX, rolls = {},
            },
            expected = {
                rngCalls = 0,
                -- Six items and six characters, everyone entered everywhere: the fixed
                -- point gives each character exactly one item and withdraws it from
                -- the other five.
                { idx = 1, unclaimed = false, winners = "Ann",
                  withdrawn = "Bob,Cat,Dan,Eve,Fay" },
                { idx = 2, unclaimed = false, winners = "Bob",
                  withdrawn = "Ann,Cat,Dan,Eve,Fay" },
                { idx = 3, unclaimed = false, winners = "Cat",
                  withdrawn = "Ann,Bob,Dan,Eve,Fay" },
                { idx = 4, unclaimed = false, winners = "Dan",
                  withdrawn = "Ann,Bob,Cat,Eve,Fay" },
                { idx = 5, unclaimed = false, winners = "Eve",
                  withdrawn = "Ann,Bob,Cat,Dan,Fay" },
                { idx = 6, unclaimed = false, winners = "Fay",
                  withdrawn = "Ann,Bob,Cat,Dan,Eve" },
            },
        },
        {
            name = "SK star: the starred item is taken and the other is still awarded",
            input = {
                kind = "batch", tierCount = 3, lootMode = "SK", priority = SK_LIST,
                stars = { Ann = 4 },
                items = {
                    { idx = 1, entries = { entry("Ann", "A", 1), entry("Cat", "C", 1) } },
                    { idx = 4, entries = { entry("Ann", "A", 1), entry("Bob", "B", 1) } },
                },
                rolls = {},
            },
            expected = {
                rngCalls = 0,
                { idx = 1, unclaimed = false, winners = "Cat", withdrawn = "Ann" },
                { idx = 4, unclaimed = false, winners = "Ann", withdrawn = "" },
            },
        },
        {
            name = "SK star on an item the character would not have won changes nothing",
            input = {
                kind = "batch", tierCount = 3, lootMode = "SK", priority = SK_LIST,
                stars = { Cat = 1 },
                items = {
                    { idx = 1, entries = { entry("Ann", "A", 1), entry("Cat", "C", 1) } },
                    { idx = 4, entries = { entry("Ann", "A", 1), entry("Bob", "B", 1) } },
                },
                rolls = {},
            },
            expected = {
                rngCalls = 0,
                { idx = 1, unclaimed = false, winners = "Ann", withdrawn = "" },
                { idx = 4, unclaimed = false, winners = "Bob", withdrawn = "Ann" },
            },
        },
        {
            name = "ROLL batch items are fully independent",
            input = {
                kind = "batch", tierCount = 3,
                items = {
                    { idx = 1, entries = { entry("Ann", "A", 1), entry("Bob", "B", 1) } },
                    { idx = 2, entries = { entry("Ann", "A", 1), entry("Bob", "B", 1) } },
                },
                rolls = { 90, 10, 80, 20 },
            },
            expected = {
                rngCalls = 4,
                { idx = 1, unclaimed = false, winners = "Ann", withdrawn = "" },
                { idx = 2, unclaimed = false, winners = "Ann", withdrawn = "" },
            },
        },
    },
}
