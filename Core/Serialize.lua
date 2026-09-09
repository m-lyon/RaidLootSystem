-- Core/Serialize.lua
--
-- The wire format (spec 000 section 5). Owns encode/decode and chunk split/join.
-- No module builds a wire string by hand. Pure Lua, no WoW API.
--
--   envelope: <proto>^<op>^<msgId>^<seq>^<total>^<body>
--
-- Delimiters are "^" (fields), "~" (list elements) and "=" (sub-fields), because
-- item strings contain ":" and item links contain "|".

local ADDON, ns = ...

ns.Serialize = {}
local Serialize = ns.Serialize

local C = ns.Constants
local Util = ns.Util

local FIELD, LIST, SUB = C.DELIM_FIELD, C.DELIM_LIST, C.DELIM_SUB

--------------------------------------------------------------------------------
-- Value encoding
--------------------------------------------------------------------------------

--- A value is transmittable when it holds no delimiter and no "|".
function Serialize.isSafe(value)
    if value == nil then return false end
    return tostring(value):find(C.RESERVED_PATTERN) == nil
end

--- Join sub-fields of one list element with "=".
function Serialize.encodeElement(fields)
    local out = {}
    for i = 1, #fields do
        local v = fields[i]
        if v == nil then v = "" end
        v = tostring(v)
        if not Serialize.isSafe(v) then
            return nil, "reserved character in field: " .. v
        end
        out[i] = v
    end
    return table.concat(out, SUB)
end

function Serialize.decodeElement(s)
    return Util.split(s, SUB)
end

--- Join encoded elements with "~".
function Serialize.encodeList(elements)
    return table.concat(elements, LIST)
end

function Serialize.decodeList(s)
    if s == nil or s == "" then return {} end
    return Util.split(s, LIST)
end

--- Join top-level fields with "^".
function Serialize.encodeFields(fields)
    local out = {}
    for i = 1, #fields do
        out[i] = fields[i] == nil and "" or tostring(fields[i])
    end
    return table.concat(out, FIELD)
end

function Serialize.decodeFields(s)
    return Util.split(s, FIELD)
end

--------------------------------------------------------------------------------
-- Envelope and chunking
--------------------------------------------------------------------------------

--- Split a body into wire-ready chunks.
-- @return array of strings, each a complete envelope
function Serialize.pack(op, body, msgId)
    body = body or ""
    local max = C.CHUNK_BODY_MAX
    local chunks = {}
    if #body == 0 then
        chunks[1] = ""
    else
        local pos = 1
        while pos <= #body do
            chunks[#chunks + 1] = body:sub(pos, pos + max - 1)
            pos = pos + max
        end
    end

    local total = #chunks
    local out = {}
    for seq = 1, total do
        out[seq] = table.concat({ C.PROTO, op, msgId, seq, total, chunks[seq] }, FIELD)
    end
    return out
end

--- Parse one received envelope.
-- @return table { proto, op, msgId, seq, total, body } or nil, reason
function Serialize.unpack(wire)
    if type(wire) ~= "string" or wire == "" then return nil, "empty message" end

    -- The body may itself contain "^", so only the first five fields are split off.
    local proto, op, msgId, seq, total, body =
        wire:match("^([^%^]*)%^([^%^]*)%^([^%^]*)%^([^%^]*)%^([^%^]*)%^(.*)$")
    if not proto then return nil, "malformed envelope" end

    proto, seq, total = tonumber(proto), tonumber(seq), tonumber(total)
    if not proto or not seq or not total then return nil, "non-numeric envelope field" end
    if op == "" or msgId == "" then return nil, "missing op or message id" end
    if seq < 1 or total < 1 or seq > total then return nil, "bad chunk sequence" end

    return { proto = proto, op = op, msgId = msgId, seq = seq, total = total, body = body }
end

--------------------------------------------------------------------------------
-- Reassembly
--
-- Stateful but timeless: `now` is passed in, so this stays testable and pure
-- (spec 000 section 2).
--------------------------------------------------------------------------------

function Serialize.newAssembler()
    return { pending = {} }
end

--- Feed one parsed envelope in.
-- @return the complete body when the set is finished, otherwise nil
function Serialize.assemble(assembler, sender, msg, now)
    if msg.total == 1 then return msg.body end

    local key = tostring(sender) .. "/" .. msg.msgId
    local set = assembler.pending[key]
    if not set then
        set = { total = msg.total, count = 0, parts = {}, started = now }
        assembler.pending[key] = set
    end
    if set.parts[msg.seq] == nil then
        set.parts[msg.seq] = msg.body
        set.count = set.count + 1
    end
    if set.count < set.total then return nil end

    assembler.pending[key] = nil
    return table.concat(set.parts, "", 1, set.total)
end

--- Drop message sets older than the timeout.
-- @return array of dropped keys, so the caller can surface the loss
function Serialize.pruneAssembler(assembler, now, timeout)
    timeout = timeout or C.REASSEMBLY_TIMEOUT
    local dropped = {}
    for key, set in pairs(assembler.pending) do
        if now - set.started > timeout then
            dropped[#dropped + 1] = key
            assembler.pending[key] = nil
        end
    end
    return dropped
end

--------------------------------------------------------------------------------
-- ROSTER payload (spec 001 section 5)
--
--   name=class~name=class~...   in hierarchy order
--------------------------------------------------------------------------------

function Serialize.encodeRoster(order, chars)
    local elements = {}
    for i = 1, #order do
        local name = order[i]
        local entry = chars[name]
        local element, err = Serialize.encodeElement({ name, entry and entry.class or "" })
        if not element then return nil, err end
        elements[#elements + 1] = element
    end
    return Serialize.encodeList(elements)
end

--- The ROSTER message body (spec 012 section 10): campaignId^name=class~...
-- The plain list above stays the export format of spec 001 section 8, which
-- carries no campaign.
function Serialize.encodeRosterMsg(campaignId, order, chars)
    local body, err = Serialize.encodeRoster(order, chars)
    if not body then return nil, err end
    return Serialize.encodeFields({ campaignId, body })
end

--- @return { campaignId, order, chars }, or nil plus a reason
function Serialize.decodeRosterMsg(body)
    local fields = Serialize.decodeFields(body)
    local campaignId = fields[1]
    if not campaignId or campaignId == "" then return nil, "ROSTER has no campaign id" end
    local order, chars = Serialize.decodeRoster(fields[2] or "")
    if not order then return nil, chars end
    return { campaignId = campaignId, order = order, chars = chars }
end

--- Decode a ROSTER body.
-- @return order array, chars map, or nil plus a reason
function Serialize.decodeRoster(body)
    local order, chars = {}, {}
    local seen = {}
    for _, element in ipairs(Serialize.decodeList(body)) do
        local fields = Serialize.decodeElement(element)
        local name, class = fields[1], fields[2]
        if not name or name == "" then return nil, "empty character name" end
        local key = name:lower()
        if seen[key] then return nil, "duplicate character: " .. name end
        seen[key] = true
        order[#order + 1] = name
        chars[name] = { class = (class ~= "" and class or nil) }
    end
    return order, chars
end

--------------------------------------------------------------------------------
-- Round payloads (spec 000 section 5, spec 002)
--
-- One encoder and one decoder per op. Nothing outside this file builds or parses
-- a round wire string. Decoders return nil plus a reason on anything malformed:
-- a half-read round is worse than no round.
--------------------------------------------------------------------------------

local function flag(value)
    return value and "1" or "0"
end

local function isFlag(field)
    return field == "1"
end

local function number(field, default)
    local n = tonumber(field)
    if n == nil then return default end
    return n
end

--- Encode a list of elements, each an array of sub-fields.
-- @return body, or nil plus the offending value
local function encodeElements(rows)
    local elements = {}
    for i = 1, #rows do
        local element, err = Serialize.encodeElement(rows[i])
        if not element then return nil, err end
        elements[i] = element
    end
    return Serialize.encodeList(elements)
end

--------------------------------------------------------------------------------
-- OPEN: roundId^tierCount^secondsLeft^idx=itemString=count~...
--
-- The third field is the round's REMAINING SECONDS, not the host's absolute
-- `endsAt`. The client clock the host reads is time since that client started, so
-- an absolute deadline is meaningless on any other machine; each client adds the
-- remainder to its own clock. Resyncing mid-round (spec 002 section 10) sends what is left, so a late
-- arrival lands on the same wall-clock deadline as everyone else.
--------------------------------------------------------------------------------

--- @param lootMode optional; a trailing field (spec 010 section 8), so a round carries
--        its own mode and a late joiner who never saw CFG still knows it. Omitted when
--        nil, and a body without it decodes as ROLL.
function Serialize.encodeOpen(campaignId, roundId, tierCount, secondsLeft, items, lootMode)
    local rows = {}
    for i = 1, #items do
        local item = items[i]
        rows[i] = { item.idx, item.itemString, item.count or 1 }
    end
    local body, err = encodeElements(rows)
    if not body then return nil, err end
    local fields = { campaignId, roundId, tierCount, secondsLeft, body }
    if lootMode then fields[6] = lootMode end
    return Serialize.encodeFields(fields)
end

function Serialize.decodeOpen(body)
    local fields = Serialize.decodeFields(body)
    local campaignId = fields[1]
    if not campaignId or campaignId == "" then return nil, "OPEN has no campaign id" end
    local roundId = fields[2]
    if not roundId or roundId == "" then return nil, "OPEN has no round id" end

    local tierCount = tonumber(fields[3])
    local secondsLeft = tonumber(fields[4])
    if not tierCount or not secondsLeft then return nil, "OPEN has a non-numeric field" end

    local items = {}
    for _, element in ipairs(Serialize.decodeList(fields[5])) do
        local sub = Serialize.decodeElement(element)
        local idx, itemString = tonumber(sub[1]), sub[2]
        if not idx then return nil, "OPEN has a non-numeric item index" end
        if not itemString or itemString == "" then
            return nil, "OPEN item " .. idx .. " has no item string"
        end
        items[#items + 1] = { idx = idx, itemString = itemString,
                              count = number(sub[3], 1) }
    end
    if #items == 0 then return nil, "OPEN carries no items" end

    local lootMode = fields[6]
    if lootMode ~= C.LOOT_MODE.SK then lootMode = C.LOOT_MODE.ROLL end

    return { campaignId = campaignId, roundId = roundId, tierCount = tierCount,
             secondsLeft = secondsLeft, items = items, lootMode = lootMode }
end

--------------------------------------------------------------------------------
-- SUBMIT: roundId^itemIdx=charName=override=star~...
--
-- Always the sender's COMPLETE entry set for the round (spec 002 section 5), so
-- an empty entry list is a valid message meaning "I withdraw everything".
--------------------------------------------------------------------------------

function Serialize.encodeSubmit(roundId, entries)
    local rows = {}
    for i = 1, #entries do
        local e = entries[i]
        rows[i] = { e.itemIdx, e.char, flag(e.override), flag(e.star) }
    end
    local body, err = encodeElements(rows)
    if not body then return nil, err end
    return Serialize.encodeFields({ roundId, body })
end

function Serialize.decodeSubmit(body)
    local fields = Serialize.decodeFields(body)
    local roundId = fields[1]
    if not roundId or roundId == "" then return nil, "SUBMIT has no round id" end

    local entries = {}
    for _, element in ipairs(Serialize.decodeList(fields[2])) do
        local sub = Serialize.decodeElement(element)
        local itemIdx, char = tonumber(sub[1]), sub[2]
        if not itemIdx then return nil, "SUBMIT has a non-numeric item index" end
        if not char or char == "" then return nil, "SUBMIT entry has no character" end
        entries[#entries + 1] = { itemIdx = itemIdx, char = char,
                                  override = isFlag(sub[3]), star = isFlag(sub[4]) }
    end
    return { roundId = roundId, entries = entries }
end

--------------------------------------------------------------------------------
-- STATE: roundId^name~name...^itemIdx=charName=owner=tier~...
--
-- The authoritative aggregate and the only source for the live open view.
--------------------------------------------------------------------------------

function Serialize.encodeState(roundId, submitted, entries)
    local names = {}
    for i = 1, #submitted do
        local element, err = Serialize.encodeElement({ submitted[i] })
        if not element then return nil, err end
        names[i] = element
    end

    local rows = {}
    for i = 1, #entries do
        local e = entries[i]
        rows[i] = { e.itemIdx, e.char, e.owner, e.tier }
    end
    local body, err = encodeElements(rows)
    if not body then return nil, err end

    return Serialize.encodeFields({ roundId, Serialize.encodeList(names), body })
end

function Serialize.decodeState(body)
    local fields = Serialize.decodeFields(body)
    local roundId = fields[1]
    if not roundId or roundId == "" then return nil, "STATE has no round id" end

    local submitted = {}
    for _, name in ipairs(Serialize.decodeList(fields[2])) do
        if name ~= "" then submitted[#submitted + 1] = name end
    end

    local entries = {}
    for _, element in ipairs(Serialize.decodeList(fields[3])) do
        local sub = Serialize.decodeElement(element)
        local itemIdx, char, owner, tier = tonumber(sub[1]), sub[2], sub[3], tonumber(sub[4])
        if not itemIdx then return nil, "STATE has a non-numeric item index" end
        if not char or char == "" then return nil, "STATE entry has no character" end
        if not tier then return nil, "STATE entry for " .. char .. " has no tier" end
        entries[#entries + 1] = { itemIdx = itemIdx, char = char,
                                  owner = (owner ~= "" and owner or nil), tier = tier }
    end

    return { roundId = roundId, submitted = submitted, entries = entries }
end

--------------------------------------------------------------------------------
-- RESULT: roundId^itemIdx=winner=tier=roll=outcome~...
--
-- One element per awarded copy. An item nobody entered gets one element with an
-- empty winner and the UNCLAIMED outcome, so a client can tell "nobody wanted it"
-- apart from "the message about that item never arrived".
--------------------------------------------------------------------------------

function Serialize.encodeResult(roundId, results)
    local rows = {}
    for i = 1, #results do
        local r = results[i]
        rows[i] = { r.itemIdx, r.winner or "", r.tier or 0, r.roll or 0, r.outcome }
    end
    local body, err = encodeElements(rows)
    if not body then return nil, err end
    return Serialize.encodeFields({ roundId, body })
end

function Serialize.decodeResult(body)
    local fields = Serialize.decodeFields(body)
    local roundId = fields[1]
    if not roundId or roundId == "" then return nil, "RESULT has no round id" end

    local results = {}
    for _, element in ipairs(Serialize.decodeList(fields[2])) do
        local sub = Serialize.decodeElement(element)
        local itemIdx = tonumber(sub[1])
        if not itemIdx then return nil, "RESULT has a non-numeric item index" end
        local outcome = sub[5]
        if not outcome or outcome == "" then
            return nil, "RESULT for item " .. itemIdx .. " has no outcome"
        end
        results[#results + 1] = {
            itemIdx = itemIdx,
            winner  = (sub[2] ~= "" and sub[2] or nil),
            tier    = number(sub[3], 0),
            roll    = number(sub[4], 0),
            outcome = outcome,
        }
    end

    return { roundId = roundId, results = results }
end

--------------------------------------------------------------------------------
-- ROLLS: roundId^itemIdx=charName=tier=roll=listIdx=status=rerolls~...
--
-- The full record behind the results table. `roll` is 0 under SK and `listIdx`
-- is 0 under ROLL (spec 010 section 8). `status` is empty for an entry that rolled
-- (or was looked up under SK), NC for one never consulted and WD for one withdrawn
-- by SK's one-win rule; `rerolls` is the entry's tie re-rolls joined with "+". Both
-- are what let the results table show an entry as not-consulted rather than as a
-- loss, and a re-roll as "83 -> 47" (spec 005 section 5). A row without them
-- decodes as rolled with no re-rolls.
--------------------------------------------------------------------------------

function Serialize.encodeRolls(roundId, rolls)
    local rows = {}
    for i = 1, #rolls do
        local r = rolls[i]
        local rerolls = {}
        for j, value in ipairs(r.rerolled or {}) do rerolls[j] = tostring(value) end
        rows[i] = { r.itemIdx, r.char, r.tier or 0, r.roll or 0, r.listIdx or 0,
                    r.status or C.ROLL_STATUS.ROLLED,
                    table.concat(rerolls, C.REROLL_JOIN) }
    end
    local body, err = encodeElements(rows)
    if not body then return nil, err end
    return Serialize.encodeFields({ roundId, body })
end

function Serialize.decodeRolls(body)
    local fields = Serialize.decodeFields(body)
    local roundId = fields[1]
    if not roundId or roundId == "" then return nil, "ROLLS has no round id" end

    local rolls = {}
    for _, element in ipairs(Serialize.decodeList(fields[2])) do
        local sub = Serialize.decodeElement(element)
        local itemIdx, char = tonumber(sub[1]), sub[2]
        if not itemIdx then return nil, "ROLLS has a non-numeric item index" end
        if not char or char == "" then return nil, "ROLLS entry has no character" end
        local rerolled = {}
        for _, value in ipairs(Util.split(sub[7] or "", C.REROLL_JOIN)) do
            local n = tonumber(value)
            if n then rerolled[#rerolled + 1] = n end
        end
        rolls[#rolls + 1] = { itemIdx = itemIdx, char = char,
                              tier = number(sub[3], 0), roll = number(sub[4], 0),
                              listIdx = number(sub[5], 0),
                              status = sub[6] or C.ROLL_STATUS.ROLLED,
                              rerolled = rerolled }
    end

    return { roundId = roundId, rolls = rolls }
end

--------------------------------------------------------------------------------
-- SKLIST: version^seed^name~name~...   (spec 010 section 8)
--
-- The authoritative priority list. Sent after OPEN under SK, after RESULT once the
-- suicides are applied, and on SYNC. A client whose copy differs replaces it whole.
--------------------------------------------------------------------------------

local function encodeNames(order)
    local names = {}
    for i = 1, #order do
        local element, err = Serialize.encodeElement({ order[i] })
        if not element then return nil, err end
        names[i] = element
    end
    return Serialize.encodeList(names)
end

function Serialize.encodeSklist(campaignId, version, seed, order)
    local names, err = encodeNames(order)
    if not names then return nil, err end
    return Serialize.encodeFields({ campaignId, version, seed, names })
end

function Serialize.decodeSklist(body)
    local fields = Serialize.decodeFields(body)
    local campaignId = fields[1]
    if not campaignId or campaignId == "" then return nil, "SKLIST has no campaign id" end
    local version, seed = tonumber(fields[2]), tonumber(fields[3])
    if not version or not seed then return nil, "SKLIST has a non-numeric field" end
    local order, seen = {}, {}
    for _, name in ipairs(Serialize.decodeList(fields[4])) do
        if name ~= "" then
            local key = name:lower()
            if seen[key] then return nil, "SKLIST lists " .. name .. " twice" end
            seen[key] = true
            order[#order + 1] = name
        end
    end
    return { campaignId = campaignId, version = version, seed = seed, order = order }
end

--------------------------------------------------------------------------------
-- HI: addonVersion^campaignId^label      CINV: campaignId^label
--
-- HI carries the label as well as the id so the host panel can say "Dave is in
-- 'Alt Run'" rather than showing an opaque timestamp (spec 012 section 10).
--------------------------------------------------------------------------------

function Serialize.encodeHi(addonVersion, campaignId, label)
    return Serialize.encodeFields({ addonVersion, campaignId, label })
end

function Serialize.decodeHi(body)
    local fields = Serialize.decodeFields(body)
    local version = fields[1]
    if not version or version == "" then return nil, "HI has no version" end
    return { version = version,
             campaignId = (fields[2] ~= "" and fields[2] or nil),
             label = (fields[3] ~= "" and fields[3] or nil) }
end

function Serialize.encodeCinv(campaignId, label)
    return Serialize.encodeFields({ campaignId, label })
end

function Serialize.decodeCinv(body)
    local fields = Serialize.decodeFields(body)
    if not fields[1] or fields[1] == "" then return nil, "CINV has no campaign id" end
    if not fields[2] or fields[2] == "" then return nil, "CINV has no label" end
    return { campaignId = fields[1], label = fields[2] }
end

--------------------------------------------------------------------------------
-- The campaign export payload (spec 012 section 12)
--
--   id^label^createdAt^createdBy^tierCount=timer=quality=lootMode
--     ^version^seed^seedChars~...^order~...^event~event~...
--
-- One event is kind=char=from=to=seed=version=at=by=present+...=chars+...
-- It carries no hierarchy: that is personal and per client.
--------------------------------------------------------------------------------

local EVENT_JOIN = "+"

local function encodeEvent(e)
    local present, chars = {}, {}
    for i, v in ipairs(e.present or {}) do present[i] = tostring(v) end
    for i, v in ipairs(e.chars or {}) do chars[i] = tostring(v) end
    return Serialize.encodeElement({ e.kind, e.char or "", e.from or "", e.to or "",
        e.seed or "", e.version or "", e.at or "", e.by or "",
        table.concat(present, EVENT_JOIN), table.concat(chars, EVENT_JOIN) })
end

local function decodeEvent(element)
    local sub = Serialize.decodeElement(element)
    local kind = sub[1]
    if not kind or kind == "" then return nil end
    local present, chars = {}, {}
    for _, v in ipairs(Util.split(sub[9] or "", EVENT_JOIN)) do
        local n = tonumber(v)
        if n then present[#present + 1] = n end
    end
    for _, v in ipairs(Util.split(sub[10] or "", EVENT_JOIN)) do
        if v ~= "" then chars[#chars + 1] = v end
    end
    local event = { kind = kind }
    if sub[2] ~= "" then event.char = sub[2] end
    event.from = tonumber(sub[3])
    event.to = tonumber(sub[4])
    event.seed = tonumber(sub[5])
    event.version = tonumber(sub[6])
    event.at = tonumber(sub[7])
    if sub[8] ~= "" then event.by = sub[8] end
    if #present > 0 then event.present = present end
    if #chars > 0 then event.chars = chars end
    return event
end

function Serialize.encodeCampaign(campaign)
    local host = campaign.host or {}
    local priority = campaign.priority or {}

    local hostElement, err = Serialize.encodeElement({ host.tierCount or 3,
        host.timerSeconds or 180, host.qualityThreshold or 4,
        host.lootMode or C.LOOT_MODE.ROLL })
    if not hostElement then return nil, err end

    local seedChars, err2 = encodeNames(priority.seedChars or {})
    if not seedChars then return nil, err2 end
    local order, err3 = encodeNames(priority.order or {})
    if not order then return nil, err3 end

    local events = {}
    for i, e in ipairs(priority.log or {}) do
        local element, err4 = encodeEvent(e)
        if not element then return nil, err4 end
        events[i] = element
    end

    return Serialize.encodeFields({ campaign.id, campaign.label,
        campaign.createdAt or 0, campaign.createdBy or "", hostElement,
        priority.version or 0, priority.seed or 0, seedChars, order,
        Serialize.encodeList(events) })
end

--- @return a campaign record without a hierarchy, or nil plus a reason
function Serialize.decodeCampaign(body)
    local fields = Serialize.decodeFields(body)
    local id, label = fields[1], fields[2]
    if not id or id == "" then return nil, "the campaign string has no id" end
    if not label or label == "" then return nil, "the campaign string has no label" end

    local host = Serialize.decodeElement(fields[5] or "")
    local version, seed = tonumber(fields[6]), tonumber(fields[7])
    if not version or not seed then
        return nil, "the campaign string has a non-numeric priority field"
    end

    local log = {}
    for _, element in ipairs(Serialize.decodeList(fields[10])) do
        local event = decodeEvent(element)
        if not event then return nil, "the campaign string has an unreadable log event" end
        log[#log + 1] = event
    end

    local lootMode = host[4]
    if lootMode ~= C.LOOT_MODE.SK then lootMode = C.LOOT_MODE.ROLL end

    return {
        id = id,
        label = label,
        createdAt = number(fields[3], 0),
        createdBy = (fields[4] ~= "" and fields[4] or nil),
        host = {
            tierCount        = number(host[1], 3),
            timerSeconds     = number(host[2], 180),
            qualityThreshold = number(host[3], 4),
            lootMode         = lootMode,
        },
        priority = {
            version   = version,
            seed      = seed,
            seedChars = Serialize.decodeList(fields[8]),
            order     = Serialize.decodeList(fields[9]),
            log       = log,
        },
    }
end

--------------------------------------------------------------------------------
-- ABORT: roundId^reasonCode        CFG: tierCount^timerSeconds^lootMode
--------------------------------------------------------------------------------

function Serialize.encodeAbort(roundId, reason)
    return Serialize.encodeFields({ roundId, reason })
end

function Serialize.decodeAbort(body)
    local fields = Serialize.decodeFields(body)
    if not fields[1] or fields[1] == "" then return nil, "ABORT has no round id" end
    if not fields[2] or fields[2] == "" then return nil, "ABORT has no reason code" end
    return { roundId = fields[1], reason = fields[2] }
end

function Serialize.encodeConfig(campaignId, tierCount, timerSeconds, lootMode)
    return Serialize.encodeFields({ campaignId, tierCount, timerSeconds, lootMode })
end

function Serialize.decodeConfig(body)
    local fields = Serialize.decodeFields(body)
    local campaignId = fields[1]
    if not campaignId or campaignId == "" then return nil, "CFG has no campaign id" end
    local tierCount, timerSeconds = tonumber(fields[2]), tonumber(fields[3])
    if not tierCount or not timerSeconds then
        return nil, "CFG has a non-numeric field"
    end
    local lootMode = fields[4]
    if not lootMode or lootMode == "" then return nil, "CFG has no loot mode" end
    return { campaignId = campaignId, tierCount = tierCount,
             timerSeconds = timerSeconds, lootMode = lootMode }
end
