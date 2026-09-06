-- tests/fixtures/tiers.lua
--
-- Spec 001 section 3 and spec 000 section 6. Adding a regression case means
-- adding a table entry, never writing new test code.

local ns = ...

--- Each case feeds one input table through `run` and compares the whole result.
local function run(input, ns)
    local Tiers = ns.Tiers

    if input.kind == "positions" then
        -- The tier of positions 1..10 for one tier count.
        local out = {}
        for position = 1, 10 do
            out[position] = Tiers.forPosition(position, input.tierCount)
        end
        return out
    elseif input.kind == "labels" then
        local out = {}
        for position = 1, 10 do
            out[position] = Tiers.label(Tiers.forPosition(position, input.tierCount), input.tierCount)
        end
        return out
    elseif input.kind == "bands" then
        return Tiers.bands(input.orderLength, input.tierCount)
    elseif input.kind == "span" then
        return Tiers.tierSpan(input.tierCount)
    elseif input.kind == "isRest" then
        return Tiers.isRest(input.tier, input.tierCount)
    elseif input.kind == "truncation" then
        -- Lowering then raising the tier count must not touch the ordering.
        local order = { "Steve", "Sneaky", "Smash", "Locky", "Shammy", "Bear" }
        local before = table.concat(order, ",")
        Tiers.bands(#order, 2)
        Tiers.bands(#order, 5)
        return { order = table.concat(order, ","), unchanged = (table.concat(order, ",") == before) }
    end
    return nil
end

return {
    name = "tiers",
    run = run,
    cases = {
        -- Positions 1-10 across every legal tier count. Together these are the
        -- full 10 x 6 matrix the acceptance criterion asks for.
        {
            name = "tierCount 0 is a flat roll",
            input = { kind = "positions", tierCount = 0 },
            expected = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        },
        {
            name = "tierCount 1 puts everything below position 1 in Rest",
            input = { kind = "positions", tierCount = 1 },
            expected = { 1, 2, 2, 2, 2, 2, 2, 2, 2, 2 },
        },
        {
            name = "tierCount 2",
            input = { kind = "positions", tierCount = 2 },
            expected = { 1, 2, 3, 3, 3, 3, 3, 3, 3, 3 },
        },
        {
            name = "tierCount 3 is the default",
            input = { kind = "positions", tierCount = 3 },
            expected = { 1, 2, 3, 4, 4, 4, 4, 4, 4, 4 },
        },
        {
            name = "tierCount 4",
            input = { kind = "positions", tierCount = 4 },
            expected = { 1, 2, 3, 4, 5, 5, 5, 5, 5, 5 },
        },
        {
            name = "tierCount 5 is the maximum",
            input = { kind = "positions", tierCount = 5 },
            expected = { 1, 2, 3, 4, 5, 6, 6, 6, 6, 6 },
        },

        -- Labels.
        {
            name = "labels are Flat at tierCount 0",
            input = { kind = "labels", tierCount = 0 },
            expected = { "Flat", "Flat", "Flat", "Flat", "Flat", "Flat", "Flat", "Flat", "Flat", "Flat" },
        },
        {
            name = "labels name the Rest tier at tierCount 3",
            input = { kind = "labels", tierCount = 3 },
            expected = { "T1", "T2", "T3", "Rest", "Rest", "Rest", "Rest", "Rest", "Rest", "Rest" },
        },
        {
            name = "isRest is true only for the tier past the cut-off",
            input = { kind = "isRest", tier = 4, tierCount = 3 },
            expected = true,
        },
        {
            name = "isRest is false for a counted tier",
            input = { kind = "isRest", tier = 3, tierCount = 3 },
            expected = false,
        },
        {
            name = "isRest is false under a flat roll",
            input = { kind = "isRest", tier = 1, tierCount = 0 },
            expected = false,
        },

        -- Bands, which drive the editor separators.
        {
            name = "bands for a 6-character roster at tierCount 3",
            input = { kind = "bands", orderLength = 6, tierCount = 3 },
            expected = { 1, 2, 3, 4, 4, 4 },
        },
        {
            name = "bands for an empty roster",
            input = { kind = "bands", orderLength = 0, tierCount = 3 },
            expected = {},
        },
        {
            name = "bands are all tier 1 under a flat roll",
            input = { kind = "bands", orderLength = 4, tierCount = 0 },
            expected = { 1, 1, 1, 1 },
        },
        {
            name = "tier span counts the Rest tier",
            input = { kind = "span", tierCount = 3 },
            expected = 4,
        },
        {
            name = "tier span is 1 under a flat roll",
            input = { kind = "span", tierCount = 0 },
            expected = 1,
        },

        -- Truncation is a view, never a mutation (spec 001 section 3).
        {
            name = "lowering then raising the tier count leaves the order untouched",
            input = { kind = "truncation" },
            expected = { order = "Steve,Sneaky,Smash,Locky,Shammy,Bear", unchanged = true },
        },
    },
}
