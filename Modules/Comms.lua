-- Modules/Comms.lua
--
-- The addon-message transport (spec 000 section 5): queueing, chunking, rate
-- limiting, reassembly and version-skew reporting.
--
-- No other file calls SendAddonMessage. RegisterAddonMessagePrefix does not
-- exist in 3.3.5a, so incoming messages are filtered by prefix in the handler.

local ADDON, ns = ...

ns.Comms = {}
local Comms = ns.Comms

local C = ns.Constants
local Serialize = ns.Serialize

local handlers = {}          -- op -> function(sender, body, channel)
local queue = {}             -- outgoing wire strings, drained at C.SEND_RATE
local assembler = Serialize.newAssembler()
local warnedSenders = {}     -- protocol-skew warning, once per sender per session
local nextMsgId = 0
local sendAccumulator = 0
local pruneAccumulator = 0
local frame

--------------------------------------------------------------------------------
-- Channel
--------------------------------------------------------------------------------

--- RAID, falling back to PARTY, then nil when solo.
function Comms.Channel()
    if GetNumRaidMembers() > 0 then return "RAID" end
    if GetNumPartyMembers() > 0 then return "PARTY" end
    return nil
end

--- Replaced by Modules/Simulate.lua with a loopback (spec 009 section 4).
-- Production sends the real thing.
function Comms.transport(prefix, message, channel, target)
    SendAddonMessage(prefix, message, channel, target)
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

local function newMsgId()
    nextMsgId = nextMsgId + 1
    if nextMsgId > 999 then nextMsgId = 1 end
    return tostring(nextMsgId)
end

--- Queue one message. It is chunked here and drained at C.SEND_RATE per second.
-- @return true when queued (plus the chunk count queued for it), false plus a
--         reason when there is nowhere to send it
function Comms.Send(op, body)
    local channel = Comms.Channel()
    if not channel then return false, "not in a group" end

    local chunks = Serialize.pack(op, body, newMsgId())
    for _, wire in ipairs(chunks) do
        queue[#queue + 1] = { wire = wire, channel = channel }
    end
    return true, #chunks
end

--- Queue a message whose body is built when it reaches the head of the queue.
-- OPEN carries seconds remaining, so encoding it at call time and then waiting
-- behind a long CSTATE would hand clients a deadline later than the host's.
-- @param build  function returning the body, or nil to send nothing
function Comms.SendDeferred(op, build)
    local channel = Comms.Channel()
    if not channel then return false, "not in a group" end
    queue[#queue + 1] = { op = op, build = build, channel = channel }
    return true
end

--- Send to one player. Used for targeted replies; bots are never comms peers.
function Comms.SendWhisper(op, body, target)
    for _, wire in ipairs(Serialize.pack(op, body, newMsgId())) do
        queue[#queue + 1] = { wire = wire, channel = "WHISPER", target = target }
    end
    return true
end

function Comms.QueueLength()
    return #queue
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

--- Register the handler for one op. One handler per op; the last wins.
function Comms.RegisterHandler(op, fn)
    handlers[op] = fn
end

function Comms.IsSelf(sender)
    local me = UnitName("player")
    return me ~= nil and sender ~= nil and me:lower() == sender:lower()
end

--- Exposed for Simulate.lua, which feeds messages in without the event.
function Comms.Receive(prefix, message, channel, sender)
    if prefix ~= C.PREFIX then return end

    local msg, why = Serialize.unpack(message)
    if not msg then
        ns.Debug("dropped a malformed message from " .. tostring(sender) .. ": " .. tostring(why))
        return
    end

    if msg.proto ~= C.PROTO then
        if not warnedSenders[sender] then
            warnedSenders[sender] = true
            ns.Print(string.format(
                "%s is running a different protocol version (%s, this client speaks %d). "
                .. "One of you needs to update; their messages are being ignored.",
                tostring(sender), tostring(msg.proto), C.PROTO))
        end
        return
    end

    local body = Serialize.assemble(assembler, sender, msg, GetTime())
    if body == nil then return end        -- more chunks to come

    local handler = handlers[msg.op]
    if not handler then
        ns.Debug("no handler for op " .. msg.op)
        return
    end
    handler(sender, body, channel)
end

--------------------------------------------------------------------------------
-- Init and pump
--------------------------------------------------------------------------------

local function onUpdate(_, elapsed)
    -- Drain the queue at a fixed rate. The server throttles addon messages
    -- silently, so going faster loses messages without telling anyone.
    sendAccumulator = sendAccumulator + elapsed
    local interval = 1 / C.SEND_RATE
    while sendAccumulator >= interval and #queue > 0 do
        sendAccumulator = sendAccumulator - interval
        local item = table.remove(queue, 1)
        while item and item.build do
            local body = item.build()
            if body then
                local chunks = Serialize.pack(item.op, body, newMsgId())
                for i = #chunks, 1, -1 do
                    table.insert(queue, 1, { wire = chunks[i], channel = item.channel })
                end
            end
            item = table.remove(queue, 1)
        end
        if not item then break end
        Comms.transport(C.PREFIX, item.wire, item.channel, item.target)
    end
    if #queue == 0 then sendAccumulator = 0 end

    pruneAccumulator = pruneAccumulator + elapsed
    if pruneAccumulator >= 1 then
        pruneAccumulator = 0
        local dropped = Serialize.pruneAssembler(assembler, GetTime(), C.REASSEMBLY_TIMEOUT)
        for _, key in ipairs(dropped) do
            -- A dropped set means someone's data never arrived. Say so.
            ns.Print("an incomplete message from " .. key:match("^(.-)/") ..
                     " timed out and was discarded.")
        end
    end
end

function Comms.Init()
    if frame then return end
    frame = CreateFrame("Frame", "RaidLootSystemCommsFrame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
        Comms.Receive(prefix, message, channel, sender)
    end)
    frame:SetScript("OnUpdate", onUpdate)
end

--- Test and simulation seam: forget queued traffic and partial message sets.
function Comms.Reset()
    queue = {}
    assembler = Serialize.newAssembler()
    warnedSenders = {}
end
