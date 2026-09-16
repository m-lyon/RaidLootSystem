-- Modules/LootDetect.lua
--
-- Which items become a round (spec 004 sections 2 and 3). Two ways in: scanning the loot
-- window as master looter, and an item link handed to us directly.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the `lootdetect`
-- suite; the file creates no frame and calls no WoW API while loading.

local ADDON, ns = ...

ns.LootDetect = {}
local LootDetect = ns.LootDetect

local C = ns.Constants

-- Why a loot slot was not offered as a round candidate. Shown by the host panel next to the
-- manual-add control (spec 006), so "why is this not in the list" is never a mystery.
LootDetect.SKIP = {
    NO_LINK        = "NO_LINK",          -- a coin slot
    BELOW_QUALITY  = "BELOW_QUALITY",
    NOT_EQUIPPABLE = "NOT_EQUIPPABLE",
    ALREADY_ROLLED = "ALREADY_ROLLED",   -- a closed round on this corpse took it
}

LootDetect.SKIP_TEXT = {
    NO_LINK        = "not an item",
    BELOW_QUALITY  = "below the quality threshold",
    NOT_EQUIPPABLE = "not equippable and not a tier token",
    ALREADY_ROLLED = "already rolled for",
}

--------------------------------------------------------------------------------
-- Pure: the candidate rule (section 2)
--------------------------------------------------------------------------------

--- Should this loot slot be offered as a round candidate?
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
-- @param removedIds set of item ids the host took out by hand. They are not offered
--                   back under `skipped` either -- the host said no. "Add item" on the
--                   link puts one back.
-- @param consumedIds set of item ids a closed round already rolled for. Offered under
--                   `skipped`, not dropped: a different corpse can share ids with the
--                   last one, and a silently missing drop costs someone an item.
-- @return rows for Collapse, skipped array of { lootSlot, info, quality, reason }
function LootDetect.Partition(scanRows, manualIds, manualRows, threshold, removedIds,
                              consumedIds)
    local rows, skipped = {}, {}
    manualIds = manualIds or {}
    removedIds = removedIds or {}
    consumedIds = consumedIds or {}
    for _, row in ipairs(scanRows or {}) do
        local id = row.info and row.info.itemId
        local ok, reason = LootDetect.IsCandidate(row.info, row.quality, threshold)
        -- Consumed beats a manual mark: "Add item" clears consumption, so a mark still
        -- standing beside it is left over from before the round, possibly on another corpse.
        local consumed = id and consumedIds[id]
        if consumed then
            ok, reason = false, LootDetect.SKIP.ALREADY_ROLLED
        end
        if id and removedIds[id] then                    -- withdrawn: neither list
        elseif ok or (id and manualIds[id] and not consumed) then
            rows[#rows + 1] = row
        else
            skipped[#skipped + 1] = { lootSlot = row.lootSlot, info = row.info,
                                      quality = row.quality, reason = reason }
        end
    end
    for _, row in ipairs(manualRows or {}) do
        local id = row.info and row.info.itemId
        if not (id and (removedIds[id] or consumedIds[id])) then rows[#rows + 1] = row end
    end
    return rows, skipped
end

--- Is a fresh scan the same corpse reopened, rather than a new one?
--
-- 3.3.5a has no loot-source API, so it is judged by contents: a reopened corpse holds
-- nothing it did not hold before (awards only take slots away). Items a closed round
-- consumed survive a reopen, or the loot already rolled for comes back as candidates
-- and a second round on it is one click away.
--
-- @param oldRows the previous scan's rows
-- @param newRows the fresh scan's rows
function LootDetect.SameSource(oldRows, newRows)
    if #(oldRows or {}) == 0 or #(newRows or {}) == 0 then return false end
    local had = {}
    for _, row in ipairs(oldRows) do
        local id = row.info and row.info.itemId
        if id then had[id] = true end
    end
    -- A row the item cache has not resolved yet is unknown, not a mismatch.
    local matched = false
    for _, row in ipairs(newRows) do
        local id = row.info and row.info.itemId
        if id then
            if not had[id] then return false end
            matched = true
        end
    end
    return matched
end

--- Which remembered loot source is a fresh scan reopening, if any?
--
-- Every source is kept, not only the last one: a host who closes a round on the boss,
-- loots a trash mob and goes back to the boss to award must still find the boss's
-- consumed items out. A dead target's GUID tells two sources apart when both have one;
-- it never matches on its own, since the looter need not be targeting the corpse.
-- Newest first, so the most recent match wins. A source older than the last scan is
-- only matched by contents when every fresh row is resolved, or both GUIDs agree: an
-- unresolved row could be what tells a new corpse apart, and the older the sources a
-- partial scan is checked against, the likelier a false reopen.
--
-- @param sources array of { guid, rows, consumed }, newest first
-- @param guid    the dead target's GUID at LOOT_OPENED, or nil
-- @param newRows the fresh scan's rows
-- @return index into sources, or nil for a new source
function LootDetect.MatchSource(sources, guid, newRows)
    local allResolved = true
    for _, row in ipairs(newRows or {}) do
        if not (row.info and row.info.itemId) then allResolved = false break end
    end
    for i, source in ipairs(sources or {}) do
        if not (guid and source.guid and guid ~= source.guid)
            and (i == 1 or allResolved or (guid and source.guid == guid))
            and LootDetect.SameSource(source.rows, newRows) then
            return i
        end
    end
    return nil
end

--- Remember a fresh scan as a loot source, reusing the one it reopens.
--
-- A contents-only match is not certain: a different corpse holding a subset of the
-- matched one's ids passes it. So the matched record's rows and GUID are replaced only
-- when both GUIDs agree; otherwise it is kept as it was, and reopening the original
-- corpse still finds it with its consumed set.
--
-- @param sources array of { guid, rows, consumed }, newest first; modified in place
-- @param guid    the dead target's GUID at LOOT_OPENED, or nil
-- @param rows    the fresh scan's rows
-- @param max     how many sources to keep
-- @return the source, and the index it matched at (nil for a new source)
function LootDetect.RememberSource(sources, guid, rows, max)
    local match = LootDetect.MatchSource(sources, guid, rows)
    local source
    if match then
        source = table.remove(sources, match)
        if guid and source.guid == guid then source.rows = rows end
    else
        source = { consumed = {}, rows = rows, guid = guid }
        -- A scan with no resolved ids can never be matched again; remembering it would
        -- only push a real corpse, and its consumed set, off the end of the list.
        local anyId = false
        for _, row in ipairs(rows or {}) do
            if row.info and row.info.itemId then anyId = true break end
        end
        if not anyId then return source, nil end
    end
    table.insert(sources, 1, source)
    for i = #sources, (max or #sources) + 1, -1 do sources[i] = nil end
    return source, match
end

--- Which loot source a closing round consumes into, and whether it strips the manual
-- additions.
--
-- A round bound to a corpse writes to that corpse's consumed set, which need not be the
-- one open now. A round with no loot-slot items (an item-link round) consumes into the
-- source that was open when it opened, but only the ids that source's scan actually holds,
-- so a rolled-by-link corpse item still leaves the setup list and nothing else is marked.
-- A round bound to neither -- nothing was open when it opened, so it was rolled from bags
-- -- consumes into no corpse, but still strips the manual rows: leaving them there invites
-- a second round on loot already awarded (spec 006 section 3). Only a simulated round
-- touches nothing at all. The manual additions belong to the corpse open now, so another
-- corpse's round leaves them.
--
-- @param roundSources round id -> the source that round was opened from
-- @param openSource   the source of the last scan, or nil
-- @param roundId      the closing round, or nil for the open source
-- @param linkSources  round id -> the source open when an item-link round opened
-- @param simulated    round id -> true for a simulated round
-- @return the source to consume into (nil for none), whether to strip manual rows, and
--         whether to consume only the ids the source's scan holds
function LootDetect.ConsumeTarget(roundSources, openSource, roundId, linkSources, simulated)
    if not roundId then return openSource, true, false end
    if simulated and simulated[roundId] then return nil, false, false end
    local bound = roundSources[roundId]
    if bound ~= nil then return bound, bound == openSource, false end
    local held = linkSources and linkSources[roundId]
    if held == nil then return nil, true, false end
    return held, held == openSource, true
end

--------------------------------------------------------------------------------
-- Pure: duplicate stacks (section 2)
--------------------------------------------------------------------------------

--- Collapse rows that hold the same item into one round item with a count.
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
-- Pure: losing loot mid-round (section 3)
--------------------------------------------------------------------------------

--- Drop the loot slots `isGone(slot)` reports as no longer there.
--
-- An item with two slots keeps going on one copy rather than vanishing whole -- the count
-- drops instead. A round that loses every item is what makes the host abort with LOOT_GONE;
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
            kept[#kept + 1] = item             -- an item-link round has no slot to lose
        else
            local live, gone, goneUnits = {}, {}, 0
            for j = 1, #slots do
                local slot = slots[j]
                if isGone(slot) then
                    gone[#gone + 1] = slot
                    -- A slot that held a stack loses the whole stack. A slot with no
                    -- recorded quantity (an older round record) counts as one unit.
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

-- The candidates from the last corpse scan, waiting for the host to start a round
-- (spec 006 owns the panel; this owns the list).
LootDetect.candidates = {}     -- from Collapse
LootDetect.skipped = {}        -- { lootSlot, info, quality, reason } -- the manual-add list
LootDetect.scanning = false
LootDetect.windowOpen = false
LootDetect.sourceName = nil    -- the looted creature, as far as 3.3.5a lets us tell
LootDetect.sourceGuid = nil    -- its GUID, when the looter is targeting it

local scanRows = {}            -- every slot of the last scan: { lootSlot, quantity, quality, info }
local manualIds = {}           -- item ids the host added by hand from the skipped list
local manualRows = {}          -- item-link additions with no loot slot: { quantity, info }
local removedIds = {}          -- ids withdrawn by hand
local consumedIds = {}         -- ids a closed round rolled for; the open source's set
local sources = {}             -- remembered loot sources, newest first: { guid, rows, consumed }
local roundSources = {}        -- round id -> the source that round was opened from
local linkSources = {}         -- round id -> the source open when an item-link round opened
local simulatedRounds = {}     -- round id -> true; a simulation consumes nothing
local openSource = nil         -- the last scan's source, remembered or not
local MAX_SOURCES = 10

local listeners = {}
local expectedClears = {}      -- loot slots our own award is about to empty
local scanToken = 0            -- see LootDetect.Scan
local frame

function LootDetect.RegisterListener(fn)
    listeners[#listeners + 1] = fn
end

--- @param newScan true when a fresh corpse replaced the list, false for a rebuild
--- @param reopened true when that corpse is a remembered source the host reopened
local function fireChanged(newScan, reopened)
    for _, fn in ipairs(listeners) do
        fn(LootDetect.candidates, newScan == true, reopened == true)
    end
end

--------------------------------------------------------------------------------
-- The corpse path (section 2)
--------------------------------------------------------------------------------

local function threshold()
    local host = ns.Database.Host()
    return (host and host.qualityThreshold) or 4
end

--- Recompute the candidate and skipped lists from the retained scan (Partition).
local function rebuild(newScan, reopened)
    local rows, skipped = LootDetect.Partition(scanRows, manualIds, manualRows, threshold(),
        removedIds, consumedIds)
    LootDetect.candidates = LootDetect.Collapse(rows)
    LootDetect.skipped = skipped
    fireChanged(newScan, reopened)
end

--- Scan the open loot window. Asynchronous, because an uncached item takes up to five
-- seconds to resolve and a round must not open on a half-classified list.
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
        -- last one. A reopened one keeps what its closed rounds consumed, and what the
        -- host added or removed, even with other corpses opened in between.
        local source, match = LootDetect.RememberSource(sources, LootDetect.sourceGuid,
            slots, MAX_SOURCES)
        openSource = source
        source.manualIds = source.manualIds or {}
        source.manualRows = source.manualRows or {}
        source.removedIds = source.removedIds or {}
        consumedIds = source.consumed
        scanRows, manualIds, manualRows, removedIds =
            slots, source.manualIds, source.manualRows, source.removedIds
        LootDetect.scanning = false
        rebuild(true, match ~= nil)
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
--- With no loot window open, hand edits must not write into the last corpse's tables:
-- that corpse would bring them back on a reopen. Copy them once; the next scan replaces
-- the copies with the scanned source's own.
local function detach()
    if LootDetect.windowOpen or not openSource or manualRows ~= openSource.manualRows then
        return
    end
    local ids, rows, removed, consumed = {}, {}, {}, {}
    for k, v in pairs(manualIds) do ids[k] = v end
    for i, row in ipairs(manualRows) do rows[i] = { quantity = row.quantity, info = row.info } end
    for k, v in pairs(removedIds) do removed[k] = v end
    for k, v in pairs(consumedIds) do consumed[k] = v end
    manualIds, manualRows, removedIds, consumedIds = ids, rows, removed, consumed
end

function LootDetect.AddCandidate(link, callback)
    local itemString, itemId = ns.ItemInfo.ParseLink(link)
    if not itemString then
        ns.Print("that is not an item link.")
        if callback then callback(false) end
        return false
    end
    detach()
    removedIds[itemId] = nil            -- adding it back undoes a withdrawal
    consumedIds[itemId] = nil

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
-- until a new corpse is scanned or an explicit "Add item" on the same link.
function LootDetect.RemoveCandidate(itemId)
    if not itemId then return end
    detach()
    for i = #manualRows, 1, -1 do
        if manualRows[i].info.itemId == itemId then table.remove(manualRows, i) end
    end
    manualIds[itemId] = nil
    removedIds[itemId] = true
    rebuild()
end

--- The items a round closed on stop being candidates for the next one (spec 006
-- section 3). Called on close, not on open: an aborted round leaves its items in
-- place so the host can start it again.
function LootDetect.Consume(items, roundId)
    local target, stripManual, heldOnly =
        LootDetect.ConsumeTarget(roundSources, openSource, roundId, linkSources, simulatedRounds)
    local set = target and target.consumed
    local held
    if set and heldOnly then
        held = {}
        for _, row in ipairs(target.rows or {}) do
            if row.info and row.info.itemId then held[row.info.itemId] = true end
        end
    end
    for _, item in ipairs(items or {}) do
        local _, id = ns.ItemInfo.ParseLink(item.itemString)
        if id then
            if stripManual then
                for i = #manualRows, 1, -1 do
                    if manualRows[i].info.itemId == id then table.remove(manualRows, i) end
                end
                manualIds[id] = nil
            end
            if set and (not held or held[id]) then
                set[id] = true
                if target == openSource then consumedIds[id] = true end
            end
        end
    end
    rebuild()
end

--- Tie a round to the loot source open when it started, for Consume.
-- A round with loot-slot items took them from the last scan, whether or not its loot
-- window is still open, so it is bound to that scan's source regardless. A round with none
-- is bound only to a source actually open now. A simulated round is bound to nothing, so
-- it cannot mark a real corpse's drops rolled for.
function LootDetect.BindRound(roundId, items)
    if not roundId then return end
    if ns.Simulate and ns.Simulate.active then
        simulatedRounds[roundId] = true
        return
    end
    for _, item in ipairs(items or {}) do
        if item.lootSlot then
            roundSources[roundId] = openSource
            return
        end
    end
    if LootDetect.SourceOpen(openSource) then linkSources[roundId] = openSource end
end

--- The loot source round `roundId` was bound to, or nil.
function LootDetect.RoundSource(roundId)
    return roundId and roundSources[roundId]
end

--- Is `source` the loot source open now?
function LootDetect.SourceOpen(source)
    -- Until a new window's scan lands, openSource is still the last corpse's.
    return source ~= nil and LootDetect.windowOpen and not LootDetect.scanning
        and source == openSource
end

--- Is `source` still remembered (or the one open now), so the corpse can come back?
function LootDetect.SourceKnown(source)
    if source == nil then return false end
    if source == openSource then return true end
    for _, known in ipairs(sources) do
        if known == source then return true end
    end
    return false
end

--- Forget a round's source once its close or abort has been handled.
function LootDetect.ReleaseRound(roundId)
    if roundId then
        -- A restarted round on the same corpse may leave nothing again; say so again.
        local source = roundSources[roundId] or linkSources[roundId]
        if source then source.hint = nil end
        roundSources[roundId] = nil
        linkSources[roundId] = nil
        simulatedRounds[roundId] = nil
    end
end

--------------------------------------------------------------------------------
-- The item-link path (section 2)
--------------------------------------------------------------------------------

--- Start a round on one item link. No loot slot, so the award step goes to the trade
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
-- corpse being looted out from under the round.
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

--- Items in the open round that are still sitting on the corpse. Drives the host panel's
-- "loot still on corpse" banner (section 3) -- three minutes is long enough to walk away.
function LootDetect.UnresolvedItems()
    local round = ns.Round.current
    if not round or not round.items then return {} end

    local out = {}
    for i = 1, #round.items do
        local item = round.items[i]
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

    -- Somebody else took it, or it was looted by hand. Whatever the round thought it was
    -- rolling for is not there any more, and a silently shrinking round costs an item.
    local round = ns.Round.current
    if round and round.state == C.ROUND_STATE.OPEN and ns.Round.IsHost() then
        ns.Round.DropSlots({ [lootSlot] = true })
    end

    local kept = {}
    for _, row in ipairs(scanRows) do
        if row.lootSlot ~= lootSlot then kept[#kept + 1] = row end
    end
    if #kept ~= #scanRows then
        if openSource and openSource.rows == scanRows then openSource.rows = kept end
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
            LootDetect.sourceGuid = UnitGUID("target")
        else
            LootDetect.sourceName = nil
            LootDetect.sourceGuid = nil
        end
        -- Only the master looter builds a round, and only they see the candidate list.
        if not ns.Round.IsHost() then return end
        LootDetect.Scan(function(items)
            if #items == 0 then
                -- Judged the same corpse by contents, which a different one sharing
                -- drops can pass. Say so rather than show nothing.
                local rolled, handAdd = 0, 0
                for _, skip in ipairs(LootDetect.skipped) do
                    if skip.reason == LootDetect.SKIP.ALREADY_ROLLED then rolled = rolled + 1 end
                    if skip.reason ~= LootDetect.SKIP.ALREADY_ROLLED
                        and ns.RollWindow and ns.RollWindow.HandAddable(skip, GetLootThreshold()) then
                        handAdd = handAdd + 1
                    end
                end
                -- Once per source: the host reopens a corpse after every award, and a
                -- trash mob's mats say the same thing each time.
                local hint = rolled .. ":" .. handAdd
                if openSource then
                    if openSource.hint == hint then return end
                    openSource.hint = hint
                end
                if rolled > 0 then
                    ns.Print(string.format("%d item(s) here were already rolled for. "
                        .. "/rls loot to list them.", rolled))
                end
                if handAdd > 0 then
                    ns.Print(string.format("%d item(s) here are not automatic candidates and "
                        .. "can be added by hand. /rls loot to list them.", handAdd))
                end
                return
            end
            -- The roll window's setup state, not the host panel: one window for the
            -- whole loot journey (spec 005 section 2). Only the master looter gets it,
            -- and only when this corpse actually has something worth rolling for.
            -- A window left on a closed round's results (an award still owed here) is
            -- not an invitation to start another round on the same loot. A live round
            -- still gets the chat line, so this corpse is not silently passed over.
            if ns.RollWindow then
                if ns.RollWindow.ShowSetup() then return end
                local round = ns.Round.current
                if ns.RollWindow.IsShown() and round and round.state == C.ROUND_STATE.CLOSED then
                    return
                end
            end
            ns.Print(string.format("%d item(s) here are worth rolling for. "
                .. "/rls loot to list them, /rls start to open a round.", #items))
        end)
    elseif event == "LOOT_SLOT_CLEARED" then
        onSlotCleared(arg1)
    elseif event == "LOOT_CLOSED" then
        -- Not fatal: the slot indices survive and the corpse can be reopened (section 3).
        LootDetect.windowOpen = false
        expectedClears = {}
        fireChanged(false)
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
