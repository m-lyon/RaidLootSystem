-- Modules/Announce.lua
--
-- Chat output (spec 006 section 4). Only the host announces; clients never write to
-- raid chat. Every line goes through one formatter here, so the prefix and the
-- item-link handling are consistent, and every line goes through one queue, so a
-- verbose round drains rather than tripping the client's chat throttle.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the
-- `announce` suite: the formats, and which verbosity level emits which kind.

local ADDON, ns = ...

ns.Announce = {}
local Announce = ns.Announce

local C = ns.Constants

--------------------------------------------------------------------------------
-- Pure: verbosity (section 4)
--------------------------------------------------------------------------------

Announce.PREFIX = "[RLS] "

Announce.LEVEL = { OFF = 0, SUMMARY = 1, VERBOSE = 2 }

local LEVEL_OF_VERBOSITY = { OFF = 0, SUMMARY = 1, VERBOSE = 2 }

--- The level each kind of line needs. Summary is the round's shape and outcome;
-- verbose adds every roll and every tie.
Announce.KIND_LEVEL = {
    OPEN       = 1,
    WIN        = 1,
    UNCLAIMED  = 1,
    DEGRADED   = 1,
    ABORT      = 1,
    LOOT_LOST  = 1,
    EXTEND     = 1,
    TIER_COUNT = 1,
    TIMER      = 1,
    LOOT_MODE  = 1,
    HIERARCHY_LOCK = 1,    -- it changes what members may do; never silent
    PRIORITY   = 1,        -- priority-list edits (spec 010 section 10) are never silent
    ROLL       = 2,
    TIE        = 2,
}

--- Does this verbosity setting emit a line of this level?
-- @param level      Announce.LEVEL value, or a kind name
-- @param verbosity  "OFF" | "SUMMARY" | "VERBOSE", as stored in settings
function Announce.Emits(level, verbosity)
    if type(level) == "string" then level = Announce.KIND_LEVEL[level] or 1 end
    local ceiling = LEVEL_OF_VERBOSITY[verbosity or "SUMMARY"] or 1
    return level <= ceiling
end

--------------------------------------------------------------------------------
-- Pure: formats (section 4)
--------------------------------------------------------------------------------

local function clock(seconds)
    seconds = math.max(0, math.floor((seconds or 0) + 0.5))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function joinNames(names)
    if #names == 0 then return "" end
    if #names == 1 then return names[1] end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

--- "T1, T2, Rest" for a tier count, or "flat roll" for 0.
local function tierList(tierCount)
    if not tierCount or tierCount <= 0 then return "flat roll" end
    local parts = {}
    for i = 1, tierCount do parts[i] = "T" .. i end
    parts[#parts + 1] = "Rest"
    return table.concat(parts, ", ")
end

--- "SK" or "Roll", from a round's or a setting's loot mode. One definition, so the
-- open line and the mode-change line cannot name the same mode two different ways.
--
-- Abbreviated because it is chat: the group says SK, and every line here competes
-- with combat spam for a raider's attention inside a 255-byte cap. The panel and the
-- dialogs still spell it out, where there is room to teach the term.
local function modeName(lootMode)
    return lootMode == C.LOOT_MODE.SK and "SK" or "Roll"
end

local FORMATS = {
    -- Rolling: [Item A] [Item B] [Item C] - 3:00       (ROLL)
    -- SK: [Item A] [Item B] [Item C] - 3:00             (SK)
    --
    -- The mode leads the line rather than trailing it. A host who has seeded a list
    -- and left the mode on ROLL reads the first word of their own announcement and
    -- sees it, which is the raid-night failure this carries (spec 006 section 4).
    -- ROLL reads as "Rolling" here and "Roll" as a setting: one is the thing about to
    -- happen, the other is the name of a mode.
    OPEN = function(a)
        local lead = a.lootMode == C.LOOT_MODE.SK and modeName(a.lootMode) or "Rolling"
        return lead .. ": " .. table.concat(a.labels or {}, " ") .. " - " .. clock(a.seconds)
    end,

    -- Botty [T2, 83] wins [Item A]          (ROLL)
    -- Botty [T2, #3] wins [Item A]          (SK)
    WIN = function(a)
        local inside = a.tierLabel
        if a.listIdx and a.listIdx > 0 then
            inside = inside .. ", #" .. a.listIdx
        elseif a.roll and a.roll > 0 then
            inside = inside .. ", " .. a.roll
        end
        local text = a.char .. " [" .. inside .. "] wins " .. a.label
        if a.copy and a.copies and a.copies > 1 then
            text = text .. " (copy " .. a.copy .. " of " .. a.copies .. ")"
        end
        return text
    end,

    -- [Item B] - no entries, master looter's choice
    UNCLAIMED = function(a)
        return a.label .. " - no entries, master looter's choice"
    end,

    DEGRADED = function(a)
        return a.label .. " - tie re-rolls exhausted, the order was decided without one"
    end,

    -- Botty rolled 83 [T2] on [Item A]
    ROLL = function(a)
        return a.char .. " rolled " .. a.roll .. " [" .. a.tierLabel .. "] on " .. a.label
    end,

    -- Botty and Sneaky tied on 83 - rerolling: Botty 47, Sneaky 90
    TIE = function(a)
        local parts = {}
        for i, r in ipairs(a.rerolls or {}) do parts[i] = r.char .. " " .. r.roll end
        return joinNames(a.names or {}) .. " tied on " .. a.roll .. " - rerolling: "
            .. table.concat(parts, ", ")
    end,

    ABORT = function(a)
        return "Round cancelled: " .. (a.reasonText or a.reason or "?")
    end,

    LOOT_LOST = function(a)
        if a.remaining then
            return string.format("%s: %d cop%s no longer on the corpse; the roll continues on what is left",
                a.label, a.count, a.count == 1 and "y is" or "ies are")
        end
        return a.label .. " is no longer on the corpse and has left the round"
    end,

    -- Entry timer extended by 60 seconds - 1:32 left
    EXTEND = function(a)
        return "Entry timer extended by " .. a.seconds .. " seconds - " .. clock(a.left) .. " left"
    end,

    -- Tier count is now 2 (T1, T2, Rest)
    TIER_COUNT = function(a)
        return "Tier count is now " .. a.tierCount .. " (" .. tierList(a.tierCount) .. ")"
    end,

    TIMER = function(a)
        return "Entry timer is now " .. clock(a.seconds)
    end,

    LOOT_MODE = function(a)
        return "Loot mode is now " .. modeName(a.lootMode)
    end,

    -- Hierarchies are locked - tier rankings are fixed for this campaign
    HIERARCHY_LOCK = function(a)
        if a.locked then
            return "Hierarchies are locked - tier rankings are fixed for this campaign"
        end
        return "Hierarchies are unlocked - you may re-rank your characters"
    end,

    PRIORITY = function(a)
        return "Priority list: " .. (a.text or "changed")
    end,
}

--- Render one kind of line, without the prefix.
-- @return text, or nil for an unknown kind
function Announce.Format(kind, args)
    local format = FORMATS[kind]
    if not format then return nil end
    return format(args or {})
end

--- The lines a resolved round produces at a given verbosity, in the order they are
-- said. Pure, so the exact chat output of a round is fixture-testable.
--
-- @param items     the round items, with `label` already resolved by the caller
-- @param results   Core/Resolve results, parallel to items
-- @param opts      { verbosity, isSK, tierCount }
-- @return array of strings (without the prefix)
function Announce.RoundLines(items, results, opts)
    opts = opts or {}
    local Tiers = ns.Tiers
    local lines = {}
    local function say(kind, args)
        if Announce.Emits(kind, opts.verbosity) then
            lines[#lines + 1] = Announce.Format(kind, args)
        end
    end

    for i = 1, #items do
        local item, result = items[i], results[i]
        local label = item.label or item.itemString or ("item " .. tostring(item.idx))
        if result then
            if not opts.isSK then
                -- Every roll, then every tie, then the winner (verbose adds the first two).
                for _, e in ipairs(result.record or {}) do
                    if e.rolled and (e.roll or 0) > 0 then
                        say("ROLL", { char = e.char, roll = e.roll,
                                      tierLabel = Tiers.label(e.tier, opts.tierCount),
                                      label = label })
                    end
                end
                -- Tie groups: entries sharing an original roll that re-rolled.
                local groups, order = {}, {}
                for _, e in ipairs(result.record or {}) do
                    if #(e.rerolled or {}) > 0 then
                        local key = tostring(e.tier) .. "/" .. tostring(e.roll)
                        if not groups[key] then
                            groups[key] = { roll = e.roll, names = {}, rerolls = {} }
                            order[#order + 1] = key
                        end
                        local g = groups[key]
                        g.names[#g.names + 1] = e.char
                        g.rerolls[#g.rerolls + 1] = { char = e.char, roll = e.rerolled[#e.rerolled] }
                    end
                end
                for _, key in ipairs(order) do say("TIE", groups[key]) end
            end

            if result.unclaimed then
                say("UNCLAIMED", { label = label })
            else
                local copies = #result.awards
                for copy, award in ipairs(result.awards) do
                    local listIdx
                    for _, e in ipairs(result.record or {}) do
                        if e.char == award.char then listIdx = e.listIdx end
                    end
                    say("WIN", { char = award.char, roll = award.roll,
                                 listIdx = opts.isSK and listIdx or nil,
                                 tierLabel = Tiers.label(award.tier, opts.tierCount),
                                 label = label, copy = copy, copies = copies })
                end
                if result.degraded then say("DEGRADED", { label = label }) end
            end
        end
    end
    return lines
end

--------------------------------------------------------------------------------
-- WoW-facing. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

local queue = {}             -- { text, channel, target }
local accumulator = 0
local frame

local function verbosity()
    return ns.Database.Settings().verbosity or "SUMMARY"
end

--- RAID, falling back to PARTY, then SAY (section 4). Unlike addon messages, a
-- solo host still hears their own announcements.
function Announce.Channel()
    if GetNumRaidMembers() > 0 then return "RAID" end
    if GetNumPartyMembers() > 0 then return "PARTY" end
    return "SAY"
end

--- Replaced by Modules/Simulate.lua, which must never reach real chat (spec 009).
function Announce.transport(text, channel, target)
    SendChatMessage(text, channel, nil, target)
end

local function enqueue(text, channel, target)
    queue[#queue + 1] = { text = text, channel = channel, target = target }
    if frame then frame:Show() end
end

--- Say one already-formatted line to the group, subject to verbosity.
-- @param level  Announce.LEVEL value or a kind name; defaults to SUMMARY
function Announce.Say(message, level)
    if not Announce.Emits(level or Announce.LEVEL.SUMMARY, verbosity()) then return false end
    enqueue(Announce.PREFIX .. message, Announce.Channel())
    return true
end

--- Format and say one kind of line.
function Announce.Emit(kind, args)
    local text = Announce.Format(kind, args)
    if not text then
        ns.Debug("no announcement format for " .. tostring(kind))
        return false
    end
    return Announce.Say(text, kind)
end

--- Say several pre-formatted lines (from RoundLines). Already gated by verbosity.
function Announce.SayAll(lines)
    for _, line in ipairs(lines) do enqueue(Announce.PREFIX .. line, Announce.Channel()) end
end

--- Whisper a bot a command (spec 007 section 7). Bots are not comms peers; this is
-- plain chat, and it shares the queue so six equip commands do not burst.
function Announce.Whisper(target, message)
    if not target or target == "" then return false end
    enqueue(message, "WHISPER", target)
    return true
end

function Announce.QueueLength()
    return #queue
end

local function onUpdate(_, elapsed)
    accumulator = accumulator + elapsed
    local interval = 1 / C.CHAT_RATE
    while accumulator >= interval and #queue > 0 do
        accumulator = accumulator - interval
        local line = table.remove(queue, 1)
        Announce.transport(line.text, line.channel, line.target)
    end
    if #queue == 0 then
        accumulator = 0
        frame:Hide()
    end
end

function Announce.Init()
    if frame then return end
    frame = CreateFrame("Frame", "RaidLootSystemAnnounceFrame")
    frame:SetScript("OnUpdate", onUpdate)
    frame:Hide()                       -- shown only while something is queued
end

--- Test and simulation seam.
function Announce.Reset()
    queue = {}
    accumulator = 0
end
