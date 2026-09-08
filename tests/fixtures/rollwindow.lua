-- tests/fixtures/rollwindow.lua
--
-- The pure half of UI/RollWindow.lua (spec 005): cell states and their reasons, the
-- submission an entry grid represents, the dirty check against host STATE, the
-- submitted counter, and the ordering of the detail panel and the results table.

local ns = ...

local function run(input, ns)
    local RW = ns.RollWindow

    if input.op == "cell" then
        local state = RW.CellState(input.info, input.char, input.tick, input.config)
        return {
            enterable = state.enterable, ticked = state.ticked, override = state.override,
            star = state.star, reason = state.reason or "", overridable = state.overridable,
            text = state.text or "",
        }

    elseif input.op == "entries" then
        local out = {}
        for i, e in ipairs(RW.LocalEntries(input.ticks, input.items)) do
            out[i] = string.format("%d/%s%s%s", e.itemIdx, e.char,
                e.override and "!" or "", e.star and "*" or "")
        end
        return out

    elseif input.op == "dirty" then
        local accepted = RW.AcceptedFor(input.entries, input.me)
        return { dirty = RW.IsDirty(input.localEntries, accepted, input.lastSent),
                 accepted = #accepted }

    elseif input.op == "outstanding" then
        local inCount, total, names = RW.Outstanding(input.expected, input.submitted)
        return { inCount = inCount, total = total, outstanding = table.concat(names, ",") }

    elseif input.op == "detail" then
        local out = {}
        for i, d in ipairs(RW.DetailRows(input.entries, input.isSK, input.priority)) do
            out[i] = string.format("T%d %s (%s) #%s", d.tier, d.char, d.owner or "?",
                tostring(d.listIdx or "?"))
        end
        return out

    elseif input.op == "results" then
        local t = RW.ResultTable(input.itemIdx, input.results, input.rolls, input.owners,
            input.isSK)
        local winners, rows = {}, {}
        for i, w in ipairs(t.winners) do
            winners[i] = string.format("%d:%s(%s)", w.copy, w.char, w.owner or "?")
        end
        for i, r in ipairs(t.rows) do
            local tierLabel = ns.Tiers.label(r.tier, input.tierCount or 3)
            rows[i] = string.format("%s %s(%s) %s%s", tierLabel, r.char, r.owner or "?",
                RW.RowText(r, input.isSK, tierLabel, r.wonItemIdx and ("item " .. r.wonItemIdx)),
                r.won and " WON" or "")
        end
        return { unclaimed = t.unclaimed, degraded = t.degraded, winners = winners, rows = rows }

    elseif input.op == "countdown" then
        return RW.FormatCountdown(input.seconds)

    elseif input.op == "median" then
        return RW.AboveMedian(input.position, input.present)
    end

    error("unknown op: " .. tostring(input.op))
end

local PLATE = { itemId = 40000, itemString = "item:40000", equipLoc = "INVTYPE_CHEST",
                armorSubclass = "PLATE" }
local TOKEN = { itemId = 40616, itemString = "item:40616", tokenGroup = "PROTECTOR",
                tokenClasses = { WARRIOR = true, HUNTER = true, SHAMAN = true } }
local STAFF = { itemId = 40001, itemString = "item:40001", equipLoc = "INVTYPE_2HWEAPON",
                weaponSubclass = "STAFF" }
local MOUNT = { itemId = 44083, itemString = "item:44083", special = true }

local function char(name, class, fields)
    local out = { name = name, class = class, present = true, contested = false }
    for k, v in pairs(fields or {}) do out[k] = v end
    return out
end

local ITEMS = { { idx = 1, itemString = "item:1", count = 1 },
                { idx = 2, itemString = "item:2", count = 2 } }

-- A resolved two-item batch: Steve took item 1 on a re-roll, item 2 had two copies.
local RESULTS = {
    { itemIdx = 1, winner = "Steve", tier = 1, roll = 83, outcome = "WON" },
    { itemIdx = 2, winner = "Bonk", tier = 1, roll = 60, outcome = "WON" },
    { itemIdx = 2, winner = "Sneaky", tier = 2, roll = 40, outcome = "WON" },
}
local ROLLS = {
    { itemIdx = 1, char = "Steve", tier = 1, roll = 83, listIdx = 0, status = "", rerolled = { 47, 90 } },
    { itemIdx = 1, char = "Chop", tier = 1, roll = 83, listIdx = 0, status = "", rerolled = { 47, 12 } },
    { itemIdx = 1, char = "Smash", tier = 3, roll = 0, listIdx = 0, status = "NC", rerolled = {} },
    { itemIdx = 2, char = "Bonk", tier = 1, roll = 60, listIdx = 0, status = "", rerolled = {} },
    { itemIdx = 2, char = "Sneaky", tier = 2, roll = 40, listIdx = 0, status = "", rerolled = {} },
    { itemIdx = 2, char = "Locky", tier = 2, roll = 15, listIdx = 0, status = "", rerolled = {} },
}
local OWNERS = { steve = "Steve", chop = "Dave", smash = "Steve", bonk = "Dave",
                 sneaky = "Steve", locky = "Steve" }

return {
    name = "rollwindow",
    run = run,
    cases = {
        ----------------------------------------------------------------------
        -- Cells (section 3)
        ----------------------------------------------------------------------
        {
            name = "a plate item is enterable by a warrior",
            input = { op = "cell", info = PLATE, char = char("Smash", "WARRIOR"),
                      config = { filterEnabled = true } },
            expected = { enterable = true, ticked = false, override = false, star = false,
                         reason = "", overridable = false, text = "" },
        },
        {
            -- Acceptance: a plate item disables cloth rows with a class-specific reason.
            name = "a plate item disables a mage with a class-specific reason",
            input = { op = "cell", info = PLATE, char = char("Steve", "MAGE"),
                      config = { filterEnabled = true } },
            expected = { enterable = false, ticked = false, override = false, star = false,
                         reason = "WRONG_ARMOR", overridable = true,
                         text = "Mages can't wear plate" },
        },
        {
            name = "a staff names the weapon type",
            input = { op = "cell", info = STAFF, char = char("Sneaky", "ROGUE"),
                      config = { filterEnabled = true } },
            expected = { enterable = false, ticked = false, override = false, star = false,
                         reason = "WRONG_WEAPON", overridable = true,
                         text = "Rogues can't use staves" },
        },
        {
            name = "a token refuses the wrong class",
            input = { op = "cell", info = TOKEN, char = char("Steve", "MAGE"),
                      config = { filterEnabled = true } },
            expected = { enterable = false, ticked = false, override = false, star = false,
                         reason = "WRONG_CLASS_TOKEN", overridable = true,
                         text = "Mages can't use this token" },
        },
        {
            -- Acceptance: right-clicking a WRONG_ARMOR cell enables it with the marker.
            name = "an override tick makes a WRONG_ARMOR cell enterable and marked",
            input = { op = "cell", info = PLATE, char = char("Steve", "MAGE"),
                      tick = { override = true }, config = { filterEnabled = true } },
            expected = { enterable = true, ticked = true, override = true, star = false,
                         reason = "", overridable = false,
                         text = "Entered with the eligibility filter overridden." },
        },
        {
            -- Acceptance: right-clicking a NOT_IN_RAID cell does nothing.
            name = "an absent character is not enterable and not overridable",
            input = { op = "cell", info = PLATE, char = char("Smash", "WARRIOR", { present = false }),
                      tick = { override = true }, config = { filterEnabled = true } },
            expected = { enterable = false, ticked = true, override = true, star = false,
                         reason = "NOT_IN_RAID", overridable = false,
                         text = "Smash is not in the raid" },
        },
        {
            name = "a contested character carries the contest reason",
            input = { op = "cell", info = PLATE,
                      char = char("Smash", "WARRIOR", { contested = true,
                          contestReason = "contested - Steve and Dave both claim Smash" }),
                      config = { filterEnabled = true } },
            expected = { enterable = false, ticked = false, override = false, star = false,
                         reason = "CONTESTED", overridable = false,
                         text = "contested - Steve and Dave both claim Smash" },
        },
        {
            name = "a special item is open to everyone, with the caveat shown",
            input = { op = "cell", info = MOUNT, char = char("Steve", "MAGE"),
                      config = { filterEnabled = true } },
            expected = { enterable = true, ticked = false, override = false, star = false,
                         reason = "", overridable = false,
                         text = "Eligibility filter off for this item - check yourself." },
        },
        {
            name = "the filter switched off admits a mage to plate",
            input = { op = "cell", info = PLATE, char = char("Steve", "MAGE"),
                      config = { filterEnabled = false } },
            expected = { enterable = true, ticked = false, override = false, star = false,
                         reason = "", overridable = false, text = "" },
        },
        {
            name = "an item still being looked up is enterable and says so",
            input = { op = "cell", info = nil, char = char("Steve", "MAGE"),
                      config = { filterEnabled = true } },
            expected = { enterable = true, ticked = false, override = false, star = false,
                         reason = "", overridable = false, text = "Still looking this item up." },
        },
        {
            name = "a starred tick is reported",
            input = { op = "cell", info = PLATE, char = char("Smash", "WARRIOR"),
                      tick = { star = true }, config = { filterEnabled = true } },
            expected = { enterable = true, ticked = true, override = false, star = true,
                         reason = "", overridable = false, text = "" },
        },

        ----------------------------------------------------------------------
        -- The submission and the dirty check (sections 3 and 4)
        ----------------------------------------------------------------------
        {
            name = "local entries are listed in item order then name order, with flags",
            input = { op = "entries", items = ITEMS, ticks = {
                [2] = { Sneaky = { star = true }, Bonk = {} },
                [1] = { Steve = { override = true } },
            } },
            expected = { "1/Steve!", "2/Bonk", "2/Sneaky*" },
        },
        {
            name = "no ticks is an empty submission",
            input = { op = "entries", items = ITEMS, ticks = {} },
            expected = {},
        },
        {
            -- Acceptance: submitting, then re-ticking, shows the dirty indicator.
            name = "a tick the host has not accepted is dirty",
            input = { op = "dirty", me = "Steve",
                      entries = { [1] = { { char = "Steve", owner = "Steve", tier = 1 } } },
                      localEntries = { { itemIdx = 1, char = "Steve" },
                                       { itemIdx = 2, char = "Sneaky" } } },
            expected = { dirty = true, accepted = 1 },
        },
        {
            name = "matching ticks and accepted entries are clean",
            input = { op = "dirty", me = "Steve",
                      entries = { [1] = { { char = "Steve", owner = "Steve", tier = 1 },
                                          { char = "Bonk", owner = "Dave", tier = 1 } },
                                  [2] = { { char = "sneaky", owner = "steve", tier = 2 } } },
                      localEntries = { { itemIdx = 2, char = "Sneaky" },
                                       { itemIdx = 1, char = "Steve" } } },
            expected = { dirty = false, accepted = 2 },
        },
        {
            -- Acceptance: pass all marks the player as submitted with zero entries.
            name = "an empty submission against no accepted entries is clean",
            input = { op = "dirty", me = "Steve", entries = {}, localEntries = {} },
            expected = { dirty = false, accepted = 0 },
        },
        {
            -- STATE cannot carry a star, so a moved star is judged against the last SUBMIT.
            name = "a moved star is dirty even though the accepted pairs match",
            input = { op = "dirty", me = "Steve",
                      entries = { [1] = { { char = "Steve", owner = "Steve", tier = 1 } },
                                  [2] = { { char = "Steve", owner = "Steve", tier = 1 } } },
                      lastSent = { { itemIdx = 1, char = "Steve", star = true },
                                   { itemIdx = 2, char = "Steve" } },
                      localEntries = { { itemIdx = 1, char = "Steve" },
                                       { itemIdx = 2, char = "Steve", star = true } } },
            expected = { dirty = true, accepted = 2 },
        },
        {
            name = "unchanged flags against the last submit are clean",
            input = { op = "dirty", me = "Steve",
                      entries = { [1] = { { char = "Steve", owner = "Steve", tier = 1 } } },
                      lastSent = { { itemIdx = 1, char = "Steve", override = true } },
                      localEntries = { { itemIdx = 1, char = "Steve", override = true } } },
            expected = { dirty = false, accepted = 1 },
        },
        {
            name = "the counter names who is still out",
            input = { op = "outstanding", expected = { "Steve", "Dave", "Anna" },
                      submitted = { Dave = true } },
            expected = { inCount = 1, total = 3, outstanding = "Anna,Steve" },
        },

        ----------------------------------------------------------------------
        -- The detail panel (section 3)
        ----------------------------------------------------------------------
        {
            name = "under ROLL the panel groups by tier, then owner, then name",
            input = { op = "detail", isSK = false, entries = {
                { char = "Locky", owner = "Steve", tier = 4 },
                { char = "Sneaky", owner = "Steve", tier = 2 },
                { char = "Bonk", owner = "Dave", tier = 1 },
                { char = "Ash", owner = "Anna", tier = 2 },
            } },
            expected = { "T1 Bonk (Dave) #?", "T2 Ash (Anna) #?", "T2 Sneaky (Steve) #?",
                         "T4 Locky (Steve) #?" },
        },
        {
            name = "under SK the panel orders a tier by list position, unknown last",
            input = { op = "detail", isSK = true,
                      priority = { Sneaky = 3, Ash = 9 },
                      entries = {
                          { char = "Zed", owner = "Anna", tier = 2 },
                          { char = "Ash", owner = "Anna", tier = 2 },
                          { char = "Sneaky", owner = "Steve", tier = 2 },
                      } },
            expected = { "T2 Sneaky (Steve) #3", "T2 Ash (Anna) #9", "T2 Zed (Anna) #?" },
        },

        ----------------------------------------------------------------------
        -- The results table (section 5)
        ----------------------------------------------------------------------
        {
            -- Acceptance: not-consulted entries show as such, not as losses; re-rolls inline.
            name = "a re-rolled win and a not-consulted entry are both explicit",
            input = { op = "results", itemIdx = 1, results = RESULTS, rolls = ROLLS,
                      owners = OWNERS, isSK = false },
            expected = {
                unclaimed = false, degraded = false,
                winners = { "1:Steve(Steve)" },
                rows = { "T1 Steve(Steve) 83 -> 47 -> 90 (tie re-roll) WON",
                         "T1 Chop(Dave) 83 -> 47 -> 12 (tie re-roll)",
                         "T3 Smash(Steve) T3 - not consulted" },
            },
        },
        {
            name = "two copies list both winners in copy order and sort rolls descending",
            input = { op = "results", itemIdx = 2, results = RESULTS, rolls = ROLLS,
                      owners = OWNERS, isSK = false },
            expected = {
                unclaimed = false, degraded = false,
                winners = { "1:Bonk(Dave)", "2:Sneaky(Steve)" },
                rows = { "T1 Bonk(Dave) 60 WON", "T2 Sneaky(Steve) 40 WON", "T2 Locky(Steve) 15" },
            },
        },
        {
            -- Between RESULT and ROLLS arriving: the winner is known, the table is not.
            name = "a result with no roll record yet lists the winner and no rows",
            input = { op = "results", itemIdx = 1, results = RESULTS, rolls = nil,
                      owners = OWNERS, isSK = false },
            expected = { unclaimed = false, degraded = false,
                         winners = { "1:Steve(Steve)" }, rows = {} },
        },
        {
            -- Under ROLL items are independent: a character can win two, and its row
            -- on the second is a win, never "withdrawn".
            name = "under ROLL a character winning two items is not withdrawn from either",
            input = { op = "results", itemIdx = 2, isSK = false, owners = OWNERS,
                      results = { { itemIdx = 1, winner = "Steve", tier = 1, roll = 90, outcome = "WON" },
                                  { itemIdx = 2, winner = "Steve", tier = 1, roll = 70, outcome = "WON" } },
                      rolls = { { itemIdx = 2, char = "Steve", tier = 1, roll = 70, listIdx = 0, status = "", rerolled = {} },
                                { itemIdx = 2, char = "Chop", tier = 1, roll = 20, listIdx = 0, status = "", rerolled = {} } } },
            expected = { unclaimed = false, degraded = false, winners = { "1:Steve(Steve)" },
                         rows = { "T1 Steve(Steve) 70 WON", "T1 Chop(Dave) 20" } },
        },
        {
            name = "an unclaimed item says so",
            input = { op = "results", itemIdx = 3,
                      results = { { itemIdx = 3, winner = nil, tier = 0, roll = 0,
                                    outcome = "UNCLAIMED" } },
                      rolls = {}, owners = OWNERS, isSK = false },
            expected = { unclaimed = true, degraded = false, winners = {}, rows = {} },
        },
        {
            name = "a degraded outcome is flagged",
            input = { op = "results", itemIdx = 1,
                      results = { { itemIdx = 1, winner = "Steve", tier = 1, roll = 50,
                                    outcome = "DEGRADED" } },
                      rolls = { { itemIdx = 1, char = "Steve", tier = 1, roll = 50, listIdx = 0,
                                  status = "", rerolled = {} } },
                      owners = OWNERS, isSK = false },
            expected = { unclaimed = false, degraded = true, winners = { "1:Steve(Steve)" },
                         rows = { "T1 Steve(Steve) 50 WON" } },
        },
        {
            -- Spec 010 section 11: positions instead of rolls, "-> bottom" on the winner,
            -- and a withdrawn entry named with what it won instead.
            name = "under SK rows show positions, the winner drops, a withdrawn entry says why",
            input = { op = "results", itemIdx = 2, isSK = true, owners = OWNERS,
                      results = { { itemIdx = 1, winner = "Steve", tier = 1, roll = 0, outcome = "WON" },
                                  { itemIdx = 2, winner = "Bonk", tier = 1, roll = 0, outcome = "WON" } },
                      rolls = {
                          { itemIdx = 2, char = "Steve", tier = 1, roll = 0, listIdx = 2, status = "WD", rerolled = {} },
                          { itemIdx = 2, char = "Chop", tier = 1, roll = 0, listIdx = 7, status = "", rerolled = {} },
                          { itemIdx = 2, char = "Bonk", tier = 1, roll = 0, listIdx = 4, status = "", rerolled = {} },
                      } },
            expected = {
                unclaimed = false, degraded = false,
                winners = { "1:Bonk(Dave)" },
                rows = { "T1 Bonk(Dave) position 4 -> bottom WON",
                         "T1 Chop(Dave) position 7",
                         "T1 Steve(Steve) withdrawn (won item 1)" },
            },
        },

        ----------------------------------------------------------------------
        -- Small helpers
        ----------------------------------------------------------------------
        {
            name = "the countdown formats minutes and seconds",
            input = { op = "countdown", seconds = 161.4 },
            expected = "2:41",
        },
        {
            name = "a negative countdown clamps to zero",
            input = { op = "countdown", seconds = -3 },
            expected = "0:00",
        },
        {
            name = "a position at or above the present median is near the top",
            input = { op = "median", position = 5, present = { 12, 3, 5, 20, 9 } },
            expected = true,
        },
        {
            name = "a position below the present median is not",
            input = { op = "median", position = 12, present = { 12, 3, 5, 20, 9 } },
            expected = false,
        },
    },
}
