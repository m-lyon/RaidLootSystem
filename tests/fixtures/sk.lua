-- tests/fixtures/sk.lua
--
-- Spec 009 section 2's standing obligation for spec 010: every `resolve` case must
-- also pass with opts.lootMode absent and with "ROLL", so SK cannot quietly change the
-- base algorithm; and under SK the rng records zero calls. The cases are the resolve
-- suite's own, loaded here and re-run.

local ns = ...

local resolve = assert(loadfile("tests/fixtures/resolve.lua"))(ns)

-- Structural equality, the runner's rule.
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function run(input, ns)
    if input.op == "sameUnderRoll" then
        -- A non-SK resolve case, run with lootMode absent and with "ROLL".
        local absent = resolve.run(input.case.input, ns)
        local explicit = {}
        for k, v in pairs(input.case.input) do explicit[k] = v end
        explicit.lootMode = "ROLL"
        local rolled = resolve.run(explicit, ns)
        return { absentMatchesExpected = same(absent, input.case.expected),
                 rollMatchesExpected = same(rolled, input.case.expected) }
    elseif input.op == "noRng" then
        local out = resolve.run(input.case.input, ns)
        return { rngCalls = out.rngCalls }
    end
    error("unknown op: " .. tostring(input.op))
end

local cases = {}
for _, case in ipairs(resolve.cases) do
    if case.input.lootMode == "SK" then
        cases[#cases + 1] = {
            name = "no rng under SK: " .. case.name,
            input = { op = "noRng", case = case },
            expected = { rngCalls = 0 },
        }
    elseif case.input.kind ~= "error" and case.input.kind ~= "repeatable" then
        cases[#cases + 1] = {
            name = "unchanged with lootMode absent and ROLL: " .. case.name,
            input = { op = "sameUnderRoll", case = case },
            expected = { absentMatchesExpected = true, rollMatchesExpected = true },
        }
    end
end

return { name = "sk", run = run, cases = cases }
