-- Modules/ItemInfo.lua
--
-- The only place WoW item data is read (spec 004 section 4). It turns an item link into
-- the locale-independent `itemInfo` table Core/Eligibility.lua consumes (spec 003 section 8).
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the `iteminfo`
-- suite; the file creates no frame and calls no WoW API while loading.

local ADDON, ns = ...

ns.ItemInfo = {}
local ItemInfo = ns.ItemInfo

local C = ns.Constants

-- Retry budget for an uncached item (section 4). 20 tries at 0.25s is 5 seconds, which is
-- the acceptance criterion; past that the item is entered as `special` rather than dropped.
ItemInfo.RETRY_INTERVAL = 0.25
ItemInfo.RETRY_MAX = 20

--------------------------------------------------------------------------------
-- Pure: reading a link
--------------------------------------------------------------------------------
-- Links carry the name, which matters more than it looks: the tier-token match is by
-- trailing word (Data/TierTokens.lua), so a token is still recognised while its item data
-- is uncached. String work only; no WoW API is involved in any of this.

--- @param link an item link, a bare item string, or an item id
-- @return itemString, itemId, name -- any of which may be nil
function ItemInfo.ParseLink(link)
    if type(link) == "number" then
        return "item:" .. link .. ":0:0:0:0:0:0:0:0", link, nil
    end
    if type(link) ~= "string" then return nil, nil, nil end

    local itemString = link:match("|H(item:[%-%d:]+)|h") or link:match("^(item:[%-%d:]+)$")
    if not itemString then
        local bare = link:match("^%s*(%d+)%s*$")
        if bare then
            return "item:" .. bare .. ":0:0:0:0:0:0:0:0", tonumber(bare), nil
        end
        return nil, nil, nil
    end

    local itemId = tonumber(itemString:match("^item:(%d+)"))
    local name = link:match("|h%[(.-)%]|h")
    return itemString, itemId, name
end

--- Two links refer to the same item when their ids match. Suffix and enchant fields can
-- differ between two copies of one drop, so the id is the only sound grouping key
-- (spec 004 section 2, duplicate stacks).
function ItemInfo.SameItem(a, b)
    local _, idA = ItemInfo.ParseLink(a)
    local _, idB = ItemInfo.ParseLink(b)
    return idA ~= nil and idA == idB
end

--------------------------------------------------------------------------------
-- Pure: is this a slot a character equips?
--------------------------------------------------------------------------------
-- equipLoc is one of the few things GetItemInfo returns that is NOT localised -- it is a
-- token like "INVTYPE_CHEST". These three are equip slots that nobody rolls for.

local NOT_A_GEAR_SLOT = {
    INVTYPE_NON_EQUIP = true,
    INVTYPE_BAG       = true,
    INVTYPE_AMMO      = true,
    INVTYPE_QUIVER    = true,
}

function ItemInfo.IsEquippable(info)
    local slot = info and info.equipLoc
    if not slot or slot == "" then return false end
    return not NOT_A_GEAR_SLOT[slot]
end

--------------------------------------------------------------------------------
-- Pure: classification (sections 4 and 6)
--------------------------------------------------------------------------------

--- Build an itemInfo from data already read out of the game.
--
-- @param raw {
--   itemString, itemId, name, link,
--   quality, itemLevel, equipLoc, icon,    -- as GetItemInfo returned them
--   classIndex, subClassIndex,             -- positions, resolved by the index map below
--   cached = true                          -- false when GetItemInfo returned nil
-- }
-- @return the itemInfo table described in spec 003 section 8, plus the fields spec 008
--         records (itemLevel, quality, equipLoc). Never nil.
function ItemInfo.Classify(raw)
    raw = raw or {}
    local Data = ns.Data

    local info = {
        itemId     = raw.itemId,
        itemString = raw.itemString,
        link       = raw.link,
        name       = raw.name,
        quality    = raw.quality,
        itemLevel  = raw.itemLevel,
        equipLoc   = (raw.equipLoc ~= "" and raw.equipLoc) or nil,
        icon       = raw.icon,
        special    = false,
    }

    -- 1. Tier token. Checked first and by name, so it still works on an uncached item and
    --    so it never falls through to the equip test -- no token is equippable by anyone,
    --    and a naive equip check would filter the whole raid off the most contested drop
    --    in the game (spec 004 section 6).
    local group = Data.tokenGroup(raw.itemId, raw.name)
    if group then
        info.tokenGroup = group
        info.tokenClasses = Data.tokenClasses(group)
        if not info.tokenClasses then
            -- A token we recognise but cannot map. Opening it up to everyone is the only
            -- safe reading; excluding everyone is not.
            info.special = true
        end
        return info
    end

    -- 2. The client never gave us the item. Keep it, flagged, and let the raid judge it.
    if not raw.cached then
        info.unresolved = true
        info.special = true
        return info
    end

    -- 3. Not equippable and not a token: a mount, a pattern, Primordial Saronite. The
    --    filter has no opinion on these, so it is switched off for them.
    if not ItemInfo.IsEquippable(info) then
        info.special = true
        return info
    end

    -- 4. Armour type and weapon type, by position.
    local subclass = Data.subclassName(raw.classIndex, raw.subClassIndex)
    if subclass then
        if raw.classIndex == Data.CLASS_INDEX.ARMOR
            and not Data.ARMOR_SUBCLASS_AS_WEAPON[subclass] then
            info.armorSubclass = subclass
        elseif Data.isFilteredSubclass(subclass) then
            info.weaponSubclass = subclass
        end
    end

    return info
end

--------------------------------------------------------------------------------
-- WoW-facing. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

local classIndexOf              -- localised class name -> position
local subIndexOf                -- position -> { localised subclass name -> position }
local subCount                  -- position -> how many subclasses the client listed
local mapUsable = false         -- false disables subclass mapping; see Data/ItemClasses.lua

local pending = {}              -- items still waiting on the client cache
local elapsedSinceTick = 0
local frame

--- Build the localised-string -> position maps once (section 4, "the locale trap").
local function buildIndexMap()
    classIndexOf, subIndexOf, subCount = {}, {}, {}

    local classes = { GetAuctionItemClasses() }
    for i = 1, #classes do
        classIndexOf[classes[i]] = i
        local map = {}
        local subs = { GetAuctionItemSubClasses(i) }
        for j = 1, #subs do map[subs[j]] = j end
        subIndexOf[i] = map
        subCount[i] = #subs
    end

    -- The lengths are the one thing about Data/ItemClasses.lua's order tables that can be
    -- checked without a human. A mismatch means the tables describe a different client, so
    -- every position in them is suspect and none is used: items then carry no armour or
    -- weapon subclass and the filter stays quiet, which loses filtering but excludes nobody.
    local Data = ns.Data
    local weaponIndex, armorIndex = Data.CLASS_INDEX.WEAPON, Data.CLASS_INDEX.ARMOR
    local liveWeapons = subCount[weaponIndex] or 0
    local liveArmor = subCount[armorIndex] or 0

    mapUsable = liveWeapons == #Data.WEAPON_SUBCLASSES and liveArmor == #Data.ARMOR_SUBCLASSES
    if not mapUsable then
        ns.Print(string.format("this client lists %d weapon and %d armour subclasses, but "
            .. "Data/ItemClasses.lua describes %d and %d. Item type filtering is off for "
            .. "this session; nobody is excluded. Please report this.",
            liveWeapons, liveArmor, #Data.WEAPON_SUBCLASSES, #Data.ARMOR_SUBCLASSES))
    end
end

function ItemInfo.IndexMapUsable()
    return mapUsable
end

--------------------------------------------------------------------------------
-- Reading one item
--------------------------------------------------------------------------------

--- Look an item up now. Returns an itemInfo either way; `unresolved` says whether the
-- client had the item cached.
function ItemInfo.Get(link)
    local itemString, itemId, linkName = ItemInfo.ParseLink(link)
    if not itemString then
        return ItemInfo.Classify({ link = type(link) == "string" and link or nil })
    end

    -- Asking is also what makes the client fetch an item it does not hold.
    local name, fullLink, quality, itemLevel, _, itemType, itemSubType, _, equipLoc, icon =
        GetItemInfo(itemString)

    local classIndex, subClassIndex
    if mapUsable and itemType then
        classIndex = classIndexOf and classIndexOf[itemType] or nil
        local subs = classIndex and subIndexOf[classIndex] or nil
        subClassIndex = subs and subs[itemSubType] or nil
    end

    return ItemInfo.Classify({
        itemString = itemString,
        itemId = itemId,
        name = name or linkName,
        link = fullLink or (type(link) == "string" and link) or nil,
        quality = quality,
        itemLevel = itemLevel,
        equipLoc = equipLoc,
        icon = icon,
        classIndex = classIndex,
        subClassIndex = subClassIndex,
        cached = name ~= nil,
    })
end

--- Look an item up, retrying while the client fetches it (section 4, "uncached items").
-- 3.3.5a has no GET_ITEM_INFO_RECEIVED, so this is a ticker and not an event.
-- `callback(info)` is called exactly once, immediately when the item is already cached.
function ItemInfo.Request(link, callback)
    local info = ItemInfo.Get(link)
    if not info.unresolved or not info.itemString then
        -- No item string means there is nothing to wait for; retrying would only spend
        -- five seconds arriving at the same answer.
        callback(info)
        return
    end

    pending[#pending + 1] = { link = link, tries = 0, callback = callback }
    if frame then frame:Show() end
end

--- The batch form: `callback(list)` fires once, when every link has an itemInfo.
-- Order is preserved, because the loot slots are ordered.
function ItemInfo.RequestAll(links, callback)
    local results, outstanding, finished = {}, #links, false
    if outstanding == 0 then
        callback(results)
        return
    end

    for i = 1, #links do
        ItemInfo.Request(links[i], function(info)
            results[i] = info
            outstanding = outstanding - 1
            if outstanding == 0 and not finished then
                finished = true
                callback(results)
            end
        end)
    end
end

local function tick()
    if #pending == 0 then
        if frame then frame:Hide() end
        return
    end

    local still = {}
    for i = 1, #pending do
        local entry = pending[i]
        local info = ItemInfo.Get(entry.link)
        entry.tries = entry.tries + 1

        if not info.unresolved then
            entry.callback(info)
        elseif entry.tries >= ItemInfo.RETRY_MAX then
            -- Out of retries. The item goes in as `special`; losing an epic because the
            -- client had a cold cache would be unforgivable (spec 004 section 4).
            ns.Debug("gave up looking up " .. tostring(entry.link)
                .. "; entering it as unclassified.")
            entry.callback(info)
        else
            still[#still + 1] = entry
        end
    end
    pending = still
end

local function onUpdate(_, delta)
    elapsedSinceTick = elapsedSinceTick + delta
    if elapsedSinceTick < ItemInfo.RETRY_INTERVAL then return end
    elapsedSinceTick = 0
    tick()
end

--------------------------------------------------------------------------------
-- Verification helper
--------------------------------------------------------------------------------

--- `/rls itemclasses`. Prints the live subclass order beside our table so that flipping
-- Data.SUBCLASS_ORDER_VERIFIED is a reading exercise rather than an act of faith.
function ItemInfo.DumpClasses()
    local Data = ns.Data
    ns.Print("item class positions on this client:")
    local classes = { GetAuctionItemClasses() }
    for i = 1, #classes do
        ns.Print(string.format("  %d. %s", i, classes[i]))
    end

    local function dump(classIndex, ours, label)
        ns.Print(label .. " subclasses -- live, then Data/ItemClasses.lua:")
        local subs = { GetAuctionItemSubClasses(classIndex) }
        local rows = math.max(#subs, #ours)
        for j = 1, rows do
            ns.Print(string.format("  %2d. %-24s %s", j,
                tostring(subs[j]), tostring(ours[j])))
        end
    end

    dump(Data.CLASS_INDEX.WEAPON, Data.WEAPON_SUBCLASSES, "weapon")
    dump(Data.CLASS_INDEX.ARMOR, Data.ARMOR_SUBCLASSES, "armour")
    ns.Print("mapping is " .. (mapUsable and "in use" or "OFF -- the lengths disagree")
        .. "; Data.SUBCLASS_ORDER_VERIFIED is "
        .. tostring(Data.SUBCLASS_ORDER_VERIFIED) .. ".")
end

function ItemInfo.Init()
    if frame then return end
    buildIndexMap()

    frame = CreateFrame("Frame", "RaidLootSystemItemInfoFrame")
    frame:SetScript("OnUpdate", onUpdate)
    frame:Hide()                      -- shown only while something is pending
end
