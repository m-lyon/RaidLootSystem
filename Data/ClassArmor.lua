-- Data/ClassArmor.lua
--
-- Class -> armour and weapon permissions for WotLK 3.3.5a.
-- Consumed by Core/Eligibility.lua (spec 003 section 8). Pure data, no WoW API.
--
-- Subclass keys here are the LOCALE-INDEPENDENT names produced by Modules/ItemInfo.lua
-- (spec 004 section 4). They are NOT the strings GetItemInfo returns -- those are localised
-- and must never be compared against literals. CI greps for that.

local ADDON, ns = ...

ns.Data = ns.Data or {}
local Data = ns.Data

--------------------------------------------------------------------------------
-- Verification status
--------------------------------------------------------------------------------
-- The armour table is settled: it is the mapping specified in spec 004 section 5 and
-- reviewed in PR #1. The WEAPON table's doubtful rows were checked in game on 2026-09-06
-- (Data/VERIFY.md records what was confirmed); the one wrong row, Hunter thrown, was fixed.
--
-- Consequence of an error here is bounded but real: a wrong entry makes one class ineligible
-- for one weapon category (or wrongly eligible for it). It is not silent -- the roll window
-- shows the reason code, players can right-click to override any weapon or armour check
-- (spec 003 section 8), and the raid leader can disable the filter entirely.

Data.WEAPONS_VERIFIED = true

--------------------------------------------------------------------------------
-- Armour
--------------------------------------------------------------------------------
-- The armour class each class is expected to WEAR at level 80, not everything it can equip.
-- A Hunter can physically equip leather; it should not be competing for leather in a raid.
--
-- Only applied to the eight true armour slots. Cloaks, rings, necks and trinkets report an
-- armour subclass but are wearable by everyone -- see spec 003 section 8, check 6. Getting
-- that wrong makes every cloak in the game cloth-only.

Data.ARMOR = {
    CLOTH   = { MAGE = true, PRIEST = true, WARLOCK = true },
    LEATHER = { ROGUE = true, DRUID = true },
    MAIL    = { HUNTER = true, SHAMAN = true },
    PLATE   = { WARRIOR = true, PALADIN = true, DEATHKNIGHT = true },
}

-- The eight slots the armour rule applies to. Everything else ignores Data.ARMOR entirely.
Data.ARMOR_SLOTS = {
    INVTYPE_HEAD = true, INVTYPE_SHOULDER = true, INVTYPE_CHEST = true,
    INVTYPE_ROBE = true, INVTYPE_WRIST    = true, INVTYPE_HAND  = true,
    INVTYPE_WAIST = true, INVTYPE_LEGS    = true, INVTYPE_FEET  = true,
}

--------------------------------------------------------------------------------
-- Weapons
--------------------------------------------------------------------------------
-- Checked in game; see Data/VERIFY.md for the rows that were confirmed and when.

Data.WEAPONS = {
    WARRIOR = {
        DAGGER = true, FIST = true, POLEARM = true, STAFF = true,
        AXE_1H = true, AXE_2H = true, MACE_1H = true, MACE_2H = true,
        SWORD_1H = true, SWORD_2H = true,
        BOW = true, CROSSBOW = true, GUN = true, THROWN = true,
        SHIELD = true,
    },
    PALADIN = {
        POLEARM = true,
        AXE_1H = true, AXE_2H = true, MACE_1H = true, MACE_2H = true,
        SWORD_1H = true, SWORD_2H = true,
        SHIELD = true, LIBRAM = true,
    },
    HUNTER = {
        DAGGER = true, FIST = true, POLEARM = true, STAFF = true,
        AXE_1H = true, AXE_2H = true, SWORD_1H = true, SWORD_2H = true,
        BOW = true, CROSSBOW = true, GUN = true, THROWN = true,   -- thrown confirmed in game
    },
    ROGUE = {
        DAGGER = true, FIST = true,
        AXE_1H = true, MACE_1H = true, SWORD_1H = true,
        BOW = true, CROSSBOW = true, GUN = true, THROWN = true,
    },
    PRIEST = {
        DAGGER = true, MACE_1H = true, STAFF = true, WAND = true,
    },
    DEATHKNIGHT = {
        POLEARM = true,
        AXE_1H = true, AXE_2H = true, MACE_1H = true, MACE_2H = true,
        SWORD_1H = true, SWORD_2H = true,
        SIGIL = true,
    },
    SHAMAN = {
        DAGGER = true, FIST = true, STAFF = true,
        AXE_1H = true, AXE_2H = true, MACE_1H = true, MACE_2H = true,
        SHIELD = true, TOTEM = true,
    },
    MAGE = {
        DAGGER = true, SWORD_1H = true, STAFF = true, WAND = true,
    },
    WARLOCK = {
        DAGGER = true, SWORD_1H = true, STAFF = true, WAND = true,
    },
    DRUID = {
        DAGGER = true, FIST = true, POLEARM = true, STAFF = true,
        MACE_1H = true, MACE_2H = true,
        IDOL = true,
    },
}

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------
-- Every lookup goes through these. A caller that indexes the tables directly will get a nil
-- rather than a false for an unknown class or subclass, and nil-as-"no" is how a typo in a
-- class name turns into a whole class being silently ineligible.

function Data.canWearArmor(class, armorSubclass)
    local t = Data.ARMOR[armorSubclass]
    if not t then return true end          -- unknown armour subclass: do not filter
    return t[class] == true
end

function Data.canUseWeapon(class, weaponSubclass)
    local t = Data.WEAPONS[class]
    if not t then return true end          -- unknown class: do not filter
    return t[weaponSubclass] == true
end

function Data.isArmorSlot(equipLoc)
    return Data.ARMOR_SLOTS[equipLoc] == true
end
