-- tests/fixtures/minimap.lua
--
-- Which window the minimap button opens (spec 006 section 3). The button gives you
-- the window your role wants: a master looter's is the host panel, which before this
-- had no entry point but `/rls host`.

local ns = ...

local function run(input, ns)
    local M = ns.Minimap
    if input.op == "primary" then
        return M.PrimaryTarget(input.isHost, input.hasContent)
    elseif input.op == "ctrl" then
        return M.CtrlTarget(input.isHost, input.hasContent) or "nothing"
    elseif input.op == "reachable" then
        -- Every window the button can open, across both chords plus the fixed
        -- shift-click. Nothing a role needs may become unreachable.
        local seen = { [M.PrimaryTarget(input.isHost, input.hasContent)] = true,
                       HIERARCHY = true }
        local ctrl = M.CtrlTarget(input.isHost, input.hasContent)
        if ctrl then seen[ctrl] = true end
        local out = {}
        for _, k in ipairs({ "HIERARCHY", "HOST", "ROLL" }) do
            if seen[k] then out[#out + 1] = k end
        end
        return out
    end
    error("unknown op: " .. tostring(input.op))
end

return {
    name = "minimap",
    run = run,
    cases = {
        { name = "a master looter gets the host panel",
          input = { op = "primary", isHost = true, hasContent = false }, expected = "HOST" },
        { name = "a master looter gets the host panel during a round too",
          input = { op = "primary", isHost = true, hasContent = true }, expected = "HOST" },
        { name = "a player in a live round gets the roll window",
          input = { op = "primary", isHost = false, hasContent = true }, expected = "ROLL" },
        { name = "a player with no round gets their hierarchy",
          input = { op = "primary", isHost = false, hasContent = false },
          expected = "HIERARCHY" },

        { name = "ctrl gives a host back the roll window when there is one",
          input = { op = "ctrl", isHost = true, hasContent = true }, expected = "ROLL" },
        { name = "ctrl does nothing for a host with no round",
          input = { op = "ctrl", isHost = true, hasContent = false }, expected = "nothing" },
        { name = "ctrl does nothing for a player, whose primary click is already right",
          input = { op = "ctrl", isHost = false, hasContent = true }, expected = "nothing" },

        -- The property that matters: the host panel became reachable and nothing that
        -- was reachable before stopped being.
        { name = "a host in a live round can reach all three windows",
          input = { op = "reachable", isHost = true, hasContent = true },
          expected = { "HIERARCHY", "HOST", "ROLL" } },
        { name = "a host outside a round can reach the panel and the hierarchy",
          input = { op = "reachable", isHost = true, hasContent = false },
          expected = { "HIERARCHY", "HOST" } },
        { name = "a player in a live round keeps the roll window and the hierarchy",
          input = { op = "reachable", isHost = false, hasContent = true },
          expected = { "HIERARCHY", "ROLL" } },
        { name = "a player outside a round keeps the hierarchy",
          input = { op = "reachable", isHost = false, hasContent = false },
          expected = { "HIERARCHY" } },
    },
}
