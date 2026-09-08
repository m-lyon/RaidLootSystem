-- tests/fixtures/roster.lua
--
-- The pure half of Modules/Roster.lua: invariants, the claim index, and
-- export/import. Spec 001 sections 2, 5 and 8.

local ns = ...

local function run(input, ns)
    local Roster = ns.Roster

    if input.kind == "validate" then
        local ok, why = Roster.Validate(input.order, input.chars)
        return { ok = ok == true, why = why }

    elseif input.kind == "claims" then
        local claims = Roster.BuildClaims(input.published)
        local out = {}
        for key, claim in pairs(claims) do
            out[key] = { owners = claim.owners, contested = claim.contested }
        end
        return out

    elseif input.kind == "contestReason" then
        local claims = Roster.BuildClaims(input.published)
        return Roster.ContestReason(claims[input.name])

    elseif input.kind == "roundTrip" then
        -- Export -> wipe -> import reproduces the roster exactly (section 9).
        local text, err = Roster.Encode(input.order, input.chars)
        if not text then return { ok = false, err = err } end
        local order, chars = Roster.ParseImport(text)
        if not order then return { ok = false, err = chars } end
        local classes = {}
        for i = 1, #order do classes[i] = chars[order[i]].class end
        return { ok = true, text = text, order = order, classes = classes }

    elseif input.kind == "markSelf" then
        local chars = {}
        for name, entry in pairs(input.chars) do chars[name] = { isSelf = entry.isSelf } end
        local changed = Roster.MarkSelf(chars, input.player)
        local marked = {}
        for name, entry in pairs(chars) do
            if entry.isSelf then marked[#marked + 1] = name end
        end
        table.sort(marked)
        return { changed = changed, marked = marked }

    elseif input.kind == "import" then
        -- On success the second return is the chars map, not a reason.
        local order, second = Roster.ParseImport(input.text)
        local why
        if not order then why = second end
        return { ok = order ~= nil, count = order and #order or 0, why = why }
    end
    return nil
end

local STEVE = {
    order = { "Steve", "Sneaky", "Smash" },
    chars = { Steve = { class = "MAGE", isSelf = true },
              Sneaky = { class = "ROGUE", isSelf = false },
              Smash = { class = "WARRIOR", isSelf = false } },
}

return {
    name = "roster",
    run = run,
    cases = {
        -- Invariants, section 2.
        {
            name = "a well-formed roster validates",
            input = { kind = "validate", order = STEVE.order, chars = STEVE.chars },
            expected = { ok = true },
        },
        {
            name = "a duplicate name is rejected",
            input = {
                kind = "validate",
                order = { "Steve", "steve" },
                chars = { Steve = { class = "MAGE" }, steve = { class = "MAGE" } },
            },
            expected = { ok = false, why = "duplicate character: steve" },
        },
        {
            name = "a name with no class entry is rejected",
            input = { kind = "validate", order = { "Steve" }, chars = {} },
            expected = { ok = false, why = "no class recorded for Steve" },
        },
        {
            name = "a class entry with no position is rejected",
            input = {
                kind = "validate",
                order = { "Steve" },
                chars = { Steve = { class = "MAGE" }, Ghost = { class = "PRIEST" } },
            },
            expected = { ok = false, why = "Ghost has a class but no position in the order" },
        },
        {
            name = "an unknown class is rejected",
            input = {
                kind = "validate",
                order = { "Steve" },
                chars = { Steve = { class = "Mage" } },
            },
            expected = { ok = false, why = "unknown class for Steve: Mage" },
        },
        {
            name = "two characters marked as your own is rejected",
            input = {
                kind = "validate",
                order = { "Steve", "Sneaky" },
                chars = { Steve = { class = "MAGE", isSelf = true },
                          Sneaky = { class = "ROGUE", isSelf = true } },
            },
            expected = { ok = false, why = "more than one character is marked as your own" },
        },
        {
            name = "an empty roster validates",
            input = { kind = "validate", order = {}, chars = {} },
            expected = { ok = true },
        },

        -- The "you" marker follows the character being played, section 2.
        {
            name = "logging in on an alt moves the you marker onto it",
            input = { kind = "markSelf", player = "Sneaky",
                      chars = { Steve = { isSelf = true }, Sneaky = { isSelf = false },
                                Smash = { isSelf = false } } },
            expected = { changed = true, marked = { "Sneaky" } },
        },
        {
            name = "the marker is matched case-insensitively and reports no change",
            input = { kind = "markSelf", player = "steve",
                      chars = { Steve = { isSelf = true }, Sneaky = { isSelf = false } } },
            expected = { changed = false, marked = { "Steve" } },
        },
        {
            name = "a character outside the roster leaves nobody marked",
            input = { kind = "markSelf", player = "Ghost",
                      chars = { Steve = { isSelf = true }, Sneaky = { isSelf = false } } },
            expected = { changed = true, marked = {} },
        },
        {
            name = "a roster that never had a marker gains one",
            input = { kind = "markSelf", player = "Smash",
                      chars = { Steve = {}, Smash = {} } },
            expected = { changed = true, marked = { "Smash" } },
        },

        -- The claim index, section 5.
        {
            name = "one owner per character leaves nothing contested",
            input = {
                kind = "claims",
                published = { Steve = { order = { "Steve", "Sneaky" } },
                              Dave = { order = { "Dave", "Locky" } } },
            },
            expected = {
                steve  = { owners = { "Steve" }, contested = false },
                sneaky = { owners = { "Steve" }, contested = false },
                dave   = { owners = { "Dave" }, contested = false },
                locky  = { owners = { "Dave" }, contested = false },
            },
        },
        {
            name = "two players claiming one character contests it for both",
            input = {
                kind = "claims",
                published = { Steve = { order = { "Sneaky" } },
                              Dave = { order = { "Sneaky" } } },
            },
            expected = { sneaky = { owners = { "Dave", "Steve" }, contested = true } },
        },
        {
            name = "a claim differing only in capitalisation still contests",
            input = {
                kind = "claims",
                published = { Steve = { order = { "Sneaky" } },
                              Dave = { order = { "sneaky" } } },
            },
            expected = { sneaky = { owners = { "Dave", "Steve" }, contested = true } },
        },
        {
            name = "the contested reason names both claimants",
            input = {
                kind = "contestReason",
                name = "sneaky",
                published = { Steve = { order = { "Sneaky" } },
                              Dave = { order = { "Sneaky" } } },
            },
            expected = "contested - Dave and Steve both claim Sneaky",
        },

        -- Export and import, section 8.
        {
            name = "export then import reproduces order and classes",
            input = { kind = "roundTrip", order = STEVE.order, chars = STEVE.chars },
            expected = {
                ok = true,
                text = "RLS1:Steve=MAGE~Sneaky=ROGUE~Smash=WARRIOR",
                order = { "Steve", "Sneaky", "Smash" },
                classes = { "MAGE", "ROGUE", "WARRIOR" },
            },
        },
        {
            name = "a string without the RLS1 prefix is refused",
            input = { kind = "import", text = "Steve=MAGE~Sneaky=ROGUE" },
            expected = { ok = false, count = 0, why = "this is not a RaidLootSystem roster string" },
        },
        {
            name = "an empty import is refused",
            input = { kind = "import", text = "   " },
            expected = { ok = false, count = 0, why = "nothing to import" },
        },
        {
            name = "a prefix with no characters is refused",
            input = { kind = "import", text = "RLS1:" },
            expected = { ok = false, count = 0, why = "the roster string is empty" },
        },
        {
            name = "one bad class rejects the whole import",
            input = { kind = "import", text = "RLS1:Steve=MAGE~Sneaky=ROG" },
            expected = { ok = false, count = 0, why = "unknown class for Sneaky: ROG" },
        },
        {
            name = "a duplicate in an import rejects the whole string",
            input = { kind = "import", text = "RLS1:Steve=MAGE~Steve=ROGUE" },
            expected = { ok = false, count = 0, why = "duplicate character: Steve" },
        },
        {
            name = "surrounding whitespace is tolerated",
            input = { kind = "import", text = "  RLS1:Steve=MAGE~Sneaky=ROGUE  " },
            expected = { ok = true, count = 2 },
        },
    },
}
