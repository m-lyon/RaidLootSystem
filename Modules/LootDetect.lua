-- Modules/LootDetect.lua
--
-- Which items become a batch (spec 004 sections 2 and 3). Two ways in: scanning the loot
-- window as master looter, and an item link handed to us directly.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the `lootdetect`
-- suite; the file creates no frame and calls no WoW API while loading.

local ADDON, ns = ...

ns.LootDetect = {}
local LootDetect = ns.LootDetect

local C = ns.Constants

-- Why a loot slot was not offered as a batch candidate. Shown by the host panel next to the
-- manual-add control (spec 006), so "why is this not in the list" is never a mystery.
LootDetect.SKIP = {
    NO_LINK        = "NO_LINK",          -- a coin slot
    BELOW_QUALITY  = "BELOW_QUALITY",
    NOT_EQUIPPABLE = "NOT_EQUIPPABLE",
}

LootDetect.SKIP_TEXT = {
    NO_LINK        = "not an item",
    BELOW_QUALITY  = "below the quality threshold",
    NOT_EQUIPPABLE = "not equippable and not a tier token",
}

--------------------------------------------------------------------------------
-- Pure: the candidate rule (section 2)
--------------------------------------------------------------------------------

--- Should this loot slot be offered as a batch candidate?
--
-- @param info       an itemInfo from Modules/ItemInfo.lua
-- @param quality    the loot slot's quality. Preferred over info.quality: the loot window
--                   reports it without needing the item cached, and an item still being
--                   fetched has no info.quality at all.
-- @param threshold  host.qualityThreshold, 4 (epic) by default
-- @return true, or false plus a LootDetect.SKIP code
function LootDetect.IsCandidate(info, quality, threshold)
    threshold = threshold or 4

    if not info or not info.itemString then
        return false, LootDetect.SKIP.NO_LINK
    end

    local q = quality or info.quality
    if q and q < threshold then
        return false, LootDetect.SKIP.BELOW_QUALITY
    end

    -- A tier token is not equippable by anyone and is the whole reason this test is not
    -- simply "is it equippable" (spec 004 section 6).
    if info.tokenGroup then return true end
    if ns.ItemInfo.IsEquippable(info) then return true end

    -- The client never resolved it. It passed the quality bar, so it is very likely worth
    -- rolling for; it goes in as `special` rather than being quietly dropped.
    if info.unresolved then return true end

    -- Gold, emblems, mats, patterns, mounts. Excluded from the automatic list, still
    -- addable by hand from the host panel (section 2).
    return false, LootDetect.SKIP.NOT_EQUIPPABLE
end

--------------------------------------------------------------------------------
-- Pure: the candidate partition (section 2, spec 006 section 3)
--------------------------------------------------------------------------------

--- Split the corpse's slots into candidate rows and skipped rows, honouring the
-- host's manual additions. One function, so a manual add, a lost slot and a moved
-- quality bar cannot disagree about the list.
--
-- @param scanRows   every slot of the last scan: { lootSlot, quantity, quality, info }
-- @param manualIds  set of item ids the host added by hand from the skipped list
-- @param manualRows item-link additions with no loot slot: { quantity, info }
-- @param threshold  host.qualityThreshold
-- @param removedIds set of item ids withdrawn from the list: taken out by hand, or
--                   already rolled by a batch that closed. They are not offered back
--                   under `skipped` either -- the host said no, or the question has
--                   been answered. "Add item" on the link puts one back.
-- @return rows for Collapse, skipped array of { lootSlot, info, quality, reason }
function LootDetect.Partition(scanRows, manualIds, manualRows, threshold, removedIds)
    local rows, skipped = {}, {}
    manualIds = manualIds or {}
    removedIds = removedIds or {}
    for _, row in ipairs(scanRows or {}) do
        local id = row.info and row.info.itemId
        local ok, reason = LootDetect.IsCandidate(row.info, row.quality, threshold)
        if id and removedIds[id] then                    -- withdrawn: neither list
        elseif ok or (id and manualIds[id]) then
            rows[#rows + 1] = row
        else
            skipped[#skipped + 1] = { lootSlot = row.lootSlot, info = row.info,
                                      quality = row.quality, reason = reason }
        end
    end
    for _, row in ipairs(manualRows or {}) do
        local id = row.info and row.info.itemId
        if not (id and removedIds[id]) then rows[#rows + 1] = row end
    end
    return rows, skipped
end

--------------------------------------------------------------------------------
-- Pure: duplicate stacks (section 2)
--------------------------------------------------------------------------------

--- Collapse rows that hold the same item into one batch item with a count.
--
-- Both loot slots are kept: the award step needs every slot it will have to call
-- GiveMasterLoot on, and it needs them under one item so that resolution hands out two
-- copies of one thing rather than treating them as two unrelated drops (spec 003 section 5).
--
-- @param rows array of { lootSlot, quantity, info }
-- @return array of { idx, itemString, count, lootSlot, lootSlots, slotQuantities, info } in
--         slot order. `slotQuantities` maps each loot slot to the units it holds, so that
--         losing a slot that carried a stack subtracts the stack and not a single unit.
function LootDetect.Collapse(rows)
    local items, byItem = {}, {}

    for i = 1, #rows do
        local row = rows[i]
        local info = row.info or {}
        -- Two copies of one drop can carry different suffix or enchant fields, so the id is
        -- the grouping key and the item string is not.
        local key = info.itemId or info.itemString
        local quantity = row.quantity or 1
        local existing = key ~= nil and byItem[key] or nil

        if existing then
            existing.count = existing.count + quantity
            if row.lootSlot then
                existing.lootSlots[#existing.lootSlots + 1] = row.lootSlot
                existing.slotQuantities[row.lootSlot] = quantity
            end
        else
            local item = {
                idx = #items + 1,
                itemString = info.itemString,
                count = quantity,
                lootSlot = row.lootSlot,
                lootSlots = row.lootSlot and { row.lootSlot } or {},
                slotQuantities = row.lootSlot and { [row.lootSlot] = quantity } or {},
                info = info,
            }
            items[#items + 1] = item
            if key ~= nil then byItem[key] = item end
        end
    end

    return items
end

--------------------------------------------------------------------------------
-- Pure: losing loot mid-batch (section 3)
--------------------------------------------------------------------------------

--- Drop the loot slots `isGone(slot)` reports as no longer there.
--
-- An item with two slots keeps going on one copy rather than vanishing whole -- the count
-- drops instead. A batch that loses every item is what makes the host abort with LOOT_GONE;
-- this function reports that rather than deciding it.
--
-- @return kept array, lost array of { item, slots, quantity } (the items, the slots removed,
--         and the units those slots held)
function LootDetect.Prune(items, isGone)
    local kept, lost = {}, {}

    for i = 1, #items do
        local item = items[i]
        local slots = item.lootSlots or (item.lootSlot and { item.lootSlot }) or {}
        local quantities = item.slotQuantities or {}

        if #slots == 0 then
            kept[#kept + 1] = item             -- an item-link batch has no slot to lose
        else
            local live, gone, goneUnits = {}, {}, 0
            for j = 1, #slots do
                local slot = slots[j]
                if isGone(slot) then
                    gone[#gone + 1] = slot
                    -- A slot that held a stack loses the whole stack. A slot with no
                    -- recorded quantity (an older batch record) counts as one unit.
                    goneUnits = goneUnits + (quantities[slot] or 1)
                    quantities[slot] = nil
                else
                    live[#live + 1] = slot
                end
            end

            if #gone > 0 then
                lost[#lost + 1] = { item = item, slots = gone, quantity = goneUnits }
            end
            if #live > 0 then
                item.lootSlots = live
                item.lootSlot = live[1]
                item.count = math.max(1, (item.count or 1) - goneUnits)
                kept[#kept + 1] = item
            end
        end
    end

    return kept, lost
end

--- A short name for a message, without needing the item cached.
function LootDetect.Label(item)
    local info = item and item.info or {}
    return info.link or info.name or info.itemString or "an item"
end

--------------------------------------------------------------------------------
-- WoW-facing. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

-- The candidates from the last corpse scan, waiting for the host to start a batch
-- (spec 006 owns the panel; this owns the list).
LootDetect.candidates = {}     -- from Collapse
LootDetect.skipped = {}        -- { lootSlot, info, quality, reason } -- the manual-add list
LootDetect.scanning = false
LootDetect.windowOpen = false
LootDetect.sourceName = nil    -- the looted creature, as far as 3.3.5a lets us tell

local scanRows = {}            -- every slot of the last scan: { lootSlot, quantity, quality, info }
local manualIds = {}           -- item ids the host added by hand from the skipped list
local manualRows = {}          -- item-link additions with no loot slot: { quantity, info }
local removedIds = {}          -- ids withdrawn by hand or consumed by a closed batch

local listeners = {}
local expectedClears = {}      -- loot slots our own award is about to empty
local scanToken = 0            -- see LootDetect.Scan
local frame

function LootDetect.RegisterListener(fn)
    listeners[#listeners + 1] = fn
end

--- @param newScan true when a fresh corpse replaced the list, false for a rebuild
local function fireChanged(newScan)
    for _, fn in ipairs(listeners) do fn(LootDetect.candidates, newScan == true) end
end

--------------------------------------------------------------------------------
-- The corpse path (section 2)
--------------------------------------------------------------------------------

local function threshold()
    return ns.Database.Host().qualityThreshold or 4
end

--- Recompute the candidate and skipped lists from the retained scan (Partition).
local function rebuild(newScan)
    local rows, skipped = LootDetect.Partition(scanRows, manualIds, manualRows, threshold(),
        removedIds)
    LootDetect.candidates = LootDetect.Collapse(rows)
    LootDetect.skipped = skipped
    fireChanged(newScan)
end

--- Scan the open loot window. Asynchronous, because an uncached item takes up to five
-- seconds to resolve and a batch must not open on a half-classified list.
-- @param callback optional, called with the candidate array
function LootDetect.Scan(callback)
    local slots, links = {}, {}
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink(slot)
        if link then
            local _, _, quantity, quality = GetLootSlotInfo(slot)
            slots[#slots + 1] = { lootSlot = slot, quantity = quantity or 1, quality = quality }
            links[#links + 1] = link
        end
    end

    -- A scan can still be waiting on the item cache when the host closes this corpse and
    -- opens the next one. The older answer must not land on the newer corpse's list.
    scanToken = scanToken + 1
    local token = scanToken

    LootDetect.scanning = true
    ns.ItemInfo.RequestAll(links, function(infos)
        if token ~= scanToken then return end
        for i = 1, #slots do slots[i].info = infos[i] end
        -- A new corpse: whatever the host added by hand, or took out, was for the
        -- last one.
        scanRows, manualIds, manualRows, removedIds = slots, {}, {}, {}
        LootDetect.scanning = false
        rebuild(true)
        if callback then callback(LootDetect.candidates) end
    end)
end

--- Re-apply the candidate rule to the last scan, after the quality bar moves.
function LootDetect.Rescan()
    if #scanRows > 0 then rebuild() end
end

--- Add an item the filter excluded (spec 006 section 3, "Add item"). A link that
-- matches a skipped loot slot joins with that slot, so the award still goes through
-- master loot; anything else joins as an item-link row and will be traded.
-- @param callback optional, called with true once it is in the list
function LootDetect.AddCandidate(link, callback)
    local itemString, itemId = ns.ItemInfo.ParseLink(link)
    if not itemString then
        ns.Print("that is not an item link.")
        if callback then callback(false) end
        return false
    end
    removedIds[itemId] = nil            -- adding it back undoes a withdrawal

    for _, row in ipairs(scanRows) do
        if row.info and row.info.itemId == itemId then
            manualIds[itemId] = true
            rebuild()
            if callback then callback(true) end
            return true
        end
    end

    ns.ItemInfo.Request(link, function(info)
        for _, row in ipairs(manualRows) do
            if row.info.itemId == info.itemId then
                row.quantity = row.quantity + 1
                rebuild()
                if callback then callback(true) end
                return
            end
        end
        manualRows[#manualRows + 1] = { quantity = 1, info = info }
        rebuild()
        if callback then callback(true) end
    end)
    return true
end

--- Take one item out of the candidate list, whatever put it there: an item-link
-- addition, a skipped row the host promoted, or a plain corpse row. It stays out
-- until the next corpse scan or an explicit "Add item" on the same link.
function LootDetect.RemoveCandidate(itemId)
    if not itemId then return end
    for i = #manualRows, 1, -1 do
        if manualRows[i].info.itemId == itemId then table.remove(manualRows, i) end
    end
    manualIds[itemId] = nil
    removedIds[itemId] = true
    rebuild()
end

--- The items a batch closed on stop being candidates for the next one (spec 006
-- section 3). Called on close, not on open: an aborted batch leaves its items in
-- place so the host can start it again.
function LootDetect.Consume(items)
    for _, item in ipairs(items or {}) do
        local _, id = ns.ItemInfo.ParseLink(item.itemString)
        if id then
            for i = #manualRows, 1, -1 do
                if manualRows[i].info.itemId == id then table.remove(manualRows, i) end
            end
            manualIds[id] = nil
            removedIds[id] = true
        end
    end
    rebuild()
end

--------------------------------------------------------------------------------
-- The item-link path (section 2)
--------------------------------------------------------------------------------

--- Start a batch on one item link. No loot slot, so the award step goes to the trade
-- path (spec 007 section 5) rather than GiveMasterLoot.
-- @param callback optional, called with the single-item array
function LootDetect.FromLink(link, callback)
    local itemString = ns.ItemInfo.ParseLink(link)
    if not itemString then
        ns.Print("that is not an item link.")
        if callback then callback(nil) end
        return false
    end

    ns.ItemInfo.Request(link, function(info)
        -- No quality bar and no equip test on this path. The host asked for this item by
        -- name; second-guessing them is the one thing the manual path exists to avoid.
        local items = LootDetect.Collapse({ { quantity = 1, info = info } })
        if callback then callback(items) end
    end)
    return true
end

--------------------------------------------------------------------------------
-- Loot source validity (section 3)
--------------------------------------------------------------------------------

--- Award tells us before it empties a slot, so that its own clear is not read as the
-- corpse being looted out from under the batch.
function LootDetect.ExpectClear(lootSlot)
    if lootSlot then expectedClears[lootSlot] = true end
end

--- The award never cleared the slot, so a later clear is somebody else's again.
function LootDetect.UnexpectClear(lootSlot)
    if lootSlot then expectedClears[lootSlot] = nil end
end

--- Does `lootSlot` still hold `itemString`? Checked at award time, when a despawned
-- corpse or a shifted slot index would otherwise send an item to the wrong person.
function LootDetect.SlotHolds(lootSlot, itemString)
    if not lootSlot or not itemString then return false end
    if lootSlot > GetNumLootItems() then return false end
    local link = GetLootSlotLink(lootSlot)
    if not link then return false end
    local _, liveId = ns.ItemInfo.ParseLink(link)
    local _, wantedId = ns.ItemInfo.ParseLink(itemString)
    return wantedId ~= nil and wantedId == liveId
end

--- Items in the open batch that are still sitting on the corpse. Drives the host panel's
-- "loot still on corpse" banner (section 3) -- three minutes is long enough to walk away.
function LootDetect.UnresolvedItems()
    local session = ns.Session.current
    if not session or not session.items then return {} end

    local out = {}
    for i = 1, #session.items do
        local item = session.items[i]
        local slots = item.lootSlots or (item.lootSlot and { item.lootSlot }) or {}
        for j = 1, #slots do
            if LootDetect.SlotHolds(slots[j], item.itemString) then
                out[#out + 1] = item
                break
            end
        end
    end
    return out
end

local function onSlotCleared(lootSlot)
    if expectedClears[lootSlot] then
        expectedClears[lootSlot] = nil
        return
    end

    -- Somebody else took it, or it was looted by hand. Whatever the batch thought it was
    -- rolling for is not there any more, and a silently shrinking batch costs an item.
    local session = ns.Session.current
    if session and session.state == C.SESSION_STATE.OPEN and ns.Session.IsHost() then
        ns.Session.DropSlots({ [lootSlot] = true })
    end

    local kept = {}
    for _, row in ipairs(scanRows) do
        if row.lootSlot ~= lootSlot then kept[#kept + 1] = row end
    end
    if #kept ~= #scanRows then
        scanRows = kept
        rebuild()
    end
end

local function onEvent(_, event, arg1)
    if event == "LOOT_OPENED" then
        LootDetect.windowOpen = true
        -- 3.3.5a has no loot-source API. The dead target is the best available guess
        -- and is right whenever the looter is targeting what they killed (spec 008).
        if UnitExists("target") and UnitIsDead("target") then
            LootDetect.sourceName = UnitName("target")
        else
            LootDetect.sourceName = nil
        end
        -- Only the master looter builds a batch, and only they see the candidate list.
        if not ns.Session.IsHost() then return end
        LootDetect.Scan(function(items)
            if #items == 0 then return end
            if ns.HostPanel then
                ns.HostPanel.Show()
            else
                -- Until spec 006's panel exists, the host is told rather than railroaded:
                -- auto-opening on every corpse would fire on trash and on other people's kills.
                ns.Print(string.format("%d item(s) here are worth rolling for. "
                    .. "/rls loot to list them, /rls start to open a batch.", #items))
            end
        end)
    elseif event == "LOOT_SLOT_CLEARED" then
        onSlotCleared(arg1)
    elseif event == "LOOT_CLOSED" then
        -- Not fatal: the slot indices survive and the corpse can be reopened (section 3).
        LootDetect.windowOpen = false
        expectedClears = {}
    end
end

function LootDetect.Init()
    if frame then return end
    frame = CreateFrame("Frame", "RaidLootSystemLootDetectFrame")
    frame:RegisterEvent("LOOT_OPENED")
    frame:RegisterEvent("LOOT_SLOT_CLEARED")
    frame:RegisterEvent("LOOT_CLOSED")
    frame:SetScript("OnEvent", onEvent)
end
