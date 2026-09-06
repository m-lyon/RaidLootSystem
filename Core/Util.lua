-- Core/Util.lua
--
-- Table and string helpers. Pure Lua, no WoW API (spec 000 section 2).

local ADDON, ns = ...

ns.Util = {}
local Util = ns.Util

--- Shallow copy of an array or map.
function Util.copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

--- Recursive copy. Cycles are not supported; the saved-variable tables have none.
function Util.deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = Util.deepCopy(v) end
    return out
end

--- Fill missing keys in `target` from `defaults`, recursing into subtables.
-- Existing values are never overwritten. Used by Database.lua for defaults.
function Util.applyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            Util.applyDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
    return target
end

--- Character names are stored in the game's capitalisation and compared
-- case-insensitively (spec 001 section 2 invariant 4).
function Util.nameKey(name)
    return type(name) == "string" and name:lower() or nil
end

--- Position of `value` in array `t`, or nil. Strings compare case-insensitively.
function Util.indexOf(t, value)
    local key = type(value) == "string" and value:lower() or value
    for i = 1, #t do
        local v = t[i]
        if (type(v) == "string" and v:lower() or v) == key then return i end
    end
    return nil
end

--- Move the element at `from` to `to`, shifting the rest. Out-of-range is a no-op.
function Util.move(t, from, to)
    if from == to then return false end
    if from < 1 or from > #t or to < 1 or to > #t then return false end
    local v = table.remove(t, from)
    table.insert(t, to, v)
    return true
end

function Util.count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--- Split `s` on a single-character delimiter. Empty fields are preserved, which
-- the wire protocol relies on -- an empty body is a valid RREQ payload.
function Util.split(s, delim)
    local out = {}
    if s == nil or s == "" then return out end
    local pattern = "([^" .. delim:gsub("(%W)", "%%%1") .. "]*)"
    local pos = 1
    while true do
        local a, b, field = s:find(pattern, pos)
        out[#out + 1] = field
        pos = b + 2
        if pos > #s + 1 then break end
    end
    return out
end

function Util.trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Title-case a hand-typed name so manual entry matches the game's capitalisation.
function Util.titleCase(s)
    s = Util.trim(s):lower()
    return (s:gsub("^%l", string.upper))
end

--- Clamp `v` into [lo, hi].
function Util.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
