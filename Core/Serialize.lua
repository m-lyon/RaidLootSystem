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
