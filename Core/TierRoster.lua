-- Core/TierRoster.lua
--
-- Who composes each tier of a campaign (spec 013 section 4). Pure Lua, no WoW API.
--
-- A tier is the first gate on every item under both loot modes -- the bucket is
-- chosen before a list index or a roll decides anything inside it (spec 003
-- section 5) -- so what T1 holds is the most consequential fact about a campaign.
-- This turns the orderings its members submitted into that answer.
--
-- Bands are derived on every read and never stored: the tier count is a host
-- setting that changes, and a member can resubmit at any time, so a stored band
-- list would be a second copy of a derivation that goes stale without saying so.

local ADDON, ns = ...

ns.TierRoster = {}
local TierRoster = ns.TierRoster

local Tiers = ns.Tiers

local function keyOf(name)
    return type(name) == "string" and name:lower() or nil
end

--- The tier bands of a campaign.
--
-- @param members  array of { player, order, chars, at }
-- @param tierCount  the campaign's, 0..5. 0 is a flat roll: one band, everyone in it.
-- @param ctx { present = { [char] = true }, listIndex = { [char] = n }, me = "Player" }
-- @return array of { tier, label, rows = { { char, owner, class, position, present,
--         isSelf, listIndex, at } } }, ascending by tier, Rest last
function TierRoster.bands(members, tierCount, ctx)
    members, ctx = members or {}, ctx or {}
    tierCount = tierCount or 0
    local present, listIndex = ctx.present or {}, ctx.listIndex or {}
    local me = keyOf(ctx.me)

    -- Every tier in play gets a band whether or not anyone reached it. A campaign
    -- at tierCount 3 where nobody has a third character shows an empty T3 rather
    -- than renumbering Rest up into its place, which would read as a smaller
    -- hierarchy instead of an unfilled one.
    local bands, byTier = {}, {}
    for tier = 1, Tiers.tierSpan(tierCount) do
        bands[tier] = { tier = tier, label = Tiers.label(tier, tierCount), rows = {} }
        byTier[tier] = bands[tier]
    end

    for _, member in ipairs(members) do
        local chars = member.chars or {}
        for position, char in ipairs(member.order or {}) do
            local band = byTier[Tiers.forPosition(position, tierCount)]
            if band then
                local entry = chars[char] or {}
                band.rows[#band.rows + 1] = {
                    char = char,
                    owner = member.player,
                    class = entry.class,
                    position = position,
                    present = present[char] == true,
                    isSelf = me ~= nil and keyOf(member.player) == me,
                    listIndex = listIndex[char],
                    at = member.at,
                }
            end
        end
    end

    -- By owner, then by the owner's own ranking. The roster answers "who composes
    -- this tier", and owner order is both stable across a tier-count change and
    -- what a person scanning for a name reads by. The list surfaces re-sort by
    -- list index for their own question (section 6).
    for _, band in ipairs(bands) do
        table.sort(band.rows, function(a, b)
            if a.owner ~= b.owner then
                return tostring(a.owner) < tostring(b.owner)
            end
            return a.position < b.position
        end)
    end
    return bands
end

--- The same bands, ordered the way a round awards: ascending tier, and inside a
-- band ascending list index (spec 003 section 5). Characters with no list index
-- sort after those that have one, by owner, so a banded list is never truncated.
function TierRoster.byListIndex(bands)
    for _, band in ipairs(bands or {}) do
        table.sort(band.rows, function(a, b)
            if (a.listIndex ~= nil) ~= (b.listIndex ~= nil) then
                return a.listIndex ~= nil
            end
            if a.listIndex and b.listIndex and a.listIndex ~= b.listIndex then
                return a.listIndex < b.listIndex
            end
            if a.owner ~= b.owner then return tostring(a.owner) < tostring(b.owner) end
            return a.position < b.position
        end)
    end
    return bands
end

--- Group priority-list rows into the same bands (spec 013 section 6).
--
-- Takes the rows PriorityList.viewRows already produces, so the two list surfaces
-- keep one row model between them and cannot disagree about what a row says.
-- Inside a band rows stay in list order, which is exactly the order a round awards
-- in: buckets ascending by tier, list index ascending inside a bucket.
--
-- Rows whose owner has submitted no ordering carry no tier, and land in a band of
-- their own at the end rather than in Rest. Rest is a real answer -- ranked, below
-- the cut-off -- and drawing "we do not know" with the same shape would be a lie
-- that reads as a fact.
-- @return array of { tier, label, rows }, Rest then unknown last; `tier` is nil on
--         the unknown band. Empty bands are kept, as in TierRoster.bands.
function TierRoster.groupRows(rows, tierCount)
    local bands, byTier = {}, {}
    for tier = 1, Tiers.tierSpan(tierCount) do
        bands[tier] = { tier = tier, label = Tiers.label(tier, tierCount), rows = {} }
        byTier[tier] = bands[tier]
    end
    local unknown = { tier = nil, label = "No hierarchy", rows = {} }

    for _, row in ipairs(rows or {}) do
        local band = row.tier and byTier[row.tier] or unknown
        band.rows[#band.rows + 1] = row
    end

    -- Carried only when it has something in it: an empty tier is a fact about the
    -- campaign worth showing, but an empty "No hierarchy" is just noise.
    if #unknown.rows > 0 then bands[#bands + 1] = unknown end
    return bands
end

--- Members announcing this campaign who have submitted no ordering. Named rather
-- than counted (section 5): "not submitted: Craig" is actionable, "2/3" is not.
-- @param announced  array of player names seen in this campaign
-- @param members    array of { player, order }, as passed to bands
function TierRoster.missing(announced, members)
    local submitted = {}
    for _, member in ipairs(members or {}) do
        if #(member.order or {}) > 0 then submitted[keyOf(member.player)] = true end
    end
    local out = {}
    for _, player in ipairs(announced or {}) do
        if not submitted[keyOf(player)] then out[#out + 1] = player end
    end
    table.sort(out)
    return out
end
