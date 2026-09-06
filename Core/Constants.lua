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
-- Session lifecycle (spec 002)
--------------------------------------------------------------------------------

C.SESSION_STATE = {
    OPEN      = "OPEN",
    RESOLVING = "RESOLVING",
    CLOSED    = "CLOSED",
    ABORTED   = "ABORTED",
}

-- Why a batch ended without a result (spec 002 section 9). Shown in the window,
-- not only in chat, and written to history so a batch never simply vanishes.
C.ABORT_REASON = {
    ML_CHANGED = "ML_CHANGED",
    HOST_LEFT  = "HOST_LEFT",
    LOOT_GONE  = "LOOT_GONE",
    EXPIRED    = "EXPIRED",
    MANUAL     = "MANUAL",
    RESOLVE_FAILED = "RESOLVE_FAILED",
}

C.ABORT_TEXT = {
    ML_CHANGED = "the master looter changed",
    HOST_LEFT  = "the host left the raid",
    LOOT_GONE  = "the loot is no longer there",
    EXPIRED    = "the batch was left unresolved for too long",
    MANUAL     = "the host cancelled it",
    RESOLVE_FAILED = "the batch could not be resolved",
}

-- Per-copy outcome on the wire (spec 000 section 5, RESULT).
C.OUTCOME = {
    WON       = "WON",         -- awarded normally
    DEGRADED  = "DEGRADED",    -- awarded, but a tie ran out of re-rolls (003 section 6)
    UNCLAIMED = "UNCLAIMED",   -- nobody entered; master looter's choice
}

-- Why an entry the host received was not accepted. Counted rather than itemised
-- on the wire; the submitting client compares counts (spec 002 section 5).
C.REJECT = {
    NO_SUCH_ITEM = "NO_SUCH_ITEM",
    NOT_PUBLISHED = "NOT_PUBLISHED",
    CONTESTED = "CONTESTED",
    NOT_PRESENT = "NOT_PRESENT",
    INELIGIBLE = "INELIGIBLE",
    DUPLICATE = "DUPLICATE",
}

C.STATE_COALESCE = 0.5        -- trailing timer on STATE broadcasts, seconds
C.SYNC_INTERVAL = 5           -- a client sends SYNC at most this often
C.HOST_LEFT_GRACE = 60        -- seconds past endsAt with no RESULT before a client aborts
C.BATCH_EXPIRY = 15 * 60      -- an unresolved batch aborts as EXPIRED after this

C.MIN_TIMER_SECONDS = 15
C.MAX_TIMER_SECONDS = 300
C.EXTEND_SECONDS = 60         -- what the host panel's Extend adds (spec 006 section 3)

-- Chat lines per second the announcement queue drains at (spec 006 section 4). The
-- client throttles chat like the server throttles addon messages, just more visibly.
C.CHAT_RATE = 3

C.VERBOSITY = { OFF = "OFF", SUMMARY = "SUMMARY", VERBOSE = "VERBOSE" }
C.QUALITY_CHOICES = { { value = 3, text = "Rare" }, { value = 4, text = "Epic" } }

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

-- The same, on the wire (ROLLS, spec 000 section 5). An entry that rolled, or that
-- was looked up under SK, carries an empty status.
C.ROLL_STATUS = {
    ROLLED        = "",
    NOT_CONSULTED = "NC",
    WITHDRAWN     = "WD",
}
C.ROLL_STATUS_OF_REASON = {
    [C.NOT_ROLLED.NOT_CONSULTED] = C.ROLL_STATUS.NOT_CONSULTED,
    [C.NOT_ROLLED.WITHDRAWN]     = C.ROLL_STATUS.WITHDRAWN,
}
C.REROLL_JOIN = "+"           -- joins a re-roll list inside one ROLLS element

-- The roll window turns amber for the last seconds of a batch (spec 005 section 3) and
-- shows an abort reason in place for this long before closing (section 6).
C.COUNTDOWN_WARN_SECONDS = 30
C.ABORT_LINGER_SECONDS = 10

--------------------------------------------------------------------------------
-- Award and delivery (spec 007)
--------------------------------------------------------------------------------

-- Per-copy delivery state, as recorded in history (spec 008 section 3). AWAITING is
-- the state between resolution and the host's click; it is distinct from PENDING,
-- which means the host holds the item for a trade.
C.DELIVERY = {
    AWAITING  = "AWAITING",
    DELIVERED = "DELIVERED",
    PENDING   = "PENDING",
    FAILED    = "FAILED",
    LOST      = "LOST",
    UNCLAIMED = "UNCLAIMED",
}

C.DELIVERY_PATH = { MASTER_LOOT = "MASTER_LOOT", TRADE = "TRADE" }

-- Named failure states (spec 007 section 4). Every one is visible and retryable.
C.AWARD_FAILURE = {
    NOT_A_CANDIDATE  = "NOT_A_CANDIDATE",
    SOURCE_INVALID   = "SOURCE_INVALID",
    SLOT_NOT_CLEARED = "SLOT_NOT_CLEARED",
    NO_LOOT_METHOD   = "NO_LOOT_METHOD",
    NOT_LOOTED       = "NOT_LOOTED",       -- the host's own LootSlot never cleared the slot
    TRADE_EXPIRED    = "TRADE_EXPIRED",    -- the two-hour window ran out; bound to the host
}

C.AWARD_CLEAR_TIMEOUT = 3          -- seconds to wait for LOOT_SLOT_CLEARED after GiveMasterLoot
C.TRADE_OPEN_TIMEOUT = 30          -- seconds to wait for TRADE_SHOW after InitiateTrade
C.PENDING_TTL = 7200               -- the 3.3.0 bind-on-pickup trade window
C.PENDING_WARN_AMBER = 30 * 60
C.PENDING_WARN_RED = 10 * 60

-- The mod-playerbots equip command (spec 007 section 7). Unconfirmed against the server
-- build; the argument form (link vs name) is the open question.
C.BOT_EQUIP_COMMAND = "equip"

--------------------------------------------------------------------------------
-- Saved-variable defaults (spec 000 section 4). Database.lua owns the copy.
--------------------------------------------------------------------------------

C.SCHEMA = 2                  -- 2: priority.seedChars and priority.log (spec 010 section 9)

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
        autoClose        = false,   -- close as soon as everyone expected has submitted
    },
    priority = {
        version   = 0,
        seed      = 0,
        seedChars = {},           -- the names the seed shuffled, in the order it took them
        order     = {},
        log       = {},           -- every mutation since the seed, for verify's replay
    },
    history = {},
    pending = {},
    -- Ticks the player has made in the roll window but not yet submitted. Kept in saved
    -- variables so a /reload mid-batch loses nothing (spec 005 section 6).
    scratch = {
        sessionId = "",
        ticks = {},               -- itemIdx -> charName -> { override, star }
    },
}

-- The enUS class file names. Used by the manual-entry class picker (spec 001 section 4).
C.CLASSES = {
    "DEATHKNIGHT", "DRUID", "HUNTER", "MAGE", "PALADIN",
    "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
}
