-- tests/run.lua
--
-- Standalone fixture runner (spec 009 section 2). No dependencies beyond a
-- Lua 5.1 interpreter.
--
--   lua tests/run.lua              # all suites
--   lua tests/run.lua tiers        # one suite
--
-- Core/ and Data/ files use the addon vararg idiom, which this emulates.

local ns = {}

local function loadCore(path)
    local chunk = assert(loadfile(path))
    return chunk("RaidLootSystem", ns)
end

-- Load order mirrors the .toc (spec 000 section 3): Core, then Data.
local CORE_FILES = {
    "Core/Constants.lua",
    "Core/Util.lua",
    "Core/Serialize.lua",
    "Core/Tiers.lua",
    "Core/Eligibility.lua",
    "Core/Resolve.lua",
}

local DATA_FILES = {
    "Data/TierTokens.lua",
    "Data/ClassArmor.lua",
    "Data/ItemClasses.lua",
}

-- Modules that are pure at file scope and expose pure helpers worth testing.
-- Anything here must create no frame and call no WoW API while loading.
local MODULE_FILES = {
    "Modules/Roster.lua",
    "Modules/ItemInfo.lua",
    "Modules/LootDetect.lua",
    "Modules/Session.lua",
    "Modules/Announce.lua",
    "UI/RollWindow.lua",
    "UI/HostPanel.lua",
}

local SUITES = { "tiers", "serialize", "roster", "session", "eligibility", "resolve",
                 "iteminfo", "lootdetect", "rollwindow", "announce", "hostpanel" }

--------------------------------------------------------------------------------
-- Comparison and reporting
--------------------------------------------------------------------------------

local function describe(value, depth)
    depth = depth or 0
    if type(value) ~= "table" then
        if type(value) == "string" then return string.format("%q", value) end
        return tostring(value)
    end
    if depth > 3 then return "{...}" end
    local parts, seen = {}, {}
    for i = 1, #value do
        seen[i] = true
        parts[#parts + 1] = describe(value[i], depth + 1)
    end
    local keys = {}
    for k in pairs(value) do
        if not seen[k] then keys[#keys + 1] = tostring(k) end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. describe(value[k] ~= nil and value[k] or value[tonumber(k)], depth + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function same(a, b, path)
    path = path or ""
    if type(a) ~= type(b) then
        return false, path .. " type " .. type(a) .. " vs " .. type(b)
    end
    if type(a) ~= "table" then
        if a ~= b then return false, path .. " " .. describe(a) .. " vs " .. describe(b) end
        return true
    end
    for k, v in pairs(a) do
        local ok, why = same(v, b[k], path .. "." .. tostring(k))
        if not ok then return false, why end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, path .. "." .. tostring(k) .. " missing in actual" end
    end
    return true
end

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------

local function runSuite(name)
    local suite = assert(loadfile("tests/fixtures/" .. name .. ".lua"))(ns)
    local passed, failed = 0, {}

    for _, case in ipairs(suite.cases) do
        local ok, actual = pcall(suite.run, case.input, ns)
        if not ok then
            failed[#failed + 1] = { name = case.name, why = "error: " .. tostring(actual) }
        else
            local match, why = same(actual, case.expected)
            if match then
                passed = passed + 1
            else
                failed[#failed + 1] = {
                    name = case.name,
                    why = why .. "\n      expected " .. describe(case.expected)
                        .. "\n      actual   " .. describe(actual),
                }
            end
        end
    end

    print(string.format("%-12s %3d passed, %d failed", name, passed, #failed))
    for _, f in ipairs(failed) do
        print("  FAIL  " .. f.name)
        print("      " .. f.why)
    end
    return #failed
end

-- Modules print through the addon; the runner has no chat frame.
ns.Print = function() end
ns.Debug = function() end

for _, path in ipairs(CORE_FILES) do loadCore(path) end
for _, path in ipairs(DATA_FILES) do loadCore(path) end
for _, path in ipairs(MODULE_FILES) do loadCore(path) end

local only = ...
local suites = only and { only } or SUITES
local failures = 0
for _, name in ipairs(suites) do
    failures = failures + runSuite(name)
end

if failures > 0 then
    print(string.format("\n%d failing case(s)", failures))
    os.exit(1)
end
print("\nall suites passed")
