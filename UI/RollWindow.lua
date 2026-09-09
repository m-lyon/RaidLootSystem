-- UI/RollWindow.lua
--
-- The window every player uses to enter a round and to read its result (spec 005).
-- One frame, two modes: entry while the round is OPEN, results once it is CLOSED.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the
-- `rollwindow` suite: which cells are enterable and why, what a submission contains,
-- whether it differs from what the host accepted, and how the results table is
-- ordered. The frame code below renders those answers and nothing else.
--
-- The live view renders host STATE exclusively (spec 002 section 7). Local ticks are
-- shown as ticks; who the host has accepted is shown in the detail panel; the two are
-- never conflated.

local ADDON, ns = ...

ns.RollWindow = {}
local RollWindow = ns.RollWindow

local C = ns.Constants

--------------------------------------------------------------------------------
-- Pure: cell states (section 3, "Cells")
--------------------------------------------------------------------------------

local CLASS_PLURAL = {
    WARRIOR = "Warriors", PALADIN = "Paladins", HUNTER = "Hunters", ROGUE = "Rogues",
    PRIEST = "Priests", DEATHKNIGHT = "Death Knights", SHAMAN = "Shamans",
    MAGE = "Mages", WARLOCK = "Warlocks", DRUID = "Druids",
}

-- Display text for the Data/ItemClasses.lua subclass keys. Lower-case and ours, so the
-- locale grep (spec 009 section 3) has nothing to object to.
local SUBCLASS_TEXT = {
    CLOTH = "cloth", LEATHER = "leather", MAIL = "mail", PLATE = "plate",
    SHIELD = "shields", LIBRAM = "librams", IDOL = "idols", TOTEM = "totems",
    SIGIL = "sigils",
    AXE_1H = "one-handed axes", AXE_2H = "two-handed axes", BOW = "bows", GUN = "guns",
    MACE_1H = "one-handed maces", MACE_2H = "two-handed maces", POLEARM = "polearms",
    SWORD_1H = "one-handed swords", SWORD_2H = "two-handed swords", STAFF = "staves",
    FIST = "fist weapons", DAGGER = "daggers", THROWN = "thrown weapons",
    CROSSBOW = "crossbows", WAND = "wands",
}

local function subclassText(key)
    if not key then return "that" end
    return SUBCLASS_TEXT[key] or key:gsub("_", " "):lower()
end

--- The plain-language reason behind an eligibility code (section 3).
-- @param char { name, class, contestReason }
function RollWindow.ReasonText(reason, char, info)
    local R = C.REASON
    char = char or {}
    info = info or {}
    local name = char.name or "this character"
    local who = CLASS_PLURAL[char.class or ""] or (name .. "'s class")

    if reason == R.NOT_IN_RAID or reason == R.NOT_PRESENT then
        return name .. " is not in the raid"
    elseif reason == R.CONTESTED then
        return char.contestReason or (name .. " is contested")
    elseif reason == R.WRONG_CLASS_TOKEN then
        return who .. " can't use this token"
    elseif reason == R.WRONG_ARMOR then
        return who .. " can't wear " .. subclassText(info.armorSubclass)
    elseif reason == R.WRONG_WEAPON then
        return who .. " can't use " .. subclassText(info.weaponSubclass)
    end
    return tostring(reason)
end

--- One cell: may this character be entered for this item, given the local tick?
--
-- @param info    the item's itemInfo, or nil while it is still being looked up
-- @param char    { name, class, present, contested, contestReason }
-- @param tick    { override, star } when the cell is ticked locally, else nil
-- @param config  { filterEnabled }
-- @return { enterable, ticked, override, star, reason, overridable, text }
function RollWindow.CellState(info, char, tick, config)
    config = config or {}
    local state = {
        ticked = tick ~= nil,
        override = (tick ~= nil and tick.override) and true or false,
        star = (tick ~= nil and tick.star) and true or false,
        overridable = false,
    }

    local ok, reason = ns.Eligibility.check(info,
        { name = char.name, class = char.class, present = char.present,
          contested = char.contested },
        { filterEnabled = config.filterEnabled ~= false, override = state.override })

    if ok then
        state.enterable = true
        if info == nil then
            state.text = "Still looking this item up."
        elseif state.override then
            state.text = "Entered with the eligibility filter overridden."
        elseif info.special then
            state.text = "Eligibility filter off for this item - check yourself."
        end
    else
        state.enterable = false
        state.reason = reason
        state.overridable = C.OVERRIDABLE_REASON[reason] == true
        state.text = RollWindow.ReasonText(reason, char, info)
    end
    return state
end

--------------------------------------------------------------------------------
-- Pure: the submission (section 3, "Footer") and the dirty check
--------------------------------------------------------------------------------

--- The complete entry set the grid represents, in item order then name order.
-- @param ticks  itemIdx -> charName -> { override, star }
-- @param items  the round's items
-- @return array of { itemIdx, char, override, star }
function RollWindow.LocalEntries(ticks, items)
    local out = {}
    for i = 1, #items do
        local idx = items[i].idx
        local byChar = ticks[idx]
        if byChar then
            local names = {}
            for name in pairs(byChar) do names[#names + 1] = name end
            table.sort(names)
            for _, name in ipairs(names) do
                local tick = byChar[name]
                out[#out + 1] = { itemIdx = idx, char = name,
                                  override = tick.override and true or false,
                                  star = tick.star and true or false }
            end
        end
    end
    return out
end

local function pairSignature(entries)
    local keys = {}
    for _, e in ipairs(entries) do
        keys[#keys + 1] = tostring(e.itemIdx) .. "/" .. tostring(e.char):lower()
    end
    table.sort(keys)
    return table.concat(keys, ",")
end

local function flagSignature(entries)
    local keys = {}
    for _, e in ipairs(entries) do
        keys[#keys + 1] = tostring(e.itemIdx) .. "/" .. tostring(e.char):lower()
            .. (e.override and "!" or "") .. (e.star and "*" or "")
    end
    table.sort(keys)
    return table.concat(keys, ",")
end

--- Do the local ticks differ from what the host has accepted for this player?
--
-- (item, character) pairs are compared against STATE, which carries nothing else. The
-- override and star flags are compared against what this client last sent: a moved
-- star is a material change under SK (spec 010 section 7) that STATE cannot reflect.
-- @param lastSent  the entries of the last SUBMIT, or nil before the first
function RollWindow.IsDirty(localEntries, accepted, lastSent)
    if pairSignature(localEntries) ~= pairSignature(accepted) then return true end
    if lastSent and flagSignature(localEntries) ~= flagSignature(lastSent) then return true end
    return false
end

--- This player's entries as the host last reported them.
-- @param entries  round.entries: itemIdx -> array of { char, owner, tier }
function RollWindow.AcceptedFor(entries, me)
    local out = {}
    local key = me and me:lower() or ""
    for itemIdx, list in pairs(entries or {}) do
        for _, e in ipairs(list) do
            if e.owner and e.owner:lower() == key then
                out[#out + 1] = { itemIdx = itemIdx, char = e.char, tier = e.tier }
            end
        end
    end
    return out
end

--- "4/6 in", and who the six-minus-four are.
-- @param expected  array of player names the host is waiting on
-- @param submitted set of player name -> true, from STATE
-- @return inCount, total, outstanding names (sorted)
function RollWindow.Outstanding(expected, submitted)
    local inCount, outstanding = 0, {}
    for _, name in ipairs(expected or {}) do
        if submitted and submitted[name] then
            inCount = inCount + 1
        else
            outstanding[#outstanding + 1] = name
        end
    end
    table.sort(outstanding)
    return inCount, #(expected or {}), outstanding
end

--------------------------------------------------------------------------------
-- Pure: the detail panel (section 3) and the results table (section 5)
--------------------------------------------------------------------------------

--- The accepted entries for one item, in the order the panel lists them.
-- Under ROLL: by tier, then owner, then name. Under SK: by list position, so the
-- outcome is legible before submission; unknown positions sort last.
-- @param priority  charName -> list index, from the host's SKLIST, or nil
function RollWindow.DetailRows(entries, isSK, priority)
    local rows = {}
    for _, e in ipairs(entries or {}) do
        local listIdx = priority and priority[e.char] or nil
        rows[#rows + 1] = { char = e.char, owner = e.owner, tier = e.tier, listIdx = listIdx }
    end
    table.sort(rows, function(a, b)
        if a.tier ~= b.tier then return a.tier < b.tier end
        if isSK then
            local ai, bi = a.listIdx or math.huge, b.listIdx or math.huge
            if ai ~= bi then return ai < bi end
        end
        local ao, bo = a.owner or "", b.owner or ""
        if ao ~= bo then return ao < bo end
        return a.char < b.char
    end)
    return rows
end

local function finalRoll(row)
    local rerolled = row.rerolled or {}
    if #rerolled > 0 then return rerolled[#rerolled] end
    return row.roll or 0
end

--- Everything the results view shows for one item.
--
-- @param itemIdx   which item
-- @param results   decoded RESULT rows (itemIdx, winner, tier, roll, outcome)
-- @param rolls     decoded ROLLS rows (itemIdx, char, tier, roll, listIdx, status, rerolled)
-- @param owners    charName (lower) -> owning player, from STATE
-- @param isSK      loot mode
-- @return { unclaimed, degraded, winners = { { char, owner, tier, roll, listIdx, copy } },
--           rows = { { char, owner, tier, roll, final, listIdx, status, rerolled, won,
--                      wonItemIdx } } }
function RollWindow.ResultTable(itemIdx, results, rolls, owners, isSK)
    owners = owners or {}
    local out = { unclaimed = false, degraded = false, winners = {}, rows = {} }

    local wonHere = {}
    local wonElsewhere = {}          -- charName (lower) -> itemIdx, for "withdrawn (won X)"
    for _, r in ipairs(results or {}) do
        if r.itemIdx == itemIdx then
            if r.outcome == C.OUTCOME.UNCLAIMED then
                out.unclaimed = true
            else
                if r.outcome == C.OUTCOME.DEGRADED then out.degraded = true end
                local key = (r.winner or ""):lower()
                wonHere[key] = true
                out.winners[#out.winners + 1] = {
                    char = r.winner, owner = owners[key], tier = r.tier, roll = r.roll,
                    copy = #out.winners + 1,
                }
            end
        elseif r.winner and r.winner ~= "" then
            wonElsewhere[r.winner:lower()] = r.itemIdx
        end
    end

    for _, r in ipairs(rolls or {}) do
        if r.itemIdx == itemIdx then
            local key = r.char:lower()
            local row = {
                char = r.char, owner = owners[key], tier = r.tier, roll = r.roll,
                final = finalRoll(r), listIdx = r.listIdx,
                status = r.status or C.ROLL_STATUS.ROLLED, rerolled = r.rerolled or {},
                won = wonHere[key] == true,
                wonItemIdx = wonElsewhere[key],
            }
            out.rows[#out.rows + 1] = row
            if row.won then
                for _, w in ipairs(out.winners) do
                    if w.char:lower() == key then w.listIdx = r.listIdx end
                end
            end
        end
    end

    -- Sorted by tier, rolled entries before not-rolled ones, then roll descending
    -- (ROLL) or list position ascending (SK), then name for a stable table.
    table.sort(out.rows, function(a, b)
        if a.tier ~= b.tier then return a.tier < b.tier end
        local ar, br = a.status == C.ROLL_STATUS.ROLLED, b.status == C.ROLL_STATUS.ROLLED
        if ar ~= br then return ar end
        if isSK then
            if a.listIdx ~= b.listIdx then return a.listIdx < b.listIdx end
        else
            if a.final ~= b.final then return a.final > b.final end
        end
        return a.char < b.char
    end)
    return out
end

--- The right-hand text of one results row (section 5).
-- @param tierLabel  Tiers.label of the row's tier under the round's tier count
-- @param wonLabel   label of the item the character won instead, for a withdrawn row
function RollWindow.RowText(row, isSK, tierLabel, wonLabel)
    if row.status == C.ROLL_STATUS.NOT_CONSULTED then
        return tierLabel .. " - not consulted"
    elseif row.status == C.ROLL_STATUS.WITHDRAWN then
        return "withdrawn (won " .. (wonLabel or "another item") .. ")"
    end
    if isSK then
        local text = "position " .. tostring(row.listIdx)
        if row.won then text = text .. " -> bottom" end
        return text
    end
    local rerolled = row.rerolled or {}
    if #rerolled == 0 then return tostring(row.roll) end
    local parts = { tostring(row.roll) }
    for _, value in ipairs(rerolled) do parts[#parts + 1] = tostring(value) end
    return table.concat(parts, " -> ") .. " (tie re-roll)"
end

--- Seconds remaining, as "m:ss".
function RollWindow.FormatCountdown(seconds)
    seconds = math.max(0, math.floor((seconds or 0) + 0.5))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

--- Is a list position "near the top" (spec 010 section 11)?
--
-- The rule itself lives in Core/PriorityList so that this window and the list
-- viewer cannot drift apart on it (spec 011 section 4). Kept here as the name 005
-- and its fixtures already use.
function RollWindow.AboveMedian(position, presentPositions)
    return ns.PriorityList.aboveMedian(position, presentPositions)
end

--------------------------------------------------------------------------------
-- WoW-facing. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

local Widgets = ns.Widgets          -- nil under the fixture runner, which never renders

local HEADER_W = 150           -- the frozen row header
local CELL_W = 56
local ROW_H = 26
local COL_HEADER_H = 40
local MAX_VISIBLE_COLS = 6     -- past this the columns scroll (section 3)
local DETAIL_H = 84
local TOGGLE_GAP = 22          -- below the grid; the horizontal slider lives in it
local TOGGLE_H = 20
local WARN_H = 16
local BUTTON_H = 22
local PAD = 16
local RESULTS_H = 380

local frame
local entryPanel, resultsPanel
local rowHeaders, colHeaderScroll, colHeaderContent, cellScroll, cellContent, hslider
local rows, columns, cells = {}, {}, {}
local resultRows = {}
local selectedIdx
local infoByIdx, infoRoundId = {}, nil
local lastShownRoundId
local lastSentRoundId
local abortHideAt
local countdownAccumulator = 0

local function DB() return ns.Database end

--------------------------------------------------------------------------------
-- Scratch ticks (section 6): survive a /reload through saved variables
--------------------------------------------------------------------------------

local function scratchFor(round)
    local scratch = DB().Scratch()
    if scratch.roundId ~= round.id then
        scratch.roundId = round.id
        scratch.ticks = {}
    end
    return scratch.ticks
end

local function getTick(round, itemIdx, char)
    local ticks = scratchFor(round)
    return ticks[itemIdx] and ticks[itemIdx][char] or nil
end

local function setTick(round, itemIdx, char, tick)
    local ticks = scratchFor(round)
    ticks[itemIdx] = ticks[itemIdx] or {}
    ticks[itemIdx][char] = tick
    if tick == nil and next(ticks[itemIdx]) == nil then ticks[itemIdx] = nil end
end

local function clearStars(round, char)
    for _, byChar in pairs(scratchFor(round)) do
        if byChar[char] then byChar[char].star = nil end
    end
end

--------------------------------------------------------------------------------
-- Reading the round
--------------------------------------------------------------------------------

local function currentRound()
    return ns.Client and ns.Client.round or nil
end

local function isSK(round)
    return round.lootMode == C.LOOT_MODE.SK          -- OPEN carries it (spec 010 section 8)
end

local function me()
    return UnitName("player")
end

--- Item info for a round item, requesting it on first sight. nil until it arrives.
local function infoFor(round, item)
    if infoRoundId ~= round.id then
        infoByIdx, infoRoundId = {}, round.id
    end
    local info = infoByIdx[item.idx]
    if info then return info end
    if not infoByIdx["pending" .. item.idx] then
        infoByIdx["pending" .. item.idx] = true
        -- A cached item answers synchronously. Refreshing from inside a refresh would
        -- rebuild the grid once per item, nested; the caller is mid-refresh and will
        -- read the answer itself.
        local immediate = true
        ns.ItemInfo.Request(item.itemString, function(result)
            if infoRoundId ~= round.id then return end
            infoByIdx[item.idx] = result
            if not immediate then RollWindow.Refresh() end
        end)
        immediate = false
    end
    return infoByIdx[item.idx]
end

local function itemLabel(round, item)
    local info = item and infoFor(round, item)
    if info and info.link then return info.link end
    if info and info.name then return "[" .. info.name .. "]" end
    return item and item.itemString or "an item"
end

local function itemByIdx(round, idx)
    for _, item in ipairs(round.items) do
        if item.idx == idx then return item end
    end
    return nil
end

--- This player's roster rows, with what the grid needs to know about each.
local function rosterRows(round)
    local roster = DB().Roster()
    local Roster = ns.Roster
    local out = {}
    for i, name in ipairs(roster.order) do
        local entry = roster.chars[name] or {}
        local claim = Roster.claims[name:lower()]
        out[i] = {
            name = name, class = entry.class, isSelf = entry.isSelf,
            position = i,
            tier = ns.Tiers.forPosition(i, round.tierCount),
            present = Roster.IsPresent(name),
            contested = Roster.IsContested(name),
            contestReason = (claim and claim.contested) and Roster.ContestReason(claim) or nil,
        }
    end
    return out
end

--- charName (lower) -> owner, from the last STATE, falling back to the claim index.
local function ownersFor(round)
    local owners = {}
    for _, list in pairs(round.entries or {}) do
        for _, e in ipairs(list) do
            if e.owner then owners[e.char:lower()] = e.owner end
        end
    end
    for key, claim in pairs(ns.Roster.claims) do
        if not owners[key] and not claim.contested then owners[key] = claim.owners[1] end
    end
    return owners
end

local function colouredChar(char)
    return Widgets.ColorName(char, ns.Roster.ClassOfAny(char))
end

--- Players the host is waiting on: group members running a compatible addon.
local function expectedPlayers()
    local expected = {}
    for _, member in ipairs(ns.Roster.GroupMembers()) do
        if member.name and (ns.Round.peers[member.name] or member.isSelf) then
            expected[#expected + 1] = member.name
        end
    end
    return expected
end

--------------------------------------------------------------------------------
-- Building the grid
--------------------------------------------------------------------------------

local function selectColumn(idx)
    selectedIdx = idx
    RollWindow.Refresh()
end

local function onCellClick(cell, button)
    local round = currentRound()
    if not round or round.state ~= C.ROUND_STATE.OPEN then return end
    local state = cell.state
    local itemIdx, char = cell.itemIdx, cell.charName
    if not state then return end

    if button == "RightButton" then
        -- Override: only on a cell the eligibility filter refused, and only for the
        -- overridable reasons (spec 003 section 8). Right-click does nothing else.
        if state.override then
            setTick(round, itemIdx, char, nil)
        elseif state.overridable then
            setTick(round, itemIdx, char, { override = true })
        else
            return
        end
    else
        if state.ticked then
            setTick(round, itemIdx, char, nil)
        elseif state.enterable then
            setTick(round, itemIdx, char, {})
        else
            return
        end
    end
    selectColumn(itemIdx)
end

local function onStarClick(star)
    local round = currentRound()
    if not round or round.state ~= C.ROUND_STATE.OPEN then return end
    local cell = star:GetParent()
    local tick = getTick(round, cell.itemIdx, cell.charName)
    if not tick then return end
    local wasStarred = tick.star
    clearStars(round, cell.charName)
    if not wasStarred then tick.star = true end
    RollWindow.Refresh()
end

local function createCell()
    local cell = CreateFrame("Button", nil, cellContent)
    cell:SetWidth(CELL_W)
    cell:SetHeight(ROW_H)
    cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    cell:SetScript("OnClick", onCellClick)

    cell.box = cell:CreateTexture(nil, "ARTWORK")
    cell.box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cell.box:SetWidth(22)
    cell.box:SetHeight(22)
    cell.box:SetPoint("CENTER", cell, "CENTER", 0, 0)

    cell.check = cell:CreateTexture(nil, "OVERLAY")
    cell.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    cell.check:SetAllPoints(cell.box)

    -- The override marker: a distinct border rather than a different check.
    cell.border = cell:CreateTexture(nil, "OVERLAY")
    cell.border:SetTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
    cell.border:SetAllPoints(cell.box)
    cell.border:SetVertexColor(1, 0.6, 0.1, 1)
    cell.border:SetBlendMode("ADD")

    cell.star = CreateFrame("Button", nil, cell)
    cell.star:SetWidth(14)
    cell.star:SetHeight(14)
    cell.star:SetPoint("TOPRIGHT", cell, "TOPRIGHT", -2, -1)
    cell.star.icon = cell.star:CreateTexture(nil, "OVERLAY")
    cell.star.icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
    cell.star.icon:SetAllPoints()
    cell.star:SetScript("OnClick", onStarClick)
    Widgets.Tooltip(cell.star, "Priority pick",
        "Star the one item this character should take if it would win several.")

    cell:SetScript("OnEnter", function(self)
        if not self.tooltipTitle then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tooltipTitle, 1, 1, 1)
        if self.tooltipBody then GameTooltip:AddLine(self.tooltipBody, nil, nil, nil, true) end
        if self.tooltipHint then GameTooltip:AddLine(self.tooltipHint, 0.6, 0.6, 0.6, true) end
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return cell
end

local function createRowHeader()
    local row = CreateFrame("Frame", nil, rowHeaders)
    row:SetWidth(HEADER_W)
    row:SetHeight(ROW_H)

    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    row.stripe:SetTexture(1, 1, 1, 0.04)

    row.badge = Widgets.Label(row, "", "GameFontNormalSmall")
    row.badge:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.badge:SetWidth(30)
    row.badge:SetJustifyH("LEFT")

    row.dot = Widgets.Dot(row, 10)
    row.dot:SetPoint("LEFT", row, "LEFT", 36, 0)

    row.name = Widgets.Label(row, "", "GameFontNormal")
    row.name:SetPoint("LEFT", row, "LEFT", 50, 0)
    row.name:SetWidth(72)
    row.name:SetJustifyH("LEFT")

    row.position = Widgets.Label(row, "", "GameFontNormalSmall")
    row.position:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.position:SetWidth(26)
    row.position:SetJustifyH("RIGHT")
    return row
end

local function onColumnClick(column)
    local round = currentRound()
    if not round then return end
    local item = itemByIdx(round, column.itemIdx)
    local info = item and infoFor(round, item)
    if IsShiftKeyDown() and info and info.link then
        if not ChatEdit_InsertLink(info.link) then ns.Print(info.link) end
        return
    end
    selectColumn(column.itemIdx)
end

-- The column is the icon and nothing else. A name under it never fitted a 56px
-- cell -- "Shadowfrost..." told nobody which shard it was -- and the hover tooltip
-- is the item's own, which says it in full.
local function createColumn()
    local column = CreateFrame("Button", nil, colHeaderContent)
    column:SetWidth(CELL_W)
    column:SetHeight(COL_HEADER_H)
    column:SetScript("OnClick", onColumnClick)

    column.selected = column:CreateTexture(nil, "BACKGROUND")
    column.selected:SetAllPoints()
    column.selected:SetTexture(1, 0.82, 0, 0.15)

    column.icon = column:CreateTexture(nil, "ARTWORK")
    column.icon:SetWidth(32)
    column.icon:SetHeight(32)
    column.icon:SetPoint("CENTER", column, "CENTER", 0, 0)

    column.count = Widgets.Label(column, "", "GameFontNormalSmall")
    column.count:SetPoint("BOTTOMRIGHT", column.icon, "BOTTOMRIGHT", 2, -2)

    column.special = Widgets.Label(column, "|cffffcc00*|r", "GameFontNormal")
    column.special:SetPoint("TOPLEFT", column.icon, "TOPLEFT", -6, 4)

    column:SetScript("OnEnter", function(self)
        local round = currentRound()
        local item = round and itemByIdx(round, self.itemIdx)
        if not item then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(item.itemString)
        local info = infoFor(round, item)
        if info and info.special then
            GameTooltip:AddLine("Eligibility filter off - check yourself.", 1, 0.8, 0, true)
        end
        GameTooltip:AddLine("Click to see who has entered. Shift-click to link it in chat.",
            0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    column:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return column
end

local function setHorizontalScroll(x)
    colHeaderScroll:SetHorizontalScroll(x)
    cellScroll:SetHorizontalScroll(x)
end

--------------------------------------------------------------------------------
-- Entry mode refresh
--------------------------------------------------------------------------------

local function refreshEntry(round)
    local settings = DB().Settings()
    local sk = isSK(round)
    local items = round.items
    local roster = rosterRows(round)
    local hideIneligible = entryPanel.hideToggle:GetChecked() == 1
    local visibleCols = math.min(#items, MAX_VISIBLE_COLS)

    -- Which item is selected: keep the selection when it still exists.
    if not selectedIdx or not itemByIdx(round, selectedIdx) then
        selectedIdx = items[1] and items[1].idx or nil
    end

    -- Present characters' list positions, for the SK median.
    local presentPositions = {}
    if sk and round.priority then
        for name, position in pairs(round.priority) do
            if ns.Roster.IsPresent(name) then presentPositions[#presentPositions + 1] = position end
        end
    end

    -- Columns.
    for _, column in ipairs(columns) do column:Hide() end
    for c, item in ipairs(items) do
        local column = columns[c]
        if not column then
            column = createColumn()
            columns[c] = column
        end
        column.itemIdx = item.idx
        column:ClearAllPoints()
        column:SetPoint("TOPLEFT", colHeaderContent, "TOPLEFT", (c - 1) * CELL_W, 0)
        local info = infoFor(round, item)
        column.icon:SetTexture(info and info.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        column.count:SetText(item.count > 1 and ("x" .. item.count) or "")
        if info and info.special then column.special:Show() else column.special:Hide() end
        if item.idx == selectedIdx then column.selected:Show() else column.selected:Hide() end
        column:Show()
    end
    colHeaderContent:SetWidth(math.max(#items, 1) * CELL_W)

    -- Rows and cells.
    for _, row in ipairs(rows) do row:Hide() end
    for _, line in ipairs(cells) do
        for _, cell in ipairs(line) do cell:Hide() end
    end

    local y = 0
    for r, char in ipairs(roster) do
        local row = rows[r]
        if not row then
            row = createRowHeader()
            rows[r] = row
        end
        cells[r] = cells[r] or {}

        local rowEnterable, rowTicked = false, false
        for c, item in ipairs(items) do
            local cell = cells[r][c]
            if not cell then
                cell = createCell()
                cells[r][c] = cell
            end
            local info = infoFor(round, item)
            local tick = getTick(round, item.idx, char.name)
            local state = RollWindow.CellState(info, char, tick,
                { filterEnabled = settings.eligibilityFilter })
            cell.state, cell.itemIdx, cell.charName = state, item.idx, char.name
            if state.enterable then rowEnterable = true end
            if state.ticked then rowTicked = true end

            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", cellContent, "TOPLEFT", (c - 1) * CELL_W, -y)
            cell.box:SetAlpha(state.enterable and 1 or 0.3)
            if state.ticked then cell.check:Show() else cell.check:Hide() end
            if state.override then cell.border:Show() else cell.border:Hide() end
            if sk and state.ticked then
                cell.star:Show()
                cell.star.icon:SetAlpha(state.star and 1 or 0.25)
            else
                cell.star:Hide()
            end

            local label = itemLabel(round, item)
            if state.enterable then
                cell.tooltipTitle = char.name .. " for " .. label
                cell.tooltipBody = state.text
                cell.tooltipHint = state.ticked and "Left-click to withdraw."
                    or "Left-click to enter."
            else
                cell.tooltipTitle = char.name .. " for " .. label
                cell.tooltipBody = "|cffff6060" .. (state.text or "Not enterable") .. "|r"
                cell.tooltipHint = state.overridable
                    and "Right-click to override the filter for this entry." or nil
            end
        end

        local show = not hideIneligible or rowEnterable or rowTicked
        if show then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", rowHeaders, "TOPLEFT", 0, -y)
            local tierLabel = ns.Tiers.label(char.tier, round.tierCount)
            local rest = ns.Tiers.isRest(char.tier, round.tierCount)
            row.badge:SetText((rest and "|cffe6b422" or "|cffaaaaaa") .. tierLabel .. "|r")
            local name = Widgets.ColorName(char.name, char.class)
            if char.isSelf then name = name .. " |cff888888*|r" end
            row.name:SetText(name)
            Widgets.SetDotPresent(row.dot, char.present)
            row:SetAlpha(char.present and 1 or 0.5)
            if sk then
                local position = round.priority and round.priority[char.name] or nil
                if not position then
                    row.position:SetText("|cff888888?|r")
                elseif RollWindow.AboveMedian(position, presentPositions) then
                    row.position:SetText("|cff66ff66#" .. position .. "|r")
                else
                    row.position:SetText("|cffaaaaaa#" .. position .. "|r")
                end
            else
                row.position:SetText("")
            end
            row:Show()
            for c = 1, #items do cells[r][c]:Show() end
            y = y + ROW_H
        end
    end

    local gridH = math.max(y, ROW_H)
    rowHeaders:SetHeight(gridH)
    cellContent:SetHeight(gridH)
    cellContent:SetWidth(math.max(#items, 1) * CELL_W)
    cellScroll:SetHeight(gridH)
    cellScroll:SetWidth(visibleCols * CELL_W)
    colHeaderScroll:SetWidth(visibleCols * CELL_W)

    -- The horizontal slider only when the columns overflow.
    if #items > MAX_VISIBLE_COLS then
        hslider:SetMinMaxValues(0, (#items - MAX_VISIBLE_COLS) * CELL_W)
        hslider:SetWidth(visibleCols * CELL_W)
        hslider:Show()
        setHorizontalScroll(hslider:GetValue())
    else
        hslider:Hide()
        setHorizontalScroll(0)
    end

    -- Detail panel: who the host has accepted for the selected item (STATE only).
    local item = selectedIdx and itemByIdx(round, selectedIdx)
    if item then
        local lines = { "Selected: " .. itemLabel(round, item) }
        local detail = RollWindow.DetailRows(round.entries[item.idx], sk, round.priority)
        if #detail == 0 then
            lines[#lines + 1] = "|cff888888No entries accepted yet.|r"
        else
            local parts = {}
            for _, d in ipairs(detail) do
                local text = ns.Tiers.label(d.tier, round.tierCount) .. "  "
                    .. colouredChar(d.char) .. " (" .. tostring(d.owner or "?") .. ")"
                if sk then
                    text = text .. " |cff888888#" .. tostring(d.listIdx or "?") .. "|r"
                end
                parts[#parts + 1] = text
            end
            lines[#lines + 1] = table.concat(parts, "     ")
        end
        if sk and not round.priority then
            lines[#lines + 1] = "|cffff8800List positions unknown: the host's list has not arrived.|r"
        end
        entryPanel.detail:SetText(table.concat(lines, "\n"))
    else
        entryPanel.detail:SetText("")
    end

    -- Footer.
    if sk then entryPanel.fullList:Show() else entryPanel.fullList:Hide() end
    local myName = me()
    local localEntries = RollWindow.LocalEntries(scratchFor(round), items)
    local accepted = RollWindow.AcceptedFor(round.entries, myName)
    local submitted = round.submitted[myName] == true or lastSentRoundId == round.id
    entryPanel.submit:SetText(submitted and "Revise" or
        string.format("Submit %d entr%s", #localEntries, #localEntries == 1 and "y" or "ies"))
    local dirty = submitted and RollWindow.IsDirty(localEntries, accepted, ns.Client.LastSent())
    entryPanel.dirty:SetText(dirty and "|cffffaa00unsent changes|r" or "")

    -- Read-only: this round belongs to a campaign this client is not in, so there is
    -- nothing to submit (spec 012 section 6). The controls are disabled rather than
    -- hidden, so the window still shows what is being rolled for.
    if round.readOnly then
        entryPanel.submit:Disable()
        entryPanel.pass:Disable()
    else
        entryPanel.submit:Enable()
        entryPanel.pass:Enable()
    end

    if round.lastRejected and #round.lastRejected > 0 then
        entryPanel.warning:SetText("|cffff6060The host refused: "
            .. table.concat(round.lastRejected, ", ") .. "|r")
    elseif round.priorityNotice then
        entryPanel.warning:SetText("|cffffaa00" .. round.priorityNotice .. "|r")
    else
        entryPanel.warning:SetText("")
    end

    -- Window size follows the grid. The terms are the entry panel's anchors, top to
    -- bottom: column header, grid, the gap holding the slider, the toggle, the detail
    -- panel, the warning line, the buttons.
    local width = PAD * 2 + HEADER_W + visibleCols * CELL_W + 8
    local height = 70 + COL_HEADER_H + gridH + TOGGLE_GAP + TOGGLE_H + 4 + DETAIL_H
        + 2 + WARN_H + 6 + BUTTON_H + PAD
    frame:SetWidth(math.max(width, 420))
    frame:SetHeight(height)
end

--------------------------------------------------------------------------------
-- Results mode refresh (section 5)
--------------------------------------------------------------------------------

local function resultRow(pool, content, i)
    local row = pool[i]
    if row then return row end
    row = CreateFrame("Frame", nil, content)
    row:SetHeight(16)
    row:SetWidth(content:GetWidth() - Widgets.SCROLLBAR_GUTTER)
    row.left = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.left:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.left:SetJustifyH("LEFT")
    row.left:SetWidth(300)
    row.right = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.right:SetJustifyH("RIGHT")
    row.right:SetWidth(160)
    row.award = Widgets.Button(row, "Award", 64, 18, function(self)
        if not ns.Award then return end
        if self.action == "deliver" then
            local record = ns.Award.Get(self.roundId, self.itemIdx, self.copy)
            for _, pending in ipairs(ns.Pending.OutstandingRecords()) do
                if record and pending.roundId == record.roundId
                    and pending.itemIdx == record.itemIdx and pending.copy == record.copy then
                    ns.Pending.Deliver(pending)
                    return
                end
            end
            ns.Print("no pending record for that item; see /rls pending.")
        else
            ns.Award.Prompt(self.roundId, self.itemIdx, self.copy, IsShiftKeyDown())
        end
    end)
    row.award:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.award:RegisterForClicks("LeftButtonUp")
    Widgets.Tooltip(row.award, "Award",
        "Give the item to the winner. Click for the corpse (master loot); shift-click to take "
        .. "it into your bags and trade it instead.")
    row.award:Hide()
    row.status = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.status:SetPoint("RIGHT", row.award, "LEFT", -6, 0)
    row.status:SetJustifyH("RIGHT")
    row.status:Hide()
    pool[i] = row
    return row
end

--- Render a results view into `content`, reusing `pool`'s rows. One rendering
-- component for the roll window and the history browser (spec 008 section 5).
--
-- @param view { roundId, items = { { idx, itemString, count, label } }, results, rolls,
--               owners, isSK, tierCount, host, awardRecord = function(itemIdx, copy),
--               outcome, abortReason }
-- @return the rendered height
function RollWindow.RenderResults(content, pool, view)
    local sk = view.isSK
    local n, y = 0, 0

    local function line(left, right, height, font)
        n = n + 1
        local row = resultRow(pool, content, n)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        row:SetWidth(content:GetWidth())
        row:SetHeight(height or 16)
        row.left:SetFontObject(font or "GameFontHighlightSmall")
        row.left:SetText(left or "")
        row.right:SetText(right or "")
        row.award:Hide()
        row.status:Hide()
        row.right:Show()
        row:Show()
        y = y + (height or 16)
        return row
    end

    local function labelOf(idx)
        for _, item in ipairs(view.items) do
            if item.idx == idx then return item.label or item.itemString end
        end
        return "another item"
    end

    if view.outcome == "ABORTED" then
        line("|cffff6060Cancelled: " .. (C.ABORT_TEXT[view.abortReason] or tostring(view.abortReason)) .. "|r",
            "", 20, "GameFontNormal")
    end

    for _, item in ipairs(view.items) do
        local table_ = RollWindow.ResultTable(item.idx, view.results, view.rolls, view.owners, sk)
        local header = (item.label or item.itemString) .. (item.count > 1 and (" x" .. item.count) or "")
        line(header, table_.degraded and "|cffff6600degraded: re-rolls exhausted|r" or "",
            20, "GameFontNormal")

        if table_.unclaimed then
            line("   |cff888888No entries - master looter's choice|r", "")
        end
        for _, w in ipairs(table_.winners) do
            local text = "   |cff66ff66Winner|r " .. colouredChar(w.char)
                .. " (" .. tostring(w.owner or "?") .. ") "
                .. ns.Tiers.label(w.tier, view.tierCount)
            local right = sk and ("position " .. tostring(w.listIdx or "?") .. " -> bottom")
                or ("roll " .. tostring(w.roll))
            if item.count > 1 then text = text .. "  |cff888888copy " .. w.copy .. "|r" end
            local row = line(text, right)
            local record = view.awardRecord and view.awardRecord(item.idx, w.copy) or nil
            if record then
                -- The delivery state (spec 007), and for the host the one action it
                -- allows next. Nobody else sees the control.
                local D = C.DELIVERY
                local colour = record.delivery == D.DELIVERED and "|cff66ff66"
                    or record.delivery == D.PENDING and "|cffffaa00"
                    or (record.delivery == D.FAILED or record.delivery == D.LOST) and "|cffff6060"
                    or "|cffaaaaaa"
                row.status:SetText(colour .. ns.Award.StatusText(record) .. "|r")
                if view.host then
                    row.right:Hide()
                    row.award.roundId, row.award.itemIdx, row.award.copy =
                        view.roundId, item.idx, w.copy
                    if record.delivery == D.DELIVERED then
                        row.award:Hide()
                    elseif record.delivery == D.PENDING then
                        row.award.action = "deliver"
                        row.award:SetText("Deliver")
                        row.award:Show()
                    else
                        row.award.action = "award"
                        row.award:SetText(record.delivery == D.AWAITING and "Award" or "Retry")
                        if ns.Award.Retryable(record) then row.award:Show() else row.award:Hide() end
                    end
                    row.status:ClearAllPoints()
                    row.status:SetPoint("RIGHT", row.award:IsShown() and row.award or row, "LEFT", -6, 0)
                    if not row.award:IsShown() then
                        row.status:SetPoint("RIGHT", row, "RIGHT", -4, 0)
                    end
                else
                    row.right:SetText(right .. "  " .. colour .. ns.Award.StatusText(record) .. "|r")
                end
                if view.host then row.status:Show() end
            end
        end
        for _, r in ipairs(table_.rows) do
            local tierLabel = ns.Tiers.label(r.tier, view.tierCount)
            local right = RollWindow.RowText(r, sk, tierLabel,
                r.wonItemIdx and labelOf(r.wonItemIdx) or nil)
            local left = "      " .. tierLabel .. "  " .. colouredChar(r.char)
                .. " |cff888888(" .. tostring(r.owner or "?") .. ")|r"
            if r.status ~= C.ROLL_STATUS.ROLLED then
                left = "|cff777777" .. left .. "|r"
                right = "|cff777777" .. right .. "|r"
            end
            line(left, right)
        end
        if not view.rolls then
            line("      |cff888888waiting for the roll record...|r", "")
        end
        y = y + 6
    end

    for i = n + 1, #pool do pool[i]:Hide() end
    content:SetHeight(math.max(y, 1))
    return y
end

local function refreshResults(round)
    local items = {}
    for i, item in ipairs(round.items) do
        items[i] = { idx = item.idx, itemString = item.itemString, count = item.count,
                     label = itemLabel(round, item) }
    end
    local host = ns.Round.IsHost() and ns.Award ~= nil
    RollWindow.RenderResults(resultsPanel.content, resultRows, {
        roundId = round.id, items = items,
        results = round.results, rolls = round.rolls, owners = ownersFor(round),
        isSK = isSK(round), tierCount = round.tierCount, host = host,
        awardRecord = host and function(itemIdx, copy)
            return ns.Award.Get(round.id, itemIdx, copy)
        end or nil,
    })

    frame:SetWidth(PAD * 2 + HEADER_W + MAX_VISIBLE_COLS * CELL_W + 8)
    frame:SetHeight(70 + RESULTS_H + PAD)
end

--------------------------------------------------------------------------------
-- Refresh: pick the mode
--------------------------------------------------------------------------------

function RollWindow.Refresh()
    if not frame or not frame:IsShown() then return end
    local round = currentRound()
    if not round then
        frame.titleText:SetText("Raid Loot System - no round")
        frame.status:SetText("")
        frame.counter:SetText("")
        entryPanel:Hide()
        resultsPanel:Hide()
        frame.banner:SetText("There is no round open and no results to show.")
        return
    end

    local hostLabel = round.host and (round.host .. "'s round") or "Round"
    frame.titleText:SetText(string.format("%s - %s - %d item%s", hostLabel,
        round.campaignLabel or ns.Campaign.ActiveLabel(), #round.items,
        #round.items == 1 and "" or "s"))

    local inCount, total, outstanding = RollWindow.Outstanding(expectedPlayers(), round.submitted)
    frame.counter:SetText(string.format("%d/%d in", inCount, total))
    frame.counter.outstanding = outstanding

    if round.state == C.ROUND_STATE.OPEN then
        -- A round in a campaign this client is not in opens read-only, and says why
        -- (spec 012 section 6). Silence would be the worst available outcome, and
        -- this is also how a mistaken Ignore is noticed within one boss.
        frame.banner:SetText(round.readOnly and string.format(
            "|cffffaa00You are not in the campaign \"%s\". Ask the master looter to invite you.|r",
            round.campaignLabel or "?") or "")
        resultsPanel:Hide()
        entryPanel:Show()
        refreshEntry(round)
    elseif round.state == C.ROUND_STATE.CLOSED then
        frame.banner:SetText("")
        frame.status:SetText("|cff66ff66Resolved|r")
        entryPanel:Hide()
        resultsPanel:Show()
        refreshResults(round)
    elseif round.state == C.ROUND_STATE.ABORTED then
        entryPanel:Hide()
        resultsPanel:Hide()
        frame.status:SetText("")
        frame.banner:SetText("|cffff6060Round cancelled: "
            .. (C.ABORT_TEXT[round.abortReason] or tostring(round.abortReason)) .. "|r")
        frame:SetHeight(120)
    else
        frame.status:SetText("|cffffaa00Resolving...|r")
    end
end

--------------------------------------------------------------------------------
-- Submitting (section 3, footer; section 4)
--------------------------------------------------------------------------------

local function submitGrid(passAll)
    local round = currentRound()
    if not round or round.state ~= C.ROUND_STATE.OPEN then
        ns.Print("there is no round open.")
        return
    end

    local entries = {}
    if passAll then
        DB().Scratch().ticks = {}
    else
        -- A tick on a cell that has since become unenterable (the character left the
        -- raid, say) is dropped here rather than sent for the host to refuse.
        local settings = DB().Settings()
        local roster = {}
        for _, char in ipairs(rosterRows(round)) do roster[char.name] = char end
        for _, e in ipairs(RollWindow.LocalEntries(scratchFor(round), round.items)) do
            local char = roster[e.char]
            local item = itemByIdx(round, e.itemIdx)
            local state = char and RollWindow.CellState(infoFor(round, item), char,
                { override = e.override, star = e.star },
                { filterEnabled = settings.eligibilityFilter })
            if state and state.enterable then
                entries[#entries + 1] = e
            else
                ns.Print(string.format("%s was not sent for %s: %s", e.char,
                    itemLabel(round, item), state and state.text or "not in your roster"))
            end
        end
    end

    local ok, why = ns.Client.Submit(entries)
    if not ok then
        ns.Print("could not submit: " .. tostring(why))
        return
    end
    lastSentRoundId = round.id
    ns.Print(passAll and "passed on everything." or
        string.format("submitted %d entr%s.", #entries, #entries == 1 and "y" or "ies"))
    RollWindow.Refresh()
end

--------------------------------------------------------------------------------
-- Building the window
--------------------------------------------------------------------------------

local function buildEntryPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -70)
    panel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -PAD, PAD)

    -- Frozen row header on the left, the item columns to its right.
    rowHeaders = CreateFrame("Frame", nil, panel)
    rowHeaders:SetWidth(HEADER_W)
    rowHeaders:SetHeight(ROW_H)
    rowHeaders:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -COL_HEADER_H)

    colHeaderScroll = CreateFrame("ScrollFrame", nil, panel)
    colHeaderScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", HEADER_W, 0)
    colHeaderScroll:SetHeight(COL_HEADER_H)
    colHeaderScroll:SetWidth(CELL_W)
    colHeaderContent = CreateFrame("Frame", nil, colHeaderScroll)
    colHeaderContent:SetHeight(COL_HEADER_H)
    colHeaderContent:SetWidth(CELL_W)
    colHeaderScroll:SetScrollChild(colHeaderContent)

    cellScroll = CreateFrame("ScrollFrame", nil, panel)
    cellScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", HEADER_W, -COL_HEADER_H)
    cellScroll:SetHeight(ROW_H)
    cellScroll:SetWidth(CELL_W)
    cellContent = CreateFrame("Frame", nil, cellScroll)
    cellContent:SetHeight(ROW_H)
    cellContent:SetWidth(CELL_W)
    cellScroll:SetScrollChild(cellContent)
    cellScroll:EnableMouseWheel(true)
    cellScroll:SetScript("OnMouseWheel", function(_, delta)
        if hslider:IsShown() then
            hslider:SetValue(hslider:GetValue() - delta * CELL_W)
        end
    end)

    hslider = CreateFrame("Slider", "RaidLootSystemRollWindowSlider", panel, "OptionsSliderTemplate")
    hslider:SetOrientation("HORIZONTAL")
    hslider:SetHeight(16)
    hslider:SetPoint("TOPLEFT", cellScroll, "BOTTOMLEFT", 0, -2)
    hslider:SetValueStep(CELL_W)
    hslider:SetValue(0)
    hslider:SetScript("OnValueChanged", function(self, value) setHorizontalScroll(value) end)
    _G[hslider:GetName() .. "Low"]:SetText("")
    _G[hslider:GetName() .. "High"]:SetText("")
    _G[hslider:GetName() .. "Text"]:SetText("")
    hslider:Hide()

    panel.hideToggle = CreateFrame("CheckButton", "RaidLootSystemRollWindowHide", panel,
        "UICheckButtonTemplate")
    panel.hideToggle:SetWidth(TOGGLE_H)
    panel.hideToggle:SetHeight(TOGGLE_H)
    panel.hideToggle:SetPoint("TOPLEFT", rowHeaders, "BOTTOMLEFT", 0, -TOGGLE_GAP)
    _G[panel.hideToggle:GetName() .. "Text"]:SetText("Hide ineligible rows")
    panel.hideToggle:SetChecked(false)
    panel.hideToggle:SetScript("OnClick", function() RollWindow.Refresh() end)

    local detailPanel = Widgets.Panel(panel, 0.35)
    detailPanel:SetPoint("TOPLEFT", panel.hideToggle, "BOTTOMLEFT", 0, -4)
    detailPanel:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    detailPanel:SetHeight(DETAIL_H)
    panel.detail = Widgets.Label(detailPanel, "", "GameFontHighlightSmall")
    panel.detail:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 8, -6)
    panel.detail:SetPoint("BOTTOMRIGHT", detailPanel, "BOTTOMRIGHT", -8, 6)
    panel.detail:SetJustifyH("LEFT")
    panel.detail:SetJustifyV("TOP")

    panel.warning = Widgets.Label(panel, "", "GameFontHighlightSmall")
    panel.warning:SetPoint("TOPLEFT", detailPanel, "BOTTOMLEFT", 0, -2)
    panel.warning:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    panel.warning:SetHeight(WARN_H)
    panel.warning:SetJustifyH("LEFT")

    -- The buttons hang off the warning line, never off the panel bottom, so they cannot
    -- cover it whatever the grid height works out to.
    panel.pass = Widgets.Button(panel, "Pass all", 90, BUTTON_H, function()
        StaticPopup_Show("RLS_CONFIRM_PASS_ALL")
    end)
    panel.pass:SetPoint("TOPLEFT", panel.warning, "BOTTOMLEFT", 0, -6)
    Widgets.Tooltip(panel.pass, "Pass all",
        "Clear every tick and submit nothing. That still counts you as in, so the host can close.")

    -- Under SK only: the moment a player wants the whole list is the moment they
    -- are looking at their own position here and wondering who is above them.
    panel.fullList = Widgets.Button(panel, "Full list", 80, BUTTON_H, function()
        ns.PriorityViewer.Show()
    end)
    panel.fullList:SetPoint("LEFT", panel.pass, "RIGHT", 6, 0)
    Widgets.Tooltip(panel.fullList, "Full list",
        "The whole priority list, in order, read-only.")
    panel.fullList:Hide()

    panel.submit = Widgets.Button(panel, "Submit", 130, BUTTON_H, function() submitGrid(false) end)
    panel.submit:SetPoint("TOPRIGHT", panel.warning, "BOTTOMRIGHT", 0, -6)

    panel.dirty = Widgets.Label(panel, "", "GameFontHighlightSmall")
    panel.dirty:SetPoint("RIGHT", panel.submit, "LEFT", -8, 0)

    return panel
end

local function buildResultsPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -70)
    panel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -PAD, PAD)

    local width = HEADER_W + MAX_VISIBLE_COLS * CELL_W - 20
    local scroll, content = Widgets.ScrollArea(panel, "RaidLootSystemRollWindowResults",
        width, RESULTS_H)
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    panel.scroll, panel.content = scroll, content
    return panel
end

local function build()
    -- Passing marks you as in for the whole round, and every tick you had made
    -- is cleared to get there, so it asks first.
    StaticPopupDialogs["RLS_CONFIRM_PASS_ALL"] = {
        text = "Pass on every item in this round? Your ticks are cleared and you enter "
            .. "nothing. You can still submit again while the round is open.",
        button1 = "Pass all",
        button2 = CANCEL,
        OnAccept = function() submitGrid(true) end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    frame = Widgets.Window("RaidLootSystemRollWindow", "roll", "Raid Loot System",
        PAD * 2 + HEADER_W + MAX_VISIBLE_COLS * CELL_W + 8, 480)
    frame.titleText:ClearAllPoints()
    frame.titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -16)

    frame.status = Widgets.Label(frame, "", "GameFontNormal")
    frame.status:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -40, -16)
    frame.status:SetJustifyH("RIGHT")

    frame.counter = Widgets.Label(frame, "", "GameFontHighlightSmall")
    frame.counter:SetPoint("TOPRIGHT", frame.status, "BOTTOMRIGHT", 0, -4)
    frame.counter:SetJustifyH("RIGHT")
    local counterHit = CreateFrame("Frame", nil, frame)
    counterHit:SetPoint("TOPLEFT", frame.counter, "TOPLEFT", -4, 4)
    counterHit:SetPoint("BOTTOMRIGHT", frame.counter, "BOTTOMRIGHT", 4, -4)
    counterHit:EnableMouse(true)
    counterHit:SetScript("OnEnter", function(self)
        local outstanding = frame.counter.outstanding or {}
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Submitted", 1, 1, 1)
        if #outstanding == 0 then
            GameTooltip:AddLine("Everyone is in.", 0.6, 1, 0.6)
        else
            GameTooltip:AddLine("Still to submit: " .. table.concat(outstanding, ", "),
                1, 0.8, 0.4, true)
        end
        GameTooltip:Show()
    end)
    counterHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame.banner = Widgets.Label(frame, "", "GameFontNormal")
    frame.banner:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -70)
    frame.banner:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
    frame.banner:SetJustifyH("LEFT")

    entryPanel = buildEntryPanel(frame)
    resultsPanel = buildResultsPanel(frame)

    -- The countdown and the abort linger, on a light throttle. The window never takes
    -- keyboard input (section 6): nothing here enables it.
    frame:SetScript("OnUpdate", function(_, elapsed)
        countdownAccumulator = countdownAccumulator + elapsed
        if countdownAccumulator < 0.2 then return end
        countdownAccumulator = 0

        local round = currentRound()
        if round and round.state == C.ROUND_STATE.OPEN then
            local left = round.endsAt - GetTime()
            local text = RollWindow.FormatCountdown(left)
            if left <= C.COUNTDOWN_WARN_SECONDS then text = "|cffffaa00" .. text .. "|r" end
            frame.status:SetText(text)
        end
        if abortHideAt and GetTime() >= abortHideAt then
            abortHideAt = nil
            frame:Hide()
        end
    end)

    frame:SetScript("OnShow", function() RollWindow.Refresh() end)
    frame:SetScript("OnHide", function() abortHideAt = nil end)
end

--------------------------------------------------------------------------------
-- Public surface
--------------------------------------------------------------------------------

function RollWindow.Show()
    if not frame then build() end
    frame:RestorePosition()
    frame:Show()
    RollWindow.Refresh()
end

function RollWindow.Hide()
    if frame then frame:Hide() end
end

function RollWindow.Toggle()
    if frame and frame:IsShown() then frame:Hide() else RollWindow.Show() end
end

function RollWindow.IsShown()
    return frame ~= nil and frame:IsShown()
end

--- Is there something for the minimap button to pulse about (section 6)?
function RollWindow.NeedsAttention()
    local round = currentRound()
    if not round or round.state ~= C.ROUND_STATE.OPEN then return false end
    if RollWindow.IsShown() then return false end
    local myName = me()
    if round.submitted[myName] or lastSentRoundId == round.id then return false end
    return true
end

--- Does the roll window own the minimap button and a bare `/rls` right now?
--
-- Only while a round is live, or while the results of one are still on screen. A
-- concluded round hands the button back to the hierarchy: results open themselves
-- when they land, and once the player has closed them the window is stale -- the
-- history browser is where an old round is read, not here (spec 005 section 2).
function RollWindow.HasContent()
    local round = currentRound()
    if not round then return false end
    if round.state == C.ROUND_STATE.OPEN then return true end
    return round.state == C.ROUND_STATE.CLOSED and RollWindow.IsShown()
end

local function onClientChanged(round)
    if not round then
        RollWindow.Refresh()
        return
    end
    -- A SYNC resend can bring an aborted mirror back to OPEN (Client.lua); the abort
    -- linger must not then close a live grid.
    if round.state ~= C.ROUND_STATE.ABORTED then abortHideAt = nil end
    if round.state == C.ROUND_STATE.OPEN then
        if lastShownRoundId ~= round.id then
            -- A new round opens the window (section 2). A resend of the same round
            -- (SYNC) does not reopen a window the player closed.
            lastShownRoundId = round.id
            RollWindow.Show()
        end
    elseif round.state == C.ROUND_STATE.CLOSED then
        if round.results and not RollWindow.IsShown() then RollWindow.Show() end
    elseif round.state == C.ROUND_STATE.ABORTED then
        if RollWindow.IsShown() and not abortHideAt then
            abortHideAt = GetTime() + C.ABORT_LINGER_SECONDS
        end
    end
    RollWindow.Refresh()
end

function RollWindow.Init()
    ns.Client.RegisterListener(onClientChanged)
    ns.Roster.RegisterListener(function() RollWindow.Refresh() end)
end
