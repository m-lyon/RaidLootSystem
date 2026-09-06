-- Core/Eligibility.lua
--
-- May one character be entered for one item? Pure Lua, no WoW API (spec 003 section 8).
--
-- The item description arrives already locale-independent from Modules/ItemInfo.lua
-- (spec 004 section 4). This file never sees a localised string, so it never compares
-- against one.

local ADDON, ns = ...

ns.Eligibility = {}
local Eligibility = ns.Eligibility

-- Data/ loads after Core/ (spec 000 section 3), so the tables are read inside the
-- function body, never at file scope.

--- Is `class` in the token's class set?
-- ItemInfo may supply either the array form given in spec 003 section 8
-- ({ "PALADIN", ... }) or the set form held in Data/TierTokens.lua
-- ({ PALADIN = true, ... }). Both are accepted; a caller should not have to know.
local function tokenAllows(tokenClasses, class)
    if tokenClasses[class] == true then return true end
    for i = 1, #tokenClasses do
        if tokenClasses[i] == class then return true end
    end
    return false
end

--- Decide one character against one item.
-- @param itemInfo  spec 003 section 8: equipLoc, armorSubclass, weaponSubclass,
--                  tokenClasses, special, quality
-- @param charInfo  { name, class, present, contested }
-- @param config    { filterEnabled = true, override = false }
--                  `override` is the player's per-entry flag. It skips checks 5 to 7
--                  only. Checks 1 and 2 are never overridable (spec 003 section 8).
-- @return ok, reasonCode. reasonCode is nil when ok is true.
function Eligibility.check(itemInfo, charInfo, config)
    itemInfo = itemInfo or {}
    charInfo = charInfo or {}
    config = config or {}

    local Data = ns.Data
    local REASON = ns.Constants.REASON

    -- 1 and 2: raid state. Not overridable.
    if not charInfo.present then return false, REASON.NOT_IN_RAID end
    if charInfo.contested then return false, REASON.CONTESTED end

    -- 3: an item the classifier could not place. The filter has nothing to say about it.
    if itemInfo.special then return true end

    -- 4: the raid leader turned the filter off.
    if not config.filterEnabled then return true end

    -- 5 to 7 are the overridable class checks (off-spec and judgement calls, DESIGN section 4).
    if config.override then return true end

    local class = charInfo.class

    -- 5: tier token. The token's class set is the whole rule; nothing else applies.
    if itemInfo.tokenClasses then
        if not tokenAllows(itemInfo.tokenClasses, class) then
            return false, REASON.WRONG_CLASS_TOKEN
        end
        return true
    end

    -- 6: armour type, but ONLY on the eight true armour slots. Cloaks, rings, necks and
    -- trinkets report an armour subclass and are wearable by everyone (spec 003 section 8).
    if itemInfo.armorSubclass and Data.isArmorSlot(itemInfo.equipLoc) then
        if not Data.canWearArmor(class, itemInfo.armorSubclass) then
            return false, REASON.WRONG_ARMOR
        end
    end

    -- 7: weapon type.
    if itemInfo.weaponSubclass then
        if not Data.canUseWeapon(class, itemInfo.weaponSubclass) then
            return false, REASON.WRONG_WEAPON
        end
    end

    -- 8: nothing objected.
    return true
end
