-- Data/TierTokens.lua
--
-- Tier set tokens -> the classes that may redeem them. WotLK 3.3.5a (T7 through T10).
-- Consumed by Modules/ItemInfo.lua (spec 004 section 5) and Core/Eligibility.lua (003 section 8).

local ADDON, ns = ...

ns.Data = ns.Data or {}
local Data = ns.Data

--------------------------------------------------------------------------------
-- Token groups
--------------------------------------------------------------------------------
-- Stable across every WotLK tier. These three groupings are the settled part of this file.

Data.TOKEN_CLASSES = {
    VANQUISHER = { DEATHKNIGHT = true, DRUID = true, MAGE = true, ROGUE = true },
    PROTECTOR  = { WARRIOR = true, HUNTER = true, SHAMAN = true },
    CONQUEROR  = { PALADIN = true, PRIEST = true, WARLOCK = true },
}

--------------------------------------------------------------------------------
-- Detection: trailing word
--------------------------------------------------------------------------------
-- Token names all end in the group name -- "Breastplate of the Lost Vanquisher",
-- "Chestguard of the Wayward Conqueror". Matching the trailing word covers every tier
-- including ones that do not exist yet, which an item-id list cannot.
--
-- This is deliberately the PRIMARY path and the id table below is the exception list, not the
-- other way round. Spec 004 section 5: "the trailing-word match is the robust path".
--
-- Caveat: this is an English-only match, which is consistent with the addon having no locale
-- layer (CLAUDE.md, Conventions). On a localised client it fails safe -- the item is simply not
-- recognised as a token, so nobody is wrongly excluded; it just is not class-filtered.

local TRAILING = {
    Vanquisher = "VANQUISHER",
    Protector  = "PROTECTOR",
    Conqueror  = "CONQUEROR",
}

--------------------------------------------------------------------------------
-- Item id overrides
--------------------------------------------------------------------------------
-- For tokens whose name does NOT end in the group word, and for anything the trailing-word
-- match gets wrong.
--
-- INTENTIONALLY EMPTY. Populating it from memory would be worse than leaving it empty: a wrong
-- id here silently sends a token to the wrong classes, and unlike a missing entry there is no
-- fallback behind it. Add entries only when a real token is observed to be misclassified in
-- game, with the item link recorded in the comment.
--
--   [40616] = "VANQUISHER",   -- example shape only, not a real mapping

Data.TOKEN_IDS = {}

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

-- Returns the group name, or nil when the item is not a tier token.
-- itemId may be nil; itemName may be nil (uncached item -- see spec 004 section 4's retry path).
function Data.tokenGroup(itemId, itemName)
    if itemId and Data.TOKEN_IDS[itemId] then
        return Data.TOKEN_IDS[itemId]
    end
    if itemName then
        local last = itemName:match("(%a+)%s*$")
        if last then return TRAILING[last] end
    end
    return nil
end

-- Returns the class set for a token group, or nil. Callers treat nil as "not a token",
-- never as "no classes" -- the difference is a whole raid being unable to enter.
function Data.tokenClasses(group)
    return group and Data.TOKEN_CLASSES[group] or nil
end
