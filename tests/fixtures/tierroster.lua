-- tests/fixtures/tierroster.lua
--
-- The campaign tier roster (spec 013 section 7): who composes each tier, built from
-- the orderings the campaign's members submitted.
--
-- The cases that matter are the ones where a band is not simply "the Nth character
-- of everyone who has one" -- a member with fewer characters than there are tiers, a
-- tier nobody has reached, a flat campaign, and the list-index ordering the two
-- priority surfaces re-sort by, which has to match what the resolution engine
-- awards in.

local ns = ...

local TierRoster = ns.TierRoster

--- "T1: Bonk(Dave) Sneaky(Steve)" -- one string per band, so a case reads as the
-- shape of the whole roster rather than a nest of tables.
local function render(bands)
    local out = {}
    for i, band in ipairs(bands) do
        local parts = {}
        for _, row in ipairs(band.rows) do
            parts[#parts + 1] = string.format("%s(%s)", row.char, tostring(row.owner))
        end
        out[i] = band.label .. ": " .. (#parts > 0 and table.concat(parts, " ") or "-")
    end
    return out
end

local MEMBERS = {
    { player = "Craig",   order = { "Craigmain" }, at = 100 },
    { player = "Matt",    order = { "Matt", "Mattbot", "Mattpal" }, at = 200,
      chars = { Matt = { class = "WARRIOR" } } },
    { player = "Stewart", order = { "Stew", "Stewalt", "Stewpal", "Stewsham", "Stewdk" },
      at = 300 },
}

local function run(input, ns)
    if input.op == "bands" then
        return render(TierRoster.bands(input.members, input.tierCount, input.ctx))

    elseif input.op == "listOrder" then
        -- What the host panel and the viewer draw: bands, and inside a band the
        -- list order, which is the order spec 003 section 5 awards in.
        local bands = TierRoster.bands(input.members, input.tierCount,
            { listIndex = input.listIndex })
        return render(TierRoster.byListIndex(bands))

    elseif input.op == "groupRows" then
        -- "Bob#2/1" is Bob at global list index 2, first in his tier. The number the
        -- two list surfaces draw is the second one.
        local bands = TierRoster.groupRows(input.rows, input.tierCount)
        local out = {}
        for i, band in ipairs(bands) do
            local parts = {}
            for _, row in ipairs(band.rows) do
                parts[#parts + 1] = string.format("%s#%s/%s", row.char,
                    tostring(row.position), tostring(row.tierPosition))
            end
            out[i] = band.label .. ": " .. (#parts > 0 and table.concat(parts, " ") or "-")
        end
        return out

    elseif input.op == "ranks" then
        -- "Bob=1": the rank the roll window draws beside Bob.
        local ranks = TierRoster.ranks(input.positions, input.tiers, input.tierCount)
        local out = {}
        for char, rank in pairs(ranks) do out[#out + 1] = char .. "=" .. rank end
        table.sort(out)
        return out

    elseif input.op == "row" then
        -- One row in full, so the fields the window reads are pinned.
        local bands = TierRoster.bands(input.members, input.tierCount, input.ctx)
        local row = bands[input.band].rows[input.index]
        return { char = row.char, owner = row.owner, class = row.class or "",
                 position = row.position, present = row.present == true,
                 isSelf = row.isSelf == true, at = row.at,
                 listIndex = row.listIndex or 0 }

    elseif input.op == "missing" then
        return TierRoster.missing(input.announced, input.members)
    end
    error("unknown op " .. tostring(input.op))
end

return {
    name = "tierroster",
    run = run,
    cases = {
        ------------------------------------------------------------------
        -- Bands (section 4)
        ------------------------------------------------------------------
        {
            -- The sentence the feature exists to make true: T1 is everyone's
            -- first-ranked character, across every member of the campaign.
            name = "T1 holds the first-ranked character of every member",
            input = { op = "bands", tierCount = 3, members = MEMBERS },
            expected = {
                "T1: Craigmain(Craig) Matt(Matt) Stew(Stewart)",
                "T2: Mattbot(Matt) Stewalt(Stewart)",
                "T3: Mattpal(Matt) Stewpal(Stewart)",
                "Rest: Stewsham(Stewart) Stewdk(Stewart)",
            },
        },
        {
            -- Craig plays one character. He is in T1 and nowhere else -- not in
            -- Rest, which would read as him having a ranked character down there.
            name = "a member with one character appears only in T1",
            input = { op = "bands", tierCount = 3,
                      members = { { player = "Craig", order = { "Craigmain" } } } },
            expected = { "T1: Craigmain(Craig)", "T2: -", "T3: -", "Rest: -" },
        },
        {
            -- An unfilled T3 is not a two-tier campaign, and renumbering would
            -- present it as one.
            name = "a tier nobody has reached is an empty band, not a missing one",
            input = { op = "bands", tierCount = 3,
                      members = { { player = "Matt", order = { "Matt", "Mattbot" } },
                                  { player = "Craig", order = { "Craigmain" } } } },
            expected = { "T1: Craigmain(Craig) Matt(Matt)", "T2: Mattbot(Matt)",
                         "T3: -", "Rest: -" },
        },
        {
            name = "a flat campaign is one band holding everyone",
            input = { op = "bands", tierCount = 0, members = MEMBERS },
            expected = {
                "Flat: Craigmain(Craig) Matt(Matt) Mattbot(Matt) Mattpal(Matt) "
                    .. "Stew(Stewart) Stewalt(Stewart) Stewpal(Stewart) "
                    .. "Stewsham(Stewart) Stewdk(Stewart)",
            },
        },
        {
            name = "a member who has submitted an empty ordering contributes no rows",
            input = { op = "bands", tierCount = 2,
                      members = { { player = "Craig", order = {} },
                                  { player = "Matt", order = { "Matt" } } } },
            expected = { "T1: Matt(Matt)", "T2: -", "Rest: -" },
        },
        {
            name = "no members at all still draws every band of the campaign",
            input = { op = "bands", tierCount = 2, members = {} },
            expected = { "T1: -", "T2: -", "Rest: -" },
        },
        {
            -- Sorted by owner inside a band, so the roster does not reshuffle
            -- between two reads that happened to iterate a table differently.
            name = "band order does not depend on the order members are passed in",
            input = { op = "bands", tierCount = 1,
                      members = { { player = "Stewart", order = { "Stew" } },
                                  { player = "Craig", order = { "Craigmain" } },
                                  { player = "Matt", order = { "Matt" } } } },
            expected = { "T1: Craigmain(Craig) Matt(Matt) Stew(Stewart)", "Rest: -" },
        },
        {
            name = "a row carries the fields the roster window reads",
            input = { op = "row", tierCount = 3, members = MEMBERS, band = 1, index = 2,
                      ctx = { present = { Matt = true }, me = "Matt",
                              listIndex = { Matt = 7 } } },
            expected = { char = "Matt", owner = "Matt", class = "WARRIOR", position = 1,
                         present = true, isSelf = true, at = 200, listIndex = 7 },
        },
        {
            -- Nobody claims it on this client, but its owner ranked it, so it has
            -- a tier. Presence defaults false rather than erroring.
            name = "a character nobody is present for still lands in its owner's band",
            input = { op = "row", tierCount = 2, members = MEMBERS, band = 2, index = 1,
                      ctx = {} },
            expected = { char = "Mattbot", owner = "Matt", class = "", position = 2,
                         present = false, isSelf = false, at = 200, listIndex = 0 },
        },

        ------------------------------------------------------------------
        -- List order inside a band (section 6)
        ------------------------------------------------------------------
        {
            -- Ascending tier, and inside a tier ascending list index: exactly the
            -- order spec 003 section 5 awards in. Stew is list 1 but T1 holds
            -- Craigmain at list 9, and both are consulted before any T2 row.
            name = "inside a band the list index decides, which is the award order",
            input = { op = "listOrder", tierCount = 2, members = MEMBERS,
                      listIndex = { Stew = 1, Matt = 4, Craigmain = 9,
                                    Stewalt = 2, Mattbot = 6 } },
            expected = {
                "T1: Stew(Stewart) Matt(Matt) Craigmain(Craig)",
                "T2: Stewalt(Stewart) Mattbot(Matt)",
                "Rest: Mattpal(Matt) Stewpal(Stewart) Stewsham(Stewart) Stewdk(Stewart)",
            },
        },
        {
            -- A character on nobody's list sorts after those on it rather than
            -- ahead of them or out of the band entirely.
            name = "a character with no list index sorts to the end of its band",
            input = { op = "listOrder", tierCount = 1,
                      members = { { player = "Matt", order = { "Matt" } },
                                  { player = "Craig", order = { "Craigmain" } } },
                      listIndex = { Craigmain = 5 } },
            expected = { "T1: Craigmain(Craig) Matt(Matt)", "Rest: -" },
        },

        ------------------------------------------------------------------
        -- Grouping the priority list's own rows (section 6)
        ------------------------------------------------------------------
        {
            name = "each row is numbered within its own tier, not by list index",
            input = { op = "groupRows", tierCount = 2, rows = {
                { char = "Ann", position = 1, tier = 2 },
                { char = "Bob", position = 2, tier = 1 },
                { char = "Cat", position = 3, tier = 3 },
                { char = "Dan", position = 4, tier = 1 },
            } },
            expected = { "T1: Bob#2/1 Dan#4/2", "T2: Ann#1/1", "Rest: Cat#3/1" },
        },
        {
            -- Rest is a real answer: ranked, below the cut-off. "We do not know"
            -- has to look different or it reads as a fact.
            name = "rows whose owner submitted nothing band separately from Rest",
            input = { op = "groupRows", tierCount = 2, rows = {
                { char = "Ann", position = 1, tier = 3 },
                { char = "Bob", position = 2, tier = nil },
                { char = "Cat", position = 3, tier = 1 },
            } },
            expected = { "T1: Cat#3/1", "T2: -", "Rest: Ann#1/1", "No hierarchy: Bob#2/1" },
        },
        {
            -- The roll window holds the list as SKLIST's name -> index map and the
            -- tiers as Campaign.TierIndex's lowercase keys; the ranks must still be
            -- groupRows' numbers, keyed by the name as the map spells it.
            name = "ranks from a position map match groupRows' tier numbers",
            input = { op = "ranks", tierCount = 2,
                      positions = { Ann = 1, Bob = 2, Cat = 3, Dan = 4, Eve = 5 },
                      tiers = { ann = 2, bob = 1, cat = 3, dan = 1 } },
            expected = { "Ann=1", "Bob=1", "Cat=1", "Dan=2", "Eve=1" },
        },
        {
            name = "the unknown band is absent when every row has a tier",
            input = { op = "groupRows", tierCount = 1, rows = {
                { char = "Ann", position = 1, tier = 1 },
            } },
            expected = { "T1: Ann#1/1", "Rest: -" },
        },
        {
            -- The number restarts at 1 in each band, including the one for rows
            -- whose owner has submitted nothing.
            name = "the tier number restarts at one in every band",
            input = { op = "groupRows", tierCount = 1, rows = {
                { char = "Ann", position = 1, tier = 2 },
                { char = "Bob", position = 2, tier = 1 },
                { char = "Cat", position = 3, tier = 2 },
                { char = "Dan", position = 4, tier = 1 },
                { char = "Eve", position = 5, tier = nil },
                { char = "Fay", position = 6, tier = nil },
            } },
            expected = { "T1: Bob#2/1 Dan#4/2", "Rest: Ann#1/1 Cat#3/2",
                         "No hierarchy: Eve#5/1 Fay#6/2" },
        },
        {
            -- A character can be third on the list and first in the queue for a T1
            -- item, which is the whole reason the displayed number changed.
            name = "a low list index can still be first in its tier",
            input = { op = "groupRows", tierCount = 2, rows = {
                { char = "Ann", position = 1, tier = 3 },
                { char = "Bob", position = 2, tier = 3 },
                { char = "Cat", position = 3, tier = 1 },
            } },
            expected = { "T1: Cat#3/1", "T2: -", "Rest: Ann#1/1 Bob#2/2" },
        },
        {
            name = "an empty list groups into empty bands without erroring",
            input = { op = "groupRows", tierCount = 2, rows = {} },
            expected = { "T1: -", "T2: -", "Rest: -" },
        },

        ------------------------------------------------------------------
        -- Who has not submitted (section 5)
        ------------------------------------------------------------------
        {
            name = "a member announcing the campaign with no ordering is named",
            input = { op = "missing", announced = { "Matt", "Stewart", "Craig" },
                      members = { { player = "Matt", order = { "Matt" } },
                                  { player = "Craig", order = {} } } },
            expected = { "Craig", "Stewart" },
        },
        {
            name = "nobody is missing when everyone announcing has submitted",
            input = { op = "missing", announced = { "Matt" },
                      members = { { player = "Matt", order = { "Matt" } } } },
            expected = {},
        },
        {
            -- Out of a raid nobody is announcing, so nobody is reported missing
            -- merely for being offline.
            name = "nobody announcing means nobody is reported missing",
            input = { op = "missing", announced = {}, members = {} },
            expected = {},
        },
    },
}
