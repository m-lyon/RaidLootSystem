-- Modules/PriorityList.lua
--
-- The stateful half of Suicide Kings (spec 010 sections 5, 6, 8, 9 and 10): the list
-- in saved variables, seeding, the suicides a resolved round applies, the restore a
-- failed delivery earns, the SKLIST broadcast and its client side, the event log
-- that `verify` replays, and the host panel section.
--
-- The namespace is `ns.Priority`; the pure list operations are `ns.PriorityList`
-- (Core/PriorityList.lua). Everything above the "WoW-facing" divider is pure and
-- fixture-tested by the `priority` suite.
--
-- Every mutation bumps the version, is written to the list's own event log, and on
-- the host is announced and broadcast. A silent edit to a public list would end the
-- group's trust in it (section 10).

local ADDON, ns = ...

ns.Priority = {}
local Priority = ns.Priority

local C = ns.Constants
local Util = ns.Util
local PriorityList = ns.PriorityList

--------------------------------------------------------------------------------
-- Pure: the stored list and its log (sections 8 and 9)
--------------------------------------------------------------------------------

--- Apply one mutation to a stored priority table, returning a new table. The event
-- is stamped with the version it produced and appended to the log (section 8).
-- @param priority  { version, seed, seedChars, order, log }
-- @param event     as PriorityList.apply, plus `at` and `by`
-- @return priority', or nil plus a reason when the event does not apply
function Priority.Mutate(priority, event)
    local order, why = PriorityList.apply(priority.order or {}, event)
    if why then return nil, why end
    local version = (priority.version or 0) + 1
    local logged = Util.copy(event)
    logged.version = version

    local out = {
        version = version,
        seed = priority.seed,
        seedChars = priority.seedChars,
        order = order,
        log = {},
    }
    if event.kind == "seed" then
        -- A (re)seed starts the log over: replay begins at the seed (section 8).
        out.seed = event.seed
        out.seedChars = Util.copy(event.chars or {})
        out.log[1] = logged
    else
        for i, e in ipairs(priority.log or {}) do out.log[i] = e end
        out.log[#out.log + 1] = logged
    end
    return out
end

--- Recompute the list from its seed and log and compare it to what is stored
-- (section 8, `verify`). Reports; never repairs.
-- @return { ok, replayed, drift = { { index, stored, replayed } }, problems }
function Priority.Verify(priority)
    if not priority.seed or (priority.seed or 0) == 0 then
        return { ok = false, replayed = {}, drift = {}, problems = {},
                 why = "the list has never been seeded" }
    end
    local replayed, problems = PriorityList.replay(priority.seed, priority.seedChars or {},
        priority.log or {})
    local drift = PriorityList.diff(priority.order or {}, replayed)
    return { ok = (#drift == 0 and #problems == 0), replayed = replayed, drift = drift,
             problems = problems }
end

--- Should a delivery change move the list (section 6)? A suicide is applied when the
-- award is made; it is undone only when the delivery reaches a state it cannot
-- recover from -- lost, expired, abandoned -- not on a retryable failure, which would
-- otherwise re-suicide the winner to a different bottom on the retry. A delivery
-- that later succeeds after a restore suicides again.
-- @param record  an Award record with priorIndex set (an SK award)
-- @return "restore", "suicide" or nil
function Priority.DeliveryAction(record)
    if record.priorIndex == nil then return nil end
    local D = C.DELIVERY
    local terminal = record.delivery == D.LOST
        or (record.delivery == D.FAILED and record.failure == C.AWARD_FAILURE.TRADE_EXPIRED)
    if terminal and not record.restored then return "restore" end
    if record.delivery == D.DELIVERED and record.restored then return "suicide" end
    return nil
end

--- "17" for one held position, "15-17" for several. The positions below a landing
-- index are contiguous: everything under the last present index is absent.
local function heldRange(to, count)
    if count == 1 then return tostring(to + 1) end
    return (to + 1) .. "-" .. (to + count)
end

--- "Milhouse", "Ino and Milhouse", "Ino, Milhouse and 2 more".
local function nameList(names)
    local n = #names
    if n == 0 then return "" end
    if n == 1 then return names[1] end
    if n == 2 then return names[1] .. " and " .. names[2] end
    if n == 3 then return names[1] .. ", " .. names[2] .. " and " .. names[3] end
    return names[1] .. ", " .. names[2] .. " and " .. (n - 2) .. " more"
end

--- The confirmation a manual suicide shows (section 10).
--
-- It names the destination index, not "the bottom". A host who reads "bottom" and
-- then watches the character land one row short concludes the button is broken; the
-- rule that put it there (absent characters hold their index, section 6) is only
-- visible if the dialog says so before the click.
-- @param held  the absent characters below `to`, from PriorityList.suicidePreview
function Priority.SuicideText(char, from, to, held)
    held = held or {}
    if #held == 0 then
        return string.format("Move %s from %d to %d, the bottom of the list? "
            .. "Announced and logged.", char, from, to)
    end
    return string.format("Move %s from %d to %d, below every character in the raid? "
        .. "%s %s not here and %s %s. Announced and logged.",
        char, from, to, nameList(held), #held == 1 and "is" or "are",
        #held == 1 and "holds" or "hold", heldRange(to, #held))
end

--- The chat line a manual suicide announces (section 10). Same facts as the dialog,
-- inside a chat line's budget.
function Priority.SuicideAnnounce(by, char, from, to, held)
    local line = string.format("%s moved %s to the bottom by hand (%d -> %d)", by, char, from, to)
    if #(held or {}) > 0 then
        line = line .. string.format("; %d absent character%s %s %s",
            #held, #held == 1 and "" or "s", #held == 1 and "holds" or "hold",
            heldRange(to, #held))
    end
    return line
end

--- Every uncontested claimed character, sorted, for seeding (section 5).
-- @param claims  Roster.claims: lower name -> { name, owners, contested }
function Priority.SeedCandidates(claims)
    local names = {}
    for _, claim in pairs(claims or {}) do
        if not claim.contested then names[#names + 1] = claim.name end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

--- The wire form and back (section 8): SKLIST is
-- campaignId^version^seed^name~...^event~... The campaign id is what stops a foreign
-- master looter's list replacing yours (spec 012 section 10); the events are what
-- let every member keep the host's log rather than a bare order.
-- @param events  the entries since the previous broadcast, or nil to restate
function Priority.Encode(campaignId, priority, events)
    return ns.Serialize.encodeSklist(campaignId, priority.version or 0, priority.seed or 0,
        priority.order or {}, events)
end

--- Does a received list differ from the stored one? Same version and same order is
-- the only "no"; a client never merges (section 8).
function Priority.Differs(stored, received)
    if (stored.version or 0) ~= (received.version or 0) then return true end
    return #PriorityList.diff(stored.order or {}, received.order or {}) > 0
end

--- Can the events on a SKLIST be appended to this client's log, or has it fallen too
-- far behind to chain them (section 8)?
--
-- A log is only worth holding if it is complete. Applying events over a gap would
-- produce a log that replays to the wrong order and says nothing about why, which is
-- worse than admitting the gap and asking for the whole thing.
-- @return "apply" when the events chain from the stored version to the received one,
--         "current" when there is nothing to do, "resync" otherwise
function Priority.ChainAction(stored, received)
    local from = stored.version or 0
    local to = received.version or 0
    if to < from then return "resync" end            -- a reseed, or a different list
    if to == from then
        return #PriorityList.diff(stored.order or {}, received.order or {}) > 0
            and "resync" or "current"
    end
    local events = received.events or {}
    if #events ~= to - from then return "resync" end
    for i, event in ipairs(events) do
        if (event.version or 0) ~= from + i then return "resync" end
        -- A seed restarts the log rather than extending it, so it never chains.
        if event.kind == "seed" then return "resync" end
    end
    return "apply"
end

--- Apply chained events to a stored list, returning the new priority table.
-- Every event is logged, so a client's log is the host's log (section 8).
-- @return priority', or nil plus the event that would not apply
function Priority.Chain(stored, events)
    local out = stored
    for _, event in ipairs(events or {}) do
        local next_, why = Priority.Mutate(out, event)
        if not next_ then return nil, why end
        out = next_
    end
    return out
end

--------------------------------------------------------------------------------
-- WoW-facing. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

-- Resolved in Init, not here: this module draws part of the host panel, but
-- Modules/ load ahead of UI/ in the .toc, so ns.Widgets does not exist yet at
-- file scope. Init runs at PLAYER_LOGIN, well after every file has loaded, and
-- ahead of HostPanel.Init -- the only thing that reaches RefreshSection. It
-- stays nil under the fixture runner, which never renders.
local Widgets

local listeners = {}
local rows = {}
local noticeText                    -- shown in the roll window after a replace

-- campaignId -> the logged events since that campaign's last successful broadcast.
-- A run of quiet mutations (a round's suicides) accumulates here and rides out on the
-- single SKLIST that follows, so clients append exactly what the host logged.
-- Cleared only on a send that succeeded: dropping them on a failed send would leave
-- every client with a gap and no way to know it (section 8).
local pendingEvents = {}

--- The stored list of one campaign, defaulting to the active one. Every mutation
-- below takes a campaign id so that a restore-on-failure lands in the campaign the
-- award was made in, never in whichever campaign happens to be active
-- (spec 012 section 14).
local function DB(campaignId)
    return ns.Database.Priority(campaignId)
end

function Priority.RegisterListener(fn)
    listeners[#listeners + 1] = fn
end

local function fireChanged()
    for _, fn in ipairs(listeners) do fn() end
    if ns.HostPanel then ns.HostPanel.Refresh() end
    if ns.RollWindow then ns.RollWindow.Refresh() end
end

local function store(priority, campaignId)
    local db = DB(campaignId)
    if not db then return end
    db.version, db.seed, db.seedChars, db.order, db.log =
        priority.version, priority.seed, priority.seedChars, priority.order, priority.log
end

function Priority.Seeded(campaignId)
    local priority = DB(campaignId)
    return priority ~= nil and #(priority.order or {}) > 0
end

function Priority.Version(campaignId)
    local priority = DB(campaignId)
    return priority and priority.version or 0
end

--- The version this client can actually *replay* to, which is what SYNC asks about.
--
-- Not the same as the stored version. A client that took an order it could not chain
-- holds the right list at the right version with no history behind it, so comparing
-- versions would say "in step" and no CSTATE would ever be sent. Zero means "send me
-- everything" (section 8).
function Priority.HistoryVersion(campaignId)
    local priority = DB(campaignId)
    if not priority or priority.logIncomplete then return 0 end
    if #(priority.log or {}) == 0 then return 0 end
    return priority.version or 0
end

--- The present set the list operations take: lowercase character names in the raid.
local function presentSet()
    local set = {}
    for _, member in ipairs(ns.Roster.GroupMembers()) do
        if member.name then set[member.name:lower()] = true end
    end
    return set
end

local function announce(text)
    if ns.Announce then ns.Announce.Emit("PRIORITY", { text = text }) end
end

--- Send the authoritative list (host only). Always for a named campaign, defaulting
-- to the active one, so a broadcast can never carry one campaign's list under
-- another's id.
function Priority.Broadcast(campaignId)
    if not ns.Round.IsHost() then return false end
    campaignId = campaignId or ns.Campaign.ActiveId()
    local priority = DB(campaignId)
    if not priority or #(priority.order or {}) == 0 then return false end
    local events = pendingEvents[campaignId]
    local body, err = Priority.Encode(campaignId, priority, events)
    if not body then
        -- Sending nothing would report success and throw the queued events away.
        ns.Print("the priority list could not be sent (" .. tostring(err)
            .. "); its events are still queued.")
        return false
    end
    local ok = ns.Comms.Send(C.OPS.SKLIST, body)
    if ok then pendingEvents[campaignId] = nil end
    return ok
end

--- The whole campaign, log and all: what a client needs to rebuild a history it
-- cannot chain, and what makes a master-looter handover lossless (section 8).
function Priority.BroadcastState(campaignId)
    if not ns.Round.IsHost() then return false end
    campaignId = campaignId or ns.Campaign.ActiveId()
    local campaign = ns.Campaign.Get(campaignId)
    if not campaign then return false end
    -- Never answer a SYNC with a worse copy than the asker already has: an empty
    -- list, or a log this host itself could not chain, would replace everyone's.
    local priority = ns.Campaign.Normalise(campaign).priority
    if #(priority.order or {}) == 0 then
        ns.Debug("not sending CSTATE: this client holds no list for " .. tostring(campaignId))
        return false
    end
    if priority.logIncomplete then
        ns.Print("a member asked for this campaign's history, but your own copy of it is "
            .. "incomplete, so it was not sent.")
        return false
    end
    local body, err = ns.Serialize.encodeCampaign(campaign)
    if not body then
        ns.Print("the campaign could not be sent: " .. tostring(err))
        return false
    end
    local ok, chunks = ns.Comms.Send(C.OPS.CSTATE, body)
    -- The CSTATE carries the whole log up to the current version, so anything still
    -- queued from before it is already included -- left in place, it re-attaches to
    -- the next SKLIST and makes that message's event count outrun its version delta,
    -- which Priority.ChainAction reads as a gap and resyncs a client that was fine.
    if ok then pendingEvents[campaignId] = nil end
    return ok, chunks
end

--- Apply one mutation on the host: store, log, announce, broadcast.
-- @param quiet  skip the broadcast; the caller sends one list once it is done
-- @param campaignId  whose list this mutates; the active campaign by default
local function hostMutate(event, text, quiet, campaignId)
    campaignId = campaignId or ns.Campaign.ActiveId()
    local priority = DB(campaignId)
    if not priority then
        ns.Print("the priority list was not changed: that campaign is gone.")
        return false, "no such campaign"
    end
    event.at = time()
    event.by = UnitName("player")
    local next_, why = Priority.Mutate(priority, event)
    if not next_ then
        ns.Print("the priority list was not changed: " .. tostring(why))
        return false, why
    end
    store(next_, campaignId)

    -- The event as logged, version stamp and all, queued for the next broadcast.
    local logged = next_.log[#next_.log]
    if event.kind == "seed" then
        -- A seed restarts the log, so no client can chain onto it; the full state
        -- goes out instead and the queue starts over with it. The new log begins at
        -- the seed and is complete by construction, so a stale incomplete flag is
        -- cleared here -- otherwise BroadcastState refuses the one message the seed
        -- path exists to send.
        pendingEvents[campaignId] = nil
        priority.logIncomplete = nil
    elseif logged then
        local queued = pendingEvents[campaignId] or {}
        queued[#queued + 1] = logged
        pendingEvents[campaignId] = queued
    end

    if text then announce(text) end
    -- A seed sends nothing here. Nothing can chain onto it, so clients need the whole
    -- campaign -- and Priority.Seed sets the loot mode immediately after, so sending
    -- now would ship a state that is already stale. Seed broadcasts it once, after.
    if event.kind ~= "seed" and not quiet then Priority.Broadcast(campaignId) end
    fireChanged()
    return true
end

--------------------------------------------------------------------------------
-- Seeding (section 5) and manual edits (section 10). All confirmed by the panel.
--------------------------------------------------------------------------------

--- Seeding turns the loot mode on as well as unlocking it (section 5).
--
-- A seeded list with the mode left on ROLL is the one half-configured state this
-- feature can reach, and it is silent: rounds resolve by roll, nobody suicides, and
-- the host finds out a raid later. Seeding is an explicit, confirmed, announced act
-- with exactly one purpose, so it finishes the job.
--
-- ROLL is still one dropdown click away for guests or a list in a bad state.
local function enableSK()
    local ok, why = ns.Round.ChangeSetting("lootMode", C.LOOT_MODE.SK)
    if not ok then
        -- Never swallowed: the host would otherwise open the next round by roll
        -- believing it was Suicide Kings.
        ns.Print("the list is seeded, but the loot mode is still Roll: " .. tostring(why)
            .. " Set it from the host panel once you can.")
    end
    return ok
end

--- @param reseed  true to replace an existing list; refused otherwise
function Priority.Seed(reseed)
    if Priority.Seeded() and not reseed then
        return false, "the list is already seeded. Reseed to start over."
    end
    local chars = Priority.SeedCandidates(ns.Roster.claims)
    if #chars == 0 then return false, "nobody has published a roster yet." end
    local seed = time()
    local ok = hostMutate({ kind = "seed", seed = seed, chars = chars },
        string.format("%s with %d characters (seed %d, version %d)",
            reseed and "reseeded" or "seeded", #chars, seed, Priority.Version() + 1))
    -- After the mutation, never before: ChangeSetting refuses SK without a list.
    -- Then one CSTATE, carrying the new seed, the new log and the mode it just set,
    -- so no client is left holding a list it cannot replay (section 8).
    if ok then
        enableSK()
        Priority.BroadcastState()
    end
    return ok
end

function Priority.Move(from, to)
    local order = DB().order
    if from == to or not order[from] or not order[to] then return false, "position out of range." end
    return hostMutate({ kind = "move", from = from, to = to, char = order[from] },
        string.format("%s moved %s from %d to %d", UnitName("player"), order[from], from, to))
end

function Priority.ManualSuicide(char)
    local order = DB().order
    local from = PriorityList.indexOf(order, char)
    if not from then return false, char .. " is not on the list." end
    -- One present set for both, so the move that is applied and the move that is
    -- announced cannot come from two different reads of the raid.
    local present = presentSet()
    local _, _, presentIdx = PriorityList.suicide(order, char, present)
    local to, _, held = PriorityList.suicidePreview(order, char, present)
    return hostMutate({ kind = "suicide", char = order[from], from = from, present = presentIdx },
        Priority.SuicideAnnounce(UnitName("player"), order[from], from, to, held))
end

--- The panel's confirmation for one row, resolved against the raid as it stands.
function Priority.SuicidePrompt(char)
    local order = DB().order
    local to, from, held = PriorityList.suicidePreview(order, char, presentSet())
    if not to then return char .. " is not on the list." end
    return Priority.SuicideText(char, from, to, held)
end

function Priority.ManualRestore(char, index)
    local order = DB().order
    local at = PriorityList.indexOf(order, char)
    if not at then return false, char .. " is not on the list." end
    index = Util.clamp(math.floor(tonumber(index) or 1), 1, #order)
    local _, present, why = PriorityList.restoreNow(order, char, index, presentSet())
    if not present then return false, why .. "." end
    return hostMutate({ kind = "restore", char = order[at], to = index, present = present },
        string.format("%s restored %s to position %d by hand (from %d)", UnitName("player"),
            order[at], index, at))
end

--- A character nobody claims any more (section 4, removeChar). Manual, from the
-- panel: an automatic removal on a transient claim loss would send someone to the
-- bottom for reloading their UI.
function Priority.Remove(char)
    if not PriorityList.indexOf(DB().order, char) then return false, char .. " is not on the list." end
    return hostMutate({ kind = "remove", char = char },
        string.format("%s removed %s from the list", UnitName("player"), char))
end

--- Newly claimed, uncontested characters join at the bottom. Host only; nothing is
-- ever removed here.
function Priority.SyncRoster()
    if not ns.Round.IsHost() or not Priority.Seeded() then return end
    local order = DB().order
    local added = false
    for _, name in ipairs(Priority.SeedCandidates(ns.Roster.claims)) do
        if not PriorityList.indexOf(order, name) then
            hostMutate({ kind = "add", char = name }, name .. " joined the list at the bottom", true)
            order = DB().order
            added = true
        end
    end
    if added then Priority.Broadcast() end
end

--------------------------------------------------------------------------------
-- Suicides at close, restores on failure (sections 6 and 7)
--------------------------------------------------------------------------------

--- Called by Round.Close after Award.Begin, host side, under SK. One suicide per
-- winning character in (item index, copy) order; each award record learns the
-- prior index, the present indices and the version, so a failed delivery can be
-- undone exactly and `verify` can replay it.
function Priority.ApplyAwards(round)
    if round.lootMode ~= C.LOOT_MODE.SK or not round.awards then return end
    local campaignId = round.campaignId
    local present = presentSet()
    local done = {}
    for _, item in ipairs(round.items) do
        for _, record in ipairs(round.awards[item.idx] or {}) do
            local key = record.char:lower()
            record.campaignId = campaignId
            if not done[key] then
                done[key] = true
                local from = PriorityList.indexOf(DB(campaignId).order, record.char)
                if from then
                    local _, _, presentIdx = PriorityList.suicide(DB(campaignId).order,
                        record.char, present)
                    record.priorIndex = from
                    record.presentIndices = presentIdx
                    hostMutate({ kind = "suicide", char = record.char, from = from, present = presentIdx },
                        nil, true, campaignId)
                    record.listVersion = Priority.Version(campaignId)
                else
                    ns.Print(record.char .. " won under Suicide Kings but is not on the list; "
                        .. "nothing moved. Seed or add them.")
                end
            else
                -- A second copy to the same character (unreachable under rule 1, but a
                -- record must still say where it stood).
                record.priorIndex = PriorityList.indexOf(DB(campaignId).order, record.char)
            end
        end
    end
    Priority.Broadcast(campaignId)
end

--- Restore a character to its prior index (section 6). The recorded present indices
-- give the exact inverse; when the list has moved since and they no longer fit, the
-- restore is made against the raid as it stands, and says so.
-- @param entry  { char, priorIndex, presentIndices } -- an award or a pending record
-- @return true when the list changed
local function restoreEntry(entry, why)
    -- Into the campaign the award was made in, never the active one: the two-hour
    -- trade window routinely outlives a campaign switch, and restoring into an
    -- unrelated list is a corruption invisible by inspection (spec 012 section 14).
    local campaignId = entry.campaignId
    local priority = DB(campaignId)
    if not priority then
        ns.Print(string.format("%s won in a campaign this client no longer has; its list "
            .. "cannot be restored.", tostring(entry.char)))
        return false
    end
    local order = priority.order
    local at = PriorityList.indexOf(order, entry.char)
    if not at then
        ns.Print(entry.char .. " is not on the priority list; nothing to restore.")
        return false
    end
    if at == entry.priorIndex then return true end     -- nothing moved it; nothing to undo

    local ok = hostMutate({ kind = "restore", char = entry.char, to = entry.priorIndex,
                            present = entry.presentIndices or { entry.priorIndex } },
        string.format("%s restored to position %d (%s)", entry.char, entry.priorIndex, why),
        false, campaignId)
    if ok then return true end

    -- The list moved since the suicide. Restore against today's raid rather than leave
    -- the character suicided for an item it never received.
    local _, present, reason = PriorityList.restoreNow(order, entry.char, entry.priorIndex, presentSet())
    if not present then
        ns.Print(string.format("%s could not be restored to %d: %s. Fix the list by hand "
            .. "from the host panel.", entry.char, entry.priorIndex, tostring(reason)))
        return false
    end
    ns.Print(string.format("the list moved since %s won; restoring against the current raid.",
        entry.char))
    return (hostMutate({ kind = "restore", char = entry.char, to = entry.priorIndex, present = present },
        string.format("%s restored to position %d (%s)", entry.char, entry.priorIndex, why),
        false, campaignId))
end

--- A character restored earlier was delivered to after all: it drops again, from
-- wherever it now stands -- in the campaign the award was made in.
local function suicideEntry(entry)
    local campaignId = entry.campaignId
    local priority = DB(campaignId)
    if not priority then return false end
    local from = PriorityList.indexOf(priority.order, entry.char)
    if not from then return false end
    local _, _, present = PriorityList.suicide(priority.order, entry.char, presentSet())
    local ok = hostMutate({ kind = "suicide", char = entry.char, from = from, present = present },
        string.format("%s moved to the bottom after all (delivered)", entry.char),
        false, campaignId)
    if ok then
        entry.priorIndex = from
        entry.presentIndices = present
    end
    return ok
end

local function needsHost(entry)
    if ns.Round.IsHost() then return true end
    ns.Print("the priority list needs a change for " .. entry.char
        .. ", but only the master looter can make it. Ask them to restore by hand.")
    return false
end

--- Award tells us a delivery changed (spec 007). Section 6: a delivery that will
-- never happen returns the character to its prior index.
function Priority.OnDeliveryChanged(record)
    local action = Priority.DeliveryAction(record)
    if not action then return end
    if not needsHost(record) then return end
    if action == "restore" then
        if restoreEntry(record, "the delivery failed") then record.restored = true end
    else
        if suicideEntry(record) then record.restored = nil end
    end
    if ns.History then ns.History.UpdateDeliveryFromAward(record) end
end

--- Pending tells us a record changed state after a reload took the award records
-- with it (spec 007 section 5). The pending record carries what a restore needs.
-- @param state  "failed" or "delivered"
function Priority.OnPendingChanged(record, state)
    if record.priorIndex == nil then return end
    if state == "failed" and not record.restored then
        if not needsHost(record) then return end
        if restoreEntry(record, "the delivery failed") then record.restored = true end
    elseif state == "delivered" and record.restored then
        if not needsHost(record) then return end
        if suicideEntry(record) then record.restored = nil end
    end
end

--------------------------------------------------------------------------------
-- The client side (section 8)
--------------------------------------------------------------------------------

--- Too far behind to chain: take the order as authoritative so the current round
-- resolves against the right list, mark the log as not ours, and ask the host for the
-- whole campaign. A half-written log is worse than an absent one -- it replays to the
-- wrong answer and gives no reason (section 8).
local function requestState(msg, stored, round)
    noticeText = string.format("Priority list for \"%s\" replaced by the host's copy "
        .. "(version %d -> %d). Fetching its history.",
        ns.Campaign.LabelFor(msg.campaignId), stored.version or 0, msg.version)
    stored.version, stored.seed, stored.order = msg.version, msg.seed, msg.order
    stored.log = {}
    stored.seedChars = {}
    stored.logIncomplete = true       -- until a CSTATE arrives; verify says so
    ns.Print(noticeText)
    if round then round.priorityNotice = noticeText end
    -- Ask about the campaign that needs the repair, not whichever one is active:
    -- the host would otherwise compare the wrong list's version, find it in step
    -- and send nothing, leaving this one flagged incomplete for good.
    -- RequestSync refuses inside C.SYNC_INTERVAL, and nothing else asks again from here:
    -- later SKLISTs chain cleanly off the version just taken wholesale. So a throttled
    -- request is said out loud rather than leaving the log flagged incomplete in silence.
    if ns.Client and ns.Client.RequestSync then
        if not ns.Client.RequestSync(msg.campaignId) then
            ns.Print("the request for its history was throttled; ask again with /rls sync "
                .. "in a few seconds.")
        end
    end
end

--- SKLIST from the host: chain the events when in step, replace and resync when not.
--
-- The campaign gate here is the bug this whole feature exists to fix. Before it, a
-- master looter you were guesting with replaced your own group's list and cleared
-- its event log, and nothing said so (spec 012 section 10).
local function onSklist(sender, body)
    if not ns.Round.IsAuthoritative(sender) then
        ns.Debug("dropped SKLIST from " .. tostring(sender) .. ", who is not the master looter")
        return
    end
    local msg, why = ns.Serialize.decodeSklist(body)
    if not msg then
        ns.Debug("unreadable SKLIST: " .. tostring(why))
        return
    end
    if not ns.Campaign.AcceptsMessage(C.OPS.SKLIST, msg.campaignId, sender) then return end

    -- The positions matter to a round only under SK (spec 005 section 3); a list
    -- edit during a ROLL round must not make the window render it as Suicide Kings.
    local round = ns.Client.round
    if round and round.lootMode == C.LOOT_MODE.SK and round.campaignId == msg.campaignId then
        round.priority = PriorityList.positions(msg.order)
    end

    if not ns.Comms.IsSelf(sender) then
        local stored = DB(msg.campaignId)
        if stored then
            local action = Priority.ChainAction(stored, msg)
            if action == "current" then
                noticeText = nil
            elseif action == "apply" then
                -- In step: append what the host logged, so this client's history is
                -- the host's history and can be replayed or handed on (section 8).
                local next_, why = Priority.Chain(stored, msg.events)
                if next_ and #PriorityList.diff(next_.order or {}, msg.order or {}) > 0 then
                    -- The host is authoritative and clients never merge: a chain that
                    -- lands somewhere other than the order in the same message means
                    -- this log is not the host's, so take the copy and resync.
                    ns.Debug("chained SKLIST events disagree with the host's order; resyncing")
                    requestState(msg, stored, round)
                elseif next_ then
                    store(next_, msg.campaignId)
                    noticeText = nil
                else
                    ns.Debug("SKLIST events did not apply (" .. tostring(why) .. "); resyncing")
                    requestState(msg, stored, round)
                end
            else
                requestState(msg, stored, round)
            end
        end
    end
    fireChanged()
end

--- CSTATE from the host: the whole campaign, log and all (section 8).
--
-- This is what makes a master-looter handover lossless. A client that holds the seed,
-- the seed characters, the order and every event since can become host and still
-- replay its own list; before this existed, the log stopped at the handover and
-- `verify` reported drift on a list that was perfectly correct.
local function onCstate(sender, body)
    if not ns.Round.IsAuthoritative(sender) then
        ns.Debug("dropped CSTATE from " .. tostring(sender) .. ", who is not the master looter")
        return
    end
    if ns.Comms.IsSelf(sender) then return end
    local incoming, why = ns.Serialize.decodeCampaign(body)
    if not incoming then
        ns.Print("the campaign state could not be read (" .. tostring(why)
            .. "). Your priority list history may be incomplete.")
        return
    end
    if not ns.Campaign.AcceptsMessage(C.OPS.CSTATE, incoming.id, sender) then return end

    local campaign = ns.Campaign.Get(incoming.id)
    if not campaign then return end
    ns.Campaign.Normalise(campaign)

    -- The campaign is the source of truth for how the group plays it, so the shared
    -- host settings come with it (spec 012 section 9). The hierarchy is on the campaign
    -- too, but it is per member -- it orders this member's own characters -- so the
    -- host holds no copy of it to send and this leaves it alone.
    campaign.host.tierCount = incoming.host.tierCount
    campaign.host.timerSeconds = incoming.host.timerSeconds
    campaign.host.qualityThreshold = incoming.host.qualityThreshold
    campaign.host.lootMode = incoming.host.lootMode
    if incoming.host.lockHierarchy ~= nil then
        campaign.host.lockHierarchy = incoming.host.lockHierarchy
    end
    -- One-way, as on CFG: a campaign that has begun stays begun (spec 014).
    if incoming.host.started then campaign.host.started = true end

    local priority = campaign.priority
    -- An older version of the same list is not an answer to anything: a host who
    -- joined late and holds less than we do must not roll us backwards. A different
    -- seed is a reseed, which legitimately restarts the numbering.
    if (incoming.priority.version or 0) < (priority.version or 0)
        and (incoming.priority.seed or 0) == (priority.seed or 0) then
        ns.Debug(string.format("ignored a CSTATE at version %d, behind the stored %d",
            incoming.priority.version or 0, priority.version or 0))
        -- A client that took a newer list wholesale while this one was draining asked
        -- once, and the host coalesced that ask into this stale answer. Nothing else
        -- will ask again, so say so rather than leave the log incomplete in silence.
        if priority.logIncomplete then
            ns.Print(string.format("the history for \"%s\" arrived behind the list you "
                .. "hold and was ignored; ask again with /rls sync in a few seconds.",
                campaign.label or incoming.id))
        end
        return
    end
    priority.version = incoming.priority.version
    priority.seed = incoming.priority.seed
    priority.seedChars = incoming.priority.seedChars
    priority.order = incoming.priority.order
    priority.log = incoming.priority.log
    -- The flag is cleared only by a log that actually replays to the order it came
    -- with; a truncated one leaves it set, so `verify` and the next SYNC still say so.
    local verified = Priority.Verify(priority)
    priority.logIncomplete = verified.ok and nil or true

    ns.Print(string.format("received the history for \"%s\": version %d, %d characters, "
        .. "%d logged events.", campaign.label or incoming.id, priority.version,
        #priority.order, #priority.log))
    if priority.logIncomplete then
        ns.Print("that history does not replay to the list it came with, so it is still "
            .. "marked incomplete. Ask the master looter to resend it.")
    end
    noticeText = nil
    fireChanged()
    if ns.Campaign.FireChanged then ns.Campaign.FireChanged() end
end

--- `/rls sk verify`: replay and report (section 8). Anyone may run it. Every member
-- holds the host's log now, and "here is the seed, run it yourself" is only a fact if
-- running it yourself is something a non-host can do (section 5).
function Priority.RunVerify()
    local priority = DB()
    if not priority then
        ns.Print("verify: there is no campaign to verify. Create or join one first.")
        return nil
    end
    if priority.logIncomplete then
        ns.Print("verify: this client took a list it could not chain and is still waiting for "
            .. "its history from the master looter. Try again in a moment.")
        return nil
    end
    local result = Priority.Verify(DB())
    if result.why then
        ns.Print("verify: " .. result.why)
        return result
    end
    if result.ok then
        ns.Print(string.format("verify: the stored list (version %d, %d characters) matches its "
            .. "replay from seed %d.", DB().version or 0, #(DB().order or {}), DB().seed or 0))
    else
        ns.Print(string.format("verify: the stored list DIFFERS from its replay at %d position(s).",
            #result.drift))
        for i, d in ipairs(result.drift) do
            if i <= 10 then
                ns.Print(string.format("  %d: stored %s, replayed %s", d.index,
                    tostring(d.stored), tostring(d.replayed)))
            end
        end
        for _, p in ipairs(result.problems) do
            ns.Print(string.format("  event at version %s did not apply: %s",
                tostring(p.version), p.why))
        end
        ns.Print("verify never repairs. Reseed, or fix positions by hand from the host panel.")
    end
    return result
end

function Priority.PrintList()
    local db = DB()
    if not Priority.Seeded() then
        ns.Print("the priority list is not seeded.")
        return
    end
    ns.Print(string.format("priority list, version %d, seed %d:", db.version or 0, db.seed or 0))
    for i, name in ipairs(db.order) do
        local claim = ns.Roster.claims[name:lower()]
        local owner = claim and claim.owners[1] or "?"
        local present = ns.Roster.IsPresent(name)
        ns.Print(string.format("  %2d. %s (%s)%s", i, name, owner, present and "" or "  [absent]"))
    end
end

--------------------------------------------------------------------------------
-- The host panel section (section 10)
--------------------------------------------------------------------------------

local ROW_H = 18
local BAND_H = 20

local bands = {}

local function confirm(kind, text, payload)
    StaticPopup_Show("RLS_CONFIRM_PRIORITY", text, nil, { kind = kind, payload = payload })
end

local function panelRow(panel, i)
    local row = rows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, panel.list)
    row:SetWidth(panel.list:GetWidth())
    row:SetHeight(ROW_H)

    row.position = Widgets.Label(row, "", "GameFontNormalSmall")
    row.position:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.position:SetWidth(24)
    row.position:SetJustifyH("RIGHT")

    row.name = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.position, "RIGHT", 6, 0)
    row.name:SetWidth(200)
    row.name:SetJustifyH("LEFT")

    row.remove = Widgets.IconButton(row, "remove", 16, 16, function()
        confirm("remove", "Remove " .. row.char .. " from the priority list? Announced and logged.",
            row.char)
    end)
    row.remove:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    Widgets.Tooltip(row.remove, "Remove", "For a character nobody claims any more.")

    row.down = Widgets.IconButton(row, "down", 18, 16, function()
        confirm("move", string.format("Move %s down one place, to %d? Announced and logged.",
            row.char, row.index + 1), { from = row.index, to = row.index + 1 })
    end)
    row.down:SetPoint("RIGHT", row.remove, "LEFT", -2, 0)
    Widgets.Tooltip(row.down, "Move down", "Move this character one place down the list.")

    row.up = Widgets.IconButton(row, "up", 18, 16, function()
        confirm("move", string.format("Move %s up one place, to %d? Announced and logged.",
            row.char, row.index - 1), { from = row.index, to = row.index - 1 })
    end)
    row.up:SetPoint("RIGHT", row.down, "LEFT", -2, 0)
    Widgets.Tooltip(row.up, "Move up", "Move this character one place up the list.")

    -- "Suicide", not "Bottom": absent characters hold their index (section 6), so the
    -- landing position is the last one in the raid and need not be the last row.
    row.suicide = Widgets.Button(row, "Suicide", 56, 16, function()
        confirm("suicide", Priority.SuicidePrompt(row.char), row.char)
    end)
    row.suicide:SetPoint("RIGHT", row.up, "LEFT", -2, 0)
    Widgets.Tooltip(row.suicide, "Manual suicide", "As if this character had just won. "
        .. "Characters not in the raid keep their position, so this lands at the bottom "
        .. "of the raid rather than the bottom of the list.")

    row.restore = Widgets.Button(row, "Top", 40, 16, function()
        confirm("restore", string.format("Restore %s to position 1 by hand? Announced and logged.",
            row.char), { char = row.char, index = 1 })
    end)
    row.restore:SetPoint("RIGHT", row.suicide, "LEFT", -2, 0)
    Widgets.Tooltip(row.restore, "Manual restore", "Move this character back to the top.")

    rows[i] = row
    return row
end

--- A tier heading (spec 013 section 6). The list is grouped because a tier is the
-- first gate on every item: the top of the list is not the front of the queue, the
-- top of T1 is, and a host reading a flat list to decide a manual move was reading
-- the wrong shape.
local function panelBand(panel, i)
    local band = bands[i]
    if band then return band end
    band = CreateFrame("Frame", nil, panel.list)
    band:SetWidth(panel.list:GetWidth())
    band:SetHeight(BAND_H)

    band.text = Widgets.Label(band, "", "GameFontNormalSmall")
    band.text:SetPoint("BOTTOMLEFT", band, "BOTTOMLEFT", 0, 4)

    band.line = band:CreateTexture(nil, "ARTWORK")
    band.line:SetHeight(1)
    band.line:SetPoint("BOTTOMLEFT", band, "BOTTOMLEFT", 0, 1)
    band.line:SetPoint("BOTTOMRIGHT", band, "BOTTOMRIGHT", 0, 1)

    bands[i] = band
    return band
end

--- Build (once) and refresh the section the host panel reserved (spec 006).
function Priority.RefreshSection(panel)
    if not panel.built then
        panel.built = true
        panel.note:SetText("")

        panel.seed = Widgets.Button(panel, "Seed", 70, 20, function()
            local chars = Priority.SeedCandidates(ns.Roster.claims)
            if Priority.Seeded() then
                confirm("reseed", string.format("Reseed the list from scratch over %d characters? "
                    .. "Every position is lost. The loot mode is set to Suicide Kings. "
                    .. "Announced and logged.", #chars))
            else
                confirm("seed", string.format("Seed the priority list over %d claimed characters "
                    .. "and switch the loot mode to Suicide Kings? Announced and logged.", #chars))
            end
        end)
        panel.seed:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -6)

        panel.verify = Widgets.Button(panel, "Verify", 70, 20, function() Priority.RunVerify() end)
        panel.verify:SetPoint("RIGHT", panel.seed, "LEFT", -4, 0)
        Widgets.Tooltip(panel.verify, "Verify",
            "Replay the list from its seed and event log and report any drift. Never repairs.")

        panel.list = CreateFrame("Frame", nil, panel)
        panel.list:SetPoint("TOPLEFT", panel.note, "BOTTOMLEFT", 0, -4)
        panel.list:SetWidth(panel:GetWidth() - 20)
        panel.list:SetHeight(1)

        StaticPopupDialogs["RLS_CONFIRM_PRIORITY"] = {
            text = "%s",
            button1 = "Do it",
            button2 = CANCEL,
            OnAccept = function(self)
                local d = self.data
                local ok, why
                if d.kind == "seed" then ok, why = Priority.Seed(false)
                elseif d.kind == "reseed" then ok, why = Priority.Seed(true)
                elseif d.kind == "move" then ok, why = Priority.Move(d.payload.from, d.payload.to)
                elseif d.kind == "suicide" then ok, why = Priority.ManualSuicide(d.payload)
                elseif d.kind == "restore" then ok, why = Priority.ManualRestore(d.payload.char, d.payload.index)
                elseif d.kind == "remove" then ok, why = Priority.Remove(d.payload)
                end
                if not ok and why then ns.Print(why) end
            end,
            timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        }
    end

    local db = DB() or {}
    local order = db.order or {}
    if #order == 0 then
        panel.note:SetText("Not seeded. Seed the priority list to enable Suicide Kings.")
        panel.seed:SetText("Seed")
        -- Empty tier bands over an empty list would be four headings saying nothing.
        -- The campaign's tiers are still readable, on their own screen (spec 013 §5).
        for _, row in ipairs(rows) do row:Hide() end
        for _, band in ipairs(bands) do band:Hide() end
        panel.list:SetHeight(1)
        panel:SetHeight(56)
        return
    else
        panel.note:SetText(string.format("%d characters, version %d, seed %d. "
            .. "Every edit here is confirmed, announced and logged.", #order, db.version or 0, db.seed or 0))
        panel.seed:SetText("Reseed")
    end

    local me = UnitName("player")
    local claims = ns.Roster.claims
    local tierCount = ns.Client.TierCountInForce(ns.Campaign.ActiveId())
    local tierOf = ns.Campaign.TierIndex(tierCount)

    -- Grouped by tier, and inside a band still in list order, which is the order a
    -- round awards in (spec 003 section 5). The controls are unchanged: they act on
    -- list position, and a band is a grouping of the same rows.
    local model = {}
    for i, name in ipairs(order) do
        model[i] = { position = i, char = name, tier = tierOf[name:lower()] }
    end
    local groups = ns.TierRoster.groupRows(model, tierCount)

    local y, rowIndex, bandIndex = 0, 0, 0
    for _, group in ipairs(groups) do
        bandIndex = bandIndex + 1
        local band = panelBand(panel, bandIndex)
        band.text:SetText(string.format("|cffe6b422%s|r |cff888888(%d)|r",
            group.label, #group.rows))
        band.line:SetTexture(0.5, 0.4, 0.15, 0.7)
        band:ClearAllPoints()
        band:SetPoint("TOPLEFT", panel.list, "TOPLEFT", 0, -y)
        band:Show()
        y = y + BAND_H

        for _, entry in ipairs(group.rows) do
            local i, name = entry.position, entry.char
            rowIndex = rowIndex + 1
            local row = panelRow(panel, rowIndex)
            row.index, row.char = i, name
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", panel.list, "TOPLEFT", 0, -y)
            -- Rank inside the tier, not the global index: the controls still act on
            -- `row.index`, which is the list position every move and suicide is
            -- announced in terms of (spec 013 section 6).
            row.position:SetText(tostring(entry.tierPosition or i))
            local claim = claims[name:lower()]
            local owner = claim and claim.owners[1] or nil
            local class = ns.Roster.ClassOfAny(name)
            local label = Widgets.ColorName(name, class) .. " |cff888888(" .. tostring(owner or "unclaimed") .. ")|r"
            if owner and me and owner:lower() == me:lower() then label = label .. " |cffaaaaaa*|r" end
            if claim and claim.contested then label = label .. " |cffff4040contested|r" end
            row.name:SetText(label)
            row:SetAlpha(ns.Roster.IsPresent(name) and 1 or 0.5)
            if i > 1 then row.up:Enable() else row.up:Disable() end
            if i < #order then row.down:Enable() else row.down:Disable() end
            if i > 1 then row.restore:Enable() else row.restore:Disable() end
            if owner then row.remove:Hide() else row.remove:Show() end
            row:Show()
            y = y + ROW_H
        end
    end
    for i = rowIndex + 1, #rows do rows[i]:Hide() end
    for i = bandIndex + 1, #bands do bands[i]:Hide() end
    panel.list:SetHeight(math.max(y, 1))
    panel:SetHeight(50 + y + 6)
end

function Priority.Notice()
    return noticeText
end

function Priority.Init()
    Widgets = ns.Widgets
    ns.Comms.RegisterHandler(C.OPS.SKLIST, onSklist)
    ns.Comms.RegisterHandler(C.OPS.CSTATE, onCstate)
    ns.Roster.RegisterListener(function() Priority.SyncRoster() end)
end
