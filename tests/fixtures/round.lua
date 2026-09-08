-- tests/fixtures/round.lua
--
-- The pure half of Modules/Round.lua: submission validation, replacement,
-- the tier snapshot, the STATE aggregate and the RESULT/ROLLS records.
-- Spec 002 sections 5 to 8.

local ns = ...

local ITEMS = {
    { idx = 1, itemString = "item:40395", count = 1 },
    { idx = 2, itemString = "item:40474", count = 2 },
}

local STEVE = {
    order = { "Steve", "Sneaky", "Smash" },
    chars = { Steve = { class = "MAGE" }, Sneaky = { class = "ROGUE" },
              Smash = { class = "WARRIOR" } },
}

local DAVE = {
    order = { "Dave", "Bonk" },
    chars = { Dave = { class = "PRIEST" }, Bonk = { class = "WARRIOR" } },
}

--- Everything the host knows about the raid, from the case's own description.
local function context(state, ns)
    local function has(list, name)
        for _, n in ipairs(list or {}) do
            if n:lower() == name:lower() then return true end
        end
        return false
    end

    return {
        tierCount = state.tierCount,
        rosterOf = function(sender) return state.published[sender] end,
        isContested = function(char) return has(state.contested, char) end,
        isPresent = function(char) return not has(state.absent, char) end,
        eligible = function(_, char, _, override)
            if override then return true end
            return not has(state.ineligible, char)
        end,
    }
end

local function run(input, ns)
    local Round = ns.Round

    if input.kind == "id" then
        return Round.NewId(input.host, input.timestamp)

    elseif input.kind == "results" then
        return { results = Round.ResultRows(input.results),
                 rolls = Round.RollRows(input.results) }
    end

    -- Everything else drives a round through a sequence of submissions.
    local state = {
        tierCount = input.tierCount or 3,
        published = {},
        contested = input.contested,
        absent = input.absent,
        ineligible = input.ineligible,
    }
    for player, roster in pairs(input.published or {}) do state.published[player] = roster end

    local round = Round.New("Steve-100", "Steve", state.tierCount, 0,
        input.items or ITEMS)

    local rejections = {}
    for step, submit in ipairs(input.submits) do
        -- `republish` re-publishes one player's hierarchy between submissions,
        -- which is how the tier-snapshot rule (section 6) gets exercised.
        if submit.republish then
            state.published[submit.republish.player] = submit.republish.roster
        end
        local accepted, rejected = Round.Validate(round, submit.sender,
            submit.entries, context(state, ns))
        Round.Apply(round, submit.sender, accepted, submit.now or step)
        for _, r in ipairs(rejected) do
            rejections[#rejections + 1] = r.char .. ":" .. r.reason
        end
    end

    local entries = {}
    for _, e in ipairs(Round.StateEntries(round)) do
        entries[#entries + 1] = string.format("%d/%s/%s/T%d",
            e.itemIdx, e.char, e.owner, e.tier)
    end

    local timestamps = {}
    for player, record in pairs(round.submitted) do
        timestamps[player] = { submittedAt = record.submittedAt,
                               revisedAt = record.revisedAt, count = record.count }
    end

    return {
        entries = entries,
        rejections = rejections,
        submitted = Round.SubmittedNames(round),
        timestamps = timestamps,
        stars = Round.Stars(round),
    }
end

local function entry(itemIdx, char, override, star)
    return { itemIdx = itemIdx, char = char, override = override, star = star }
end

return {
    name = "round",
    run = run,
    cases = {
        {
            name = "a round id names its host and its time",
            input = { kind = "id", host = "Steve", timestamp = 1757155200.7 },
            expected = "Steve-1757155200",
        },

        -- Validation, section 5.
        {
            name = "an entry is accepted with the tier the host derives itself",
            input = {
                published = { Steve = STEVE },
                submits = { { sender = "Steve", entries = { entry(1, "Sneaky") } } },
            },
            expected = {
                entries = { "1/Sneaky/Steve/T2" },
                rejections = {},
                submitted = { "Steve" },
                timestamps = { Steve = { submittedAt = 1, count = 1 } },
                stars = {},
            },
        },
        {
            name = "a character the sender has not published is rejected",
            input = {
                published = { Steve = STEVE, Dave = DAVE },
                submits = { { sender = "Steve", entries = { entry(1, "Bonk") } } },
            },
            expected = {
                entries = {},
                rejections = { "Bonk:NOT_PUBLISHED" },
                submitted = { "Steve" },
                timestamps = { Steve = { submittedAt = 1, count = 0 } },
                stars = {},
            },
        },
        {
            name = "an item index outside the round is rejected",
            input = {
                published = { Steve = STEVE },
                submits = { { sender = "Steve", entries = { entry(9, "Steve") } } },
            },
            expected = {
                entries = {}, rejections = { "Steve:NO_SUCH_ITEM" },
                submitted = { "Steve" }, timestamps = { Steve = { submittedAt = 1, count = 0 } }, stars = {},
            },
        },
        {
            name = "a contested character is rejected",
            input = {
                published = { Steve = STEVE }, contested = { "Sneaky" },
                submits = { { sender = "Steve", entries = { entry(1, "Sneaky") } } },
            },
            expected = {
                entries = {}, rejections = { "Sneaky:CONTESTED" },
                submitted = { "Steve" }, timestamps = { Steve = { submittedAt = 1, count = 0 } }, stars = {},
            },
        },
        {
            name = "a character who is not in the raid is rejected",
            input = {
                published = { Steve = STEVE }, absent = { "Smash" },
                submits = { { sender = "Steve", entries = { entry(1, "Smash") } } },
            },
            expected = {
                entries = {}, rejections = { "Smash:NOT_PRESENT" },
                submitted = { "Steve" }, timestamps = { Steve = { submittedAt = 1, count = 0 } }, stars = {},
            },
        },
        {
            name = "an ineligible character is rejected, and accepted with an override",
            input = {
                published = { Steve = STEVE }, ineligible = { "Steve", "Sneaky" },
                submits = { { sender = "Steve",
                              entries = { entry(1, "Steve"), entry(2, "Sneaky", true) } } },
            },
            expected = {
                entries = { "2/Sneaky/Steve/T2" },
                rejections = { "Steve:INELIGIBLE" },
                submitted = { "Steve" }, timestamps = { Steve = { submittedAt = 1, count = 1 } }, stars = {},
            },
        },
        {
            name = "a duplicated character on one item keeps the first entry",
            input = {
                published = { Steve = STEVE },
                submits = { { sender = "Steve",
                              entries = { entry(1, "Steve"), entry(1, "steve", true) } } },
            },
            expected = {
                entries = { "1/Steve/Steve/T1" },
                rejections = { "steve:DUPLICATE" },
                submitted = { "Steve" }, timestamps = { Steve = { submittedAt = 1, count = 1 } }, stars = {},
            },
        },
        {
            name = "the same character may enter two different items",
            input = {
                published = { Steve = STEVE },
                submits = { { sender = "Steve",
                              entries = { entry(1, "Steve"), entry(2, "Steve") } } },
            },
            expected = {
                entries = { "1/Steve/Steve/T1", "2/Steve/Steve/T1" },
                rejections = {},
                submitted = { "Steve" }, timestamps = { Steve = { submittedAt = 1, count = 2 } }, stars = {},
            },
        },

        -- Replacement and revision, sections 5 and 6.
        {
            name = "re-submitting replaces rather than appends",
            input = {
                published = { Steve = STEVE },
                submits = {
                    { sender = "Steve", now = 10,
                      entries = { entry(1, "Steve"), entry(1, "Sneaky") } },
                    { sender = "Steve", now = 20, entries = { entry(1, "Steve") } },
                },
            },
            expected = {
                entries = { "1/Steve/Steve/T1" },
                rejections = {},
                submitted = { "Steve" },
                timestamps = { Steve = { submittedAt = 10, revisedAt = 20, count = 1 } },
                stars = {},
            },
        },
        {
            name = "an empty re-submission withdraws everything the sender entered",
            input = {
                published = { Steve = STEVE },
                submits = {
                    { sender = "Steve", now = 10, entries = { entry(1, "Steve") } },
                    { sender = "Steve", now = 20, entries = {} },
                },
            },
            expected = {
                entries = {}, rejections = {}, submitted = { "Steve" },
                timestamps = { Steve = { submittedAt = 10, revisedAt = 20, count = 0 } },
                stars = {},
            },
        },
        {
            name = "one player's submission never touches another's entries",
            input = {
                published = { Steve = STEVE, Dave = DAVE },
                submits = {
                    { sender = "Steve", now = 10, entries = { entry(1, "Steve") } },
                    { sender = "Dave", now = 11, entries = { entry(1, "Bonk") } },
                    { sender = "Steve", now = 12, entries = { entry(2, "Sneaky") } },
                },
            },
            expected = {
                entries = { "1/Bonk/Dave/T2", "2/Sneaky/Steve/T2" },
                rejections = {},
                submitted = { "Dave", "Steve" },
                timestamps = {
                    Steve = { submittedAt = 10, revisedAt = 12, count = 1 },
                    Dave = { submittedAt = 11, count = 1 },
                },
                stars = {},
            },
        },
        {
            name = "reordering a hierarchy after submitting does not move the entry",
            input = {
                published = { Steve = STEVE, Dave = DAVE },
                submits = {
                    { sender = "Steve", now = 10, entries = { entry(1, "Sneaky") } },
                    -- Steve promotes Sneaky, then Dave submits. Steve's pending entry
                    -- keeps the tier it was accepted with (section 6).
                    { sender = "Dave", now = 11, entries = { entry(1, "Dave") },
                      republish = { player = "Steve",
                                    roster = { order = { "Sneaky", "Steve", "Smash" },
                                               chars = STEVE.chars } } },
                },
            },
            expected = {
                entries = { "1/Sneaky/Steve/T2", "1/Dave/Dave/T1" },
                rejections = {},
                submitted = { "Dave", "Steve" },
                timestamps = { Steve = { submittedAt = 10, count = 1 },
                               Dave = { submittedAt = 11, count = 1 } },
                stars = {},
            },
        },
        {
            name = "re-submitting after a reorder re-derives the tier",
            input = {
                published = { Steve = STEVE },
                submits = {
                    { sender = "Steve", now = 10, entries = { entry(1, "Sneaky") } },
                    { sender = "Steve", now = 11, entries = { entry(1, "Sneaky") },
                      republish = { player = "Steve",
                                    roster = { order = { "Sneaky", "Steve", "Smash" },
                                               chars = STEVE.chars } } },
                },
            },
            expected = {
                entries = { "1/Sneaky/Steve/T1" },
                rejections = {},
                submitted = { "Steve" },
                timestamps = { Steve = { submittedAt = 10, revisedAt = 11, count = 1 } },
                stars = {},
            },
        },
        {
            name = "the star is carried through to resolution",
            input = {
                published = { Steve = STEVE },
                submits = { { sender = "Steve", entries = {
                    entry(1, "Steve"), entry(2, "Steve", false, true) } } },
            },
            expected = {
                entries = { "1/Steve/Steve/T1", "2/Steve/Steve/T1" },
                rejections = {},
                submitted = { "Steve" },
                timestamps = { Steve = { submittedAt = 1, count = 2 } },
                stars = { Steve = 2 },
            },
        },

        -- The records the host broadcasts, section 8.
        {
            name = "two copies produce two RESULT rows and the whole roll record",
            input = {
                kind = "results",
                results = { {
                    itemIdx = 2, unclaimed = false, degraded = false,
                    awards = { { char = "Steve", tier = 1, roll = 91 },
                               { char = "Bonk", tier = 2, roll = 40 } },
                    record = { { char = "Steve", tier = 1, roll = 91, rerolled = { 91, 55 } },
                               { char = "Bonk", tier = 2, roll = 40 },
                               { char = "Sneaky", tier = 2, roll = nil,
                                 reason = "not consulted" } },
                } },
            },
            expected = {
                results = {
                    { itemIdx = 2, winner = "Steve", tier = 1, roll = 91, outcome = "WON" },
                    { itemIdx = 2, winner = "Bonk", tier = 2, roll = 40, outcome = "WON" },
                },
                rolls = {
                    { itemIdx = 2, char = "Steve", tier = 1, roll = 91, listIdx = 0,
                      status = "", rerolled = { 91, 55 } },
                    { itemIdx = 2, char = "Bonk", tier = 2, roll = 40, listIdx = 0,
                      status = "", rerolled = {} },
                    { itemIdx = 2, char = "Sneaky", tier = 2, roll = 0, listIdx = 0,
                      status = "NC", rerolled = {} },
                },
            },
        },
        {
            name = "an item nobody entered gets an UNCLAIMED row, not silence",
            input = {
                kind = "results",
                results = { { itemIdx = 1, unclaimed = true, awards = {}, record = {} } },
            },
            expected = {
                results = { { itemIdx = 1, winner = "", tier = 0, roll = 0,
                              outcome = "UNCLAIMED" } },
                rolls = {},
            },
        },
        {
            name = "a degraded resolution says so in the outcome",
            input = {
                kind = "results",
                results = { {
                    itemIdx = 1, unclaimed = false, degraded = true,
                    awards = { { char = "Steve", tier = 1, roll = 55 } },
                    record = { { char = "Steve", tier = 1, roll = 55 } },
                } },
            },
            expected = {
                results = { { itemIdx = 1, winner = "Steve", tier = 1, roll = 55,
                              outcome = "DEGRADED" } },
                rolls = { { itemIdx = 1, char = "Steve", tier = 1, roll = 55, listIdx = 0,
                            status = "", rerolled = {} } },
            },
        },
    },
}
