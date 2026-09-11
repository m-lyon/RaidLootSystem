-- tests/fixtures/announce.lua
--
-- Spec 006 section 4: the formats, which verbosity emits which kind, and the exact
-- lines a resolved round produces.

local ns = ...

local function run(input, ns)
    local A = ns.Announce
    if input.op == "emits" then
        return A.Emits(input.level, input.verbosity)
    elseif input.op == "format" then
        return A.Format(input.kind, input.args)
    elseif input.op == "round" then
        return A.RoundLines(input.items, input.results, input.opts)
    end
    error("unknown op: " .. tostring(input.op))
end

-- A two-item ROLL round: item 1 had a boundary tie; item 2 nobody entered.
local ITEMS = { { idx = 1, itemString = "item:1", label = "[Item A]" },
                { idx = 2, itemString = "item:2", label = "[Item B]" } }
local RESULTS = {
    {
        itemIdx = 1, unclaimed = false, degraded = false,
        awards = { { char = "Botty", owner = "Dave", tier = 2, roll = 83 } },
        record = {
            { char = "Botty", owner = "Dave", tier = 2, listIdx = 0, rolled = true, roll = 83,
              rerolled = { 90 } },
            { char = "Sneaky", owner = "Steve", tier = 2, listIdx = 0, rolled = true, roll = 83,
              rerolled = { 47 } },
            { char = "Locky", owner = "Steve", tier = 4, listIdx = 0, rolled = false, roll = 0,
              rerolled = {}, reason = "not consulted" },
        },
    },
    { itemIdx = 2, unclaimed = true, degraded = false, awards = {}, record = {} },
}

return {
    name = "announce",
    run = run,
    cases = {
        { name = "OFF emits nothing",
          input = { op = "emits", level = "WIN", verbosity = "OFF" }, expected = false },
        { name = "SUMMARY emits a win",
          input = { op = "emits", level = "WIN", verbosity = "SUMMARY" }, expected = true },
        { name = "SUMMARY does not emit a roll",
          input = { op = "emits", level = "ROLL", verbosity = "SUMMARY" }, expected = false },
        { name = "VERBOSE emits a tie",
          input = { op = "emits", level = "TIE", verbosity = "VERBOSE" }, expected = true },
        { name = "an unknown verbosity behaves as SUMMARY",
          input = { op = "emits", level = "ROLL", verbosity = "LOUD" }, expected = false },

        { name = "the open line lists the links and the timer",
          input = { op = "format", kind = "OPEN",
                    args = { labels = { "[Item A]", "[Item B]", "[Item C]" }, seconds = 180 } },
          expected = "Rolling: [Item A] [Item B] [Item C] - 3:00" },
        { name = "the open line leads with the mode under ROLL",
          input = { op = "format", kind = "OPEN",
                    args = { labels = { "[Item A]" }, seconds = 180, lootMode = "ROLL" } },
          expected = "Rolling: [Item A] - 3:00" },
        { name = "the open line leads with the mode under SK",
          input = { op = "format", kind = "OPEN",
                    args = { labels = { "[Item A]" }, seconds = 180, lootMode = "SK" } },
          expected = "SK: [Item A] - 3:00" },
        { name = "a win line carries tier and roll",
          input = { op = "format", kind = "WIN",
                    args = { char = "Botty", tierLabel = "T2", roll = 83, label = "[Item A]" } },
          expected = "Botty [T2, 83] wins [Item A]" },
        { name = "a win line under SK carries the list position instead",
          input = { op = "format", kind = "WIN",
                    args = { char = "Botty", tierLabel = "T2", roll = 0, listIdx = 3, label = "[Item A]" } },
          expected = "Botty [T2, #3] wins [Item A]" },
        { name = "a duplicate drop says which copy",
          input = { op = "format", kind = "WIN",
                    args = { char = "Botty", tierLabel = "T1", roll = 60, label = "[Item A]",
                             copy = 2, copies = 2 } },
          expected = "Botty [T1, 60] wins [Item A] (copy 2 of 2)" },
        { name = "an unclaimed item is the master looter's choice",
          input = { op = "format", kind = "UNCLAIMED", args = { label = "[Item B]" } },
          expected = "[Item B] - no entries, master looter's choice" },
        { name = "a tie line names the tied and their re-rolls",
          input = { op = "format", kind = "TIE",
                    args = { names = { "Botty", "Sneaky" }, roll = 83,
                             rerolls = { { char = "Botty", roll = 47 }, { char = "Sneaky", roll = 90 } } } },
          expected = "Botty and Sneaky tied on 83 - rerolling: Botty 47, Sneaky 90" },
        { name = "the tier count line spells out the tiers",
          input = { op = "format", kind = "TIER_COUNT", args = { tierCount = 2 } },
          expected = "Tier count is now 2 (T1, T2, Rest)" },
        { name = "a tier count of zero is a flat roll",
          input = { op = "format", kind = "TIER_COUNT", args = { tierCount = 0 } },
          expected = "Tier count is now 0 (flat roll)" },
        { name = "locking hierarchies says what it stops, not that a flag flipped",
          input = { op = "format", kind = "HIERARCHY_LOCK", args = { locked = true } },
          expected = "Hierarchies are locked - tier rankings are fixed for this campaign" },
        { name = "unlocking says what is now allowed",
          input = { op = "format", kind = "HIERARCHY_LOCK", args = { locked = false } },
          expected = "Hierarchies are unlocked - you may re-rank your characters" },
        { name = "the timer line is a clock",
          input = { op = "format", kind = "TIMER", args = { seconds = 90 } },
          expected = "Entry timer is now 1:30" },
        { name = "the loot mode line names the mode the open line names",
          input = { op = "format", kind = "LOOT_MODE", args = { lootMode = "SK" } },
          expected = "Loot mode is now SK" },
        { name = "the loot mode line back to roll says Roll",
          input = { op = "format", kind = "LOOT_MODE", args = { lootMode = "ROLL" } },
          expected = "Loot mode is now Roll" },
        { name = "an extension says what is left",
          input = { op = "format", kind = "EXTEND", args = { seconds = 60, left = 92 } },
          expected = "Entry timer extended by 60 seconds - 1:32 left" },
        { name = "an abort carries its reason",
          input = { op = "format", kind = "ABORT", args = { reasonText = "the host cancelled it" } },
          expected = "Round cancelled: the host cancelled it" },
        { name = "a lost copy with survivors",
          input = { op = "format", kind = "LOOT_LOST", args = { label = "[Item A]", count = 1, remaining = true } },
          expected = "[Item A]: 1 copy is no longer on the corpse; the roll continues on what is left" },
        { name = "an unknown kind formats to nil",
          input = { op = "format", kind = "NOPE", args = {} }, expected = nil },

        {
            -- Acceptance: verbosity Off produces zero chat output across a full round.
            name = "a round at OFF says nothing",
            input = { op = "round", items = ITEMS, results = RESULTS,
                      opts = { verbosity = "OFF", tierCount = 3 } },
            expected = {},
        },
        {
            name = "a round at SUMMARY says the winner and the unclaimed item only",
            input = { op = "round", items = ITEMS, results = RESULTS,
                      opts = { verbosity = "SUMMARY", tierCount = 3 } },
            expected = { "Botty [T2, 83] wins [Item A]",
                         "[Item B] - no entries, master looter's choice" },
        },
        {
            name = "a round at VERBOSE adds every roll and the tie, in order",
            input = { op = "round", items = ITEMS, results = RESULTS,
                      opts = { verbosity = "VERBOSE", tierCount = 3 } },
            expected = { "Botty rolled 83 [T2] on [Item A]",
                         "Sneaky rolled 83 [T2] on [Item A]",
                         "Botty and Sneaky tied on 83 - rerolling: Botty 90, Sneaky 47",
                         "Botty [T2, 83] wins [Item A]",
                         "[Item B] - no entries, master looter's choice" },
        },
        {
            name = "under SK the win line shows the position and VERBOSE adds no rolls",
            input = { op = "round", opts = { verbosity = "VERBOSE", tierCount = 3, isSK = true },
                      items = { { idx = 1, itemString = "item:1", label = "[Item A]" } },
                      results = { {
                          itemIdx = 1, unclaimed = false, degraded = false,
                          awards = { { char = "Ann", owner = "A", tier = 1, roll = 0 } },
                          record = { { char = "Ann", tier = 1, listIdx = 2, rolled = true, roll = 0, rerolled = {} },
                                     { char = "Bob", tier = 1, listIdx = 5, rolled = true, roll = 0, rerolled = {} } },
                      } } },
            expected = { "Ann [T1, #2] wins [Item A]" },
        },
        {
            name = "a degraded item says so after the winner",
            input = { op = "round", opts = { verbosity = "SUMMARY", tierCount = 3 },
                      items = { { idx = 1, itemString = "item:1", label = "[Item A]" } },
                      results = { {
                          itemIdx = 1, unclaimed = false, degraded = true,
                          awards = { { char = "Ann", owner = "A", tier = 1, roll = 50 } },
                          record = { { char = "Ann", tier = 1, listIdx = 0, rolled = true, roll = 50, rerolled = {} } },
                      } } },
            expected = { "Ann [T1, 50] wins [Item A]",
                         "[Item A] - tie re-rolls exhausted, the order was decided without one" },
        },
    },
}
