-- Modules/Pending.lua
--
-- Undelivered items and their two-hour countdown (spec 007 section 5). An item the
-- host took into their own bags is soulbound to the host and tradeable to
-- kill-eligible characters for two hours; this module records it the moment it is
-- taken, reminds the host at login, delivers it by trade, and keeps expired entries
-- rather than deleting them.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the
-- `pending` suite: the record, expiry, the countdown text and its urgency, and the
-- login reminder lines.

local ADDON, ns = ...

ns.Pending = {}
local Pending = ns.Pending

local C = ns.Constants

--------------------------------------------------------------------------------
-- Pure: records and expiry (section 5)
--------------------------------------------------------------------------------

--- A pending record from an award record. `now` is passed in (spec 000 section 2).
function Pending.NewRecord(award, now)
    return {
        itemString = award.itemString,
        winner = award.char,
        owner = award.owner,
        roundId = award.roundId,
        itemIdx = award.itemIdx,
        -- The campaign the award was made in (spec 012 section 14). A restore on
        -- terminal failure targets THAT campaign's list, and the two-hour trade
        -- window routinely outlives a campaign switch.
        campaignId = award.campaignId,
        copy = award.copy or 1,
        takenAt = now,
        expiresAt = now + C.PENDING_TTL,
        delivered = false,
        deliveredAt = nil,
        expired = false,
        -- What a Suicide Kings restore needs (spec 010 section 6), carried here because
        -- the award records do not survive a reload and a two-hour window often spans one.
        priorIndex = award.priorIndex,
        presentIndices = award.presentIndices,
        listVersion = award.listVersion,
    }
end

--- Mark what has run out. Expired entries are kept: an item welded to the wrong
-- character is exactly what needs to stay visible.
-- @return the records newly marked expired
function Pending.Expire(records, now)
    local newly = {}
    for _, r in ipairs(records or {}) do
        if not r.delivered and not r.expired and now >= r.expiresAt then
            r.expired = true
            newly[#newly + 1] = r
        end
    end
    return newly
end

--- Records still to deliver, expired ones included, oldest first. An abandoned
-- record stays in the table (nothing is deleted) but is no longer outstanding.
function Pending.Outstanding(records)
    local out = {}
    for _, r in ipairs(records or {}) do
        if not r.delivered and not r.abandoned then out[#out + 1] = r end
    end
    table.sort(out, function(a, b) return a.takenAt < b.takenAt end)
    return out
end

local function sameCopy(r, award)
    return r.roundId == award.roundId and r.itemIdx == award.itemIdx
        and (r.copy or 1) == (award.copy or 1)
end

--- The undelivered record for this award's copy, or nil.
function Pending.FindRecord(records, award)
    for _, r in ipairs(records or {}) do
        if not r.delivered and not r.abandoned and sameCopy(r, award) then return r end
    end
    return nil
end

--- Units of an item id that undelivered records already account for, so that a
-- second copy is looted rather than assumed to be the first one (spec 007 section 5).
-- @param except  an award whose own record, if any, is not counted
function Pending.UnitsHeld(records, itemId, except)
    local units = 0
    for _, r in ipairs(records or {}) do
        if not r.delivered and not r.abandoned then
            local _, id = ns.ItemInfo.ParseLink(r.itemString)
            if id == itemId and not (except and sameCopy(r, except)) then
                units = units + 1
            end
        end
    end
    return units
end

--- "1h 32m" and how urgent it is: "ok", "amber" (under 30 min), "red" (under 10) or
-- "expired".
function Pending.TimeLeft(record, now)
    local left = record.expiresAt - now
    if record.expired or left <= 0 then return "expired", "expired" end
    local minutes = math.ceil(left / 60)
    local text
    if minutes >= 60 then
        text = string.format("%dh %02dm", math.floor(minutes / 60), minutes % 60)
    else
        text = minutes .. "m"
    end
    local urgency = "ok"
    if left < C.PENDING_WARN_RED then urgency = "red"
    elseif left < C.PENDING_WARN_AMBER then urgency = "amber" end
    return text, urgency
end

--- The login reminder (section 5): one line per outstanding item.
-- @param label  function(itemString) -> display label
function Pending.ReminderLines(records, now, label)
    local lines = {}
    for _, r in ipairs(Pending.Outstanding(records)) do
        local left = Pending.TimeLeft(r, now)
        local who = r.winner .. (r.owner and (" (" .. r.owner .. ")") or "")
        if left == "expired" then
            lines[#lines + 1] = string.format("%s for %s - the trade window has EXPIRED; "
                .. "it is bound to you.", label(r.itemString), who)
        else
            lines[#lines + 1] = string.format("%s for %s - %s left to trade it.",
                label(r.itemString), who, left)
        end
    end
    return lines
end

--- Why a trade might have been refused (section 5): the two-hour flag only permits
-- trading to characters eligible for the loot at kill time.
Pending.REFUSED_HINT = "If the trade was refused, the likely cause is that the character was "
    .. "not eligible for that kill (summoned in after the boss died). The item is bound to you."

--------------------------------------------------------------------------------
-- WoW-facing. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

Pending.BOT_TRADE_COMMAND = nil    -- whisper sent to a bot after the item is placed, once
                                   -- the server's playerbot build says what it wants.
                                   -- nil sends nothing; mod-playerbots bots accept a
                                   -- master's trade on their own in the builds seen.

local frame
local expected = {}                -- lootSlot -> true while our own LootSlot is in flight
local trade                        -- { record, shown, bothAccepted, unitsBefore, startedAt }
local tickAccumulator = 0

local function DB() return ns.Database.Pending() end

local function labelFor(itemString)
    local info = itemString and ns.ItemInfo.Get(itemString) or nil
    return (info and (info.link or info.name)) or itemString or "an item"
end

local function fireChanged()
    if ns.HostPanel then ns.HostPanel.Refresh() end
end

--- Record an item that has reached the host's bags (from Award, once observed).
function Pending.Add(award)
    local record = Pending.NewRecord(award, time())
    local records = DB()
    records[#records + 1] = record
    fireChanged()
    return record
end

--- Award is about to LootSlot this slot itself, for the trade path. Registered before
-- the call: LOOT_BIND_CONFIRM fires from inside LootSlot.
function Pending.ExpectSlot(lootSlot)
    if lootSlot then expected[lootSlot] = true end
end

--- Is this loot slot one our own LootSlot is emptying? Answers the LOOT_BIND_CONFIRM
-- that Award.lua watches for. Consumed on answer.
function Pending.ExpectsSlot(lootSlot)
    if expected[lootSlot] then
        expected[lootSlot] = nil
        return true
    end
    return false
end

--- The slot cleared, or the attempt is over: a later corpse's slot of the same index
-- must never be auto-confirmed on the strength of this one.
function Pending.ForgetSlot(lootSlot)
    if lootSlot then expected[lootSlot] = nil end
end

function Pending.ClearExpectations()
    expected = {}
end

function Pending.Records()
    return DB()
end

function Pending.Find(award)
    return Pending.FindRecord(DB(), award)
end

function Pending.OutstandingRecords()
    return Pending.Outstanding(DB())
end

local function awardFor(record)
    return ns.Award.Get(record.roundId, record.itemIdx, record.copy)
end

--- The delivery happened: by our trade, by the host's own hand, or because the
-- host is the winner and it was already where it needed to be.
function Pending.MarkDelivered(record, path)
    if record.delivered then return end
    path = path or C.DELIVERY_PATH.TRADE
    record.delivered = true
    record.deliveredAt = time()
    local award = awardFor(record)
    if award then
        ns.Award.MarkDelivered(award, path)
    else
        -- After a reload there is no award record: history and the list are told from here.
        if path == C.DELIVERY_PATH.SELF then
            ns.Print(string.format("%s is yours - you won it, so it is recorded as delivered.",
                labelFor(record.itemString)))
        else
            ns.Print(string.format("%s delivered to %s.", labelFor(record.itemString), record.winner))
        end
        if ns.History then
            ns.History.UpdateDeliveryFromAward({ roundId = record.roundId, itemIdx = record.itemIdx,
                copy = record.copy, delivery = C.DELIVERY.DELIVERED,
                deliveryPath = path, deliveredAt = record.deliveredAt })
        end
        if ns.Priority then ns.Priority.OnPendingChanged(record, "delivered") end
    end
    fireChanged()
end

--- A pending delivery that will never happen: the award record if it exists, else
-- history and the priority list directly.
local function failPending(record)
    local award = awardFor(record)
    if award then
        ns.Award.MarkFailed(award, C.AWARD_FAILURE.TRADE_EXPIRED)
        return
    end
    if ns.History then
        ns.History.UpdateDeliveryFromAward({ roundId = record.roundId, itemIdx = record.itemIdx,
            copy = record.copy, delivery = C.DELIVERY.FAILED, deliveryPath = C.DELIVERY_PATH.TRADE,
            failure = C.AWARD_FAILURE.TRADE_EXPIRED })
    end
    if ns.Priority then ns.Priority.OnPendingChanged(record, "failed") end
end

--- The host has given up on it: it stays in the table, marked, but leaves the list.
function Pending.Abandon(record)
    if record.delivered or record.abandoned then return end
    record.abandoned = true
    failPending(record)
    ns.Print(string.format("%s for %s abandoned. It stays in your bags and in the history.",
        labelFor(record.itemString), record.winner))
    fireChanged()
end

--------------------------------------------------------------------------------
-- Delivering by trade (section 5)
--------------------------------------------------------------------------------

local function unitFor(name)
    local key = name:lower()
    for i = 1, GetNumRaidMembers() do
        local member = GetRaidRosterInfo(i)
        if member and member:lower() == key then return "raid" .. i end
    end
    for i = 1, GetNumPartyMembers() do
        local member = UnitName("party" .. i)
        if member and member:lower() == key then return "party" .. i end
    end
    return nil
end

--- Target the recipient, open trade, place the item (section 5).
function Pending.Deliver(record)
    if record.delivered then
        ns.Print("that item was already delivered.")
        return false
    end
    -- You cannot trade with yourself, and you do not need to: a record whose winner
    -- is the character being played is already delivered. This is reachable on a
    -- record written before the host logged into the winner, and on any record the
    -- award path did not catch (spec 007 section 5).
    if ns.Award.IsSelfDelivery(record.winner, UnitName("player")) then
        Pending.MarkDelivered(record, C.DELIVERY_PATH.SELF)
        return true
    end
    local unit = unitFor(record.winner)
    if not unit then
        ns.Print(record.winner .. " is not in your group.")
        return false
    end
    if not CheckInteractDistance(unit, 2) then
        ns.Print(record.winner .. " is out of trade range (about 11 yards). Get closer and try again.")
        return false
    end
    if not ns.Award.FindInBags(record.itemString) then
        ns.Print(labelFor(record.itemString) .. " is not in your bags.")
        return false
    end
    if trade and trade.shown and TradeFrame and TradeFrame:IsShown() then
        ns.Print("a trade is already in progress.")
        return false
    end
    -- A request that never opened a window (declined silently, too far, busy) leaves
    -- no event behind; a new Deliver replaces it rather than waiting on it.
    local _, id = ns.ItemInfo.ParseLink(record.itemString)
    trade = { record = record, shown = false, bothAccepted = false,
              unitsBefore = ns.Award.CountInBags(id), startedAt = GetTime() }
    InitiateTrade(unit)
    return true
end

local function unitsNow(record)
    local _, id = ns.ItemInfo.ParseLink(record.itemString)
    return ns.Award.CountInBags(id)
end

local function onTradeShow()
    if not trade then return end
    trade.shown = true
    local bag, slot = ns.Award.FindInBags(trade.record.itemString)
    if not bag then
        ns.Print(labelFor(trade.record.itemString) .. " is not in your bags; the trade was cancelled.")
        CancelTrade()
        trade = nil
        return
    end
    ClearCursor()
    PickupContainerItem(bag, slot)
    ClickTradeButton(1)
    ns.Print(string.format("%s placed in the trade for %s. Press Trade to hand it over.",
        labelFor(trade.record.itemString), trade.record.winner))
    if Pending.BOT_TRADE_COMMAND then
        ns.Announce.Whisper(trade.record.winner, Pending.BOT_TRADE_COMMAND)
    end
end

local function onEvent(_, event, arg1, arg2)
    if event == "TRADE_SHOW" then
        onTradeShow()
    elseif event == "TRADE_ACCEPT_UPDATE" then
        if trade and arg1 == 1 and arg2 == 1 then trade.bothAccepted = true end
    elseif event == "TRADE_CLOSED" then
        if not trade or not trade.shown then return end
        local current = trade
        trade = nil
        -- Delivered when a unit left the bags, not when none of the id remain: the
        -- host may hold another copy for another winner, or one of their own.
        if current.bothAccepted and unitsNow(current.record) < current.unitsBefore then
            Pending.MarkDelivered(current.record)
        else
            ns.Print(string.format("the trade with %s did not complete; %s is still in your bags. %s",
                current.record.winner, labelFor(current.record.itemString), Pending.REFUSED_HINT))
        end
    elseif event == "TRADE_REQUEST_CANCEL" then
        if trade then
            ns.Print(trade.record.winner .. " declined the trade.")
            trade = nil
        end
    elseif event == "UI_ERROR_MESSAGE" then
        -- Too far, busy, dead, no response: the server says so here and nowhere else.
        if trade and not trade.shown then
            ns.Print("the trade with " .. trade.record.winner .. " could not be opened: "
                .. tostring(arg1))
            trade = nil
        end
    end
end

--------------------------------------------------------------------------------
-- The clock: expiry marks, and the login reminder
--------------------------------------------------------------------------------

local function onUpdate(_, elapsed)
    if trade and not trade.shown and GetTime() - trade.startedAt > C.TRADE_OPEN_TIMEOUT then
        ns.Print("no trade window opened with " .. trade.record.winner .. "; try again.")
        trade = nil
    end

    tickAccumulator = tickAccumulator + elapsed
    if tickAccumulator < 30 then return end
    tickAccumulator = 0
    local newly = Pending.Expire(DB(), time())
    for _, r in ipairs(newly) do
        ns.Print(string.format("%s for %s can no longer be traded: the two hours are up. "
            .. "It stays in the pending list.", labelFor(r.itemString), r.winner))
        failPending(r)
    end
    if #newly > 0 then fireChanged() end
end

--- `/rls pending`: the list, numbered for `/rls deliver <n>`.
function Pending.PrintList()
    local outstanding = Pending.OutstandingRecords()
    if #outstanding == 0 then
        ns.Print("nothing pending delivery.")
        return
    end
    local now = time()
    for i, r in ipairs(outstanding) do
        local left, urgency = Pending.TimeLeft(r, now)
        local colour = urgency == "red" and "|cffff4040" or urgency == "amber" and "|cffffaa00"
            or urgency == "expired" and "|cff888888" or "|cffaaaaaa"
        ns.Print(string.format("  %d. %s for %s (%s) - %s%s|r", i, labelFor(r.itemString),
            r.winner, r.owner or "?", colour, left))
    end
    ns.Print("/rls deliver <n> opens the trade; /rls abandon <n> gives up on one.")
end

function Pending.Init()
    if frame then return end
    frame = CreateFrame("Frame", "RaidLootSystemPendingFrame")
    frame:RegisterEvent("TRADE_SHOW")
    frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
    frame:RegisterEvent("TRADE_CLOSED")
    frame:RegisterEvent("TRADE_REQUEST_CANCEL")
    frame:RegisterEvent("UI_ERROR_MESSAGE")
    frame:SetScript("OnEvent", onEvent)
    frame:SetScript("OnUpdate", onUpdate)

    -- The login reminder (section 5). Anything outstanding is said now, expiry first.
    Pending.Expire(DB(), time())
    local lines = Pending.ReminderLines(DB(), time(), labelFor)
    if #lines > 0 then
        ns.Print("you are holding loot for other characters:")
        for _, line in ipairs(lines) do ns.Print("  " .. line) end
    end
end
