-- tests/fixtures/award.lua
--
-- The pure half of Modules/Award.lua (spec 007): the award records a resolved round
-- produces, which delivery path an award takes and why, the confirmation and
-- failure texts, and the auto-equip rule.

local ns = ...

local function run(input, ns)
    local Award = ns.Award

    if input.op == "build" then
        local out = {}
        for idx, list in pairs(Award.Build(input.round)) do
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

    elseif input.op == "outstanding" then
        -- Begin registers the round; the deliveries are then set as if the host had
        -- worked through some of it, and the section asks what is left.
        Award.Reset()
        for _, round in ipairs(input.rounds) do
            Award.Begin(round)
            for _, set in ipairs(input.delivered or {}) do
                if set.roundId == round.id then
                    local record = Award.Get(set.roundId, set.itemIdx, set.copy)
                    if record then
                        record.delivery = set.delivery
                        record.failure = set.failure
                    end
                end
            end
        end
        local out = {}
        for i, record in ipairs(Award.OutstandingRecords()) do
            out[i] = string.format("%s/%d/%d %s %s", record.roundId, record.itemIdx,
                record.copy, record.char, record.delivery)
        end
        return out

    elseif input.op == "spare" then
        return Award.SpareUnits(input.record, input.held, input.baseline, input.claimed)

    elseif input.op == "retryable" then
        return Award.Retryable(input.record)

    elseif input.op == "self" then
        return Award.IsSelfDelivery(input.char, input.player)
    end
    error("unknown op: " .. tostring(input.op))
end

local ROUND = {
    id = "Steve-100",
    items = {
        { idx = 1, itemString = "item:1", count = 1, lootSlot = 2, lootSlots = { 2 } },
        { idx = 2, itemString = "item:2", count = 2, lootSlot = 3, lootSlots = { 3, 5 } },
        { idx = 3, itemString = "item:3", count = 1 },                 -- item-link round
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
            -- an item-link round has no slot; an unclaimed item has no records.
            name = "records are one per copy with their own loot slot",
            input = { op = "build", round = ROUND },
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
            input = { op = "build", round = {
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
        { name = "an item-link round goes to trade when the item is in bags",
          input = { op = "path", record = LINKED, ctx = { inBags = true } },
          expected = { path = "TRADE", why = "" } },
        { name = "an item-link round with nothing in bags cannot be awarded",
          input = { op = "path", record = LINKED, ctx = { inBags = false } },
          expected = { path = "", why = "The item is not in your bags." } },

        -- What the host holds (section 5). The regression: an item-link round is
        -- opened on an item already in the host's bags, so the open-time baseline
        -- covers the very copy being awarded and must not be charged against it.
        { name = "an item-link copy counts even though the baseline covered it",
          input = { op = "spare", record = LINKED, held = 1, baseline = 1, claimed = 0 },
          expected = 1 },
        { name = "an item-link copy already promised to another record does not count twice",
          input = { op = "spare", record = LINKED, held = 1, baseline = 1, claimed = 1 },
          expected = 0 },
        { name = "a corpse copy the host owned before the round does not count",
          input = { op = "spare", record = CORPSE, held = 1, baseline = 1, claimed = 0 },
          expected = 0 },
        { name = "a corpse copy looted on top of one the host owned counts once",
          input = { op = "spare", record = CORPSE, held = 2, baseline = 1, claimed = 0 },
          expected = 1 },

        -- What is left to award (spec 007 section 4). The host panel's section reads
        -- this; an unclaimed item contributes nothing, and a copy that has moved on to
        -- Pending or been delivered has left.
        { name = "every won copy is outstanding before the host does anything",
          input = { op = "outstanding", rounds = { ROUND } },
          expected = { "Steve-100/1/1 Bonk AWAITING", "Steve-100/2/1 Ann AWAITING",
                       "Steve-100/2/2 Bob AWAITING", "Steve-100/3/1 Cat AWAITING" } },
        { name = "delivered and pending copies drop out, the rest keep item order",
          input = { op = "outstanding", rounds = { ROUND }, delivered = {
              { roundId = "Steve-100", itemIdx = 1, copy = 1, delivery = "DELIVERED" },
              { roundId = "Steve-100", itemIdx = 2, copy = 1, delivery = "PENDING" },
          } },
          expected = { "Steve-100/2/2 Bob AWAITING", "Steve-100/3/1 Cat AWAITING" } },
        { name = "a failed award stays outstanding, an expired trade does not",
          input = { op = "outstanding", rounds = { ROUND }, delivered = {
              { roundId = "Steve-100", itemIdx = 1, copy = 1, delivery = "FAILED",
                failure = "NOT_A_CANDIDATE" },
              { roundId = "Steve-100", itemIdx = 2, copy = 1, delivery = "FAILED",
                failure = "TRADE_EXPIRED" },
          } },
          expected = { "Steve-100/1/1 Bonk FAILED", "Steve-100/2/2 Bob AWAITING",
                       "Steve-100/3/1 Cat AWAITING" } },

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
          expected = "Award didn't complete - check Bonk's bags." },
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

        -- Winning your own item (section 5): no trade, no pending clock.
        { name = "the character being played is the winner",
          input = { op = "self", char = "Steve", player = "Steve" },
          expected = true },
        { name = "the winner is matched case-insensitively",
          input = { op = "self", char = "steve", player = "Steve" },
          expected = true },
        { name = "the host's own bot is not the host",
          input = { op = "self", char = "Bonk", player = "Steve" },
          expected = false },
        { name = "no player name means no self delivery",
          input = { op = "self", char = "Steve" },
          expected = false },
        { name = "an item you won yourself is kept, not delivered by trade",
          input = { op = "status",
                    record = { char = "Steve", delivery = "DELIVERED", deliveryPath = "SELF" } },
          expected = "kept - you won it" },
        { name = "the self confirmation promises no trade",
          input = { op = "confirm", record = { char = "Steve" }, label = "[Shard]", path = "SELF" },
          expected = "Take [Shard] for yourself?\n\n"
              .. "You won it, so it is delivered the moment it reaches your bags." },

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
