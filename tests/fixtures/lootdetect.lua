-- tests/fixtures/lootdetect.lua
--
-- Spec 004 sections 2 and 3: the candidate rule, duplicate stacks, and losing loot
-- under an open round.

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
            input.manualRows, input.threshold, input.removedIds, input.consumedIds)
        local candidates = project(LootDetect.Collapse(rows))
        local out = {}
        for i, skip in ipairs(skipped) do
            out[i] = tostring(skip.lootSlot) .. ":" .. skip.reason
        end
        return { candidates = candidates, skipped = out }

    elseif input.op == "samesource" then
        return LootDetect.SameSource(input.old, input.new)

    elseif input.op == "matchsource" then
        return LootDetect.MatchSource(input.sources, input.guid, input.new) or 0

    elseif input.op == "remember" then
        -- Each scan in turn; the source each one lands on, numbered by first sighting.
        local sources, seen, out = {}, {}, {}
        for i, scan in ipairs(input.scans) do
            local source = LootDetect.RememberSource(sources, scan.guid, scan.rows,
                input.max or 10)
            -- A round consumed from each corpse, so an evicted one coming back empty is
            -- visible as well as renumbered.
            if seen[source] then out[i] = seen[source] .. (next(source.consumed) and "" or "!")
            else
                seen[source] = i
                out[i] = i
            end
            source.consumed[i] = true
        end
        return table.concat(out, ",")

    elseif input.op == "consumetarget" then
        -- Sources are named by string so the result can say which one was picked.
        local byName, roundSources = {}, {}
        local function named(name)
            if not name then return nil end
            byName[name] = byName[name] or { consumed = {}, name = name }
            return byName[name]
        end
        for roundId, name in pairs(input.rounds or {}) do roundSources[roundId] = named(name) end
        local linkSources = {}
        for roundId, name in pairs(input.links or {}) do linkSources[roundId] = named(name) end
        local target, strip, heldOnly = LootDetect.ConsumeTarget(roundSources,
            named(input.open), input.roundId, linkSources, input.simulated)
        return { target = target and target.name or "", strip = strip,
                 heldOnly = heldOnly }

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

    elseif input.op == "rebind" then
        local records = input.records or {}
        local kept, lost = LootDetect.Rebind(input.scan, records, input.items or {})
        -- Then a hand-loot of `thenGone`, the way onSlotCleared would prune it.
        if input.thenGone then
            local gone = input.thenGone
            local more
            kept, more = LootDetect.Prune(kept, function(slot) return gone[slot] == true end)
            for _, l in ipairs(more) do lost[#lost + 1] = l end
        end
        local recordSlots, lostOut = {}, {}
        for i, record in ipairs(records) do recordSlots[i] = tostring(record.lootSlot) end
        for i = 1, #lost do
            lostOut[i] = { idx = lost[i].item.idx, quantity = lost[i].quantity }
        end
        return { kept = project(kept), lost = lostOut,
                 records = table.concat(recordSlots, ",") }
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

--- A fresh scan row: what LootDetect.Scan records per slot.
local function scanRow(slot, id, quantity)
    return { lootSlot = slot, quantity = quantity or 1, info = id and info(id) or {} }
end

--- An owed award record's slot-relevant fields.
local function record(id, slot)
    return { itemString = "item:" .. id .. ":0:0:0:0:0:0:0:0", lootSlot = slot }
end

local EPIC_CHEST = info(40000, { equipLoc = "INVTYPE_CHEST", armorSubclass = "PLATE" })
local TOKEN = info(40616, { equipLoc = nil, tokenGroup = "PROTECTOR",
                            tokenClasses = { WARRIOR = true } })
local MOUNT = info(44083, { special = true })
local COLD = info(50000, { quality = nil, special = true, unresolved = true })
local GREEN = info(41000, { equipLoc = "INVTYPE_CHEST", quality = 2 })

--- A round item as LootDetect.Collapse would produce it.
local function roundItem(idx, id, count, slots, slotQuantities)
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
            -- Reopening a corpse to award from it must not bring back what a closed
            -- round consumed, or the same loot is offered for a second round.
            name = "a reopened corpse holding a subset of the last scan is the same source",
            input = { op = "samesource",
                      old = { { lootSlot = 1, info = TOKEN }, { lootSlot = 2, info = MOUNT } },
                      new = { { lootSlot = 1, info = TOKEN } } },
            expected = true,
        },
        {
            name = "a corpse holding anything new is a new source",
            input = { op = "samesource",
                      old = { { lootSlot = 1, info = TOKEN } },
                      new = { { lootSlot = 1, info = TOKEN }, { lootSlot = 2, info = MOUNT } } },
            expected = false,
        },
        {
            name = "the first scan is a new source",
            input = { op = "samesource", old = {}, new = { { lootSlot = 1, info = TOKEN } } },
            expected = false,
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
            name = "two loot slots of one item become one round item with count 2",
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
            name = "an item-link round has no loot slot",
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
        -- Withdrawn items (spec 006 section 3): taken out by hand, or already
        -- rolled by a round that closed. Unlike a filtered row these are not
        -- offered back under `skipped` -- the question has been answered.
        ----------------------------------------------------------------------
        {
            name = "a withdrawn corpse row is neither a candidate nor skipped",
            input = { op = "partition", threshold = 4, removedIds = { [40000] = true },
                      scanRows = {
                          { lootSlot = 1, quantity = 1, quality = 4, info = EPIC_CHEST },
                          { lootSlot = 2, quantity = 1, quality = 4, info = MOUNT },
                      } },
            expected = { candidates = {}, skipped = { "2:NOT_EQUIPPABLE" } },
        },
        {
            name = "a withdrawn item-link addition is dropped, the corpse rows stay",
            input = { op = "partition", threshold = 4, removedIds = { [50001] = true },
                      manualRows = { { quantity = 1, info = info(50001) } },
                      scanRows = {
                          { lootSlot = 1, quantity = 1, quality = 4, info = EPIC_CHEST },
                      } },
            expected = {
                candidates = { { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                                 count = 1, slots = "1", units = "1=1" } },
                skipped = {},
            },
        },
        {
            name = "a withdrawal outranks a manual promotion of the same row",
            input = { op = "partition", threshold = 4, manualIds = { [44083] = true },
                      removedIds = { [44083] = true }, scanRows = {
                          { lootSlot = 2, quantity = 1, quality = 4, info = MOUNT },
                      } },
            expected = { candidates = {}, skipped = {} },
        },
        {
            -- A different corpse can hold only ids the last one did and pass SameSource.
            -- What a closed round consumed is then offered back, never silently dropped.
            name = "a different corpse sharing an overlapping drop is judged the same source",
            input = { op = "samesource",
                      old = { { lootSlot = 1, info = TOKEN }, { lootSlot = 2, info = EPIC_CHEST } },
                      new = { { lootSlot = 1, info = TOKEN } } },
            expected = true,
        },
        {
            -- Boss A closed a round, trash B was looted, then A was reopened to award.
            -- A must still be found, or its consumed items come back as candidates.
            name = "a corpse reopened after another was looted matches its own source (A, B, A)",
            input = { op = "matchsource", new = { { lootSlot = 1, info = TOKEN } },
                      sources = {
                          { rows = { { lootSlot = 1, info = MOUNT } } },
                          { rows = { { lootSlot = 1, info = TOKEN },
                                     { lootSlot = 2, info = EPIC_CHEST } } },
                      } },
            expected = 2,
        },
        {
            -- Boss A (no GUID), then trash B holding a subset of A's ids, then A again.
            -- B's contents match must not overwrite A's rows, or A reopens as a stranger.
            name = "a subset corpse matched by contents leaves the source it matched intact",
            input = { op = "remember", scans = {
                { rows = { { lootSlot = 1, info = TOKEN }, { lootSlot = 2, info = EPIC_CHEST } } },
                { guid = "0xF130000003", rows = { { lootSlot = 1, info = TOKEN } } },
                { rows = { { lootSlot = 1, info = TOKEN }, { lootSlot = 2, info = EPIC_CHEST } } },
            } },
            expected = "1,1,1",
        },
        {
            -- Awards took the chest; the same GUID reopened holds only the token. The
            -- source's rows are replaced, so the chest back again reads as another corpse.
            name = "a same-GUID reopen replaces the matched source's rows",
            input = { op = "remember", scans = {
                { guid = "0xF130000004", rows = { { lootSlot = 1, info = TOKEN },
                                                  { lootSlot = 2, info = EPIC_CHEST } } },
                { guid = "0xF130000004", rows = { { lootSlot = 1, info = TOKEN } } },
                { rows = { { lootSlot = 1, info = TOKEN } } },
                { rows = { { lootSlot = 1, info = TOKEN }, { lootSlot = 2, info = EPIC_CHEST } } },
            } },
            expected = "1,1,1,4",
        },
        {
            -- Coin-only corpses can never match; ten of them must not push the boss out.
            name = "scans with no resolved ids are not remembered",
            input = { op = "remember", scans = {
                { rows = { { lootSlot = 1, info = TOKEN } } },
                { rows = {} }, { rows = {} }, { rows = {} }, { rows = {} }, { rows = {} },
                { rows = {} }, { rows = {} }, { rows = {} }, { rows = {} }, { rows = {} },
                { rows = { { lootSlot = 1, info = TOKEN } } },
            } },
            expected = "1,2,3,4,5,6,7,8,9,10,11,1",
        },
        {
            -- The eviction boundary: `max` real corpses and one more drops the oldest,
            -- so reopening it is a new source with an empty consumed set -- its rolled
            -- loot comes back as candidates, which is the boundary the cap trades away.
            name = "the oldest source is evicted once max real corpses are open",
            input = { op = "remember", max = 3, scans = {
                { guid = "0xF1300000A1", rows = { { lootSlot = 1, info = TOKEN } } },
                { guid = "0xF1300000A2", rows = { { lootSlot = 1, info = EPIC_CHEST } } },
                { guid = "0xF1300000A3", rows = { { lootSlot = 1, info = MOUNT } } },
                { guid = "0xF1300000A4", rows = { { lootSlot = 1, info = GREEN } } },
                { guid = "0xF1300000A1", rows = { { lootSlot = 1, info = TOKEN } } },
            } },
            expected = "1,2,3,4,5",
        },
        {
            -- Under the cap the same corpse reopens onto its own source, consumed set
            -- and all -- the "2" is a match, and it is not flagged empty.
            name = "a corpse within max reopens with its consumed set",
            input = { op = "remember", max = 3, scans = {
                { guid = "0xF1300000B1", rows = { { lootSlot = 1, info = TOKEN } } },
                { guid = "0xF1300000B2", rows = { { lootSlot = 1, info = EPIC_CHEST } } },
                { guid = "0xF1300000B1", rows = { { lootSlot = 1, info = TOKEN } } },
            } },
            expected = "1,2,1",
        },
        {
            -- An item the cache has not resolved yet must not make a reopened corpse a
            -- stranger, or what its closed rounds consumed comes back as candidates.
            name = "an unresolved row does not stop a reopened corpse matching",
            input = { op = "samesource",
                      old = { { lootSlot = 1, info = TOKEN }, { lootSlot = 2, info = EPIC_CHEST } },
                      new = { { lootSlot = 1, info = TOKEN }, { lootSlot = 2 } } },
            expected = true,
        },
        {
            name = "a scan with no resolved rows matches nothing",
            input = { op = "samesource",
                      old = { { lootSlot = 1, info = TOKEN } },
                      new = { { lootSlot = 1 } } },
            expected = false,
        },
        {
            -- A partial scan checked against every remembered corpse is a false reopen
            -- waiting to happen; only the last scan gets the benefit of the doubt.
            name = "an unresolved row matches only the last source, not an older one",
            input = { op = "matchsource", new = { { lootSlot = 1, info = TOKEN }, { lootSlot = 2 } },
                      sources = {
                          { rows = { { lootSlot = 1, info = MOUNT } } },
                          { rows = { { lootSlot = 1, info = TOKEN },
                                     { lootSlot = 2, info = EPIC_CHEST } } },
                      } },
            expected = 0,
        },
        {
            name = "an agreeing GUID matches an older source despite an unresolved row",
            input = { op = "matchsource", guid = "0xF130000005",
                      new = { { lootSlot = 1, info = TOKEN }, { lootSlot = 2 } },
                      sources = {
                          { rows = { { lootSlot = 1, info = MOUNT } } },
                          { guid = "0xF130000005", rows = { { lootSlot = 1, info = TOKEN },
                                     { lootSlot = 2, info = EPIC_CHEST } } },
                      } },
            expected = 2,
        },
        {
            name = "a corpse matching no remembered source is a new source",
            input = { op = "matchsource", new = { { lootSlot = 1, info = MOUNT } },
                      sources = { { rows = { { lootSlot = 1, info = TOKEN } } } } },
            expected = 0,
        },
        {
            name = "a different dead target's GUID keeps a same-contents corpse apart",
            input = { op = "matchsource", guid = "0xF130000001", new = { { lootSlot = 1, info = TOKEN } },
                      sources = { { guid = "0xF130000002", rows = { { lootSlot = 1, info = TOKEN } } } } },
            expected = 0,
        },
        {
            name = "an unknown GUID falls back to contents",
            input = { op = "matchsource", new = { { lootSlot = 1, info = TOKEN } },
                      sources = { { guid = "0xF130000002", rows = { { lootSlot = 1, info = TOKEN } } } } },
            expected = 1,
        },
        {
            name = "an item a closed round consumed is skipped as already rolled, not dropped",
            input = { op = "partition", threshold = 4, consumedIds = { [40616] = true },
                      scanRows = {
                          { lootSlot = 1, quantity = 1, quality = 4, info = TOKEN },
                          { lootSlot = 2, quantity = 1, quality = 4, info = EPIC_CHEST },
                      } },
            expected = {
                candidates = { { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                                 count = 1, slots = "2", units = "2=1" } },
                skipped = { "1:ALREADY_ROLLED" },
            },
        },
        {
            -- Added by hand on A, rolled for, closed while trash B was open: A's manual mark
            -- survives, but the item must not come back when A is reopened. Add item clears
            -- consumption, so a real re-add never reaches Partition in this state.
            name = "a consumed item with a leftover manual mark stays already rolled (A, B, A)",
            input = { op = "partition", threshold = 4, consumedIds = { [40616] = true },
                      manualIds = { [40616] = true },
                      scanRows = { { lootSlot = 1, quantity = 1, quality = 4, info = TOKEN } } },
            expected = { candidates = {}, skipped = { "1:ALREADY_ROLLED" } },
        },
        {
            -- Add item undoes consumption: the host asked for it by hand.
            name = "a consumed item the host added back by hand is offered again",
            input = { op = "partition", threshold = 4, manualIds = { [40616] = true },
                      scanRows = { { lootSlot = 1, quantity = 1, quality = 4, info = TOKEN } } },
            expected = {
                candidates = { { idx = 1, itemString = "item:40616:0:0:0:0:0:0:0:0",
                                 count = 1, slots = "1", units = "1=1" } },
                skipped = {},
            },
        },
        {
            name = "a consumed item-link addition is not offered again",
            input = { op = "partition", threshold = 4, consumedIds = { [50001] = true },
                      manualRows = { { quantity = 1, info = info(50001) } } },
            expected = { candidates = {}, skipped = {} },
        },

        {
            -- Round on boss A, trash B looted, round closed with B open: A's set takes
            -- the ids, and the host's additions on B stay put.
            name = "a round bound to another corpse consumes into it and leaves manual rows (A, B, A)",
            input = { op = "consumetarget", rounds = { r1 = "A" }, open = "B", roundId = "r1" },
            expected = { target = "A", strip = false, heldOnly = false },
        },
        {
            name = "an item-link round consumes only the ids its opening corpse holds",
            input = { op = "consumetarget", rounds = {}, links = { r2 = "A" }, open = "A",
                      roundId = "r2" },
            expected = { target = "A", strip = true, heldOnly = true },
        },
        {
            -- Rolled from bags on boss A, trash B looted before close: B's drops and
            -- the host's additions on B are untouched.
            name = "an item-link round leaves the corpse open at close alone (A, B)",
            input = { op = "consumetarget", rounds = {}, links = { r2 = "A" }, open = "B",
                      roundId = "r2" },
            expected = { target = "A", strip = false, heldOnly = true },
        },
        {
            -- Rolled from bags with no corpse open: no consumed set takes the ids, but
            -- the hand-added rows still go, or Start roll offers them again.
            name = "an unbound round consumes into nothing and still strips manual rows",
            input = { op = "consumetarget", rounds = {}, open = "B", roundId = "r3" },
            expected = { target = "", strip = true, heldOnly = false },
        },
        {
            name = "a simulated round touches nothing at all",
            input = { op = "consumetarget", rounds = {}, open = "B", roundId = "r3",
                      simulated = { r3 = true } },
            expected = { target = "", strip = false, heldOnly = false },
        },
        {
            name = "a round bound to the open corpse consumes into it and strips manual rows",
            input = { op = "consumetarget", rounds = { r1 = "A" }, open = "A", roundId = "r1" },
            expected = { target = "A", strip = true, heldOnly = false },
        },

        ----------------------------------------------------------------------
        -- Losing loot mid-round (section 3)
        ----------------------------------------------------------------------
        {
            name = "nothing gone means nothing changes",
            input = { op = "prune", gone = {}, items = {
                roundItem(1, 40000, 1, { 1 }),
                roundItem(2, 40001, 1, { 2 }),
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
                roundItem(1, 40000, 1, { 1 }),
                roundItem(2, 40001, 1, { 2 }),
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
                roundItem(1, 40000, 2, { 1, 3 }),
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
                roundItem(1, 40000, 1, { 1 }),
                roundItem(2, 40001, 1, { 2 }),
            } },
            expected = {
                kept = {},
                lost = { { idx = 1, slots = "1", quantity = 1 }, { idx = 2, slots = "2", quantity = 1 } },
            },
        },
        {
            name = "an item-link round has no slot to lose",
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
                roundItem(1, 40000, 4, { 1, 2 }, { [1] = 1, [2] = 3 }),
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
                roundItem(1, 40000, 4, { 1, 2 }, { [1] = 1, [2] = 3 }),
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
            -- A round record from before slotQuantities existed still prunes sanely.
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
        ----------------------------------------------------------------------
        -- Re-finding items on a reopened corpse (section 3, 0.4.1)
        ----------------------------------------------------------------------
        {
            -- Slot 2 was taken and the corpse reopened: what was slot 4 is slot 3 now.
            name = "a reopened corpse moves a round item to its new slot",
            input = { op = "rebind",
                      scan = { scanRow(1, 40000), scanRow(2, 50000), scanRow(3, 40001) },
                      items = { roundItem(1, 40001, 1, { 4 }) } },
            expected = {
                kept = { { idx = 1, itemString = "item:40001:0:0:0:0:0:0:0:0",
                           count = 1, slots = "3", units = "3=1" } },
                lost = {}, records = "",
            },
        },
        {
            -- The bug this exists for: the round's item moved from 4 to 3, and the host
            -- then hand-loots whatever now sits in slot 4. The round must keep its item.
            name = "hand-looting a neighbour after a reopen does not drop the round's item",
            input = { op = "rebind",
                      scan = { scanRow(1, 40000), scanRow(3, 40001), scanRow(4, 50000) },
                      items = { roundItem(1, 40001, 1, { 4 }) },
                      thenGone = { [4] = true } },
            expected = {
                kept = { { idx = 1, itemString = "item:40001:0:0:0:0:0:0:0:0",
                           count = 1, slots = "3", units = "3=1" } },
                lost = {}, records = "",
            },
        },
        {
            name = "a round item no longer on the reopened corpse is lost",
            input = { op = "rebind",
                      scan = { scanRow(1, 40000) },
                      items = { roundItem(1, 40000, 1, { 1 }), roundItem(2, 40001, 1, { 2 }) } },
            expected = {
                kept = { { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                           count = 1, slots = "1", units = "1=1" } },
                lost = { { idx = 2, quantity = 1 } }, records = "",
            },
        },
        {
            name = "two copies with one left on the corpse drop the count, not the item",
            input = { op = "rebind",
                      scan = { scanRow(2, 40000) },
                      items = { roundItem(1, 40000, 2, { 1, 3 }) } },
            expected = {
                kept = { { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                           count = 1, slots = "2", units = "2=1" } },
                lost = { { idx = 1, quantity = 1 } }, records = "",
            },
        },
        {
            name = "a stacked slot serves every unit it holds",
            input = { op = "rebind",
                      scan = { scanRow(1, 40000, 3) },
                      items = { roundItem(1, 40000, 3, { 2 }, { [2] = 3 }) } },
            expected = {
                kept = { { idx = 1, itemString = "item:40000:0:0:0:0:0:0:0:0",
                           count = 3, slots = "1", units = "1=3" } },
                lost = {}, records = "",
            },
        },
        {
            -- A row with no item id could be the missing copy; announcing a loss that is
            -- not real is worse than leaving the old slot for SlotHolds to judge.
            name = "an incomplete scan never reports a loss",
            input = { op = "rebind",
                      scan = { scanRow(1, 40000), scanRow(2, nil) },
                      items = { roundItem(1, 40001, 1, { 3 }) } },
            expected = {
                kept = { { idx = 1, itemString = "item:40001:0:0:0:0:0:0:0:0",
                           count = 1, slots = "3", units = "3=1" } },
                lost = {}, records = "",
            },
        },
        {
            name = "an item-link round item has no slot to move",
            input = { op = "rebind",
                      scan = { scanRow(1, 40000) },
                      items = { { idx = 1, itemString = "item:40001:0:0:0:0:0:0:0:0",
                                  count = 1, lootSlots = {}, info = info(40001) } } },
            expected = {
                kept = { { idx = 1, itemString = "item:40001:0:0:0:0:0:0:0:0",
                           count = 1, slots = "", units = "" } },
                lost = {}, records = "",
            },
        },
        {
            -- An award still owed from a closed round follows its item; one whose item is
            -- gone keeps its old slot, and SlotHolds marks it lost at award time.
            name = "owed awards follow their items, and a gone one keeps its slot",
            input = { op = "rebind",
                      scan = { scanRow(1, 40001), scanRow(2, 40000) },
                      records = { record(40000, 5), record(40002, 3), record(40001, 2) } },
            expected = { kept = {}, lost = {}, records = "2,3,1" },
        },
        {
            name = "two awards of one item share its stacked slot",
            input = { op = "rebind",
                      scan = { scanRow(3, 40000, 2) },
                      records = { record(40000, 1), record(40000, 2) } },
            expected = { kept = {}, lost = {}, records = "3,3" },
        },
        {
            -- Two copies on the corpse, two awards owed: each gets its own slot rather
            -- than both pointing at the first.
            name = "two awards of one item take one slot each",
            input = { op = "rebind",
                      scan = { scanRow(1, 40000), scanRow(2, 40000) },
                      records = { record(40000, 2), record(40000, 3) } },
            expected = { kept = {}, lost = {}, records = "1,2" },
        },
    },
}
