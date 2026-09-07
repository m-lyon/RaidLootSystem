-- tests/fixtures/priority.lua
--
-- Core/PriorityList.lua and the pure half of Modules/PriorityList.lua (spec 010
-- sections 4, 5, 6, 8 and 12): seeding, suicide with absentees, restore, roster
-- churn, replay, and the stored list's mutation and verification.

local ns = ...

local function run(input, ns)
    local PL = ns.PriorityList
    local P = ns.Priority

    if input.op == "seed" then
        return PL.seed(input.chars, PL.rngFrom(input.seed))
    elseif input.op == "seedTwice" then
        local a = PL.seed(input.chars, PL.rngFrom(input.seed))
        local b = PL.seed(input.chars, PL.rngFrom(input.seed))
        return { identical = table.concat(a, ",") == table.concat(b, ","), first = a }
    elseif input.op == "suicide" then
        local order, prior, present = PL.suicide(input.order, input.char, input.present)
        return { order = order, prior = prior, present = present,
                 untouched = table.concat(input.order, ",") == table.concat(input.original or input.order, ",") }
    elseif input.op == "roundtrip" then
        local after, prior, present = PL.suicide(input.order, input.char, input.present)
        local back = PL.restore(after, input.char, prior, present)
        return { after = after, back = back }
    elseif input.op == "restoreFails" then
        local order, why = PL.restore(input.order, input.char, input.index, input.present)
        return { order = order, why = why or "" }
    elseif input.op == "restoreNow" then
        local order, present, why = PL.restoreNow(input.order, input.char, input.index, input.present)
        return { order = order, present = present, why = why or "" }
    elseif input.op == "restoreLater" then
        -- Suicide with one present set, restore after the raid has changed.
        local after, prior, present = PL.suicide(input.order, input.char, input.present)
        local back = PL.restore(after, input.char, prior, present)
        return back
    elseif input.op == "add" then
        return PL.addChar(input.order, input.char)
    elseif input.op == "remove" then
        return PL.removeChar(input.order, input.char)
    elseif input.op == "readd" then
        return PL.addChar(PL.removeChar(input.order, input.char), input.char)
    elseif input.op == "all" then
        local order, events = PL.suicideAll(input.order, input.awards, input.present)
        local names = {}
        for i, e in ipairs(events) do names[i] = e.char .. ":" .. e.from .. "->" .. e.to end
        return { order = order, events = names }
    elseif input.op == "replay" then
        local order, problems = PL.replay(input.seed, input.chars, input.events)
        return { order = order, problems = #problems }
    elseif input.op == "bigReplay" then
        -- 200 suicides over 25 characters, everyone present: the replay must
        -- reproduce the list produced by applying them live.
        local chars = {}
        for i = 1, 25 do chars[i] = string.format("C%02d", i) end
        local rng = PL.rngFrom(99)
        local present = {}
        for _, c in ipairs(chars) do present[c:lower()] = true end
        local live = PL.seed(chars, PL.rngFrom(input.seed))
        local events = {}
        for v = 1, 200 do
            local winner = live[rng(1, #live)]
            local after, from, pres = PL.suicide(live, winner, present)
            events[v] = { kind = "suicide", char = winner, from = from, present = pres, version = v }
            live = after
        end
        local replayed, problems = PL.replay(input.seed, chars, events)
        return { identical = table.concat(live, ",") == table.concat(replayed, ","),
                 problems = #problems }
    elseif input.op == "diff" then
        local out = {}
        for i, d in ipairs(PL.diff(input.a, input.b)) do
            out[i] = d.index .. ":" .. tostring(d.stored) .. "/" .. tostring(d.replayed)
        end
        return out
    elseif input.op == "mutate" then
        local priority = input.priority
        for _, e in ipairs(input.events) do
            local next_, why = P.Mutate(priority, e)
            if not next_ then return { failed = why } end
            priority = next_
        end
        local kinds = {}
        for i, e in ipairs(priority.log) do kinds[i] = e.version .. ":" .. e.kind end
        return { version = priority.version, seed = priority.seed, order = priority.order, log = kinds }
    elseif input.op == "verify" then
        local r = P.Verify(input.priority)
        local drift = {}
        for i, d in ipairs(r.drift) do drift[i] = d.index end
        return { ok = r.ok, drift = drift, why = r.why or "" }
    elseif input.op == "action" then
        return P.DeliveryAction(input.record) or ""
    elseif input.op == "candidates" then
        return P.SeedCandidates(input.claims)
    elseif input.op == "differs" then
        return P.Differs(input.stored, input.received)

    elseif input.op == "median" then
        return PL.aboveMedian(input.position, input.present)
    elseif input.op == "medianAgrees" then
        -- 005 kept the name; 011 moved the rule. They must not drift apart.
        local same = true
        for position = 1, input.upTo do
            if PL.aboveMedian(position, input.present)
                ~= ns.RollWindow.AboveMedian(position, input.present) then
                same = false
            end
        end
        return same
    elseif input.op == "viewRows" then
        local out = {}
        for i, row in ipairs(PL.viewRows(input.order, input.ctx)) do
            out[i] = string.format("%d %s %s%s%s%s", row.position, row.char,
                row.owner or "unclaimed",
                row.isSelf and " self" or "",
                row.contested and " contested" or "",
                row.present and (row.aboveMedian and " top" or " here") or " absent")
        end
        return out
    end
    error("unknown op: " .. tostring(input.op))
end

local ORDER = { "Ann", "Bob", "Cat", "Dan", "Eve" }
local ALL = { ann = true, bob = true, cat = true, dan = true, eve = true }
-- Bob and Dan are at home.
local SOME = { ann = true, cat = true, eve = true }

return {
    name = "priority",
    run = run,
    cases = {
        ----------------------------------------------------------------------
        -- Seeding (section 5)
        ----------------------------------------------------------------------
        {
            -- Acceptance: seed with a scripted rng produces a byte-identical order.
            name = "the same seed over the same characters gives the same order, twice",
            input = { op = "seedTwice", seed = 1757155200, chars = ORDER },
            expected = { identical = true, first = { "Eve", "Dan", "Cat", "Ann", "Bob" } },
        },
        {
            name = "a different seed gives a different order",
            input = { op = "seed", seed = 7, chars = ORDER },
            expected = { "Cat", "Bob", "Ann", "Dan", "Eve" },
        },
        {
            name = "seeding an empty list is empty",
            input = { op = "seed", seed = 7, chars = {} },
            expected = {},
        },

        ----------------------------------------------------------------------
        -- Suicide (section 6)
        ----------------------------------------------------------------------
        {
            name = "with everyone present the winner drops to the bottom and the rest move up",
            input = { op = "suicide", order = ORDER, char = "Bob", present = ALL },
            expected = { order = { "Ann", "Cat", "Dan", "Eve", "Bob" }, prior = 2,
                         present = { 1, 2, 3, 4, 5 }, untouched = true },
        },
        {
            -- Acceptance: absent characters keep their absolute index; the present
            -- characters between shift up exactly one.
            name = "absent characters hold their index; only present ones rotate",
            input = { op = "suicide", order = ORDER, char = "Ann", present = SOME },
            expected = { order = { "Cat", "Bob", "Eve", "Dan", "Ann" }, prior = 1,
                         present = { 1, 3, 5 }, untouched = true },
        },
        {
            -- Acceptance: a winner already last among the present is a no-op.
            name = "a winner already at the last present index does not move",
            input = { op = "suicide", order = ORDER, char = "Eve", present = SOME },
            expected = { order = { "Ann", "Bob", "Cat", "Dan", "Eve" }, prior = 5,
                         present = { 1, 3, 5 }, untouched = true },
        },
        {
            name = "a winner the presence cache missed still moves",
            input = { op = "suicide", order = ORDER, char = "Cat", present = { ann = true, eve = true } },
            expected = { order = { "Ann", "Bob", "Eve", "Dan", "Cat" }, prior = 3,
                         present = { 1, 3, 5 }, untouched = true },
        },
        {
            name = "a character not on the list changes nothing",
            input = { op = "suicide", order = ORDER, char = "Zed", present = ALL },
            expected = { order = ORDER, untouched = true },
        },
        {
            name = "names compare case-insensitively",
            input = { op = "suicide", order = ORDER, char = "bob", present = ALL },
            expected = { order = { "Ann", "Cat", "Dan", "Eve", "Bob" }, prior = 2,
                         present = { 1, 2, 3, 4, 5 }, untouched = true },
        },

        ----------------------------------------------------------------------
        -- Restore (section 6)
        ----------------------------------------------------------------------
        {
            -- Acceptance: restore after a suicide returns the exact prior order.
            name = "restore is the exact inverse of a suicide with absentees",
            input = { op = "roundtrip", order = ORDER, char = "Ann", present = SOME },
            expected = { after = { "Cat", "Bob", "Eve", "Dan", "Ann" }, back = ORDER },
        },
        {
            name = "restore is the exact inverse with everyone present",
            input = { op = "roundtrip", order = ORDER, char = "Cat", present = ALL },
            expected = { after = { "Ann", "Bob", "Dan", "Eve", "Cat" }, back = ORDER },
        },
        {
            -- The present indices recorded at the suicide drive the restore, so the
            -- raid changing in between does not change the answer.
            name = "restore uses the indices the suicide used, whoever is present now",
            input = { op = "restoreLater", order = ORDER, char = "Ann", present = SOME },
            expected = ORDER,
        },

        {
            -- The review case. Ann suicides from 1 with Bob and Dan at home and lands at
            -- 5; Cat (now at 1) wins the next batch with everyone present, which shifts
            -- Ann to 4; Ann's trade expires. The recorded indices {1,3,5} no longer
            -- cover Ann, and restore must say so rather than do nothing.
            name = "restore refuses when the list has moved since the suicide",
            input = { op = "restoreFails", char = "Ann", index = 1, present = { 1, 3, 5 },
                      -- after Ann's suicide: Cat Bob Eve Dan Ann; after Cat's with everyone:
                      order = { "Bob", "Eve", "Dan", "Ann", "Cat" } },
            expected = { why = "Ann is now at 4, which the recorded present indices do not cover" },
        },
        {
            name = "restore refuses a character that is not on the list",
            input = { op = "restoreFails", char = "Zed", index = 1, present = { 1, 2 }, order = ORDER },
            expected = { why = "Zed is not on the list" },
        },
        {
            name = "restore to the index a character already holds is a no-op",
            input = { op = "restoreFails", char = "Ann", index = 1, present = { 1, 2 }, order = ORDER },
            expected = { order = ORDER, why = "" },
        },
        {
            -- The fallback: against today's raid (everyone present), Ann returns to 1 and
            -- the present characters between shift down.
            name = "restoreNow restores against the current raid",
            input = { op = "restoreNow", char = "Ann", index = 1, present = ALL,
                      order = { "Bob", "Eve", "Dan", "Ann", "Cat" } },
            expected = { order = { "Ann", "Bob", "Eve", "Dan", "Cat" }, present = { 1, 2, 3, 4, 5 }, why = "" },
        },
        {
            name = "restoreNow keeps absent characters in place and includes the target index",
            input = { op = "restoreNow", char = "Ann", index = 2, present = { ann = true, eve = true },
                      order = { "Bob", "Cat", "Eve", "Dan", "Ann" } },
            -- present indices {2, 3, 5} (2 is the target, Bob is absent); Ann to 2,
            -- Cat to 3, Eve to 5.
            expected = { order = { "Bob", "Ann", "Cat", "Dan", "Eve" }, present = { 2, 3, 5 }, why = "" },
        },
        {
            name = "restoreNow refuses to move a character down",
            input = { op = "restoreNow", char = "Ann", index = 3, present = ALL, order = ORDER },
            expected = { why = "Ann is already at or above 3" },
        },
        {
            name = "a replayed restore that no longer fits is reported, not skipped silently",
            input = { op = "replay", seed = 1757155200, chars = ORDER, events = {
                { kind = "restore", char = "Ann", to = 1, present = { 1, 3, 5 }, version = 2 },
            } },
            expected = { order = { "Eve", "Dan", "Cat", "Ann", "Bob" }, problems = 1 },
        },

        ----------------------------------------------------------------------
        -- Roster churn (section 4)
        ----------------------------------------------------------------------
        {
            name = "addChar appends",
            input = { op = "add", order = ORDER, char = "Fay" },
            expected = { "Ann", "Bob", "Cat", "Dan", "Eve", "Fay" },
        },
        {
            name = "addChar of a listed character is a no-op",
            input = { op = "add", order = ORDER, char = "cat" },
            expected = ORDER,
        },
        {
            name = "removeChar closes the gap",
            input = { op = "remove", order = ORDER, char = "Cat" },
            expected = { "Ann", "Bob", "Dan", "Eve" },
        },
        {
            -- Acceptance: a removed and re-added character lands at the bottom.
            name = "a removed and re-added character lands at the bottom",
            input = { op = "readd", order = ORDER, char = "Bob" },
            expected = { "Ann", "Cat", "Dan", "Eve", "Bob" },
        },

        ----------------------------------------------------------------------
        -- A batch's suicides (section 7)
        ----------------------------------------------------------------------
        {
            name = "suicides apply once per winner in award order",
            input = { op = "all", order = ORDER, present = ALL,
                      awards = { { itemIdx = 1, copy = 1, char = "Bob" },
                                 { itemIdx = 2, copy = 1, char = "Ann" },
                                 { itemIdx = 2, copy = 2, char = "Bob" } } },
            expected = { order = { "Cat", "Dan", "Eve", "Bob", "Ann" },
                         events = { "Bob:2->5", "Ann:1->5" } },
        },

        ----------------------------------------------------------------------
        -- Replay and verify (section 8)
        ----------------------------------------------------------------------
        {
            name = "replay reproduces seed, suicide, restore, move, add and remove",
            input = { op = "replay", seed = 1757155200, chars = ORDER, events = {
                { kind = "suicide", char = "Eve", from = 1, present = { 1, 2, 3, 4, 5 } },
                { kind = "add", char = "Fay" },
                { kind = "move", from = 6, to = 1 },
                { kind = "remove", char = "Bob" },
                { kind = "restore", char = "Eve", to = 1, present = { 1, 2, 3, 4, 5 } },
            } },
            -- seed -> Eve Dan Cat Ann Bob; suicide Eve -> Dan Cat Ann Bob Eve; add Fay;
            -- move Fay to 1 -> Fay Dan Cat Ann Bob Eve; remove Bob -> Fay Dan Cat Ann Eve;
            -- restore Eve to 1 with present {1..5} -> Eve Fay Dan Cat Ann
            expected = { order = { "Eve", "Fay", "Dan", "Cat", "Ann" }, problems = 0 },
        },
        {
            -- Acceptance: replay reproduces the stored order for a 200-event history.
            name = "replay reproduces a 200-suicide history over 25 characters",
            input = { op = "bigReplay", seed = 424242 },
            expected = { identical = true, problems = 0 },
        },
        {
            name = "a suicide event whose character is not where it says is reported",
            input = { op = "replay", seed = 1757155200, chars = ORDER, events = {
                { kind = "suicide", char = "Cat", from = 1, present = { 1, 2, 3, 4, 5 }, version = 2 },
            } },
            expected = { order = { "Eve", "Dan", "Cat", "Ann", "Bob" }, problems = 1 },
        },
        {
            -- Acceptance: verify detects a single transposed pair.
            name = "diff finds a transposed pair",
            input = { op = "diff", a = { "A", "B", "C", "D" }, b = { "A", "C", "B", "D" } },
            expected = { "2:B/C", "3:C/B" },
        },
        {
            name = "Mutate seeds, logs and bumps the version",
            input = { op = "mutate", priority = { version = 0, seed = 0, order = {}, log = {} },
                      events = { { kind = "seed", seed = 1757155200, chars = ORDER },
                                 { kind = "suicide", char = "Eve", from = 1, present = { 1, 2, 3, 4, 5 } } } },
            expected = { version = 2, seed = 1757155200, order = { "Dan", "Cat", "Ann", "Bob", "Eve" },
                         log = { "1:seed", "2:suicide" } },
        },
        {
            name = "a reseed starts the log over",
            input = { op = "mutate",
                      priority = { version = 5, seed = 1, seedChars = ORDER, order = ORDER,
                                   log = { { version = 1, kind = "seed" }, { version = 5, kind = "move" } } },
                      events = { { kind = "seed", seed = 7, chars = ORDER } } },
            expected = { version = 6, seed = 7, order = { "Cat", "Bob", "Ann", "Dan", "Eve" },
                         log = { "6:seed" } },
        },
        {
            name = "verify passes when the stored order matches its replay",
            input = { op = "verify", priority = {
                version = 2, seed = 1757155200, seedChars = ORDER,
                order = { "Dan", "Cat", "Ann", "Bob", "Eve" },
                log = { { version = 1, kind = "seed", seed = 1757155200, chars = ORDER },
                        { version = 2, kind = "suicide", char = "Eve", from = 1, present = { 1, 2, 3, 4, 5 } } },
            } },
            expected = { ok = true, drift = {}, why = "" },
        },
        {
            -- Acceptance: verify detects a single transposed pair in the stored list.
            name = "verify reports a transposed pair and does not repair it",
            input = { op = "verify", priority = {
                version = 2, seed = 1757155200, seedChars = ORDER,
                order = { "Dan", "Cat", "Bob", "Ann", "Eve" },
                log = { { version = 1, kind = "seed", seed = 1757155200, chars = ORDER },
                        { version = 2, kind = "suicide", char = "Eve", from = 1, present = { 1, 2, 3, 4, 5 } } },
            } },
            expected = { ok = false, drift = { 3, 4 }, why = "" },
        },
        {
            name = "verify on an unseeded list says so",
            input = { op = "verify", priority = { version = 0, seed = 0, order = {}, log = {} } },
            expected = { ok = false, drift = {}, why = "the list has never been seeded" },
        },

        ----------------------------------------------------------------------
        -- Delivery and the list (section 6), seeding candidates, sync
        ----------------------------------------------------------------------
        {
            -- Acceptance: an award flipped to a terminal failure restores the winner.
            name = "a lost item restores",
            input = { op = "action", record = { priorIndex = 3, delivery = "LOST" } },
            expected = "restore",
        },
        { name = "an expired trade restores",
          input = { op = "action", record = { priorIndex = 3, delivery = "FAILED", failure = "TRADE_EXPIRED" } },
          expected = "restore" },
        { name = "a retryable failure keeps the suicide",
          input = { op = "action", record = { priorIndex = 3, delivery = "FAILED", failure = "NOT_A_CANDIDATE" } },
          expected = "" },
        { name = "a pending trade keeps the suicide",
          input = { op = "action", record = { priorIndex = 3, delivery = "PENDING" } },
          expected = "" },
        { name = "a delivery after a restore suicides again",
          input = { op = "action", record = { priorIndex = 3, delivery = "DELIVERED", restored = true } },
          expected = "suicide" },
        { name = "a restore is not repeated",
          input = { op = "action", record = { priorIndex = 3, delivery = "LOST", restored = true } },
          expected = "" },
        { name = "a ROLL award (no prior index) never moves the list",
          input = { op = "action", record = { delivery = "LOST" } },
          expected = "" },
        {
            name = "seed candidates are every uncontested claim, sorted",
            input = { op = "candidates", claims = {
                sneaky = { name = "Sneaky", owners = { "Steve" }, contested = false },
                bonk = { name = "Bonk", owners = { "Dave", "Anna" }, contested = true },
                chop = { name = "Chop", owners = { "Dave" }, contested = false },
                ann = { name = "ann", owners = { "Anna" }, contested = false },
            } },
            expected = { "ann", "Chop", "Sneaky" },
        },
        {
            -- Acceptance: a client one version behind replaces its list wholesale.
            name = "a received list with another version differs",
            input = { op = "differs", stored = { version = 3, order = ORDER }, received = { version = 4, order = ORDER } },
            expected = true,
        },
        { name = "the same version and order does not differ",
          input = { op = "differs", stored = { version = 3, order = ORDER }, received = { version = 3, order = { "Ann", "Bob", "Cat", "Dan", "Eve" } } },
          expected = false },
        ----------------------------------------------------------------------
        -- The viewer (spec 011 sections 4 and 8)
        ----------------------------------------------------------------------
        {
            -- Six of ten absent: the median is over the four who are here, at
            -- positions 2, 4, 6 and 8, so it sits at 4 and rows 1-4 are "top".
            name = "the median is taken over present positions only",
            input = { op = "viewRows", order = { "C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8", "C9", "C10" }, ctx = {
                present = { C2 = true, C4 = true, C6 = true, C8 = true },
                owners = { C2 = "Steve", C4 = "Dave" }, me = "steve",
                contested = { C4 = true },
            } },
            expected = {
                "1 C1 unclaimed absent", "2 C2 Steve self top", "3 C3 unclaimed absent",
                "4 C4 Dave contested top", "5 C5 unclaimed absent", "6 C6 unclaimed here",
                "7 C7 unclaimed absent", "8 C8 unclaimed here", "9 C9 unclaimed absent",
                "10 C10 unclaimed absent",
            },
        },
        { name = "an empty order gives no rows rather than erroring",
          input = { op = "viewRows", order = {}, ctx = {} },
          expected = {} },
        { name = "no ctx at all still reports every position, unclaimed and absent",
          input = { op = "viewRows", order = { "Ann", "Bob" } },
          expected = { "1 Ann unclaimed absent", "2 Bob unclaimed absent" } },
        { name = "an odd present-count puts the median on the middle position",
          input = { op = "median", position = 3, present = { 1, 3, 5 } },
          expected = true },
        { name = "the position below an odd median is not near the top",
          input = { op = "median", position = 5, present = { 1, 3, 5 } },
          expected = false },
        { name = "an even present-count takes the lower of the two middle positions",
          input = { op = "median", position = 4, present = { 2, 4, 6, 8 } },
          expected = true },
        { name = "the upper middle of an even present-count is not near the top",
          input = { op = "median", position = 6, present = { 2, 4, 6, 8 } },
          expected = false },
        { name = "nobody present means nothing is near the top",
          input = { op = "median", position = 1, present = {} },
          expected = false },
        { name = "the roll window and the core rule agree at every position",
          input = { op = "medianAgrees", upTo = 12, present = { 2, 3, 5, 8, 11 } },
          expected = true },

        { name = "the same version with another order differs",
          input = { op = "differs", stored = { version = 3, order = ORDER }, received = { version = 3, order = { "Bob", "Ann", "Cat", "Dan", "Eve" } } },
          expected = true },
    },
}
