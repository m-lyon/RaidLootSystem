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

    elseif input.kind == "knownClass" then
        local class, from = Roster.KnownClass(input.candidates)
        return { class = class or "", from = from or "" }

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

    elseif input.kind == "prune" then
        return Roster.PruneToChars(input.list, input.chars)

    elseif input.kind == "seed" then
        return Roster.SeedTemplate(input.template, input.order)

    elseif input.kind == "importTemplate" then
        -- What an import does to the template: prune to the new character table,
        -- then seed with the imported ordering (spec 012 section 7).
        local template = Roster.PruneToChars(input.template, input.chars)
        return Roster.SeedTemplate(template, input.order)

    elseif input.kind == "importLosses" then
        return Roster.ImportLosses(input.campaigns, input.chars, input.activeId)
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
            -- Spec 012 section 4: chars is global and the ordering is one campaign's
            -- hierarchy, so a character you did not bring to this campaign is the
            -- ordinary state, not a broken roster.
            name = "a class entry with no position is accepted: it is out of this campaign",
            input = {
                kind = "validate",
                order = { "Steve" },
                chars = { Steve = { class = "MAGE" }, Ghost = { class = "PRIEST" } },
            },
            expected = { ok = true },
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

        -- Inferring a class rather than being told one, section 4.
        {
            name = "the most directly observed source wins",
            input = { kind = "knownClass", candidates = {
                { from = "the group", class = "MAGE" },
                { from = "your guild roster", class = "ROGUE" } } },
            expected = { class = "MAGE", from = "the group" },
        },
        {
            name = "a source with nothing to say is skipped, not trusted",
            input = { kind = "knownClass", candidates = {
                { from = "a published roster" },
                { from = "your guild roster", class = "WARRIOR" } } },
            expected = { class = "WARRIOR", from = "your guild roster" },
        },
        {
            name = "a localised class name is refused, so a drifted lookup fails loudly",
            input = { kind = "knownClass", candidates = {
                { from = "your guild roster", class = "Death Knight" } } },
            expected = { class = "", from = "" },
        },
        {
            name = "nothing knowing the class is not an answer",
            input = { kind = "knownClass", candidates = {} },
            expected = { class = "", from = "" },
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

        -- Hierarchies against the character table, spec 012 section 7.
        {
            name = "pruning drops the names the character table no longer holds",
            input = { kind = "prune", list = { "Steve", "Ghost", "Sneaky" },
                      chars = { Steve = { class = "MAGE" }, Sneaky = { class = "ROGUE" } } },
            expected = { "Steve", "Sneaky" },
        },
        {
            name = "pruning matches case-insensitively",
            input = { kind = "prune", list = { "steve" },
                      chars = { Steve = { class = "MAGE" } } },
            expected = { "steve" },
        },
        {
            name = "seeding appends only the names the template does not already hold",
            input = { kind = "seed", template = { "Steve" },
                      order = { "Sneaky", "steve", "Smash" } },
            expected = { "Steve", "Sneaky", "Smash" },
        },
        {
            -- The bug: an import that shares no character with the old roster pruned
            -- the template to nothing, so the next new campaign or join opened with
            -- nothing ticked and Campaign.Join refused it.
            name = "an import reseeds the template it just pruned to nothing",
            input = { kind = "importTemplate", template = { "Steve", "Sneaky" },
                      order = { "Bonk", "Whacky" },
                      chars = { Bonk = { class = "WARRIOR" }, Whacky = { class = "DRUID" } } },
            expected = { "Bonk", "Whacky" },
        },
        {
            name = "an overlapping import keeps the shared names in their template order",
            input = { kind = "importTemplate", template = { "Sneaky", "Steve" },
                      order = { "Steve", "Bonk" },
                      chars = { Steve = { class = "MAGE" }, Bonk = { class = "WARRIOR" } } },
            expected = { "Steve", "Bonk" },
        },
        {
            -- The confirmation has to say which other campaigns lose characters: the
            -- active one is excluded because the import replaces its ordering outright.
            name = "import losses name every other campaign that loses a character",
            input = { kind = "importLosses", activeId = "Steve-1",
                      chars = { Bonk = { class = "WARRIOR" } },
                      campaigns = {
                          ["Steve-1"] = { id = "Steve-1", label = "Main",
                                          hierarchy = { "Steve", "Sneaky" } },
                          ["Steve-2"] = { id = "Steve-2", label = "Alt run",
                                          hierarchy = { "Steve" } },
                          ["Steve-3"] = { id = "Steve-3", label = "Tuesdays",
                                          hierarchy = { "Bonk" } },
                          ["Steve-4"] = { id = "Steve-4", label = "Ally",
                                          hierarchy = { "Smash" } },
                      } },
            expected = { "Ally", "Alt run" },
        },
        {
            name = "import losses are empty when no other campaign ranks a dropped name",
            input = { kind = "importLosses", activeId = "Steve-1",
                      chars = { Bonk = { class = "WARRIOR" } },
                      campaigns = {
                          ["Steve-1"] = { id = "Steve-1", label = "Main",
                                          hierarchy = { "Steve" } },
                          ["Steve-2"] = { id = "Steve-2", label = "Alt run",
                                          hierarchy = { "Bonk" } },
                      } },
            expected = {},
        },
        {
            -- Labels are cosmetic, not unique (Campaign.ValidLabel never checks for a
            -- collision); two campaigns sharing one must print once, not "X, X".
            name = "import losses dedupes campaigns that share a label",
            input = { kind = "importLosses", activeId = "Steve-1",
                      chars = { Bonk = { class = "WARRIOR" } },
                      campaigns = {
                          ["Steve-1"] = { id = "Steve-1", label = "Main",
                                          hierarchy = { "Steve" } },
                          ["Steve-2"] = { id = "Steve-2", label = "Alt run",
                                          hierarchy = { "Steve" } },
                          ["Steve-3"] = { id = "Steve-3", label = "Alt run",
                                          hierarchy = { "Sneaky" } },
                      } },
            expected = { "Alt run" },
        },
    },
}
