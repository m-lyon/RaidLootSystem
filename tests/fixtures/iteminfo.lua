-- tests/fixtures/iteminfo.lua
--
-- Spec 004 sections 4 and 6: link parsing and classification.
--
-- Classification takes class and subclass POSITIONS, never localised strings, so these
-- cases are written in positions too. They are the same positions Data/ItemClasses.lua
-- names, which is what makes this suite a check on that file and not just on the code.

local ns = ...

local function run(input, ns)
    if input.parse ~= nil then
        local itemString, itemId, name = ns.ItemInfo.ParseLink(input.parse)
        return { itemString = itemString or "", itemId = itemId or 0, name = name or "" }
    end

    local info = ns.ItemInfo.Classify(input.raw)

    -- tokenClasses is a set; flatten it so a case can state it in one string.
    local token = ""
    if info.tokenClasses then
        local names = {}
        for class in pairs(info.tokenClasses) do names[#names + 1] = class end
        table.sort(names)
        token = table.concat(names, ",")
    end

    return {
        equipLoc   = info.equipLoc or "",
        armor      = info.armorSubclass or "",
        weapon     = info.weaponSubclass or "",
        group      = info.tokenGroup or "",
        token      = token,
        special    = info.special and true or false,
        unresolved = info.unresolved and true or false,
    }
end

-- Positions, as Data/ItemClasses.lua orders them.
local WEAPON, ARMOR = 1, 2
local AXE_1H, SWORD_2H, STAFF = 1, 9, 10
local WEAPON_MISC, DAGGER, FISHING_POLE = 12, 13, 17
local ARMOR_MISC, CLOTH, LEATHER, MAIL, PLATE = 1, 2, 3, 4, 5
local SHIELD, LIBRAM, IDOL = 6, 7, 8

--- A cached, epic, equippable item. A case names only what it changes.
local function item(fields)
    local raw = {
        itemId = 40000, itemString = "item:40000:0:0:0:0:0:0:0:0",
        name = "Something", quality = 4, itemLevel = 226, cached = true,
    }
    for k, v in pairs(fields) do raw[k] = v end
    return raw
end

local NOTHING = {
    equipLoc = "", armor = "", weapon = "", group = "", token = "",
    special = false, unresolved = false,
}

local function expect(fields)
    local out = {}
    for k, v in pairs(NOTHING) do out[k] = v end
    for k, v in pairs(fields) do out[k] = v end
    return out
end

local CONQUEROR = "PALADIN,PRIEST,WARLOCK"

return {
    name = "iteminfo",
    run = run,
    cases = {
        ----------------------------------------------------------------------
        -- Link parsing
        ----------------------------------------------------------------------
        {
            name = "a full item link yields its string, id and name",
            input = { parse = "|cffa335ee|Hitem:49623:0:0:0:0:0:0:0:80|h"
                .. "[Shadowmourne]|h|r" },
            expected = { itemString = "item:49623:0:0:0:0:0:0:0:80",
                         itemId = 49623, name = "Shadowmourne" },
        },
        {
            name = "a bare item string parses, with no name to read",
            input = { parse = "item:40616:0:0:0:0:0:0:0:0" },
            expected = { itemString = "item:40616:0:0:0:0:0:0:0:0",
                         itemId = 40616, name = "" },
        },
        {
            name = "a bare item id is accepted from a slash command",
            input = { parse = "49623" },
            expected = { itemString = "item:49623:0:0:0:0:0:0:0:0",
                         itemId = 49623, name = "" },
        },
        {
            name = "a number is accepted as an item id",
            input = { parse = 49623 },
            expected = { itemString = "item:49623:0:0:0:0:0:0:0:0",
                         itemId = 49623, name = "" },
        },
        {
            name = "a spell link is not an item link",
            input = { parse = "|cff71d5ff|Hspell:47540|h[Penance]|h|r" },
            expected = { itemString = "", itemId = 0, name = "" },
        },
        {
            name = "plain chat text is not an item link",
            input = { parse = "give me the axe" },
            expected = { itemString = "", itemId = 0, name = "" },
        },

        ----------------------------------------------------------------------
        -- Armour (section 4)
        ----------------------------------------------------------------------
        {
            name = "a plate chest reports PLATE",
            input = { raw = item({ equipLoc = "INVTYPE_CHEST",
                                   classIndex = ARMOR, subClassIndex = PLATE }) },
            expected = expect({ equipLoc = "INVTYPE_CHEST", armor = "PLATE" }),
        },
        {
            name = "a robe reports CLOTH on its own slot token",
            input = { raw = item({ equipLoc = "INVTYPE_ROBE",
                                   classIndex = ARMOR, subClassIndex = CLOTH }) },
            expected = expect({ equipLoc = "INVTYPE_ROBE", armor = "CLOTH" }),
        },
        {
            -- The acceptance criterion in section 7. The armour type is reported; the
            -- decision not to enforce it belongs to Core/Eligibility.lua check 6, which
            -- only applies the rule on the eight true armour slots.
            name = "a cloak reports its slot and carries no enforced restriction",
            input = { raw = item({ equipLoc = "INVTYPE_CLOAK",
                                   classIndex = ARMOR, subClassIndex = CLOTH }) },
            expected = expect({ equipLoc = "INVTYPE_CLOAK", armor = "CLOTH" }),
        },
        {
            name = "a ring reports the armour miscellaneous bucket",
            input = { raw = item({ equipLoc = "INVTYPE_FINGER",
                                   classIndex = ARMOR, subClassIndex = ARMOR_MISC }) },
            expected = expect({ equipLoc = "INVTYPE_FINGER", armor = "ARMOR_MISC" }),
        },
        {
            name = "mail legs report MAIL",
            input = { raw = item({ equipLoc = "INVTYPE_LEGS",
                                   classIndex = ARMOR, subClassIndex = MAIL }) },
            expected = expect({ equipLoc = "INVTYPE_LEGS", armor = "MAIL" }),
        },
        {
            name = "leather hands report LEATHER",
            input = { raw = item({ equipLoc = "INVTYPE_HAND",
                                   classIndex = ARMOR, subClassIndex = LEATHER }) },
            expected = expect({ equipLoc = "INVTYPE_HAND", armor = "LEATHER" }),
        },

        ----------------------------------------------------------------------
        -- Shields and relics: armour class, weapon permission
        ----------------------------------------------------------------------
        {
            name = "a shield is a weapon-table permission, not an armour type",
            input = { raw = item({ equipLoc = "INVTYPE_SHIELD",
                                   classIndex = ARMOR, subClassIndex = SHIELD }) },
            expected = expect({ equipLoc = "INVTYPE_SHIELD", weapon = "SHIELD" }),
        },
        {
            name = "an idol is a weapon-table permission",
            input = { raw = item({ equipLoc = "INVTYPE_RELIC",
                                   classIndex = ARMOR, subClassIndex = IDOL }) },
            expected = expect({ equipLoc = "INVTYPE_RELIC", weapon = "IDOL" }),
        },
        {
            name = "a libram is a weapon-table permission",
            input = { raw = item({ equipLoc = "INVTYPE_RELIC",
                                   classIndex = ARMOR, subClassIndex = LIBRAM }) },
            expected = expect({ equipLoc = "INVTYPE_RELIC", weapon = "LIBRAM" }),
        },

        ----------------------------------------------------------------------
        -- Weapons
        ----------------------------------------------------------------------
        {
            name = "a two-handed sword reports SWORD_2H",
            input = { raw = item({ equipLoc = "INVTYPE_2HWEAPON",
                                   classIndex = WEAPON, subClassIndex = SWORD_2H }) },
            expected = expect({ equipLoc = "INVTYPE_2HWEAPON", weapon = "SWORD_2H" }),
        },
        {
            name = "a dagger reports DAGGER",
            input = { raw = item({ equipLoc = "INVTYPE_WEAPON",
                                   classIndex = WEAPON, subClassIndex = DAGGER }) },
            expected = expect({ equipLoc = "INVTYPE_WEAPON", weapon = "DAGGER" }),
        },
        {
            name = "a one-handed axe reports AXE_1H",
            input = { raw = item({ equipLoc = "INVTYPE_WEAPONMAINHAND",
                                   classIndex = WEAPON, subClassIndex = AXE_1H }) },
            expected = expect({ equipLoc = "INVTYPE_WEAPONMAINHAND", weapon = "AXE_1H" }),
        },
        {
            name = "a staff reports STAFF",
            input = { raw = item({ equipLoc = "INVTYPE_2HWEAPON",
                                   classIndex = WEAPON, subClassIndex = STAFF }) },
            expected = expect({ equipLoc = "INVTYPE_2HWEAPON", weapon = "STAFF" }),
        },
        {
            -- No class is listed against a fishing pole in Data/ClassArmor.lua. Reporting
            -- the subclass would make Data.canUseWeapon read the silence as "nobody may
            -- use this" and lock the whole raid out of the item.
            name = "a fishing pole carries no weapon restriction",
            input = { raw = item({ equipLoc = "INVTYPE_2HWEAPON",
                                   classIndex = WEAPON, subClassIndex = FISHING_POLE }) },
            expected = expect({ equipLoc = "INVTYPE_2HWEAPON" }),
        },
        {
            name = "the weapon miscellaneous bucket carries no restriction either",
            input = { raw = item({ equipLoc = "INVTYPE_WEAPON",
                                   classIndex = WEAPON, subClassIndex = WEAPON_MISC }) },
            expected = expect({ equipLoc = "INVTYPE_WEAPON" }),
        },
        {
            -- What the length check in Modules/ItemInfo.lua leaves behind when it refuses
            -- to map: a slot, and no type restriction at all.
            name = "no subclass position means no restriction",
            input = { raw = item({ equipLoc = "INVTYPE_CHEST" }) },
            expected = expect({ equipLoc = "INVTYPE_CHEST" }),
        },
        {
            name = "a subclass position past the end of the table is ignored",
            input = { raw = item({ equipLoc = "INVTYPE_CHEST",
                                   classIndex = ARMOR, subClassIndex = 99 }) },
            expected = expect({ equipLoc = "INVTYPE_CHEST" }),
        },

        ----------------------------------------------------------------------
        -- Tier tokens (section 6)
        ----------------------------------------------------------------------
        {
            name = "a Conqueror token maps to its three classes",
            input = { raw = item({ name = "Chestguard of the Lost Conqueror",
                                   equipLoc = "" }) },
            expected = expect({ group = "CONQUEROR", token = CONQUEROR }),
        },
        {
            name = "a Vanquisher token maps to its four classes",
            input = { raw = item({ name = "Leggings of the Wayward Vanquisher",
                                   equipLoc = "" }) },
            expected = expect({ group = "VANQUISHER",
                                token = "DEATHKNIGHT,DRUID,MAGE,ROGUE" }),
        },
        {
            -- The token test runs before the cached test, because the name comes off the
            -- link. A cold client cache must not cost the raid the tier drop.
            name = "an uncached token is still recognised from its link name",
            input = { raw = { itemId = 40616, itemString = "item:40616:0:0:0:0:0:0:0:0",
                              name = "Breastplate of the Lost Protector", cached = false } },
            expected = expect({ group = "PROTECTOR", token = "HUNTER,SHAMAN,WARRIOR" }),
        },

        ----------------------------------------------------------------------
        -- Special items (section 6)
        ----------------------------------------------------------------------
        {
            name = "a mount is special and the filter is off for it",
            input = { raw = item({ name = "Reins of the Grand Black War Mammoth",
                                   equipLoc = "" }) },
            expected = expect({ special = true }),
        },
        {
            name = "a crafting material is special",
            input = { raw = item({ name = "Primordial Saronite", equipLoc = "" }) },
            expected = expect({ special = true }),
        },
        {
            name = "a bag is not gear, so it is special rather than a chest piece",
            input = { raw = item({ equipLoc = "INVTYPE_BAG" }) },
            expected = expect({ equipLoc = "INVTYPE_BAG", special = true }),
        },
        {
            name = "an item that never resolved is special and flagged unresolved",
            input = { raw = { itemId = 50000, itemString = "item:50000:0:0:0:0:0:0:0:0",
                              cached = false } },
            expected = expect({ special = true, unresolved = true }),
        },
        {
            name = "an empty lookup is special rather than an error",
            input = { raw = {} },
            expected = expect({ special = true, unresolved = true }),
        },
    },
}
