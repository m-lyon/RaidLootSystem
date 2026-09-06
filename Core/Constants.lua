-- Core/Constants.lua
--
-- Enums, protocol constants and defaults. Pure Lua, no WoW API (spec 000 section 2).

local ADDON, ns = ...

ns.Constants = {}
local C = ns.Constants

-- Addon version. Keep in step with the .toc "## Version:" field.
C.VERSION = "0.1.0"

--------------------------------------------------------------------------------
-- Comms (spec 000 section 5)
--------------------------------------------------------------------------------

C.PREFIX = "RLS"
C.PROTO = 1

-- Wire delimiters. Item links contain "|" and item strings contain ":", so
-- neither character may be used here.
C.DELIM_FIELD = "^"
C.DELIM_LIST = "~"
C.DELIM_SUB = "="

-- Any of these inside a payload value corrupts the frame, so encoding rejects them.
C.RESERVED_PATTERN = "[%^~=|]"

C.CHUNK_BODY_MAX = 180        -- payload bytes per chunk
C.SEND_RATE = 4               -- messages per second
C.REASSEMBLY_TIMEOUT = 10     -- seconds before an incomplete message set is dropped

C.OPS = {
    HI      = "HI",
    ROSTER  = "ROSTER",
    RREQ    = "RREQ",
    OPEN    = "OPEN",
    SUBMIT  = "SUBMIT",
    STATE   = "STATE",
    RESULT  = "RESULT",
    ROLLS   = "ROLLS",
    ABORT   = "ABORT",
    CFG     = "CFG",
    SKLIST  = "SKLIST",
    SYNC    = "SYNC",
}

--------------------------------------------------------------------------------
-- Tiers (spec 000 section 6)
--------------------------------------------------------------------------------

C.MIN_TIER_COUNT = 0
C.MAX_TIER_COUNT = 5

--------------------------------------------------------------------------------
-- Roster (spec 001)
--------------------------------------------------------------------------------

-- Prefix on an exported roster string. The digit is the protocol version.
C.EXPORT_PREFIX = "RLS1:"

-- Reasons a character cannot be entered. Rendered by the roll window (spec 005).
-- The first four are roster states (spec 001). The rest are the eligibility filter's
-- verdicts (spec 003 section 8); only those are overridable.
C.REASON = {
    NOT_PRESENT = "NOT_PRESENT",
    CONTESTED   = "CONTESTED",
    UNCLAIMED   = "UNCLAIMED",
    NOT_OWNED   = "NOT_OWNED",

    NOT_IN_RAID       = "NOT_IN_RAID",
    WRONG_CLASS_TOKEN = "WRONG_CLASS_TOKEN",
    WRONG_ARMOR       = "WRONG_ARMOR",
    WRONG_WEAPON      = "WRONG_WEAPON",
}

-- Set of reason codes the player may override per entry (spec 003 section 8, spec 005).
C.OVERRIDABLE_REASON = {
    WRONG_CLASS_TOKEN = true,
    WRONG_ARMOR       = true,
    WRONG_WEAPON      = true,
}

--------------------------------------------------------------------------------
-- Resolution (spec 003)
--------------------------------------------------------------------------------

C.LOOT_MODE = { ROLL = "ROLL", SK = "SK" }

C.ROLL_MIN = 1
C.ROLL_MAX = 100

-- Re-roll rounds allowed on a boundary tie before the result is marked degraded
-- (spec 003 section 6). A guard against a pathological rng, not an expected path.
C.MAX_REROLL = 10

-- Why an entry did not roll. Recorded so the results table can say so out loud.
C.NOT_ROLLED = {
    NOT_CONSULTED = "not consulted",
    WITHDRAWN     = "withdrawn",
}

--------------------------------------------------------------------------------
-- Saved-variable defaults (spec 000 section 4). Database.lua owns the copy.
--------------------------------------------------------------------------------

C.SCHEMA = 1

C.DEFAULTS = {
    schema = C.SCHEMA,
    roster = {
        order = {},
        chars = {},
    },
    settings = {
        eligibilityFilter = true,
        autoEquipWinners  = true,
        verbosity         = "SUMMARY",
        minimap           = { hide = false, minimapPos = 220 },
        windows           = {},
    },
    host = {
        tierCount        = 3,
        timerSeconds     = 180,
        qualityThreshold = 4,
        lootMode         = "ROLL",
    },
    priority = {
        version = 0,
        seed    = 0,
        order   = {},
    },
    history = {},
    pending = {},
}

-- The enUS class file names. Used by the manual-entry class picker (spec 001 section 4).
C.CLASSES = {
    "DEATHKNIGHT", "DRUID", "HUNTER", "MAGE", "PALADIN",
    "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
}
