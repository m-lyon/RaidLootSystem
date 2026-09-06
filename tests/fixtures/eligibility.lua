-- tests/fixtures/eligibility.lua
--
-- Spec 003 section 8. Adding a regression case means adding a table entry.

local ns = ...

--- Each case runs one check and reports the verdict plus the reason code.
local function run(input, ns)
    local ok, reason = ns.Eligibility.check(input.item, input.char, input.config)
    return { ok = ok, reason = reason or "" }
end

-- Shorthands. A present, uncontested character and the filter switched on are the
-- default; a case names only what it changes.
local function char(class, over)
    local c = { name = "Bonk", class = class, present = true, contested = false }
    if over then c.over = true end
    return c
end

local FILTER_ON = { filterEnabled = true }
local FILTER_OFF = { filterEnabled = false }
local OVERRIDE = { filterEnabled = true, override = true }

local PLATE_CHEST = { equipLoc = "INVTYPE_CHEST", armorSubclass = "PLATE", quality = 4 }
local CLOTH_CHEST = { equipLoc = "INVTYPE_CHEST", armorSubclass = "CLOTH", quality = 4 }
local CLOTH_CLOAK = { equipLoc = "INVTYPE_CLOAK", armorSubclass = "CLOTH", quality = 4 }
local MISC_RING   = { equipLoc = "INVTYPE_FINGER", armorSubclass = "MISCELLANEOUS", quality = 4 }
local SWORD_2H    = { equipLoc = "INVTYPE_2HWEAPON", weaponSubclass = "SWORD_2H", quality = 4 }
local CONQUEROR   = { equipLoc = "INVTYPE_CHEST",
                      tokenClasses = { PALADIN = true, PRIEST = true, WARLOCK = true },
                      quality = 4 }
local CONQ_ARRAY  = { equipLoc = "INVTYPE_CHEST",
                      tokenClasses = { "PALADIN", "PRIEST", "WARLOCK" }, quality = 4 }

local PASS = { ok = true, reason = "" }

return {
    name = "eligibility",
    run = run,
    cases = {
        -- Checks 1 and 2. Not overridable, and they win over everything after them.
        {
            name = "absent character is not eligible",
            input = { item = PLATE_CHEST, config = FILTER_ON,
                      char = { name = "Bonk", class = "WARRIOR", present = false } },
            expected = { ok = false, reason = "NOT_IN_RAID" },
        },
        {
            name = "contested character is not eligible",
            input = { item = PLATE_CHEST, config = FILTER_ON,
                      char = { name = "Bonk", class = "WARRIOR",
                               present = true, contested = true } },
            expected = { ok = false, reason = "CONTESTED" },
        },
        {
            name = "an override does not resurrect an absent character",
            input = { item = PLATE_CHEST, config = OVERRIDE,
                      char = { name = "Bonk", class = "WARRIOR", present = false } },
            expected = { ok = false, reason = "NOT_IN_RAID" },
        },
        {
            name = "a disabled filter does not resurrect a contested character",
            input = { item = PLATE_CHEST, config = FILTER_OFF,
                      char = { name = "Bonk", class = "WARRIOR",
                               present = true, contested = true } },
            expected = { ok = false, reason = "CONTESTED" },
        },

        -- Check 3: unclassifiable items skip the filter entirely.
        {
            name = "a special item passes for anyone",
            input = { item = { special = true, armorSubclass = "PLATE",
                               equipLoc = "INVTYPE_CHEST" },
                      char = char("MAGE"), config = FILTER_ON },
            expected = PASS,
        },

        -- Check 4: the raid leader turned the filter off.
        {
            name = "a disabled filter passes a wrong-armour case",
            input = { item = PLATE_CHEST, char = char("MAGE"), config = FILTER_OFF },
            expected = PASS,
        },

        -- Check 5: tier tokens.
        {
            name = "PALADIN passes for a Conqueror token",
            input = { item = CONQUEROR, char = char("PALADIN"), config = FILTER_ON },
            expected = PASS,
        },
        {
            name = "MAGE fails a Conqueror token",
            input = { item = CONQUEROR, char = char("MAGE"), config = FILTER_ON },
            expected = { ok = false, reason = "WRONG_CLASS_TOKEN" },
        },
        {
            name = "the array form of tokenClasses is accepted too",
            input = { item = CONQ_ARRAY, char = char("PRIEST"), config = FILTER_ON },
            expected = PASS,
        },
        {
            name = "an array-form token still excludes the wrong class",
            input = { item = CONQ_ARRAY, char = char("MAGE"), config = FILTER_ON },
            expected = { ok = false, reason = "WRONG_CLASS_TOKEN" },
        },
        {
            name = "an override lets a MAGE enter for a Conqueror token",
            input = { item = CONQUEROR, char = char("MAGE"), config = OVERRIDE },
            expected = PASS,
        },

        -- Check 6: armour, and only on the eight true armour slots.
        {
            name = "WARRIOR passes for a plate chest",
            input = { item = PLATE_CHEST, char = char("WARRIOR"), config = FILTER_ON },
            expected = PASS,
        },
        {
            name = "MAGE fails a plate chest",
            input = { item = PLATE_CHEST, char = char("MAGE"), config = FILTER_ON },
            expected = { ok = false, reason = "WRONG_ARMOR" },
        },
        {
            name = "WARRIOR fails a cloth chest",
            input = { item = CLOTH_CHEST, char = char("WARRIOR"), config = FILTER_ON },
            expected = { ok = false, reason = "WRONG_ARMOR" },
        },
        {
            name = "WARRIOR passes for a cloth cloak",
            input = { item = CLOTH_CLOAK, char = char("WARRIOR"), config = FILTER_ON },
            expected = PASS,
        },
        {
            name = "MAGE passes for a miscellaneous ring",
            input = { item = MISC_RING, char = char("MAGE"), config = FILTER_ON },
            expected = PASS,
        },
        {
            name = "a robe is an armour slot",
            input = { item = { equipLoc = "INVTYPE_ROBE", armorSubclass = "CLOTH" },
                      char = char("WARRIOR"), config = FILTER_ON },
            expected = { ok = false, reason = "WRONG_ARMOR" },
        },
        {
            name = "an override lets a MAGE enter for a plate chest",
            input = { item = PLATE_CHEST, char = char("MAGE"), config = OVERRIDE },
            expected = PASS,
        },

        -- Check 7: weapons.
        {
            name = "WARRIOR passes for a two-handed sword",
            input = { item = SWORD_2H, char = char("WARRIOR"), config = FILTER_ON },
            expected = PASS,
        },
        {
            name = "PRIEST fails a two-handed sword",
            input = { item = SWORD_2H, char = char("PRIEST"), config = FILTER_ON },
            expected = { ok = false, reason = "WRONG_WEAPON" },
        },
        {
            name = "an override lets a PRIEST enter for a two-handed sword",
            input = { item = SWORD_2H, char = char("PRIEST"), config = OVERRIDE },
            expected = PASS,
        },

        -- Check 8, and the two fail-open paths in Data/ClassArmor.lua's accessors.
        {
            name = "an unslotted item with no subclass passes",
            input = { item = { quality = 4 }, char = char("MAGE"), config = FILTER_ON },
            expected = PASS,
        },
        {
            name = "an unknown armour subclass does not filter",
            input = { item = { equipLoc = "INVTYPE_CHEST", armorSubclass = "SPACESUIT" },
                      char = char("MAGE"), config = FILTER_ON },
            expected = PASS,
        },
        {
            name = "an unknown class does not filter on weapons",
            input = { item = SWORD_2H,
                      char = { name = "Bonk", class = "TINKER", present = true },
                      config = FILTER_ON },
            expected = PASS,
        },
    },
}
