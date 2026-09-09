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
-- Schema 3: rebuilt, not migrated (spec 012 section 9)
--
-- There is no migration path to campaigns. Anything not at schema 3 has its roster,
-- campaigns, history and pending rebuilt from the defaults. No installed base exists
-- beyond the author's own test data, and a migration that has never run against real
-- data is worse than none: it looks like a safety net and is not one.
--
-- Settings survive, because they are preferences about the addon rather than state
-- the new schema reshapes.
--------------------------------------------------------------------------------

local REBUILT = { "roster", "campaigns", "activeCampaign", "history", "pending", "scratch" }

local function rebuild(db)
    for _, section_ in ipairs(REBUILT) do db[section_] = nil end
    -- Removed outright: they live on each campaign now.
    db.host, db.priority = nil, nil
    db.schema = C.SCHEMA
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
        ns.Print(string.format("saved data is at schema %d and this build is at %d. Campaigns "
            .. "replace the old single roster and priority list, and there is no migration: "
            .. "your roster, list and history have been rebuilt empty.", db.schema, C.SCHEMA))
        rebuild(db)
    end

    Util.applyDefaults(db, C.DEFAULTS)
    DB.db = db
    ns.Campaign.EnsureDefault()
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
function DB.History()  return section("history")  end
function DB.Pending()  return section("pending")  end
function DB.Scratch()  return section("scratch")  end

--------------------------------------------------------------------------------
-- Per-campaign state (spec 012 section 9)
--
-- `host` and `priority` no longer exist at the top level; they belong to the active
-- campaign, and every read of them goes through here. Database.lua keeps owning
-- these accessors so a future scoping change stays a single-file problem, exactly
-- as spec 000 section 4 requires.
--------------------------------------------------------------------------------

function DB.Campaigns() return section("campaigns") end

function DB.Host()
    return ns.Campaign.Active().host
end

--- The priority list of one campaign, defaulting to the active one. A message
-- names its campaign, and it is applied to that campaign's list -- never to
-- whichever happens to be active (spec 012 sections 10 and 14).
function DB.Priority(campaignId)
    if campaignId then
        local campaign = ns.Campaign.Get(campaignId)
        if campaign then return ns.Campaign.Normalise(campaign).priority end
        return nil
    end
    return ns.Campaign.Active().priority
end

--- This client's ordering for one campaign: what spec 001 called roster.order.
function DB.Hierarchy(campaignId)
    if campaignId then
        local campaign = ns.Campaign.Get(campaignId)
        return campaign and ns.Campaign.Normalise(campaign).hierarchy or nil
    end
    return ns.Campaign.Active().hierarchy
end

--- The global template new campaigns are seeded from. It resolves nothing: it is
-- never consulted for a tier, an entry or an award (spec 012 section 7).
function DB.DefaultHierarchy()
    return DB.Roster().defaultHierarchy
end

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
