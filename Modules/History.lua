-- Modules/History.lua
--
-- Recording what happened, keeping it bounded, and getting it out of the game
-- (spec 008). One record per round. Every client records the results it received;
-- the host's copy is canonical and carries the host-only fields.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the
-- `history` suite: building a record from a host or client round, pruning,
-- updating a delivery in place, filtering, the per-character summary, and both
-- export formats. Timestamps are passed in (spec 000 section 2).
--
-- The log is richer than v1 reads (section 1): itemLevel, quality and equipLoc are
-- written on every item, under both modes, because they cannot be backfilled.

local ADDON, ns = ...

ns.History = {}
local History = ns.History

local C = ns.Constants
local Util = ns.Util

History.MAX_RECORDS = 500
History.MAX_AGE = 90 * 86400

--------------------------------------------------------------------------------
-- Pure: building a record (section 3)
--------------------------------------------------------------------------------

local function itemFields(info)
    info = info or {}
    return info.itemLevel, info.quality, info.equipLoc
end

local function copyOrder(priority)
    if not priority then return nil end
    return { version = priority.version or 0, order = Util.copy(priority.order or {}) }
end

local function outcomeOf(round)
    if round.state == C.ROUND_STATE.CLOSED then return "RESOLVED" end
    return "ABORTED"
end

--- The fields every record carries, host or client (section 2). `settings` is the
-- only part that differs: the host adds the timer and the quality threshold.
local function recordHeader(round, ctx, recordedAsHost, settings)
    return {
        roundId = round.id,
        recordedAsHost = recordedAsHost,
        timestamp = round.openedAt or ctx.now,
        closedAt = round.closedAt or ctx.now,
        zone = ctx.zone,
        source = ctx.source,
        host = round.host,
        -- Tagged, not scoped (spec 012 section 4): stored once and filtered as a
        -- view. The label rides along so a deleted campaign still renders a name.
        campaignId = round.campaignId,
        campaignLabel = round.campaignLabel or ctx.campaignLabel,
        settings = settings,
        priorityAtOpen = copyOrder(round.priorityAtOpen),
        raid = Util.copy(ctx.raid or {}),
        outcome = outcomeOf(round),
        abortReason = round.abortReason,
        simulated = ctx.simulated or nil,
        items = {},
    }
end

--- One entry's shape, with its defaults filled in one place so the four ways of
-- building one cannot drift apart on a field.
local function entryRecord(f)
    return {
        char = f.char, owner = f.owner, tier = f.tier,
        listIdx = f.listIdx or 0,
        star = f.star and true or false,
        override = f.override and true or false,
        rolled = f.rolled and true or false,
        roll = f.roll or 0,
        rerolled = Util.copy(f.rerolled or {}),
        withdrawn = f.withdrawn and true or false,
        reason = f.reason,
        submittedAt = f.submittedAt, revisedAt = f.revisedAt,
    }
end

--- The entries of an item that never resolved: what was submitted, none of it rolled.
-- @param keepSubmission  the host's copy carries stars, overrides and timestamps
local function unrolledEntries(list, keepSubmission)
    local entries = {}
    for _, e in ipairs(list or {}) do
        entries[#entries + 1] = entryRecord({
            char = e.char, owner = e.owner, tier = e.tier,
            star = keepSubmission and e.star, override = keepSubmission and e.override,
            submittedAt = keepSubmission and e.submittedAt or nil,
            revisedAt = keepSubmission and e.revisedAt or nil,
        })
    end
    return entries
end

local function itemRecord(item, itemInfo, fields)
    local itemLevel, quality, equipLoc = itemFields(itemInfo)
    return {
        itemIdx = item.idx,
        itemString = item.itemString,
        count = item.count or 1,
        lootSlot = fields.lootSlot,
        unclaimed = fields.unclaimed or false,
        degraded = fields.degraded or false,
        itemLevel = itemLevel, quality = quality, equipLoc = equipLoc,
        entries = fields.entries,
        awards = fields.awards,
    }
end

--- The host's record (section 2): every entry with its submission timestamps, every
-- award with its delivery state, loot slots included.
--
-- @param round  the host round after Close or Abort
-- @param ctx      { now, zone, source, raid, timerSeconds, qualityThreshold, simulated }
function History.FromHost(round, ctx)
    ctx = ctx or {}
    local record = recordHeader(round, ctx, true, {
        tierCount = round.tierCount,
        timerSeconds = ctx.timerSeconds,
        qualityThreshold = ctx.qualityThreshold,
        lootMode = round.lootMode or C.LOOT_MODE.ROLL,
    })

    local resultByIdx = {}
    for _, r in ipairs(round.results or {}) do resultByIdx[r.itemIdx] = r end

    for i, item in ipairs(round.items) do
        local result = resultByIdx[item.idx]
        local submittedList = round.entries and round.entries[item.idx] or {}

        local entries
        if result then
            local submitted = {}
            for _, e in ipairs(submittedList) do submitted[e.char:lower()] = e end
            entries = {}
            for _, e in ipairs(result.record or {}) do
                local sub = submitted[e.char:lower()] or {}
                entries[#entries + 1] = entryRecord({
                    char = e.char, owner = e.owner or sub.owner, tier = e.tier,
                    listIdx = e.listIdx, star = sub.star, override = sub.override,
                    rolled = e.rolled, roll = e.roll, rerolled = e.rerolled,
                    withdrawn = e.reason == C.NOT_ROLLED.WITHDRAWN, reason = e.reason,
                    submittedAt = sub.submittedAt, revisedAt = sub.revisedAt,
                })
            end
        else
            -- Aborted before resolution.
            entries = unrolledEntries(submittedList, true)
        end

        local awards = {}
        local records = round.awards and round.awards[item.idx] or {}
        if result and not result.unclaimed then
            for copy, a in ipairs(result.awards) do
                local rec = records[copy] or {}
                awards[copy] = {
                    copy = copy, char = a.char, owner = a.owner, tier = a.tier,
                    roll = a.roll or 0,
                    listIdx = ns.Resolve.listIdxOf(result.record, a.char) or 0,
                    priorIndex = rec.priorIndex,
                    delivery = rec.delivery or C.DELIVERY.AWAITING,
                    deliveryPath = rec.deliveryPath,
                    deliveredAt = rec.deliveredAt,
                    failure = rec.failure,
                }
            end
        end

        record.items[i] = itemRecord(item, item.info, {
            lootSlot = item.lootSlot,
            unclaimed = result and result.unclaimed,
            degraded = result and result.degraded,
            entries = entries, awards = awards,
        })
    end
    return record
end

--- A client's record (section 2): what arrived in STATE, RESULT and ROLLS. No
-- submission timestamps, no loot slots, no delivery state: those are the host's.
--
-- @param round  the Client mirror after RESULT and ROLLS, or after ABORT
-- @param ctx      { now, zone, raid, infoOf = function(itemString) -> itemInfo, simulated }
function History.FromClient(round, ctx)
    ctx = ctx or {}
    local infoOf = ctx.infoOf or function() return nil end
    local record = recordHeader(round, ctx, false, {
        tierCount = round.tierCount,
        lootMode = round.lootMode or C.LOOT_MODE.ROLL,
    })

    -- Owners come from STATE; ROLLS does not carry them.
    local owners = {}
    for _, list in pairs(round.entries or {}) do
        for _, e in ipairs(list) do owners[e.char:lower()] = e.owner end
    end

    for i, item in ipairs(round.items) do
        local entries = {}
        for _, r in ipairs(round.rolls or {}) do
            if r.itemIdx == item.idx then
                local status = r.status or C.ROLL_STATUS.ROLLED
                entries[#entries + 1] = entryRecord({
                    char = r.char, owner = owners[r.char:lower()], tier = r.tier,
                    listIdx = r.listIdx,
                    rolled = status == C.ROLL_STATUS.ROLLED, roll = r.roll,
                    rerolled = r.rerolled,
                    withdrawn = status == C.ROLL_STATUS.WITHDRAWN,
                    reason = status == C.ROLL_STATUS.NOT_CONSULTED and C.NOT_ROLLED.NOT_CONSULTED
                        or status == C.ROLL_STATUS.WITHDRAWN and C.NOT_ROLLED.WITHDRAWN or nil,
                })
            end
        end
        if #entries == 0 then
            -- No ROLLS for this item: aborted, or the RESULT arrived without them.
            entries = unrolledEntries(round.entries and round.entries[item.idx], false)
        end

        local awards, unclaimed, degraded = {}, false, false
        for _, r in ipairs(round.results or {}) do
            if r.itemIdx == item.idx then
                if r.outcome == C.OUTCOME.UNCLAIMED then
                    unclaimed = true
                else
                    if r.outcome == C.OUTCOME.DEGRADED then degraded = true end
                    awards[#awards + 1] = {
                        copy = #awards + 1, char = r.winner, owner = owners[(r.winner or ""):lower()],
                        tier = r.tier, roll = r.roll or 0,
                        listIdx = ns.Resolve.listIdxOf(entries, r.winner) or 0,
                    }
                end
            end
        end

        record.items[i] = itemRecord(item, infoOf(item.itemString), {
            unclaimed = unclaimed, degraded = degraded,
            entries = entries, awards = awards,
        })
    end
    return record
end

--------------------------------------------------------------------------------
-- Pure: storage rules (sections 2 and 4)
--------------------------------------------------------------------------------

--- Add or replace a record. A record with the same round id and the same
-- recordedAsHost flag is replaced; the host's and a client's copies of one round
-- coexist (section 2). Records are kept in insertion order, oldest first.
function History.Upsert(records, record)
    for i, r in ipairs(records) do
        if r.roundId == record.roundId and r.recordedAsHost == record.recordedAsHost then
            records[i] = record
            return records, false
        end
    end
    records[#records + 1] = record
    return records, true
end

--- Keep the most recent MAX_RECORDS or MAX_AGE, whichever bites first (section 4).
-- @return kept array, removed array, count of removed records never exported
function History.Prune(records, now, opts)
    opts = opts or {}
    local max = opts.max or History.MAX_RECORDS
    local maxAge = opts.maxAge or History.MAX_AGE

    local sorted = {}
    for i, r in ipairs(records) do sorted[i] = r end
    table.sort(sorted, function(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end)

    local kept, removed, unexported = {}, {}, 0
    local excess = #sorted - max
    for i, r in ipairs(sorted) do
        local tooOld = (now - (r.timestamp or 0)) > maxAge
        if i <= excess or tooOld then
            removed[#removed + 1] = r
            if not r.exported then unexported = unexported + 1 end
        else
            kept[#kept + 1] = r
        end
    end
    return kept, removed, unexported
end

--- Update a delivery in place (section 3): a pending item handed over forty minutes
-- later changes the original record, never creates a second one.
-- @param award  an Award record: roundId, itemIdx, copy, delivery, deliveryPath,
--               deliveredAt, failure, priorIndex
-- @return the history award updated, or nil when no record holds it
function History.UpdateDelivery(records, award)
    for _, r in ipairs(records) do
        if r.roundId == award.roundId and r.recordedAsHost then
            for _, item in ipairs(r.items) do
                if item.itemIdx == award.itemIdx then
                    local a = item.awards[award.copy or 1]
                    if a then
                        a.delivery = award.delivery
                        a.deliveryPath = award.deliveryPath
                        a.deliveredAt = award.deliveredAt
                        a.failure = award.failure
                        if award.priorIndex ~= nil then a.priorIndex = award.priorIndex end
                        return a
                    end
                end
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Pure: reading (section 5)
--------------------------------------------------------------------------------

local function lower(s) return type(s) == "string" and s:lower() or "" end

--- The record-level tests: simulation, date range and campaign.
local function recordInScope(r, filter)
    if r.simulated and not filter.includeSimulated then return false end
    if filter.since and (r.timestamp or 0) < filter.since then return false end
    if filter.until_ and (r.timestamp or 0) > filter.until_ then return false end
    -- The browser defaults to the active campaign, with an All campaigns toggle
    -- (spec 012 section 13). A record written before campaigns existed has no id
    -- and only shows under All.
    if filter.campaignId and r.campaignId ~= filter.campaignId then return false end
    return true
end

--- Every lowercased character and owner a record names, across entries and awards.
local function namesIn(r)
    local chars, owners = {}, {}
    for _, it in ipairs(r.items) do
        for _, list in ipairs({ it.entries, it.awards }) do
            for _, e in ipairs(list) do
                chars[lower(e.char)] = true
                owners[lower(e.owner)] = true
            end
        end
    end
    return chars, owners
end

--- Does any item's label or item string contain `item`?
local function namesItem(r, item, labelOf)
    for _, it in ipairs(r.items) do
        local label = lower(labelOf(it.itemString)) .. " " .. lower(it.itemString)
        if label:find(item, 1, true) then return true end
    end
    return false
end

--- Records matching a filter, newest first.
-- @param filter { char, owner, item, since, until_, roster (set of lower names),
--                 includeSimulated, labelOf = function(itemString) -> string }
function History.Filter(records, filter)
    filter = filter or {}
    local labelOf = filter.labelOf or function(s) return s end
    local char, owner, item = lower(filter.char), lower(filter.owner), lower(filter.item)
    local out = {}

    for _, r in ipairs(records) do
        local ok = recordInScope(r, filter)
        if ok and (char ~= "" or owner ~= "" or filter.roster) then
            local chars, owners = namesIn(r)
            if char ~= "" and not chars[char] then ok = false end
            if owner ~= "" and not owners[owner] then ok = false end
            if ok and filter.roster then
                local hit = false
                for name in pairs(chars) do
                    if filter.roster[name] then hit = true break end
                end
                ok = hit
            end
        end
        if ok and item ~= "" then ok = namesItem(r, item, labelOf) end
        if ok then out[#out + 1] = r end
    end

    table.sort(out, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
    return out
end

--- Everything one character was awarded, newest first (section 5). Entries it
-- merely rolled on are not here.
function History.CharacterSummary(records, char)
    local key = lower(char)
    local out = {}
    for _, r in ipairs(records) do
        if not r.simulated then
            for _, item in ipairs(r.items) do
                for _, a in ipairs(item.awards) do
                    if lower(a.char) == key then
                        out[#out + 1] = {
                            timestamp = r.timestamp, zone = r.zone, source = r.source,
                            itemString = item.itemString, roundId = r.roundId,
                            delivery = a.delivery, tier = a.tier,
                            recordedAsHost = r.recordedAsHost,
                        }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
    return out
end

--------------------------------------------------------------------------------
-- Pure: export (section 6)
--------------------------------------------------------------------------------

--- Plain text: a round header, one line per award.
-- @param ctx { labelOf(itemString), formatDate(timestamp) }
function History.ExportText(records, ctx)
    ctx = ctx or {}
    local labelOf = ctx.labelOf or function(s) return s end
    local formatDate = ctx.formatDate or function(t) return tostring(t) end
    local Tiers = ns.Tiers
    local lines = {}

    for _, r in ipairs(records) do
        local where = (r.zone or "?") .. " / " .. (r.source or "?")
        -- A record from before campaigns existed has no id, and a placeholder on
        -- every such line is noise. The CSV keeps its column either way (fixed schema).
        local campaign = r.campaignLabel or r.campaignId
        lines[#lines + 1] = string.format("%s  %s  %s(host %s, %s, %d tiers%s)",
            formatDate(r.timestamp), where,
            campaign and ("[" .. campaign .. "]  ") or "",
            r.host or "?", r.settings.lootMode or "ROLL",
            r.settings.tierCount or 0, r.simulated and ", simulated" or "")
        if r.outcome == "ABORTED" then
            lines[#lines + 1] = "  aborted: " .. (C.ABORT_TEXT[r.abortReason] or r.abortReason or "?")
        end
        for _, item in ipairs(r.items) do
            local label = labelOf(item.itemString)
            if item.count > 1 then label = label .. " x" .. item.count end
            if item.unclaimed then
                lines[#lines + 1] = "  " .. label .. " -> unclaimed"
            elseif #item.awards == 0 and r.outcome == "ABORTED" then
                lines[#lines + 1] = "  " .. label .. " -> not resolved"
            end
            for _, a in ipairs(item.awards) do
                local how
                if (r.settings.lootMode == C.LOOT_MODE.SK) then
                    how = "position " .. tostring(a.listIdx)
                else
                    how = "roll " .. tostring(a.roll)
                end
                lines[#lines + 1] = string.format("  %s -> %s (%s) %s, %s%s", label, a.char,
                    a.owner or "?", Tiers.label(a.tier, r.settings.tierCount), how,
                    a.delivery and (", " .. a.delivery:lower()) or "")
            end
        end
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end

History.CSV_HEADER = "timestamp,zone,source,campaign,campaignId,item,itemLevel,quality,"
    .. "equipLoc,character,owner,tier,listIdx,star,rolled,roll,withdrawn,awarded,delivery"

local function csvField(v)
    if v == nil then return "" end
    if type(v) == "boolean" then return v and "true" or "false" end
    local s = tostring(v)
    if s:find('[,"\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
    return s
end

--- CSV: one row per ENTRY, not per award, so the data is analysable (section 6).
-- @param ctx { nameOf(itemString) -> plain item name }
function History.ExportCSV(records, ctx)
    ctx = ctx or {}
    local nameOf = ctx.nameOf or function(s) return s end
    local rows = { History.CSV_HEADER }

    for _, r in ipairs(records) do
        for _, item in ipairs(r.items) do
            local awarded = {}
            for _, a in ipairs(item.awards) do awarded[lower(a.char)] = a end
            for _, e in ipairs(item.entries) do
                local a = awarded[lower(e.char)]
                local fields = {
                    r.timestamp, r.zone, r.source,
                    r.campaignLabel, r.campaignId,
                    nameOf(item.itemString),
                    item.itemLevel, item.quality, item.equipLoc,
                    e.char, e.owner, e.tier, e.listIdx, e.star, e.rolled, e.roll,
                    e.withdrawn, a ~= nil, a and a.delivery or nil,
                }
                -- A nil (an item level the cache never gave) is a hole, so the column
                -- count is fixed rather than read from the array.
                local out = {}
                for i = 1, 19 do out[i] = csvField(fields[i]) end
                rows[#rows + 1] = table.concat(out, ",")
            end
        end
    end
    return table.concat(rows, "\n")
end

--- Mark what an export covered, so pruning can warn about the rest (section 4).
function History.MarkExported(records)
    for _, r in ipairs(records) do r.exported = true end
end

--- The record in the shape the results renderer takes (spec 005 section 5 and
-- section 5 here: one rendering component, both places).
function History.ToView(record)
    local items, results, rolls, owners = {}, {}, {}, {}
    for i, item in ipairs(record.items) do
        items[i] = { idx = item.itemIdx or i, itemString = item.itemString, count = item.count }
        local idx = items[i].idx
        if item.unclaimed then
            results[#results + 1] = { itemIdx = idx, winner = nil, tier = 0, roll = 0,
                                      outcome = C.OUTCOME.UNCLAIMED }
        end
        for _, a in ipairs(item.awards) do
            results[#results + 1] = { itemIdx = idx, winner = a.char, tier = a.tier,
                                      roll = a.roll, listIdx = a.listIdx,
                                      outcome = item.degraded and C.OUTCOME.DEGRADED or C.OUTCOME.WON,
                                      award = a }
            if a.owner then owners[lower(a.char)] = a.owner end
        end
        for _, e in ipairs(item.entries) do
            rolls[#rolls + 1] = {
                itemIdx = idx, char = e.char, tier = e.tier, roll = e.roll, listIdx = e.listIdx,
                status = e.withdrawn and C.ROLL_STATUS.WITHDRAWN
                    or (not e.rolled and C.ROLL_STATUS.NOT_CONSULTED) or C.ROLL_STATUS.ROLLED,
                rerolled = e.rerolled or {},
            }
            if e.owner then owners[lower(e.char)] = e.owner end
        end
    end
    return {
        roundId = record.roundId, items = items, results = results, rolls = rolls,
        owners = owners, isSK = record.settings.lootMode == C.LOOT_MODE.SK,
        tierCount = record.settings.tierCount or 0, outcome = record.outcome,
        abortReason = record.abortReason,
    }
end

--------------------------------------------------------------------------------
-- WoW-facing. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

local listeners = {}

local function DB() return ns.Database.History() end

function History.RegisterListener(fn)
    listeners[#listeners + 1] = fn
end

local function fireChanged()
    for _, fn in ipairs(listeners) do fn() end
end

function History.Records()
    return DB()
end

--- Players in the group running the addon, plus this client.
local function raidPlayers()
    local names, seen = {}, {}
    local me = UnitName("player")
    if me then
        names[#names + 1] = me
        seen[me] = true
    end
    for _, member in ipairs(ns.Roster.GroupMembers()) do
        if member.name and not seen[member.name] and ns.Round.peers[member.name] then
            names[#names + 1] = member.name
            seen[member.name] = true
        end
    end
    return names
end

local function simulated()
    return ns.Simulate ~= nil and ns.Simulate.active == true
end

--- Host side: called by Round.Close and Round.Abort.
function History.Record(round)
    local host = ns.Database.Host()
    local record = History.FromHost(round, {
        now = time(),
        zone = GetRealZoneText(),
        source = round.source,
        raid = raidPlayers(),
        timerSeconds = host.timerSeconds,
        qualityThreshold = host.qualityThreshold,
        campaignLabel = ns.Campaign.ActiveLabel(),
        simulated = simulated(),
    })
    History.Upsert(DB(), record)
    fireChanged()
    return record
end

--- Client side: called by Client once RESULT and ROLLS have both arrived, or on
-- ABORT. The host's own mirror is skipped: its canonical record is already written.
function History.RecordClient(round)
    -- Judged by the round's own host name, which is stable for the life of the mirror:
    -- by the time an ML_CHANGED abort fires, IsHost() is already false on the old host.
    local me = UnitName("player")
    if round.host and me and round.host:lower() == me:lower() then return nil end
    local record = History.FromClient(round, {
        now = time(),
        zone = GetRealZoneText(),
        raid = raidPlayers(),
        infoOf = function(itemString) return ns.ItemInfo.Get(itemString) end,
        simulated = simulated(),
    })
    History.Upsert(DB(), record)
    fireChanged()
    return record
end

--- Award tells us a delivery changed (spec 007); the record is updated in place.
function History.UpdateDeliveryFromAward(award)
    local updated = History.UpdateDelivery(DB(), award)
    if updated then fireChanged() end
    return updated
end

--- Prune on load (section 4), warning when never-exported records go.
function History.Init()
    local kept, removed, unexported = History.Prune(DB(), time())
    if #removed > 0 then
        ns.Database.ReplaceHistory(kept)
        if unexported > 0 then
            ns.Print(string.format("history: %d old round record(s) were pruned, %d of them never "
                .. "exported. Export regularly if you want to keep everything.", #removed, unexported))
        else
            ns.Debug(string.format("history: pruned %d old record(s).", #removed))
        end
    end
end
