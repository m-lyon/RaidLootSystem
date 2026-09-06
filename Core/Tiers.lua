-- Core/Tiers.lua
--
-- The single implementation of the tier rule (spec 000 section 6, spec 001 section 3).
-- Nothing else in the codebase derives a tier. Pure Lua, no WoW API.

local ADDON, ns = ...

ns.Tiers = {}
local Tiers = ns.Tiers

--- Tier for a hierarchy position.
-- @param position 1-based index into roster.order
-- @param tierCount 0..5
-- @return integer tier, 1 = highest. Positions past the cut-off share the Rest tier.
function Tiers.forPosition(position, tierCount)
    if type(position) ~= "number" or position < 1 then return nil end
    tierCount = tierCount or 0
    if tierCount <= 0 then return 1 end          -- flat roll
    if position <= tierCount then return position end
    return tierCount + 1                          -- Rest
end

--- Is this tier the Rest bucket for the given count?
function Tiers.isRest(tier, tierCount)
    if not tier or tierCount == nil or tierCount <= 0 then return false end
    return tier == tierCount + 1
end

--- Display label for a tier: "T1".."T5", "Rest", or "Flat" when tierCount is 0.
function Tiers.label(tier, tierCount)
    if tierCount == nil or tierCount <= 0 then return "Flat" end
    if Tiers.isRest(tier, tierCount) then return "Rest" end
    return "T" .. tostring(tier)
end

--- The tier of every position 1..orderLength, for drawing the editor's band
-- separators (spec 001 section 7).
function Tiers.bands(orderLength, tierCount)
    local out = {}
    for i = 1, (orderLength or 0) do
        out[i] = Tiers.forPosition(i, tierCount)
    end
    return out
end

--- The number of distinct tiers in play for a given count, Rest included.
function Tiers.tierSpan(tierCount)
    if tierCount == nil or tierCount <= 0 then return 1 end
    return tierCount + 1
end
