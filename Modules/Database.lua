-- Modules/Database.lua
--
-- SavedVariables load, defaults and migration (spec 000 section 4).
-- Every other module reads through these accessors and never touches the global
-- table, so migration stays a single-file problem.

local ADDON, ns = ...

ns.Database = {}
local DB = ns.Database

local C = ns.Constants
local Util = ns.Util

--------------------------------------------------------------------------------
-- Migration
--
-- One function per step, keyed by the schema version it upgrades FROM.
--------------------------------------------------------------------------------

local migrations = {
    -- [1] = function(db) ... end,   -- schema 1 -> 2
}

local function migrate(db)
    while db.schema < C.SCHEMA do
        local step = migrations[db.schema]
        if not step then
            -- No path forward. Say so rather than corrupting the table.
            ns.Print(string.format(
                "saved data is at schema %d and this build expects %d, with no migration between them. "
                .. "Your data was left untouched.", db.schema, C.SCHEMA))
            return false
        end
        step(db)
        db.schema = db.schema + 1
    end
    return true
end

--------------------------------------------------------------------------------
-- Load
--------------------------------------------------------------------------------

--- Called from ADDON_LOADED, once, before any other module initialises.
function DB.Load()
    if type(RaidLootSystemDB) ~= "table" then
        RaidLootSystemDB = {}
    end
    local db = RaidLootSystemDB

    if db.schema == nil then
        db.schema = C.SCHEMA
    elseif db.schema > C.SCHEMA then
        ns.Print(string.format(
            "saved data is from a newer version (schema %d, this build reads %d). "
            .. "Update the addon before raiding.", db.schema, C.SCHEMA))
    elseif db.schema < C.SCHEMA then
        migrate(db)
    end

    Util.applyDefaults(db, C.DEFAULTS)
    DB.db = db
    return db
end

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

local function section(name)
    local db = DB.db or DB.Load()
    return db[name]
end

function DB.Roster()   return section("roster")   end
function DB.Settings() return section("settings") end
function DB.Host()     return section("host")     end
function DB.Priority() return section("priority") end
function DB.History()  return section("history")  end
function DB.Pending()  return section("pending")  end
function DB.Scratch()  return section("scratch")  end

--- History is pruned by replacing the array (spec 008 section 4); the accessor keeps
-- the global out of every other file.
function DB.ReplaceHistory(records)
    local db = DB.db or DB.Load()
    db.history = records
    return records
end

--- The tier count to display outside a raid, or before a host announces one.
function DB.DefaultTierCount()
    return Util.clamp(DB.Host().tierCount or 3, C.MIN_TIER_COUNT, C.MAX_TIER_COUNT)
end

--- Remembered position of a named frame, for UI/Widgets.
function DB.WindowState(key)
    local windows = DB.Settings().windows
    windows[key] = windows[key] or {}
    return windows[key]
end
