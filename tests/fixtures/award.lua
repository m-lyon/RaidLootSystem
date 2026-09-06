-- tests/fixtures/award.lua
--
-- The pure half of Modules/Award.lua (spec 007): the award records a resolved batch
-- produces, which delivery path an award takes and why, the confirmation and
-- failure texts, and the auto-equip rule.

local ns = ...

local function run(input, ns)
    local Award = ns.Award

    if input.op == "build" then
        local out = {}
        for idx, list in pairs(Award.Build(input.session)) do
            local rows = {}
            for i, r in ipairs(list) do
                rows[i] = string.format("%d:%s slot=%s %s L%d", r.copy, r.char,
                    tostring(r.lootSlot), r.delivery, r.listIdx)
            end
            out[tostring(idx)] = rows
        end
        return out

    elseif input.op == "path" then
        local path, why = Award.PathFor(input.record, input.ctx)
        return { path = path or "", why = why or "" }

    elseif input.op == "confirm" then
        return Award.ConfirmText(input.record, input.label, input.path)

    elseif input.op == "failure" then
        return Award.FailureText(input.code, input.record)

    elseif input.op == "status" then
        return Award.StatusText(input.record)

    elseif input.op == "equip" then
        return Award.ShouldAutoEquip(input.record, input.roster, input.settings)

    elseif input.op == "retryable" then
        return Award.Retryable(input.record)
    end
    error("unknown op: " .. tostring(input.op))
end

local SESSION = {
    id = "Steve-100",
    items = {
        { idx = 1, itemString = "item:1", count = 1, lootSlot = 2, lootSlots = { 2 } },
        { idx = 2, itemString = "item:2", count = 2, lootSlot = 3, lootSlots = { 3, 5 } },
        { idx = 3, itemString = "item:3", count = 1 },                 -- item-link batch
        { idx = 4, itemString = "item:4", count = 1, lootSlot = 6, lootSlots = { 6 } },
    },
    results = {
        { itemIdx = 1, unclaimed = false, awards = { { char = "Bonk", owner = "Dave", tier = 1, roll = 91 } },
          record = { { char = "Bonk", listIdx = 3 } } },
        { itemIdx = 2, unclaimed = false, awards = { { char = "Ann", owner = "A", tier = 1, roll = 80 },
                                                    { char = "Bob", owner = "B", tier = 2, roll = 70 } },
          record = { { char = "Ann", listIdx = 0 }, { char = "Bob", listIdx = 0 } } },
        { itemIdx = 3, unclaimed = false, awards = { { char = "Cat", owner = "C", tier = 1, roll = 50 } },
          record = { { char = "Cat", listIdx = 0 } } },
        { itemIdx = 4, unclaimed = true, awards = {}, record = {} },
    },
}

local CORPSE = { char = "Bonk", owner = "Dave", lootSlot = 2, itemString = "item:1", delivery = "AWAITING" }
local LINKED = { char = "Cat", owner = "C", lootSlot = nil, itemString = "item:3", delivery = "AWAITING" }

return {
    name = "award",
    run = run,
    cases = {
        {
            -- Acceptance: a duplicate drop awards both copies, each from its own slot;
            -- an item-link batch has no slot; an unclaimed item has no records.
            name = "records are one per copy with their own loot slot",
            input = { op = "build", session = SESSION },
            expected = {
                ["1"] = { "1:Bonk slot=2 AWAITING L3" },
                ["2"] = { "1:Ann slot=3 AWAITING L0", "2:Bob slot=5 AWAITING L0" },
                ["3"] = { "1:Cat slot=nil AWAITING L0" },
                ["4"] = {},
            },
        },

        {
            -- A stacked slot holds several units in one slot: every copy past the slot
            -- count is awarded from the last slot.
            name = "copies beyond the slot count share the last slot",
            input = { op = "build", session = {
                id = "Steve-101",
                items = { { idx = 1, itemString = "item:9", count = 3, lootSlot = 4, lootSlots = { 4 } } },
                results = { { itemIdx = 1, unclaimed = false,
                              awards = { { char = "Ann", tier = 1 }, { char = "Bob", tier = 1 }, { char = "Cat", tier = 2 } },
                              record = {} } },
            } },
            expected = { ["1"] = { "1:Ann slot=4 AWAITING L0", "2:Bob slot=4 AWAITING L0",
                                   "3:Cat slot=4 AWAITING L0" } },
        },

        -- The path (sections 2, 4, 5)
        { name = "corpse open, slot valid, master loot: the master-loot path",
          input = { op = "path", record = CORPSE, ctx = { lootMethod = "master", windowOpen = true, slotHolds = true } },
          expected = { path = "MASTER_LOOT", why = "" } },
        { name = "shift-click forces the trade path even with the corpse open",
          input = { op = "path", record = CORPSE, ctx = { forceTrade = true, lootMethod = "master", windowOpen = true, slotHolds = true } },
          expected = { path = "TRADE", why = "" } },
        { name = "loot method changed: the trade path, with NO_LOOT_METHOD explained",
          input = { op = "path", record = CORPSE, ctx = { lootMethod = "group", windowOpen = true, slotHolds = true } },
          expected = { path = "TRADE", why = "NO_LOOT_METHOD" } },
        { name = "corpse open but the slot no longer holds the item, not in bags: lost",
          input = { op = "path", record = CORPSE, ctx = { lootMethod = "master", windowOpen = true, slotHolds = false } },
          expected = { path = "", why = "SOURCE_INVALID" } },
        { name = "slot gone but the item is in the host's bags: the trade path",
          input = { op = "path", record = CORPSE, ctx = { lootMethod = "master", windowOpen = true, slotHolds = false, inBags = true } },
          expected = { path = "TRADE", why = "" } },
        { name = "loot window closed and nothing in bags: tell the host what to do",
          input = { op = "path", record = CORPSE, ctx = { lootMethod = "master", windowOpen = false } },
          expected = { path = "", why = "Open the corpse to award from it, or loot the item yourself and award again." } },
        { name = "shift-click with the corpse closed and nothing in bags falls through to the instruction",
          input = { op = "path", record = CORPSE, ctx = { forceTrade = true, lootMethod = "master", windowOpen = false, inBags = false } },
          expected = { path = "", why = "Open the corpse to award from it, or loot the item yourself and award again." } },
        { name = "an item-link batch goes to trade when the item is in bags",
          input = { op = "path", record = LINKED, ctx = { inBags = true } },
          expected = { path = "TRADE", why = "" } },
        { name = "an item-link batch with nothing in bags cannot be awarded",
          input = { op = "path", record = LINKED, ctx = { inBags = false } },
          expected = { path = "", why = "The item is not in your bags." } },
        { name = "a delivered award is not awarded again",
          input = { op = "path", record = { char = "Bonk", lootSlot = 2, delivery = "DELIVERED" },
                    ctx = { lootMethod = "master", windowOpen = true, slotHolds = true } },
          expected = { path = "", why = "already delivered" } },

        -- Confirmation (section 6): item, winner and path, every time.
        { name = "the master-loot confirmation names the item, the winner and the binding",
          input = { op = "confirm", record = CORPSE, label = "[Deathbringer's Will]", path = "MASTER_LOOT" },
          expected = "Give [Deathbringer's Will] to Bonk (Dave)?\n\nFrom the corpse. It binds to Bonk." },
        { name = "the trade confirmation says it binds to the host for two hours",
          input = { op = "confirm", record = CORPSE, label = "[Deathbringer's Will]", path = "TRADE" },
          expected = "Take [Deathbringer's Will] into your bags for Bonk (Dave)?\n\n"
              .. "It binds to YOU and stays tradeable to kill-eligible characters for 2 hours." },

        -- Failure texts (section 4)
        { name = "NOT_A_CANDIDATE names the winner and says retry",
          input = { op = "failure", code = "NOT_A_CANDIDATE", record = CORPSE },
          expected = "Bonk is out of range. Bring them closer and retry." },
        { name = "SLOT_NOT_CLEARED points at the winner's bags",
          input = { op = "failure", code = "SLOT_NOT_CLEARED", record = CORPSE },
          expected = "Award didn't complete -- check Bonk's bags." },
        { name = "SOURCE_INVALID is the corpse",
          input = { op = "failure", code = "SOURCE_INVALID", record = CORPSE },
          expected = "The corpse is gone." },
        { name = "a failed record's status carries its reason",
          input = { op = "status", record = { char = "Bonk", delivery = "FAILED", failure = "NOT_A_CANDIDATE" } },
          expected = "failed: Bonk is out of range. Bring them closer and retry." },
        { name = "an expired trade window is its own failure, and not retryable",
          input = { op = "status", record = { char = "Bonk", delivery = "FAILED", failure = "TRADE_EXPIRED" } },
          expected = "failed: The two-hour trade window ran out; the item is bound to you." },
        { name = "TRADE_EXPIRED is not retryable",
          input = { op = "retryable", record = { delivery = "FAILED", failure = "TRADE_EXPIRED" } },
          expected = false },
        { name = "NOT_A_CANDIDATE is retryable",
          input = { op = "retryable", record = { delivery = "FAILED", failure = "NOT_A_CANDIDATE" } },
          expected = true },
        { name = "an awaiting record says so",
          input = { op = "status", record = { char = "Bonk", delivery = "AWAITING" } },
          expected = "not awarded yet" },

        -- Auto-equip (section 7)
        { name = "a delivered item to the host's own bot earns an equip whisper",
          input = { op = "equip", record = { char = "Bonk", delivery = "DELIVERED" },
                    roster = { chars = { Bonk = { isSelf = false }, Steve = { isSelf = true } } },
                    settings = { autoEquipWinners = true } },
          expected = true },
        { name = "never for the host's own character",
          input = { op = "equip", record = { char = "Steve", delivery = "DELIVERED" },
                    roster = { chars = { Steve = { isSelf = true } } },
                    settings = { autoEquipWinners = true } },
          expected = false },
        { name = "never for another player's bot",
          input = { op = "equip", record = { char = "Chop", delivery = "DELIVERED" },
                    roster = { chars = { Bonk = { isSelf = false } } },
                    settings = { autoEquipWinners = true } },
          expected = false },
        { name = "never on a pending or failed delivery",
          input = { op = "equip", record = { char = "Bonk", delivery = "PENDING" },
                    roster = { chars = { Bonk = { isSelf = false } } },
                    settings = { autoEquipWinners = true } },
          expected = false },
        { name = "exactly once: a sent whisper is not repeated",
          input = { op = "equip", record = { char = "Bonk", delivery = "DELIVERED", equipSent = true },
                    roster = { chars = { Bonk = { isSelf = false } } },
                    settings = { autoEquipWinners = true } },
          expected = false },
        { name = "with auto-equip off, nothing is whispered",
          input = { op = "equip", record = { char = "Bonk", delivery = "DELIVERED" },
                    roster = { chars = { Bonk = { isSelf = false } } },
                    settings = { autoEquipWinners = false } },
          expected = false },
    },
}
