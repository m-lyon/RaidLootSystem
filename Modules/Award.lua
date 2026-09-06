-- Modules/Award.lua
--
-- Getting the item to the winner (spec 007): the master-loot path, its named failure
-- states, the hand-off to the trade path, and the auto-equip whisper.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the `award`
-- suite: the award records a resolved batch produces, which path an award takes and
-- why, the confirmation text, and whether a delivery earns an equip whisper. The
-- frame code below performs the award and reports what happened.
--
-- Nothing here is silent. A failed award is named, shown, and retryable; an award
-- that succeeded says so; and every path passes through a confirmation naming the
-- item, the winner and the path (section 6).

local ADDON, ns = ...

ns.Award = {}
local Award = ns.Award

local C = ns.Constants

--------------------------------------------------------------------------------
-- Pure: award records (sections 2 and 3)
--------------------------------------------------------------------------------

--- One record per awarded copy, from a resolved session.
--
-- Each copy is awarded separately from its own loot slot, in copy order (section 3).
-- A stacked slot holds several units, so the last slot stands in for any copy past
-- the slot count. An item-link batch has no slot and goes straight to the trade path.
--
-- @param session  the host session after Resolve: items and results
-- @return itemIdx -> array of records, one per copy
function Award.Build(session)
    local awards = {}
    for _, result in ipairs(session.results or {}) do
        local item = ns.Session.ItemByIdx(session, result.itemIdx)
        local slots = item and (item.lootSlots or (item.lootSlot and { item.lootSlot })) or {}
        local list = {}
        if not result.unclaimed then
            for copy, a in ipairs(result.awards) do
                local listIdx
                for _, e in ipairs(result.record or {}) do
                    if e.char == a.char then listIdx = e.listIdx end
                end
                list[copy] = {
                    sessionId = session.id, itemIdx = result.itemIdx, copy = copy,
                    itemString = item and item.itemString,
                    char = a.char, owner = a.owner, tier = a.tier, roll = a.roll or 0,
                    listIdx = listIdx or 0,
                    lootSlot = slots[copy] or slots[#slots],
                    delivery = C.DELIVERY.AWAITING,
                    deliveryPath = nil, failure = nil, deliveredAt = nil,
                    equipSent = false,
                }
            end
        end
        awards[result.itemIdx] = list
    end
    return awards
end

--------------------------------------------------------------------------------
-- Pure: which path (sections 2, 4 and 5)
--------------------------------------------------------------------------------

--- Decide how an award is delivered right now.
--
-- @param record  an Award.Build record
-- @param ctx     { forceTrade, lootMethod, windowOpen, slotHolds, inBags }
-- @return path (C.DELIVERY_PATH) or nil, and a code or reason:
--         with a path, an optional failure code that explains a detour (NO_LOOT_METHOD);
--         without one, a C.AWARD_FAILURE code (SOURCE_INVALID means mark it LOST) or a
--         plain instruction for the host.
function Award.PathFor(record, ctx)
    ctx = ctx or {}
    local P, F = C.DELIVERY_PATH, C.AWARD_FAILURE

    if record.delivery == C.DELIVERY.DELIVERED then return nil, "already delivered" end

    if not record.lootSlot then
        -- An item-link batch: the item is wherever the host put it (section 2).
        if ctx.inBags then return P.TRADE end
        return nil, "The item is not in your bags."
    end

    if ctx.forceTrade then
        if ctx.inBags or (ctx.windowOpen and ctx.slotHolds) then return P.TRADE end
    end

    if ctx.windowOpen and ctx.slotHolds then
        if ctx.lootMethod ~= "master" then return P.TRADE, F.NO_LOOT_METHOD end
        return P.MASTER_LOOT
    end
    if ctx.inBags then return P.TRADE end
    if ctx.windowOpen then return nil, F.SOURCE_INVALID end
    return nil, "Open the corpse to award from it, or loot the item yourself and award again."
end

--- The confirmation dialog's text (section 6): the item, the winner, and the path.
function Award.ConfirmText(record, label, path)
    local who = record.char .. (record.owner and (" (" .. record.owner .. ")") or "")
    if path == C.DELIVERY_PATH.MASTER_LOOT then
        return string.format("Give %s to %s?\n\nFrom the corpse. It binds to %s.",
            label, who, record.char)
    end
    return string.format("Take %s into your bags for %s?\n\n"
        .. "It binds to YOU and stays tradeable to kill-eligible characters for 2 hours.",
        label, who)
end

--- The message a failure code shows (section 4).
function Award.FailureText(code, record)
    local who = record and record.char or "the winner"
    if code == C.AWARD_FAILURE.NOT_A_CANDIDATE then
        return who .. " is out of range. Bring them closer and retry."
    elseif code == C.AWARD_FAILURE.SOURCE_INVALID then
        return "The corpse is gone."
    elseif code == C.AWARD_FAILURE.SLOT_NOT_CLEARED then
        return "Award didn't complete -- check " .. who .. "'s bags."
    elseif code == C.AWARD_FAILURE.NO_LOOT_METHOD then
        return "The loot method is no longer master loot; the item goes through a trade."
    end
    return tostring(code)
end

--- Short status for the results row.
function Award.StatusText(record)
    local D = C.DELIVERY
    if record.delivery == D.DELIVERED then
        return record.deliveryPath == C.DELIVERY_PATH.TRADE and "delivered by trade" or "delivered"
    elseif record.delivery == D.PENDING then
        return "in your bags, to trade"
    elseif record.delivery == D.FAILED then
        return "failed: " .. Award.FailureText(record.failure, record)
    elseif record.delivery == D.LOST then
        return "lost: the corpse is gone"
    end
    return "not awarded yet"
end

--------------------------------------------------------------------------------
-- Pure: auto-equip (section 7)
--------------------------------------------------------------------------------

--- Should a confirmed delivery be followed by an equip whisper? Only the host's own
-- bots, never a real player, never another player's bot, and only when enabled.
-- @param roster  the host's roster: { chars = { name = { isSelf } } }
function Award.ShouldAutoEquip(record, roster, settings)
    if not settings or not settings.autoEquipWinners then return false end
    if record.delivery ~= C.DELIVERY.DELIVERED then return false end
    if record.equipSent then return false end
    local chars = roster and roster.chars or {}
    local key = record.char:lower()
    for name, entry in pairs(chars) do
        if name:lower() == key then return entry.isSelf ~= true end
    end
    return false
end

--- The whisper itself. The exact mod-playerbots syntax is unconfirmed against the
-- server build (CLAUDE.md); a link is the form most commands accept.
function Award.EquipCommand(link)
    return C.BOT_EQUIP_COMMAND .. " " .. link
end

--------------------------------------------------------------------------------
-- WoW-facing. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

Award.bySession = {}           -- sessionId -> itemIdx -> array of records

local listeners = {}
local frame
local watching                 -- { record, slot, deadline } during a GiveMasterLoot
local confirmed = {}           -- lootSlot -> true, LOOT_BIND_CONFIRM already answered

function Award.RegisterListener(fn)
    listeners[#listeners + 1] = fn
end

local function fireChanged(record)
    for _, fn in ipairs(listeners) do fn(record) end
    if ns.RollWindow then ns.RollWindow.Refresh() end
    if ns.HostPanel then ns.HostPanel.Refresh() end
end

--- Called by Session.Close, host side. Builds the records the results view offers.
function Award.Begin(session)
    session.awards = Award.Build(session)
    Award.bySession[session.id] = session.awards
    fireChanged()
end

function Award.Get(sessionId, itemIdx, copy)
    local awards = Award.bySession[sessionId]
    local list = awards and awards[itemIdx]
    return list and list[copy] or nil
end

function Award.Records(sessionId)
    return Award.bySession[sessionId]
end

local function labelFor(record)
    local info = record.itemString and ns.ItemInfo.Get(record.itemString) or nil
    return (info and (info.link or info.name)) or record.itemString or "the item"
end

--- Is the item in the host's bags? First match by id.
local function findInBags(itemString)
    local _, wantedId = ns.ItemInfo.ParseLink(itemString)
    if not wantedId then return nil end
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, id = ns.ItemInfo.ParseLink(link)
                if id == wantedId then return bag, slot end
            end
        end
    end
    return nil
end
Award.FindInBags = findInBags

--- A record's delivery changed. History (008) updates in place; the priority list
-- (010) restores a position when a delivery moves away from DELIVERED.
local function deliveryChanged(record, previous)
    if ns.History and ns.History.UpdateDelivery then ns.History.UpdateDelivery(record) end
    if ns.PriorityList and ns.PriorityList.OnDeliveryChanged then
        ns.PriorityList.OnDeliveryChanged(record, previous)
    end
    fireChanged(record)
end

local function fail(record, code)
    local previous = record.delivery
    record.delivery = C.DELIVERY.FAILED
    record.failure = code
    ns.Print(string.format("%s for %s: %s", labelFor(record), record.char,
        Award.FailureText(code, record)))
    deliveryChanged(record, previous)
end

local function markLost(record)
    local previous = record.delivery
    record.delivery = C.DELIVERY.LOST
    record.failure = C.AWARD_FAILURE.SOURCE_INVALID
    ns.Print(string.format("%s for %s: the corpse is gone and the item was not looted. "
        .. "Recorded as lost.", labelFor(record), record.char))
    deliveryChanged(record, previous)
end

--- Section 7: exactly once, after a confirmed delivery, to the host's own bot.
local function autoEquip(record)
    if not Award.ShouldAutoEquip(record, ns.Database.Roster(), ns.Database.Settings()) then
        return
    end
    local info = record.itemString and ns.ItemInfo.Get(record.itemString) or nil
    local link = info and info.link
    if not link then
        ns.Debug("no link for " .. tostring(record.itemString) .. "; equip whisper skipped.")
        return
    end
    record.equipSent = true
    ns.Announce.Whisper(record.char, Award.EquipCommand(link))
end

--- A delivery completed, by either path.
function Award.MarkDelivered(record, path)
    local previous = record.delivery
    record.delivery = C.DELIVERY.DELIVERED
    record.deliveryPath = path or record.deliveryPath
    record.failure = nil
    record.deliveredAt = time()
    ns.Print(string.format("%s delivered to %s.", labelFor(record), record.char))
    deliveryChanged(record, previous)
    autoEquip(record)
end

--- A pending delivery that will never happen (spec 007 section 5, spec 010 section 6).
function Award.MarkFailed(record, code)
    fail(record, code or C.AWARD_FAILURE.SLOT_NOT_CLEARED)
end

--------------------------------------------------------------------------------
-- The master-loot path (section 3)
--------------------------------------------------------------------------------

local function candidateIndex(name)
    local key = name:lower()
    for i = 1, 40 do
        local candidate = GetMasterLootCandidate(i)       -- one argument in 3.3.5a
        if candidate and candidate:lower() == key then return i end
    end
    return nil
end

local function giveFromCorpse(record)
    local slot = record.lootSlot
    if not ns.LootDetect.SlotHolds(slot, record.itemString) then
        markLost(record)
        return
    end
    local index = candidateIndex(record.char)
    if not index then
        fail(record, C.AWARD_FAILURE.NOT_A_CANDIDATE)
        return
    end

    -- LootDetect must not read our own clear as the corpse being looted out from
    -- under a batch; the watch below turns the clear, or its absence, into a result.
    ns.LootDetect.ExpectClear(slot)
    watching = { record = record, slot = slot, deadline = GetTime() + C.AWARD_CLEAR_TIMEOUT }
    GiveMasterLoot(slot, index)
    frame:Show()
end

--------------------------------------------------------------------------------
-- The trade path (section 5): take the item, hand it to Pending
--------------------------------------------------------------------------------

local function takeIntoBags(record)
    local previous = record.delivery
    if record.lootSlot and not findInBags(record.itemString) then
        if not ns.LootDetect.SlotHolds(record.lootSlot, record.itemString) then
            markLost(record)
            return
        end
        ns.LootDetect.ExpectClear(record.lootSlot)
        confirmed[record.lootSlot] = nil
        LootSlot(record.lootSlot)       -- LOOT_BIND_CONFIRM is answered below
    end
    record.delivery = C.DELIVERY.PENDING
    record.deliveryPath = C.DELIVERY_PATH.TRADE
    record.failure = nil
    ns.Pending.Add(record)
    ns.Print(string.format("%s is in your bags for %s. Deliver it within 2 hours: "
        .. "the host panel's pending list, or /rls pending.", labelFor(record), record.char))
    deliveryChanged(record, previous)
end

--------------------------------------------------------------------------------
-- The prompt (section 6)
--------------------------------------------------------------------------------

local function execute(payload)
    local record = Award.Get(payload.sessionId, payload.itemIdx, payload.copy)
    if not record then return end
    if payload.path == C.DELIVERY_PATH.MASTER_LOOT then
        giveFromCorpse(record)
    else
        takeIntoBags(record)
    end
end

--- Offer to award one copy. Host only. `forceTrade` (shift-click) takes the trade path
-- even when the corpse is available, for a host who wants to move on.
function Award.Prompt(sessionId, itemIdx, copy, forceTrade)
    if not ns.Session.IsHost() then
        ns.Print("only the master looter awards.")
        return false
    end
    local record = Award.Get(sessionId, itemIdx, copy)
    if not record then
        ns.Print("no award record for that item; was the batch resolved on this client?")
        return false
    end

    local path, why = Award.PathFor(record, {
        forceTrade = forceTrade,
        lootMethod = (GetLootMethod()),
        windowOpen = ns.LootDetect.windowOpen,
        slotHolds = ns.LootDetect.SlotHolds(record.lootSlot, record.itemString),
        inBags = findInBags(record.itemString) ~= nil,
    })
    if not path then
        if why == C.AWARD_FAILURE.SOURCE_INVALID then
            markLost(record)
        else
            ns.Print(why)
        end
        return false
    end
    if why == C.AWARD_FAILURE.NO_LOOT_METHOD then
        ns.Print(Award.FailureText(why, record))
    end

    StaticPopup_Show("RLS_CONFIRM_AWARD", Award.ConfirmText(record, labelFor(record), path),
        nil, { sessionId = sessionId, itemIdx = itemIdx, copy = copy, path = path })
    return true
end

--------------------------------------------------------------------------------
-- Events and the clear watch
--------------------------------------------------------------------------------

local function onEvent(_, event, arg1)
    if event == "LOOT_SLOT_CLEARED" then
        if watching and arg1 == watching.slot then
            local record = watching.record
            watching = nil
            Award.MarkDelivered(record, C.DELIVERY_PATH.MASTER_LOOT)
        end
    elseif event == "LOOT_BIND_CONFIRM" then
        -- Our own LootSlot on a bind-on-pickup item, for the trade path.
        if arg1 and not confirmed[arg1] and ns.Pending.ExpectsSlot(arg1) then
            confirmed[arg1] = true
            ConfirmLootSlot(arg1)
        end
    elseif event == "LOOT_CLOSED" then
        if watching then
            local record = watching.record
            watching = nil
            ns.LootDetect.UnexpectClear(record.lootSlot)
            fail(record, C.AWARD_FAILURE.SOURCE_INVALID)
        end
    end
end

local function onUpdate()
    if not watching then
        frame:Hide()
        return
    end
    if GetTime() >= watching.deadline then
        local record = watching.record
        watching = nil
        ns.LootDetect.UnexpectClear(record.lootSlot)
        fail(record, C.AWARD_FAILURE.SLOT_NOT_CLEARED)
    end
end

function Award.Init()
    if frame then return end

    StaticPopupDialogs["RLS_CONFIRM_AWARD"] = {
        text = "%s",
        button1 = "Award",
        button2 = CANCEL,
        OnAccept = function(self) execute(self.data) end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    frame = CreateFrame("Frame", "RaidLootSystemAwardFrame")
    frame:RegisterEvent("LOOT_SLOT_CLEARED")
    frame:RegisterEvent("LOOT_BIND_CONFIRM")
    frame:RegisterEvent("LOOT_CLOSED")
    frame:SetScript("OnEvent", onEvent)
    frame:SetScript("OnUpdate", onUpdate)
    frame:Hide()                       -- shown only while a clear is being watched
end
