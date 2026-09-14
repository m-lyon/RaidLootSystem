-- Data/ItemClasses.lua
--
-- Item class and subclass POSITIONS -> our own locale-independent names (spec 004 section 4).
--
-- GetItemInfo returns localised class and subclass strings in 3.3.5a and gives no numeric
-- ids. The only stable handle is the ORDER of GetAuctionItemClasses() and
-- GetAuctionItemSubClasses(i). Modules/ItemInfo.lua builds
--   localised string -> index
-- from those calls at load, then this file turns
--   index -> internal constant.
--
-- Nothing here is a localised string, and nothing downstream ever compares against one.
-- CI greps for that (tests/purity.sh).

local ADDON, ns = ...

ns.Data = ns.Data or {}
local Data = ns.Data

--------------------------------------------------------------------------------
-- Verification status
--------------------------------------------------------------------------------
-- The two ORDER tables below were assembled from reference material and were checked
-- against a live 3.3.5a client with `/rls itemclasses` on 2026-09-06 by Matt Lyon;
-- every row matched semantically. See Data/VERIFY.md.
--
-- The failure mode is contained by design: Modules/ItemInfo.lua compares the length of
-- each live list against the length of the matching table, and refuses to map subclasses
-- at all when they disagree. Items then carry no armour or weapon subclass, so the
-- eligibility filter has nothing to say about them and NOBODY is wrongly excluded
-- (Core/Eligibility.lua checks 6 and 7). A wrong order inside a list of the right length
-- is the case this flag exists for.

Data.SUBCLASS_ORDER_VERIFIED = true

--------------------------------------------------------------------------------
-- Class positions
--------------------------------------------------------------------------------
-- Only two class positions matter. Everything else is either a tier token (handled by
-- Data/TierTokens.lua, by name) or not equippable, and an item that is neither is marked
-- `special` and skips the filter entirely (spec 004 section 6).

Data.CLASS_INDEX = {
    WEAPON = 1,
    ARMOR  = 2,
}

--------------------------------------------------------------------------------
-- Subclass positions
--------------------------------------------------------------------------------
-- The auction-house lists, unlike the client's own item enum, omit the obsolete
-- subclasses (weapon index 9 and 11-12, armour "Buckler"). These tables are the
-- auction-house order, because that is what GetAuctionItemSubClasses returns.

Data.WEAPON_SUBCLASSES = {
    "AXE_1H", "AXE_2H", "BOW", "GUN", "MACE_1H", "MACE_2H", "POLEARM",
    "SWORD_1H", "SWORD_2H", "STAFF", "FIST", "WEAPON_MISC", "DAGGER",
    "THROWN", "CROSSBOW", "WAND", "FISHING_POLE",
}

Data.ARMOR_SUBCLASSES = {
    "ARMOR_MISC", "CLOTH", "LEATHER", "MAIL", "PLATE",
    "SHIELD", "LIBRAM", "IDOL", "TOTEM", "SIGIL",
}

-- Shields and relics are armour-class subclasses, but the permission for them lives in
-- Data.WEAPONS rather than Data.ARMOR -- they are not an armour TYPE a class wears, they
-- are a slot a class either has or has not. ItemInfo reports them as `weaponSubclass`
-- so Core/Eligibility.lua check 7 picks them up; check 6 would never see them anyway,
-- because INVTYPE_SHIELD and INVTYPE_RELIC are not armour slots.

Data.ARMOR_SUBCLASS_AS_WEAPON = {
    SHIELD = true, LIBRAM = true, IDOL = true, TOTEM = true, SIGIL = true,
}

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

--- Position -> internal name, or nil when the position is off the end of the table.
-- @param classIndex     index into GetAuctionItemClasses()
-- @param subClassIndex  index into GetAuctionItemSubClasses(classIndex)
function Data.subclassName(classIndex, subClassIndex)
    if not classIndex or not subClassIndex then return nil end
    if classIndex == Data.CLASS_INDEX.WEAPON then
        return Data.WEAPON_SUBCLASSES[subClassIndex]
    elseif classIndex == Data.CLASS_INDEX.ARMOR then
        return Data.ARMOR_SUBCLASSES[subClassIndex]
    end
    return nil
end

--- Does the permission table in Data/ClassArmor.lua actually cover this subclass?
--
-- Derived from Data.WEAPONS rather than written out, so the two files cannot drift.
-- Fishing poles and the weapon "miscellaneous" bucket are covered by nobody, and a
-- subclass nobody is listed against must not be filtered on: Data.canUseWeapon would
-- read the absence as "no class may use this" and lock every character out of the item.
local filtered
function Data.isFilteredSubclass(subclass)
    if not subclass then return false end
    if not filtered then
        filtered = {}
        for _, permitted in pairs(Data.WEAPONS or {}) do
            for key in pairs(permitted) do filtered[key] = true end
        end
    end
    return filtered[subclass] == true
end

--- Test seam: forget the derived set. Nothing in the addon calls this.
function Data.resetFilteredSubclasses()
    filtered = nil
end
