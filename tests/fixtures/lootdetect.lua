-- tests/fixtures/lootdetect.lua
--
-- Spec 004 sections 2 and 3: the candidate rule, duplicate stacks, and losing loot
-- under an open batch.

local ns = ...

local function slotList(item)
    local slots = item.lootSlots or {}
    local out = {}
    for i = 1, #slots do out[i] = tostring(slots[i]) end
    return table.concat(out, ",")
end

local function unitList(item)
    local slots = item.lootSlots or {}
    local q = item.slotQuantities or {}
    local out = {}
    for i = 1, #slots do out[i] = slots[i] .. "=" .. tostring(q[slots[i]]) end
    return table.concat(out, ",")
end

local function project(items)
    local out = {}
    for i = 1, #items do
        out[i] = {
            idx = items[i].idx,
            itemString = items[i].itemString or "",
            count = items[i].count,
            slots = slotList(items[i]),
            units = unitList(items[i]),
        }
    end
    return out
end

local function run(input, ns)
    local LootDetect = ns.LootDetect

    if input.op == "candidate" then
        local ok, reason = LootDetect.IsCandidate(input.info, input.quality, input.threshold)
        return { ok = ok, reason = reason or "" }

    elseif input.op == "collapse" then
        return { items = project(LootDetect.Collapse(input.rows)) }

    elseif input.op == "partition" then
        local rows, skipped = LootDetect.Partition(input.scanRows, input.manualIds,
            input.manualRows, input.threshold)
        local candidates = project(LootDetect.Collapse(rows))
        local out = {}
        for i, skip in ipairs(skipped) do
            out[i] = tostring(skip.lootSlot) .. ":" .. skip.reason
        end
        return { candidates = candidates, skipped = out }

    elseif input.op == "prune" then
        local gone = input.gone
        local kept, lost = LootDetect.Prune(input.items, function(slot)
            return gone[slot] == true
        end)
        local lostSlots = {}
        for i = 1, #lost do
            lostSlots[i] = { idx = lost[i].item.idx, slots = table.concat(lost[i].slots, ","),
                             quantity = lost[i].quantity }
        end
        return { kept = project(kept), lost = lostSlots }
    end

    error("unknown op: " .. tostring(input.op))
end

--- An itemInfo as Modules/ItemInfo.lua would produce it.
local function info(id, fields)
    local out = {
        itemId = id,
        itemString = "item:" .. id .. ":0:0:0:0:0:0:0:0",
        quality = 4,
    }
    for k, v in pairs(fields or {}) do out[k] = v end
    return out
end

local EPIC_CHEST = info(40000, { equipLoc = "INVTYPE_CHEST", armorSubclass = "PLATE" })
local TOKEN = info(40616, { equipLoc = nil, tokenGroup = "PROTECTOR",
                            tokenClasses = { WARRIOR = true } })
local MOUNT = info(44083, { special = true })
local COLD = info(50000, { quality = nil, special = true, unresolved = true })
local GREEN = info(41000, { equipLoc = "INVTYPE_CHEST", quality = 2 })

--- A batch item as LootDetect.Collapse would produce it.
local function batchItem(idx, id, count, slots, slotQuantities)
    if not slotQuantities then
        slotQuantities = {}
        for i = 1, #slots do slotQuantities[slots[i]] = 1 end
    end
    return {
        idx = idx,
        itemString = "item:" .. id .. ":0:0:0:0:0:0:0:0",
        count = count,
        lootSlot = slots[1],
        lootSlots = slots,
        slotQuantities = slotQuantities,
        info = info(id),
    }
end

return {
    name = "lootdetect",
    run = run,
    cases = {
        ----------------------------------------------------------------------
        -- The candidate rule (section 2)
        ----------------------------------------------------------------------
        {
            name = "an epic chest piece is a candidate",
            input = { op = "candidate", info = EPIC_CHEST, quality = 4 },
            expected = { ok = true, reason = "" },
        },
        {
            name = "a coin slot has no item link and is skipped",
            input = { op = "candidate", info = { quality = 4 }, quality = 4 },
            expected = { ok = false, reason = "NO_LINK" },
        },
        {
            name = "a green is below the default threshold",
            input = { op = "candidate", info = GREEN, quality = 2 },
            expected = { ok = false, reason = "BELOW_QUALITY" },
        },
        {
            name = "lowering the threshold to rare admits a blue",
            input = { op = "candidate", info = EPIC_CHEST, quality = 3, threshold = 3 },
            expected = { ok = true, reason = "" },
        },
        {
            name = "raising the threshold above epic excludes an epic",
            input = { op = "candidate", info = EPIC_CHEST, quality = 4, threshold = 5 },
            expected = { ok = false, reason = "BELOW_QUALITY" },
        },
        {
            -- The one the naive equip test gets wrong, and the most contested drop there is.
            name = "a tier token is a candidate despite being equippable by nobody",
            input = { op = "candidate", info = TOKEN, quality = 4 },
            expected = { ok = true, reason = "" },
        },
        {
            name = "a mount is not auto-added; it is manually addable instead",
            input = { op = "candidate", info = MOUNT, quality = 4 },
            expected = { ok = false, reason = "NOT_EQUIPPABLE" },
        },
        {
            -- The loot slot reports quality without the item cache, so the bar is still
            -- applied. Dropping the item entirely is what must not happen.
            name = "an epic the client never resolved is still a candidate",
            input = { op = "candidate", info = COLD, quality = 4 },
            expected = { ok = true, reason = "" },
        },
        {
            name = "an unresolved item below the bar is still excluded",
            input = { op = "candidate", info = COLD, quality = 2 },
            expected = { ok = false, reason = "BELOW_QUALITY" },
        },

        ----------------------------------------------------------------------
        -- Duplicate stacks (section 2)
        ----------------------------------------------------------------------
        {
            name = "two loot slots of one item become one batch item with count 2",
            input = { op = "collapse", rows = {
                { lootSlot = 1, quantity = 1, info = info(40000) },
                { lootSlot = 3, quantity = 1, info = info(40000) },
            } },
            expected = { items = {
                { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                  count = 2, slots = "1,3", units = "1=1,3=1" },
            } },
        },
        {
            name = "different items keep their own entries, in slot order",
            input = { op = "collapse", rows = {
                { lootSlot = 1, quantity = 1, info = info(40000) },
                { lootSlot = 2, quantity = 1, info = info(40001) },
                { lootSlot = 4, quantity = 1, info = info(40000) },
            } },
            expected = { items = {
                { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                  count = 2, slots = "1,4", units = "1=1,4=1" },
                { idx = 2, itemString = "item:40001:0:0:0:0:0:0:0:0",
                  count = 1, slots = "2", units = "2=1" },
            } },
        },
        {
            -- Two copies of one drop can carry different suffix fields, so the id groups
            -- them and the item string does not.
            name = "copies with different suffix fields still collapse",
            input = { op = "collapse", rows = {
                { lootSlot = 1, quantity = 1,
                  info = { itemId = 40000, itemString = "item:40000:0:0:0:0:0:0:0:80" } },
                { lootSlot = 2, quantity = 1,
                  info = { itemId = 40000, itemString = "item:40000:0:0:0:0:0:1:0:80" } },
            } },
            expected = { items = {
                { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:80",
                  count = 2, slots = "1,2", units = "1=1,2=1" },
            } },
        },
        {
            name = "a stack of three counts as three",
            input = { op = "collapse", rows = {
                { lootSlot = 1, quantity = 3, info = info(40000) },
            } },
            expected = { items = {
                { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                  count = 3, slots = "1", units = "1=3" },
            } },
        },
        {
            name = "an item-link batch has no loot slot",
            input = { op = "collapse", rows = {
                { quantity = 1, info = info(40000) },
            } },
            expected = { items = {
                { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                  count = 1, slots = "", units = "" },
            } },
        },

        ----------------------------------------------------------------------
        -- The candidate partition (section 2, spec 006 section 3)
        ----------------------------------------------------------------------
        {
            name = "the partition keeps candidates and names why the rest were skipped",
            input = { op = "partition", threshold = 4, scanRows = {
                { lootSlot = 1, quantity = 1, quality = 4, info = EPIC_CHEST },
                { lootSlot = 2, quantity = 1, quality = 4, info = MOUNT },
                { lootSlot = 3, quantity = 1, quality = 3, info = info(41001, { equipLoc = "INVTYPE_CHEST", quality = 3 }) },
            } },
            expected = {
                candidates = { { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                                 count = 1, slots = "1", units = "1=1" } },
                skipped = { "2:NOT_EQUIPPABLE", "3:BELOW_QUALITY" },
            },
        },
        {
            -- Added by hand from the skipped list: it joins WITH its loot slot, so the
            -- award still goes through master loot.
            name = "a skipped row added by hand is a candidate with its slot",
            input = { op = "partition", threshold = 4, manualIds = { [44083] = true }, scanRows = {
                { lootSlot = 1, quantity = 1, quality = 4, info = EPIC_CHEST },
                { lootSlot = 2, quantity = 1, quality = 4, info = MOUNT },
            } },
            expected = {
                candidates = { { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                                 count = 1, slots = "1", units = "1=1" },
                               { idx = 2, itemString = "item:44083:0:0:0:0:0:0:0:0",
                                 count = 1, slots = "2", units = "2=1" } },
                skipped = {},
            },
        },
        {
            -- The host's manual add survives another slot being looted out from under
            -- the list: the partition is recomputed from what is left.
            name = "a manual add stays a candidate after another slot clears",
            input = { op = "partition", threshold = 4, manualIds = { [44083] = true }, scanRows = {
                { lootSlot = 2, quantity = 1, quality = 4, info = MOUNT },
            } },
            expected = {
                candidates = { { idx = 1, itemString = "item:44083:0:0:0:0:0:0:0:0",
                                 count = 1, slots = "2", units = "2=1" } },
                skipped = {},
            },
        },
        {
            name = "lowering the bar admits a blue; raising it again re-skips it",
            input = { op = "partition", threshold = 3, scanRows = {
                { lootSlot = 3, quantity = 1, quality = 3, info = info(41001, { equipLoc = "INVTYPE_CHEST", quality = 3 }) },
            } },
            expected = {
                candidates = { { idx = 1, itemString = "item:41001:0:0:0:0:0:0:0:0",
                                 count = 1, slots = "3", units = "3=1" } },
                skipped = {},
            },
        },
        {
            name = "withdrawing a manual add returns the row to skipped with its reason",
            input = { op = "partition", threshold = 4, manualIds = {}, scanRows = {
                { lootSlot = 2, quantity = 1, quality = 4, info = MOUNT },
            } },
            expected = { candidates = {}, skipped = { "2:NOT_EQUIPPABLE" } },
        },
        {
            name = "an item-link addition joins with no slot, after the corpse rows",
            input = { op = "partition", threshold = 4,
                      manualRows = { { quantity = 1, info = info(50001) } },
                      scanRows = {
                          { lootSlot = 1, quantity = 1, quality = 4, info = EPIC_CHEST },
                      } },
            expected = {
                candidates = { { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                                 count = 1, slots = "1", units = "1=1" },
                               { idx = 2, itemString = "item:50001:0:0:0:0:0:0:0:0",
                                 count = 1, slots = "", units = "" } },
                skipped = {},
            },
        },

        ----------------------------------------------------------------------
        -- Losing loot mid-batch (section 3)
        ----------------------------------------------------------------------
        {
            name = "nothing gone means nothing changes",
            input = { op = "prune", gone = {}, items = {
                batchItem(1, 40000, 1, { 1 }),
                batchItem(2, 40001, 1, { 2 }),
            } },
            expected = {
                kept = {
                    { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                      count = 1, slots = "1", units = "1=1" },
                    { idx = 2, itemString = "item:40001:0:0:0:0:0:0:0:0",
                      count = 1, slots = "2", units = "2=1" },
                },
                lost = {},
            },
        },
        {
            -- The survivors carry on with their original idx: clients key their entries
            -- by it, so renumbering would move everyone's submission to another item.
            name = "a lost item leaves the rest with their indices intact",
            input = { op = "prune", gone = { [1] = true }, items = {
                batchItem(1, 40000, 1, { 1 }),
                batchItem(2, 40001, 1, { 2 }),
            } },
            expected = {
                kept = {
                    { idx = 2, itemString = "item:40001:0:0:0:0:0:0:0:0",
                      count = 1, slots = "2", units = "2=1" },
                },
                lost = { { idx = 1, slots = "1", quantity = 1 } },
            },
        },
        {
            name = "losing one copy of two drops the count, not the item",
            input = { op = "prune", gone = { [3] = true }, items = {
                batchItem(1, 40000, 2, { 1, 3 }),
            } },
            expected = {
                kept = {
                    { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                      count = 1, slots = "1", units = "1=1" },
                },
                lost = { { idx = 1, slots = "3", quantity = 1 } },
            },
        },
        {
            -- The host reads an empty result as LOOT_GONE (spec 002 section 9).
            name = "losing everything leaves nothing to roll for",
            input = { op = "prune", gone = { [1] = true, [2] = true }, items = {
                batchItem(1, 40000, 1, { 1 }),
                batchItem(2, 40001, 1, { 2 }),
            } },
            expected = {
                kept = {},
                lost = { { idx = 1, slots = "1", quantity = 1 }, { idx = 2, slots = "2", quantity = 1 } },
            },
        },
        {
            name = "an item-link batch has no slot to lose",
            input = { op = "prune", gone = { [1] = true }, items = {
                { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0", count = 1,
                  lootSlots = {} },
            } },
            expected = {
                kept = { { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                           count = 1, slots = "", units = "" } },
                lost = {},
            },
        },
        {
            -- The review case: one slot that holds a stack counts as its quantity, and
            -- losing that slot loses the whole stack, not one unit of it.
            name = "losing a stacked slot subtracts the stack, not one unit",
            input = { op = "prune", gone = { [2] = true }, items = {
                batchItem(1, 40000, 4, { 1, 2 }, { [1] = 1, [2] = 3 }),
            } },
            expected = {
                kept = {
                    { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                      count = 1, slots = "1", units = "1=1" },
                },
                lost = { { idx = 1, slots = "2", quantity = 3 } },
            },
        },
        {
            name = "losing the single unit next to a stack keeps the stack's count",
            input = { op = "prune", gone = { [1] = true }, items = {
                batchItem(1, 40000, 4, { 1, 2 }, { [1] = 1, [2] = 3 }),
            } },
            expected = {
                kept = {
                    { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                      count = 3, slots = "2", units = "2=3" },
                },
                lost = { { idx = 1, slots = "1", quantity = 1 } },
            },
        },
        {
            -- A batch record from before slotQuantities existed still prunes sanely.
            name = "a slot with no recorded quantity counts as one unit",
            input = { op = "prune", gone = { [3] = true }, items = {
                { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0", count = 2,
                  lootSlot = 1, lootSlots = { 1, 3 }, info = info(40000) },
            } },
            expected = {
                kept = {
                    { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                      count = 1, slots = "1", units = "1=nil" },
                },
                lost = { { idx = 1, slots = "3", quantity = 1 } },
            },
        },
    },
}
