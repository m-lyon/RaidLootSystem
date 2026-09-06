-- Modules/Client.lua
--
-- The client side of a batch (spec 002): a read-only mirror of the host's state,
-- plus this player's submissions.
--
-- The mirror is built from host `STATE` messages and nothing else (section 7).
-- A client never renders its own submission optimistically and never trusts
-- another client, so what the player sees is what the host will resolve.
--
-- The host mirrors its own broadcasts here too -- addon messages echo back to the
-- sender -- so the roll window has one code path rather than two.

local ADDON, ns = ...

ns.Client = {}
local Client = ns.Client

local C = ns.Constants
local Serialize = ns.Serialize

Client.session = nil
Client.config = nil          -- last CFG seen from the host

local listeners = {}
local frame
local lastSync = 0
local lastHost
local expectedCount          -- entries in our last SUBMIT, for the section 5 check
local lastSent = {}          -- the entries themselves, so a refused one can be named
local warnedForSubmission

function Client.RegisterListener(fn)
    listeners[#listeners + 1] = fn
end

local function fireChanged()
    for _, fn in ipairs(listeners) do fn(Client.session) end
end

--- Drop and log an op from someone who does not hold master looter. There is no
-- scenario in which a second client should be driving a batch (section 3).
local function authoritative(op, sender)
    if ns.Session.IsAuthoritative(sender) then return true end
    ns.Debug(string.format("dropped %s from %s, who is not the master looter",
        op, tostring(sender)))
    return false
end

function Client.IsOpen()
    return Client.session ~= nil and Client.session.state == C.SESSION_STATE.OPEN
end

--- The tier count in force: the open batch's frozen count, else the last CFG the host
-- sent, else nil so callers fall back to their own default.
function Client.TierCount()
    if Client.IsOpen() then return Client.session.tierCount end
    return Client.config and Client.config.tierCount or nil
end

--- The loot mode the batch runs under, as far as this client knows. Spec 010's SKLIST
-- is the definitive signal; until it exists the last CFG stands in.
function Client.LootMode()
    return Client.config and Client.config.lootMode or C.LOOT_MODE.ROLL
end

--------------------------------------------------------------------------------
-- OPEN (section 4)
--------------------------------------------------------------------------------

local function onOpen(sender, body)
    if not authoritative(C.OPS.OPEN, sender) then return end

    local msg, why = Serialize.decodeOpen(body)
    if not msg then
        ns.Print("the host opened a batch this client could not read ("
            .. tostring(why) .. "). Ask them to re-open it.")
        return
    end

    local previous = Client.session
    if previous and previous.id ~= msg.sessionId
        and previous.state == C.SESSION_STATE.OPEN then
        -- Two live batches are never run; the host's newest wins (section 3).
        ns.Debug("a second OPEN replaced batch " .. tostring(previous.id))
    end

    if previous and previous.id == msg.sessionId then
        -- A resend for SYNC: keep what we have, refresh the deadline and items.
        -- The host only answers SYNC while it still has this session OPEN (Session.lua
        -- onSync), so receiving this is proof the batch is not really over even if we
        -- had locally given up on it (e.g. HOST_LEFT on a lost RESULT).
        previous.state = C.SESSION_STATE.OPEN
        previous.abortReason = nil
        previous.endsAt = GetTime() + msg.secondsLeft
        previous.tierCount = msg.tierCount
        previous.items = msg.items
        fireChanged()
        return
    end

    Client.session = {
        id = msg.sessionId,
        host = sender,
        tierCount = msg.tierCount,
        endsAt = GetTime() + msg.secondsLeft,
        items = msg.items,
        entries = {},          -- itemIdx -> array, from STATE only
        submitted = {},
        state = C.SESSION_STATE.OPEN,
        lootMode = Client.LootMode(),
        openedAt = time(),
    }
    expectedCount, lastSent, warnedForSubmission = nil, {}, false
    fireChanged()
end

--------------------------------------------------------------------------------
-- STATE (section 7)
--------------------------------------------------------------------------------

local function ownEntryCount(session, me)
    if not me then return 0 end
    local count = 0
    for _, list in pairs(session.entries) do
        for _, e in ipairs(list) do
            if e.owner and e.owner:lower() == me:lower() then count = count + 1 end
        end
    end
    return count
end

--- Which of the entries we sent are missing from the host's STATE, named.
local function missingEntries(session, sent, me)
    local missing = {}
    local key = me and me:lower() or ""
    for _, e in ipairs(sent) do
        local found = false
        for _, accepted in ipairs(session.entries[e.itemIdx] or {}) do
            if accepted.owner and accepted.owner:lower() == key
                and accepted.char:lower() == e.char:lower() then
                found = true
                break
            end
        end
        if not found then
            local item
            for _, candidate in ipairs(session.items) do
                if candidate.idx == e.itemIdx then item = candidate end
            end
            local label = item and ns.ItemInfo.Get(item.itemString).name or nil
            missing[#missing + 1] = e.char .. " on " .. (label or ("item " .. e.itemIdx))
        end
    end
    return missing
end

local function onState(sender, body)
    if not authoritative(C.OPS.STATE, sender) then return end

    local msg, why = Serialize.decodeState(body)
    if not msg then
        ns.Debug("unreadable STATE: " .. tostring(why))
        return
    end

    local session = Client.session
    if not session or session.id ~= msg.sessionId then
        -- State for a batch we never saw open. Ask for the whole thing.
        Client.RequestSync()
        return
    end

    session.submitted = {}
    for _, name in ipairs(msg.submitted) do session.submitted[name] = true end

    session.entries = {}
    for _, e in ipairs(msg.entries) do
        local list = session.entries[e.itemIdx]
        if not list then
            list = {}
            session.entries[e.itemIdx] = list
        end
        list[#list + 1] = { char = e.char, owner = e.owner, tier = e.tier }
    end

    -- Section 5: an entry the host dropped must not be discovered after the roll.
    -- The refused entries are named (spec 005 section 4); the host does not say why,
    -- so the likely causes are listed instead. The window shows the list until the
    -- next submit replaces it.
    if expectedCount and not warnedForSubmission then
        local myName = UnitName("player")
        local mine = ownEntryCount(session, myName)
        if mine < expectedCount then
            warnedForSubmission = true
            local missing = missingEntries(session, lastSent, myName)
            session.lastRejected = missing
            ns.Print(string.format(
                "the host accepted %d of your %d entries. Refused: %s -- "
                .. "check that those characters are yours, present, not contested "
                .. "and can use the item.",
                mine, expectedCount, table.concat(missing, ", ")))
        end
    end

    fireChanged()
end

--------------------------------------------------------------------------------
-- RESULT and ROLLS (section 8)
--------------------------------------------------------------------------------

local function onResult(sender, body)
    if not authoritative(C.OPS.RESULT, sender) then return end

    local msg, why = Serialize.decodeResult(body)
    if not msg then
        ns.Print("the results could not be read (" .. tostring(why)
            .. "). Ask the host what was awarded.")
        return
    end

    local session = Client.session
    if not session or session.id ~= msg.sessionId then return end

    session.results = msg.results
    session.state = C.SESSION_STATE.CLOSED
    session.closedAt = time()
    if session.rolls and ns.History then ns.History.RecordClient(session) end
    fireChanged()
end

local function onRolls(sender, body)
    if not authoritative(C.OPS.ROLLS, sender) then return end

    local msg, why = Serialize.decodeRolls(body)
    if not msg then
        ns.Debug("unreadable ROLLS: " .. tostring(why))
        return
    end

    local session = Client.session
    if not session or session.id ~= msg.sessionId then return end

    session.rolls = msg.rolls
    -- The record is written once both RESULT and ROLLS are here (spec 008 section 2),
    -- whichever arrives second.
    if session.state == C.SESSION_STATE.CLOSED and ns.History then
        ns.History.RecordClient(session)
    end
    fireChanged()
end

--------------------------------------------------------------------------------
-- ABORT (section 9) and CFG
--------------------------------------------------------------------------------

--- End the mirror. `announce` is false when the player already knows why.
local function abortLocally(reason)
    local session = Client.session
    if not session or session.state ~= C.SESSION_STATE.OPEN then return end
    session.state = C.SESSION_STATE.ABORTED
    session.abortReason = reason
    session.closedAt = time()
    ns.Print("the batch was cancelled: " .. (C.ABORT_TEXT[reason] or reason) .. ".")
    if ns.History then ns.History.RecordClient(session) end
    fireChanged()
end

local function onAbort(sender, body)
    if not authoritative(C.OPS.ABORT, sender) then return end

    local msg, why = Serialize.decodeAbort(body)
    if not msg then
        ns.Debug("unreadable ABORT: " .. tostring(why))
        return
    end

    local session = Client.session
    if not session or session.id ~= msg.sessionId then return end
    abortLocally(msg.reason)
end

local function onConfig(sender, body)
    if not authoritative(C.OPS.CFG, sender) then return end

    local msg, why = Serialize.decodeConfig(body)
    if not msg then
        ns.Debug("unreadable CFG: " .. tostring(why))
        return
    end
    Client.config = msg
    fireChanged()
end

--------------------------------------------------------------------------------
-- Submitting (section 5)
--------------------------------------------------------------------------------

--- Send this player's COMPLETE entry set. Submissions replace, never append, so
-- revising is just another call and a dropped message heals on the next one.
-- @param entries array of { itemIdx, char, override, star }
function Client.Submit(entries)
    local session = Client.session
    if not session or session.state ~= C.SESSION_STATE.OPEN then
        return false, "there is no batch open."
    end

    local body, err = Serialize.encodeSubmit(session.id, entries)
    if not body then
        return false, "your entries could not be encoded (" .. tostring(err) .. ")."
    end

    local ok, why = ns.Comms.Send(C.OPS.SUBMIT, body)
    if not ok then return false, why end

    expectedCount = #entries
    lastSent = entries
    warnedForSubmission = false
    session.lastRejected = nil
    return true
end

--------------------------------------------------------------------------------
-- Resync (section 10)
--------------------------------------------------------------------------------

--- The entries of this client's last SUBMIT for the open batch, for the roll window's
-- dirty check. nil before the first submit of a batch.
function Client.LastSent()
    if expectedCount == nil then return nil end
    return lastSent
end

--- Ask the host to resend the batch. At most once every C.SYNC_INTERVAL seconds.
function Client.RequestSync()
    local now = GetTime()
    if now - lastSync < C.SYNC_INTERVAL then return false end
    lastSync = now
    local id = Client.session and Client.session.id or ""
    return ns.Comms.Send(C.OPS.SYNC, Serialize.encodeFields({ id }))
end

--------------------------------------------------------------------------------
-- The pump: a host that vanished without saying so
--------------------------------------------------------------------------------

local function onUpdate()
    local session = Client.session
    if not session or session.state ~= C.SESSION_STATE.OPEN then return end
    if GetTime() > session.endsAt + C.HOST_LEFT_GRACE then
        -- The timer ran out a minute ago and no result arrived. Say so rather than
        -- leaving a dead window open (section 9).
        abortLocally(C.ABORT_REASON.HOST_LEFT)
    end
end

local function onGroupEvent(_, event)
    local host = ns.Session.HostName()
    if host ~= lastHost then
        lastHost = host
        -- Every client sees this event, so each ends its own mirror. The old host
        -- can no longer send an ABORT anyone would accept (section 3).
        abortLocally(C.ABORT_REASON.ML_CHANGED)
    end
    if event == "PLAYER_ENTERING_WORLD" and ns.Comms.Channel() then
        -- A /reload mid-batch: the host is the only one who knows what is open.
        Client.RequestSync()
    end
end

function Client.Init()
    if frame then return end

    ns.Comms.RegisterHandler(C.OPS.OPEN, onOpen)
    ns.Comms.RegisterHandler(C.OPS.STATE, onState)
    ns.Comms.RegisterHandler(C.OPS.RESULT, onResult)
    ns.Comms.RegisterHandler(C.OPS.ROLLS, onRolls)
    ns.Comms.RegisterHandler(C.OPS.ABORT, onAbort)
    ns.Comms.RegisterHandler(C.OPS.CFG, onConfig)

    frame = CreateFrame("Frame", "RaidLootSystemClientFrame")
    frame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
    frame:RegisterEvent("RAID_ROSTER_UPDATE")
    frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:SetScript("OnEvent", onGroupEvent)
    frame:SetScript("OnUpdate", onUpdate)

    lastHost = ns.Session.HostName()
    Client.RequestSync()
end
