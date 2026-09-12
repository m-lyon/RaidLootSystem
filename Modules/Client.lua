-- Modules/Client.lua
--
-- The client side of a round (spec 002): a read-only mirror of the host's state,
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

Client.round = nil
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
    for _, fn in ipairs(listeners) do fn(Client.round) end
end

--- Drop and log an op from someone who does not hold master looter. There is no
-- scenario in which a second client should be driving a round (section 3).
local function authoritative(op, sender)
    if ns.Round.IsAuthoritative(sender) then return true end
    ns.Debug(string.format("dropped %s from %s, who is not the master looter",
        op, tostring(sender)))
    return false
end

function Client.IsOpen()
    return Client.round ~= nil and Client.round.state == C.ROUND_STATE.OPEN
end

--- The tier count in force: the open round's frozen count, else the last CFG the host
-- sent, else nil so callers fall back to their own default.
-- A CFG names the campaign it configures, so it stands in only for that one: a CFG
-- for a second campaign you belong to must not reband a list it says nothing about.
-- @param campaignId the campaign being drawn, active by default
function Client.TierCount(campaignId)
    campaignId = campaignId or ns.Campaign.ActiveId()
    if Client.IsOpen() and Client.round.campaignId == campaignId then
        return Client.round.tierCount
    end
    if Client.config and Client.config.campaignId == campaignId then
        return Client.config.tierCount
    end
    return nil
end

--- The tier count to draw with, plus whether it is real rather than a guess.
--
-- Real means an open round's frozen count or a CFG this session actually saw
-- from the host. Everything else -- a joined campaign's own stored `host`
-- settings, or the schema default -- is a local guess, because a member's copy
-- of `host.tierCount` is never synced to the host's value (only the ephemeral
-- CFG mirror is). Every screen that draws tiers outside a round resolves it
-- here, so they cannot disagree about what is synced.
-- @return count, synced
function Client.TierCountInForce(campaignId)
    local count = Client.TierCount(campaignId)
    if count then return count, true end
    -- The named campaign's own stored setting, not the active one's: the hierarchy
    -- editor draws a campaign that may not be active, and banding it by another
    -- campaign's count is simply wrong.
    local campaign = ns.Campaign.Get(campaignId or ns.Campaign.ActiveId())
    local stored = campaign and ns.Campaign.Normalise(campaign).host.tierCount
    return stored or ns.Database.DefaultTierCount(), false
end

--- The loot mode the round runs under, as far as this client knows. Spec 010's SKLIST
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
        ns.Print("the host opened a round this client could not read ("
            .. tostring(why) .. "). Ask them to re-open it.")
        return
    end

    -- OPEN is one of the two ops a non-member still acts on (spec 012 section 10).
    -- A client not in the campaign opens the roll window READ-ONLY with a banner,
    -- rather than doing nothing: "the addon did nothing and I do not know why" is
    -- the worst available outcome for a loot tool, and the read-only window is how a
    -- mistaken Ignore is noticed within one boss rather than at the end of the night.
    local member = ns.Campaign.IsMemberOf(msg.campaignId)
    if member then
        -- OPEN additionally sets the active campaign, for members (section 10).
        ns.Campaign.Switch(msg.campaignId)
    else
        ns.Debug("OPEN names campaign " .. tostring(msg.campaignId)
            .. ", which you are not in; the window is read-only")
    end

    local previous = Client.round
    if previous and previous.id ~= msg.roundId
        and previous.state == C.ROUND_STATE.OPEN then
        -- Two live rounds are never run; the host's newest wins (section 3).
        ns.Debug("a second OPEN replaced round " .. tostring(previous.id))
    end

    if previous and previous.id == msg.roundId then
        -- A resend for SYNC: keep what we have, refresh the deadline and items.
        -- The host only answers SYNC while it still has this round OPEN (Round.lua
        -- onSync), so receiving this is proof the round is not really over even if we
        -- had locally given up on it (e.g. HOST_LEFT on a lost RESULT).
        previous.state = C.ROUND_STATE.OPEN
        previous.abortReason = nil
        previous.endsAt = GetTime() + msg.secondsLeft
        previous.tierCount = msg.tierCount
        previous.items = msg.items
        previous.lootMode = msg.lootMode
        previous.readOnly = not member
        fireChanged()
        return
    end

    Client.round = {
        id = msg.roundId,
        host = sender,
        tierCount = msg.tierCount,
        endsAt = GetTime() + msg.secondsLeft,
        items = msg.items,
        entries = {},          -- itemIdx -> array, from STATE only
        submitted = {},
        state = C.ROUND_STATE.OPEN,
        lootMode = msg.lootMode,           -- the round carries its mode (spec 010 section 8)
        openedAt = time(),
        campaignId = msg.campaignId,
        campaignLabel = ns.Campaign.LabelFor(msg.campaignId),
        readOnly = not member,
    }
    expectedCount, lastSent, warnedForSubmission = nil, {}, false
    fireChanged()
end

--------------------------------------------------------------------------------
-- STATE (section 7)
--------------------------------------------------------------------------------

local function ownEntryCount(round, me)
    if not me then return 0 end
    local count = 0
    for _, list in pairs(round.entries) do
        for _, e in ipairs(list) do
            if e.owner and e.owner:lower() == me:lower() then count = count + 1 end
        end
    end
    return count
end

--- Which of the entries we sent are missing from the host's STATE, named.
local function missingEntries(round, sent, me)
    local missing = {}
    local key = me and me:lower() or ""
    for _, e in ipairs(sent) do
        local found = false
        for _, accepted in ipairs(round.entries[e.itemIdx] or {}) do
            if accepted.owner and accepted.owner:lower() == key
                and accepted.char:lower() == e.char:lower() then
                found = true
                break
            end
        end
        if not found then
            local item
            for _, candidate in ipairs(round.items) do
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

    local round = Client.round
    if not round or round.id ~= msg.roundId then
        -- State for a round we never saw open. Ask for the whole thing.
        Client.RequestSync()
        return
    end

    round.submitted = {}
    for _, name in ipairs(msg.submitted) do round.submitted[name] = true end

    round.entries = {}
    for _, e in ipairs(msg.entries) do
        local list = round.entries[e.itemIdx]
        if not list then
            list = {}
            round.entries[e.itemIdx] = list
        end
        list[#list + 1] = { char = e.char, owner = e.owner, tier = e.tier }
    end

    -- Section 5: an entry the host dropped must not be discovered after the roll.
    -- The refused entries are named (spec 005 section 4); the host does not say why,
    -- so the likely causes are listed instead. The window shows the list until the
    -- next submit replaces it.
    if expectedCount and not warnedForSubmission then
        local myName = UnitName("player")
        local mine = ownEntryCount(round, myName)
        if mine < expectedCount then
            warnedForSubmission = true
            local missing = missingEntries(round, lastSent, myName)
            round.lastRejected = missing
            ns.Print(string.format(
                "the host accepted %d of your %d entries. Refused: %s - "
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

    local round = Client.round
    if not round or round.id ~= msg.roundId then return end

    round.results = msg.results
    round.state = C.ROUND_STATE.CLOSED
    round.closedAt = time()
    -- The suicides are not replayed here. They arrive as logged events on the SKLIST
    -- the host sends next, so a client's list and its history move together rather
    -- than the list moving now and the history never (spec 010 section 8).
    if round.rolls and ns.History then ns.History.RecordClient(round) end
    fireChanged()
end

local function onRolls(sender, body)
    if not authoritative(C.OPS.ROLLS, sender) then return end

    local msg, why = Serialize.decodeRolls(body)
    if not msg then
        ns.Debug("unreadable ROLLS: " .. tostring(why))
        return
    end

    local round = Client.round
    if not round or round.id ~= msg.roundId then return end

    round.rolls = msg.rolls
    -- The record is written once both RESULT and ROLLS are here (spec 008 section 2),
    -- whichever arrives second.
    if round.state == C.ROUND_STATE.CLOSED and ns.History then
        ns.History.RecordClient(round)
    end
    fireChanged()
end

--------------------------------------------------------------------------------
-- ABORT (section 9) and CFG
--------------------------------------------------------------------------------

--- End the mirror. `announce` is false when the player already knows why.
local function abortLocally(reason)
    local round = Client.round
    if not round or round.state ~= C.ROUND_STATE.OPEN then return end
    round.state = C.ROUND_STATE.ABORTED
    round.abortReason = reason
    round.closedAt = time()
    ns.Print("the round was cancelled: " .. (C.ABORT_TEXT[reason] or reason) .. ".")
    if ns.History then ns.History.RecordClient(round) end
    fireChanged()
end

local function onAbort(sender, body)
    if not authoritative(C.OPS.ABORT, sender) then return end

    local msg, why = Serialize.decodeAbort(body)
    if not msg then
        ns.Debug("unreadable ABORT: " .. tostring(why))
        return
    end

    local round = Client.round
    if not round or round.id ~= msg.roundId then return end
    abortLocally(msg.reason)
end

local function onConfig(sender, body)
    if not authoritative(C.OPS.CFG, sender) then return end

    local msg, why = Serialize.decodeConfig(body)
    if not msg then
        ns.Debug("unreadable CFG: " .. tostring(why))
        return
    end
    -- Settings from a campaign you are not in are not your settings (section 10).
    if not ns.Campaign.AcceptsMessage(C.OPS.CFG, msg.campaignId, sender) then return end
    Client.config = msg

    -- The campaign owns how the group plays it, so these land on the campaign record
    -- and not only in a display field (spec 012 section 9). Without this the loot mode
    -- stops at whoever happens to be master looter: the next one to hold it opens a
    -- round under their own stale default, and a seeded Suicide Kings campaign
    -- silently resolves by roll.
    -- Never from yourself: the host already holds these, and under /rls simulate the
    -- looped-back CFG carries the simulation's settings, not the campaign's.
    local campaign = not ns.Comms.IsSelf(sender) and ns.Campaign.Get(msg.campaignId)
    if campaign then
        local host = ns.Campaign.Normalise(campaign).host
        host.tierCount = msg.tierCount or host.tierCount
        host.timerSeconds = msg.timerSeconds or host.timerSeconds
        host.lootMode = msg.lootMode or host.lootMode
        -- Always assigned, never `or`-defaulted: false is a real value here and the
        -- idiom cannot carry one, so an unlock would never reach anybody.
        if msg.lockHierarchy ~= nil then host.lockHierarchy = msg.lockHierarchy end
        -- One-way: a campaign that has run a round never un-runs it, and a host who
        -- joined late and has not seen one must not clear it for the group.
        if msg.started then host.started = true end
    end
    fireChanged()
end

--------------------------------------------------------------------------------
-- Submitting (section 5)
--------------------------------------------------------------------------------

--- Send this player's COMPLETE entry set. Submissions replace, never append, so
-- revising is just another call and a dropped message heals on the next one.
-- @param entries array of { itemIdx, char, override, star }
function Client.Submit(entries)
    local round = Client.round
    if not round or round.state ~= C.ROUND_STATE.OPEN then
        return false, "there is no round open."
    end
    if round.readOnly then
        -- A non-member submits nothing (spec 012 section 6). The host would refuse
        -- every entry anyway, having no roster of ours for this campaign.
        return false, string.format("you are not in the campaign \"%s\". Ask the master looter "
            .. "to invite you.", round.campaignLabel or "?")
    end

    local body, err = Serialize.encodeSubmit(round.id, entries)
    if not body then
        return false, "your entries could not be encoded (" .. tostring(err) .. ")."
    end

    local ok, why = ns.Comms.Send(C.OPS.SUBMIT, body)
    if not ok then return false, why end

    expectedCount = #entries
    lastSent = entries
    warnedForSubmission = false
    round.lastRejected = nil
    return true
end

--------------------------------------------------------------------------------
-- Resync (section 10)
--------------------------------------------------------------------------------

--- The entries of this client's last SUBMIT for the open round, for the roll window's
-- dirty check. nil before the first submit of a round.
function Client.LastSent()
    if expectedCount == nil then return nil end
    return lastSent
end

--- Ask the host to resend the round. At most once every C.SYNC_INTERVAL seconds.
-- @param campaignId the campaign to ask about, active by default
function Client.RequestSync(campaignId)
    local now = GetTime()
    if now - lastSync < C.SYNC_INTERVAL then return false end
    lastSync = now
    local id = Client.round and Client.round.id or ""
    -- The campaign and the list version ride along so the host can answer a history
    -- that has fallen behind without being asked twice (spec 010 section 8).
    campaignId = campaignId or ns.Campaign.ActiveId()
    return ns.Comms.Send(C.OPS.SYNC, Serialize.encodeSync(id, campaignId,
        ns.Priority and ns.Priority.HistoryVersion(campaignId) or 0))
end

--------------------------------------------------------------------------------
-- The pump: a host that vanished without saying so
--------------------------------------------------------------------------------

local function onUpdate()
    local round = Client.round
    if not round or round.state ~= C.ROUND_STATE.OPEN then return end
    if GetTime() > round.endsAt + C.HOST_LEFT_GRACE then
        -- The timer ran out a minute ago and no result arrived. Say so rather than
        -- leaving a dead window open (section 9).
        abortLocally(C.ABORT_REASON.HOST_LEFT)
    end
end

--- Re-derive the host. Public so /rls simulate can change hands without an event.
function Client.CheckHost()
    local host = ns.Round.HostName()
    if host ~= lastHost then
        lastHost = host
        -- Every client sees this event, so each ends its own mirror. The old host
        -- can no longer send an ABORT anyone would accept (section 3).
        abortLocally(C.ABORT_REASON.ML_CHANGED)
    end
end

local function onGroupEvent(_, event)
    Client.CheckHost()
    if event == "PLAYER_ENTERING_WORLD" and ns.Comms.Channel() then
        -- A /reload mid-round: the host is the only one who knows what is open.
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

    lastHost = ns.Round.HostName()
    Client.RequestSync()
end
