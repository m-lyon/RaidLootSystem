-- tests/fixtures/simulate.lua
--
-- The pure half of Modules/Simulate.lua (spec 009 section 4): every named scenario
-- builds a consistent plan whose entries name characters the submitting player
-- actually claims, and the scenario-specific shapes are what they say they are.

local ns = ...

local function run(input, ns)
    local S = ns.Simulate

    if input.op == "args" then
        return S.ParseArgs(input.text)
    elseif input.op == "build" then
        local plan, why = S.Build(input.scenario, input.params)
        if not plan then return { why = why } end
        -- Every entry must name a character in its player's roster; every item must parse.
        local badEntries, entries = 0, 0
        for _, player in ipairs(plan.players) do
            local owned = {}
            for _, name in ipairs(player.order) do owned[name] = true end
            for _, e in ipairs(plan.entries[player.name] or {}) do
                entries = entries + 1
                if not owned[e.char] or e.itemIdx < 1 or e.itemIdx > #plan.items then
                    badEntries = badEntries + 1
                end
            end
        end
        local badItems = 0
        for _, item in ipairs(plan.items) do
            if not ns.ItemInfo.ParseLink(item.link) then badItems = badItems + 1 end
        end
        local revisers = 0
        for _ in pairs(plan.revise) do revisers = revisers + 1 end
        return { players = #plan.players, items = #plan.items, entries = entries,
                 badEntries = badEntries, badItems = badItems, lootMode = plan.lootMode,
                 revisers = revisers, rolls = plan.rolls and #plan.rolls or 0,
                 absent = plan.absent and #plan.absent or 0,
                 hostChange = plan.hostChange or 0, failDelivery = plan.failDelivery == true,
                 copies = plan.items[1].quantity }
    elseif input.op == "chunks" then
        local plan = S.Build(input.scenario, input.params)
        return { multi = S.OpenChunks(plan) > 1 }
    elseif input.op == "contested" then
        local plan = S.Build("contested")
        local claims = ns.Roster.BuildClaims({
            [plan.players[1].name] = { order = plan.players[1].order },
            [plan.players[2].name] = { order = plan.players[2].order },
        })
        return { bonkContested = claims.bonk ~= nil and claims.bonk.contested == true }
    elseif input.op == "token" then
        local plan = S.Build("token")
        local info = ns.ItemInfo.Classify({ itemId = 40631, name = "Helm of the Lost Conqueror",
                                            itemString = "item:40631", cached = false })
        return { tokenGroup = info.tokenGroup or "" }
    elseif input.op == "star" then
        local plan = S.Build("star")
        local starred = 0
        for _, list in pairs(plan.entries) do
            for _, e in ipairs(list) do if e.star then starred = starred + 1 end end
        end
        return starred
    elseif input.op == "resolve" then
        -- Feed a plan through Resolve.round as the host would: tiers from roster
        -- position under tier count 3, the rng replaying plan.rolls.
        local plan = S.Build(input.scenario)
        local items, entriesByItem = {}, {}
        for i, item in ipairs(plan.items) do
            items[i] = { idx = i, itemString = "item:" .. i, count = item.quantity }
            entriesByItem[i] = {}
        end
        for _, player in ipairs(plan.players) do
            for _, e in ipairs(plan.entries[player.name]) do
                local position = ns.Util.indexOf(player.order, e.char)
                table.insert(entriesByItem[e.itemIdx], { char = e.char, owner = player.name,
                    tier = ns.Tiers.forPosition(position, 3) })
            end
        end
        local n = 0
        local results = ns.Resolve.round(items, entriesByItem, {
            rng = function() n = n + 1; return plan.rolls[n] end,
            lootMode = plan.lootMode,
        })
        local first = results[1]
        local tiers, rerolled = {}, 0
        for i, a in ipairs(first.awards) do tiers[i] = a.tier end
        for _, r in ipairs(first.record) do rerolled = rerolled + #r.rerolled end
        return { winnerTiers = tiers, rerolled = rerolled, rngCalls = n, degraded = first.degraded }
    elseif input.op == "scenarios" then
        return S.ListScenarios()
    end
    error("unknown op: " .. tostring(input.op))
end

local function consistent(scenario, params, extra)
    local expected = { badEntries = 0, badItems = 0, revisers = 1, rolls = 0, absent = 0,
                       hostChange = 0, failDelivery = false, copies = 1, lootMode = "ROLL" }
    for k, v in pairs(extra or {}) do expected[k] = v end
    return { name = "scenario " .. scenario .. " builds a consistent plan",
             input = { op = "build", scenario = scenario, params = params }, expected = expected }
end

return {
    name = "simulate",
    run = run,
    cases = {
        { name = "arguments parse with defaults",
          input = { op = "args", text = "" },
          expected = { scenario = "default" } },
        { name = "arguments parse items, players and scenario",
          input = { op = "args", text = "items=6 players=5 scenario=tie" },
          expected = { scenario = "tie", items = 6, players = 5 } },
        { name = "an unknown scenario is refused",
          input = { op = "build", scenario = "nope" },
          expected = { why = "unknown scenario: nope" } },
        { name = "the scenario list is the spec's table",
          input = { op = "scenarios" },
          expected = "abort, absent, chunked, contested, default, duplicate, restore, sk, special, star, tie, token, unclaimed" },

        consistent("default", nil, { players = 3, items = 4, entries = 24 }),
        consistent("default", { items = 6, players = 5 }, { players = 5, items = 6, entries = 60 }),
        consistent("tie", nil, { players = 3, items = 4, entries = 2, rolls = 4, revisers = 0 }),
        consistent("duplicate", nil, { players = 3, items = 4, entries = 3, rolls = 3, copies = 2, revisers = 0 }),
        consistent("unclaimed", nil, { players = 3, items = 4, entries = 18 }),
        consistent("contested", nil, { players = 3, items = 4, entries = 26, revisers = 0 }),
        consistent("token", nil, { players = 3, items = 4, entries = 18, revisers = 0 }),
        consistent("special", nil, { players = 3, items = 4, entries = 24 }),
        consistent("abort", nil, { players = 3, items = 4, entries = 24, hostChange = 3 }),
        consistent("chunked", nil, { players = 5, items = 12, entries = 120 }),
        consistent("sk", nil, { players = 3, items = 4, entries = 24, lootMode = "SK" }),
        consistent("star", nil, { players = 3, items = 4, entries = 12, lootMode = "SK", revisers = 0 }),
        consistent("absent", nil, { players = 3, items = 4, entries = 24, lootMode = "SK", absent = 2 }),
        consistent("restore", nil, { players = 3, items = 4, entries = 24, lootMode = "SK", failDelivery = true }),

        {
            -- Acceptance: `chunked` needs multi-chunk transport; the default does not.
            name = "the chunked scenario's OPEN spans several chunks",
            input = { op = "chunks", scenario = "chunked" },
            expected = { multi = true },
        },
        { name = "the default scenario's OPEN fits one chunk",
          input = { op = "chunks", scenario = "default" }, expected = { multi = false } },
        { name = "the contested scenario really contests Bonk",
          input = { op = "contested" }, expected = { bonkContested = true } },
        { name = "the token scenario's item classifies as a token by name, uncached",
          input = { op = "token" }, expected = { tokenGroup = "CONQUEROR" } },
        { name = "the star scenario stars exactly one entry",
          input = { op = "star" }, expected = 1 },
        {
            -- Acceptance: scenario=tie produces a visible re-roll.
            name = "the tie scenario's rolls tie and re-roll",
            input = { op = "resolve", scenario = "tie" },
            expected = { winnerTiers = { 1 }, rerolled = 2, rngCalls = 4, degraded = false },
        },
        {
            -- The second copy spills from T1 into T2.
            name = "the duplicate scenario's second copy spills into T2",
            input = { op = "resolve", scenario = "duplicate" },
            expected = { winnerTiers = { 1, 2 }, rerolled = 0, rngCalls = 3, degraded = false },
        },
        { name = "the absent scenario builds with a single player",
          input = { op = "build", scenario = "absent", params = { players = 1 } },
          expected = { players = 1, items = 4, entries = 8, badEntries = 0, badItems = 0,
                       lootMode = "SK", revisers = 1, rolls = 0, absent = 1, hostChange = 0,
                       failDelivery = false, copies = 1 } },
    },
}
