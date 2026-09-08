-- tests/fixtures/hostpanel.lua
--
-- The pure half of UI/HostPanel.lua (spec 006 section 3): why Start roll is
-- disabled, why a setting is frozen, the tier note, the addon-status rows and the
-- loot-mode options.

local ns = ...

local function run(input, ns)
    local HP = ns.HostPanel
    if input.op == "start" then
        return HP.StartBlocker(input.ctx) or ""
    elseif input.op == "setting" then
        return HP.SettingBlocker(input.key, input.batchOpen) or ""
    elseif input.op == "tierNote" then
        return HP.TierExplanation(input.tierCount, input.lootMode)
    elseif input.op == "status" then
        local out = {}
        for i, row in ipairs(HP.AddonStatus(input.members, input.peers, input.version)) do
            out[i] = row.name .. "=" .. row.status .. (row.drift and " (drift)" or "")
        end
        return out
    elseif input.op == "lootModes" then
        local out = {}
        for i, opt in ipairs(HP.LootModeOptions(input.seeded)) do
            out[i] = opt.value .. (opt.disabled and " disabled" or "")
        end
        return out
    end
    error("unknown op: " .. tostring(input.op))
end

return {
    name = "hostpanel",
    run = run,
    cases = {
        -- Acceptance: Start roll is disabled with a specific reason when the loot
        -- method is not master loot.
        { name = "not on master loot",
          input = { op = "start", ctx = { isHost = false, lootMethod = "group", ticked = 2 } },
          expected = "The group is not on master loot." },
        { name = "master loot but somebody else holds it",
          input = { op = "start", ctx = { isHost = false, lootMethod = "master", ticked = 2 } },
          expected = "You are not the master looter." },
        { name = "a batch is already open",
          input = { op = "start", ctx = { isHost = true, lootMethod = "master", batchOpen = true, ticked = 2 } },
          expected = "A batch is already open. Close or cancel it first." },
        { name = "the scan is still running",
          input = { op = "start", ctx = { isHost = true, lootMethod = "master", scanning = true, ticked = 2 } },
          expected = "Still looking the loot up." },
        { name = "nothing ticked",
          input = { op = "start", ctx = { isHost = true, lootMethod = "master", ticked = 0 } },
          expected = "No items are ticked." },
        { name = "ready to start",
          input = { op = "start", ctx = { isHost = true, lootMethod = "master", ticked = 3 } },
          expected = "" },

        -- Acceptance: tier count and timer are disabled while a batch is open, with a reason.
        { name = "tier count is frozen mid-batch",
          input = { op = "setting", key = "tierCount", batchOpen = true },
          expected = "Frozen while a batch is open. Your change would apply to the next one." },
        { name = "the timer is frozen mid-batch",
          input = { op = "setting", key = "timerSeconds", batchOpen = true },
          expected = "Frozen while a batch is open. Your change would apply to the next one." },
        { name = "the loot mode is frozen mid-batch",
          input = { op = "setting", key = "lootMode", batchOpen = true },
          expected = "Frozen while a batch is open. Your change would apply to the next one." },
        { name = "the quality threshold changes any time",
          input = { op = "setting", key = "qualityThreshold", batchOpen = true }, expected = "" },
        { name = "tier count is free between batches",
          input = { op = "setting", key = "tierCount", batchOpen = false }, expected = "" },

        { name = "a tier count of zero explains the flat roll",
          input = { op = "tierNote", tierCount = 0, lootMode = "ROLL" },
          expected = "Flat roll - no priorities." },
        { name = "a tier count of zero under SK explains the list decides",
          input = { op = "tierNote", tierCount = 0, lootMode = "SK" },
          expected = "No tiers - the priority list decides every item." },
        { name = "a positive tier count needs no note",
          input = { op = "tierNote", tierCount = 3, lootMode = "ROLL" }, expected = "" },

        -- Acceptance: a raid member without the addon shows as "not running".
        { name = "addon status lists versions, drift and absence",
          input = { op = "status", version = "0.1.0",
                    members = { { name = "Steve" }, { name = "Dave" }, { name = "Anna" } },
                    peers = { Steve = "0.1.0", Dave = "0.0.9" } },
          expected = { "Steve=0.1.0", "Dave=0.0.9 (drift)", "Anna=not running" } },

        -- Acceptance (010): SK cannot be selected while the list is empty.
        { name = "Suicide Kings is disabled until seeded",
          input = { op = "lootModes", seeded = false }, expected = { "ROLL", "SK disabled" } },
        { name = "Suicide Kings is selectable once seeded",
          input = { op = "lootModes", seeded = true }, expected = { "ROLL", "SK" } },
    },
}
