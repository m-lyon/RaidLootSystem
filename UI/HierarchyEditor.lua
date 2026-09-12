-- UI/HierarchyEditor.lua
--
-- The hierarchy editor (spec 001 section 7): one ordered list of the player's
-- characters, with the Rest cut-off drawn between rows so the ranking is concrete.

local ADDON, ns = ...

ns.HierarchyEditor = {}
local Editor = ns.HierarchyEditor

local Tiers = ns.Tiers
local Util = ns.Util
local Widgets = ns.Widgets

local ROW_HEIGHT = 24
local ROW_GAP = 2
local BAND_HEIGHT = 14
local LIST_WIDTH = 340

-- Rows live inside a Widgets.ScrollArea, and its scroll bar overhangs the right
-- edge of that area. Rows stop a gutter short of it so the row controls -- the
-- remove button most of all -- are never drawn underneath the bar.
local SCROLL_WIDTH = LIST_WIDTH - 32
local ROW_INSET = 4
local ROW_WIDTH = SCROLL_WIDTH - ROW_INSET - Widgets.SCROLLBAR_GUTTER

local PANEL_GAP = 1
local BOTTOM_MARGIN = 16
local START_HEIGHT = 470        -- provisional; layoutPanels measures the real one

local frame, content, rows, bands
local listPanel, manualPanel, transferPanel
local dragIndex
local layoutPanels

-- Which list is being edited: a campaign id, or Roster.DEFAULT_TARGET for the
-- global template of spec 012 section 7. The picker is prominent rather than
-- decorative -- editing the wrong campaign's hierarchy is a silent no-op you would
-- discover next Tuesday.
local target

local function Roster() return ns.Roster end

local function editingDefault()
    return target == ns.Roster.DEFAULT_TARGET
end

--- The list this editor is pointed at, falling back to the active campaign when the
-- one it held has been deleted or switched away from underneath it.
local function targetList()
    local list = Roster().HierarchyList(target)
    if not list then
        target = ns.Campaign.ActiveId()
        list = Roster().HierarchyList(target)
    end
    -- Falls through here with no active campaign either (a fresh install with
    -- nothing yet); an empty list draws as an empty editor, not a crash.
    return list or {}
end

local function targetOptions()
    local options = {}
    for i, c in ipairs(ns.Campaign.List()) do
        options[i] = { value = c.id, text = c.label or c.id }
    end
    options[#options + 1] = { value = ns.Roster.DEFAULT_TARGET, text = "Default (template)" }
    return options
end

--------------------------------------------------------------------------------
-- Tier count in force
--
-- In a raid with an active host this is the raid's count; outside one it is the
-- client's stored default, so the bands are never blank. The number itself is a
-- host setting and is not shown here (spec 001 section 7); only the bands it draws
-- are, which is what a player reorders against.
--
-- The second return says whether that number is real: an open round's frozen
-- count, or a CFG this session actually saw from that campaign's host. A joined
-- campaign's own `host.tierCount` is never synced to the real host's value (only
-- the ephemeral CFG mirror is), so falling back to it -- or to the schema default
-- -- is a guess, and the bands below are marked as one rather than presented as
-- fact.
--------------------------------------------------------------------------------

local function activeTierCount()
    local client = ns.Client
    local campaignId = not editingDefault() and target or nil
    if client and client.TierCountInForce then return client.TierCountInForce(campaignId) end
    return ns.Database.DefaultTierCount(), false
end

--- The row badge's label. Unlike Tiers.label this numbers the Rest bucket -- "T4"
-- under a count of 3 -- rather than naming it, so the column reads as one scale
-- from top to bottom. The cut-off is still called out, by the band across the
-- rows. Tiers.label itself is untouched: raid chat, the roll window and history
-- all say "Rest", which is the word people use out loud.
local function badgeLabel(tier, tierCount)
    if tierCount == nil or tierCount <= 0 then return "Flat" end
    return "T" .. tostring(tier)
end

local function roundIsOpen()
    local client = ns.Client
    return client ~= nil and client.IsOpen ~= nil and client.IsOpen() == true
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function moveRow(from, to)
    local ok, why = Roster().MoveIn(target, from, to)
    if not ok and why then ns.Print(why) end
    Editor.Refresh()
end

--- Which position is the cursor over? Used to land a drag.
local function positionUnderCursor()
    local _, cursorY = GetCursorPosition()
    cursorY = cursorY / UIParent:GetEffectiveScale()

    local order = targetList()
    for i = 1, #order do
        local row = rows[i]
        if row and row:IsShown() then
            local top, bottom = row:GetTop(), row:GetBottom()
            if top and bottom and cursorY >= bottom then
                -- Above the midpoint drops before this row, below it drops after.
                if cursorY >= (top + bottom) / 2 then return i end
                return i + 1
            end
        end
    end
    return #order
end

local function createRow(index)
    local row = CreateFrame("Button", nil, content)
    row:SetWidth(ROW_WIDTH)
    row:SetHeight(ROW_HEIGHT)
    row:RegisterForDrag("LeftButton")
    row:EnableMouse(true)

    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints()
    row.highlight:SetTexture(1, 1, 1, 0.06)

    -- The same inclusion checkbox the join dialog shows (spec 012 section 7), so a
    -- character can never become unreachable by having been unticked once.
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetWidth(18)
    row.check:SetHeight(18)
    row.check:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.check:SetScript("OnClick", function(self)
        local ok, why = Roster().SetIncludedIn(target, row.charName, self:GetChecked() == 1)
        if not ok and why then ns.Print(why) end
        Editor.Refresh()
    end)

    row.position = Widgets.Label(row, "", "GameFontNormalSmall")
    row.position:SetPoint("LEFT", row, "LEFT", 24, 0)
    row.position:SetWidth(18)
    row.position:SetJustifyH("RIGHT")

    row.dot = Widgets.Dot(row, 10)
    row.dot:SetPoint("LEFT", row, "LEFT", 46, 0)

    row.name = Widgets.Label(row, "", "GameFontNormal")
    row.name:SetPoint("LEFT", row, "LEFT", 62, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWidth(130)

    row.badge = Widgets.Label(row, "", "GameFontNormalSmall")
    row.badge:SetPoint("LEFT", row.name, "RIGHT", 2, 0)
    row.badge:SetWidth(34)
    row.badge:SetJustifyH("LEFT")

    -- UIPanelCloseButton's "X" glyph carries a lot of built-in padding, so at the
    -- same frame size it reads visibly smaller than the cropped up/down arrows;
    -- size it up to compensate.
    row.remove = Widgets.IconButton(row, "remove", 24, 24, function()
        local name = row.charName
        local ok, why = Roster().Remove(name)
        if not ok then ns.Print(why) end
        Editor.Refresh()
    end)
    row.remove:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    Widgets.Tooltip(row.remove, "Remove", "Take this character out of your roster.")

    row.down = Widgets.IconButton(row, "down", 18, 16, function()
        moveRow(row.index, row.index + 1)
    end)
    row.down:SetPoint("RIGHT", row.remove, "LEFT", -2, 0)
    Widgets.Tooltip(row.down, "Move down", "Rank this character one place lower.")

    row.up = Widgets.IconButton(row, "up", 18, 16, function()
        moveRow(row.index, row.index - 1)
    end)
    row.up:SetPoint("RIGHT", row.down, "LEFT", -2, 0)
    Widgets.Tooltip(row.up, "Move up", "Rank this character one place higher.")

    row:SetScript("OnDragStart", function(self)
        dragIndex = self.index
        self:SetAlpha(0.5)
    end)
    row:SetScript("OnDragStop", function(self)
        self:SetAlpha(1)
        if not dragIndex then return end
        local landing = positionUnderCursor()
        if landing > dragIndex then landing = landing - 1 end
        landing = Util.clamp(landing, 1, #targetList())
        if landing ~= dragIndex then moveRow(dragIndex, landing) end
        dragIndex = nil
        Editor.Refresh()
    end)

    return row
end

local function createBand()
    local band = CreateFrame("Frame", nil, content)
    band:SetWidth(ROW_WIDTH)
    band:SetHeight(BAND_HEIGHT)
    band.line, band.text = Widgets.Separator(band, "", false)
    band.line:SetPoint("LEFT", band, "LEFT", 0, 0)
    band.line:SetPoint("RIGHT", band, "RIGHT", 0, 0)
    band.text:SetPoint("RIGHT", band, "RIGHT", 0, 6)
    return band
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

function Editor.Refresh()
    if not frame or not frame:IsShown() then return end

    local chars = ns.Database.Roster().chars
    local order = targetList()
    local tierCount, tierSynced = activeTierCount()

    frame.picker:SetOptions(targetOptions())
    frame.picker:SetValue(target)
    frame.scope:SetText(editingDefault()
        and "|cffffcc00This is the template new campaigns will use.|r"
        or string.format("|cff888888Ranking for \"%s\".|r",
            ns.Campaign.LabelFor(target)))

    -- The lock outranks the roll-open note: one says a change you make now lands
    -- late, the other says you cannot make it at all, and a reader who tries and is
    -- refused learned the second one the hard way (spec 014 section 6).
    local locked = not editingDefault() and ns.Campaign.HierarchyLocked(target)
    if locked then
        frame.warning:SetText("|cffffcc00This campaign has started and its hierarchies are "
            .. "locked. You can still add a character; it joins at the bottom. The master "
            .. "looter can unlock them.|r")
    elseif not editingDefault() and roundIsOpen() then
        frame.warning:SetText("|cffffcc00A roll is open. Entries you already submitted keep "
            .. "the tiers they had at submit time.|r")
    else
        frame.warning:SetText("")
    end

    for _, band in ipairs(bands) do band:Hide() end
    for _, row in ipairs(rows) do row:Hide() end

    -- Every character, ticked ones first in their ranked order; positions count the
    -- ticked rows only (spec 012 section 7).
    local model = ns.Campaign.HierarchyRows(chars, order)

    local y, bandIndex = 0, 0
    for i = 1, #model do
        local entryRow = model[i]
        local name = entryRow.char
        local entry = chars[name] or {}
        local row = rows[i]
        if not row then
            row = createRow(i)
            rows[i] = row
        end

        row.index = entryRow.position
        row.charName = name
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", ROW_INSET, -y)
        row.check:SetChecked(entryRow.included)
        row.position:SetText(entryRow.position and tostring(entryRow.position) or "|cff666666-|r")

        local label = Widgets.ColorName(name, entry.class)
        if entry.isSelf then label = label .. " |cff888888(you)|r" end
        if not entryRow.included then label = "|cff777777" .. name .. "|r" end
        row.name:SetText(label)

        local tier = entryRow.position and Tiers.forPosition(entryRow.position, tierCount) or nil
        row.badge:SetText(tier
            and ((tierSynced and "|cffaaaaaa" or "|cff666666") .. badgeLabel(tier, tierCount) .. "|r")
            or "|cff666666out|r")

        local present = Roster().IsPresent(name)
        Widgets.SetDotPresent(row.dot, present)

        -- Presence and conflicts are the two reasons a row is not enterable, so
        -- the row tooltip states them rather than leaving the dot unexplained.
        local enterable, _, reason = Roster().Enterable(name)
        Widgets.Tooltip(row, name, not entryRow.included
            and "Not in this campaign. Tick the box to bring it in."
            or (enterable and (present and "In the raid and enterable." or "Enterable.") or reason))

        -- 3.3.5a has no Button:SetEnabled. Only ticked rows have a rank to move,
        -- and a locked campaign has none that can be moved at all.
        if not locked and entryRow.position and entryRow.position > 1 then row.up:Enable()
        else row.up:Disable() end
        if not locked and entryRow.position and entryRow.position < #order then row.down:Enable()
        else row.down:Disable() end
        -- A removal promotes everything below it, so it is a re-rank too and the
        -- lock refuses it (spec 014) -- for a character ranked in a locked campaign,
        -- exactly as Roster.Remove does, so a mistaken unticked add can still go.
        if Roster().LockedRankingOf(name) then row.remove:Disable() else row.remove:Enable() end
        row:SetAlpha(entryRow.included and 1 or 0.6)
        row:Show()

        y = y + ROW_HEIGHT + ROW_GAP

        -- One separator, at the Rest cut-off. The per-tier rules above it drew a
        -- line after every one of the top rows to repeat the tier already on the
        -- row's own badge; the cut-off is the only boundary that changes what a
        -- position means, since below it ordering stops mattering at all.
        -- Drawn only once the count is real -- an unsynced guess has no business
        -- claiming a firm cut-off; the badges and the warning above already say
        -- the ranking is provisional.
        local position = entryRow.position
        local nextTier = position and Tiers.forPosition(position + 1, tierCount) or nil
        if tierSynced and position and position < #order and nextTier
            and Tiers.isRest(nextTier, tierCount) and not Tiers.isRest(tier, tierCount) then
            bandIndex = bandIndex + 1
            local band = bands[bandIndex]
            if not band then
                band = createBand()
                bands[bandIndex] = band
            end
            band.line:SetHeight(2)
            band.line:SetTexture(0.9, 0.7, 0.2, 0.9)
            band.text:SetText("|cffe6b422Rest below|r")
            band:ClearAllPoints()
            band:SetPoint("TOPLEFT", content, "TOPLEFT", ROW_INSET, -y)
            band:Show()
            y = y + BAND_HEIGHT
        end
    end

    if #model == 0 then
        frame.empty:Show()
    else
        frame.empty:Hide()
    end

    content:SetHeight(math.max(y, 1))
    layoutPanels()
end

--------------------------------------------------------------------------------
-- Panels
--
-- The manual-entry and export/import panels hang in one slot below the list, so
-- the Export and Import buttons sit under whichever is open, and the window is
-- sized to end just below them. Guessing a fixed height instead leaves a gap
-- when the slot is empty and runs the panel through the frame when it is not --
-- and the height is not a constant anyway, since the roll-open warning above
-- the list wraps to a second line and pushes everything down.
--------------------------------------------------------------------------------

local function measurePanels()
    if not frame or not listPanel or not frame.exportButton then return end

    local anchor = listPanel
    if manualPanel and manualPanel:IsShown() then anchor = manualPanel end
    if transferPanel and transferPanel:IsShown() then anchor = transferPanel end
    frame.exportButton:ClearAllPoints()
    frame.exportButton:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -PANEL_GAP)

    -- Everything down to the buttons hangs off the frame's top edge, so this
    -- distance holds however the window is anchored on screen.
    local top, bottom = frame:GetTop(), frame.exportButton:GetBottom()
    if top and bottom then
        frame:SetHeight(top - bottom + BOTTOM_MARGIN)
    end
end

--- Size the window, then size it again on the next frame.
--
-- The scope line and the roll-open warning are wrapping font strings, and a
-- wrapping string still measures at its old height until the text has been laid
-- out for drawing. On the first Refresh after a Show the two lines above the
-- list therefore measure short, the window comes out a few pixels shy, and the
-- Export and Import buttons sit under the bottom border -- until any later
-- Refresh, such as picking a campaign, measures them at their real height. The
-- second pass measures once they have settled; it is a no-op whenever the first
-- pass already had the right numbers.
function layoutPanels()
    measurePanels()
    Widgets.NextFrame(measurePanels)
end

--- Only one panel occupies the slot below the list, so they resize the window
-- between them; hooking Show/Hide catches every caller, dialogs included.
local function trackPanel(panel)
    panel:SetScript("OnShow", layoutPanels)
    panel:SetScript("OnHide", layoutPanels)
    return panel
end

--------------------------------------------------------------------------------
-- Manual entry (section 4)
--------------------------------------------------------------------------------

local function buildManualPanel(parent)
    local panel = Widgets.Panel(parent, 0.75)
    panel:SetWidth(LIST_WIDTH)
    panel:SetHeight(92)
    panel:Hide()

    local title = Widgets.Label(panel, "Add a character by name", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -8)

    -- There is no class picker. A class the player types is unverifiable, and a
    -- wrong one is invisible until the roll window filters the character off an
    -- item they could have used. The class is looked up instead, and the add is
    -- refused when nothing on this client knows it (spec 001 section 4).
    local hint = Widgets.Label(panel,
        "The class is read from the group, a published roster, or your guild roster.",
        "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -24)
    hint:SetWidth(LIST_WIDTH - 20)
    hint:SetJustifyH("LEFT")

    local nameBox = Widgets.EditBox(panel, 150, 20)
    nameBox:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -6)

    local add = Widgets.Button(panel, "Add", 70, 20, function()
        local name = Util.titleCase(nameBox:GetText() or "")
        local ok, classOrWhy, from = Roster().AddByName(name)
        if not ok then
            ns.Print(classOrWhy)
        else
            ns.Print(string.format("%s added as %s, from %s.", name, classOrWhy, from))
            nameBox:SetText("")
            panel:Hide()
        end
        Editor.Refresh()
    end)
    add:SetPoint("TOPLEFT", nameBox, "BOTTOMLEFT", 0, -8)

    local cancel = Widgets.Button(panel, "Cancel", 70, 20, function() panel:Hide() end)
    cancel:SetPoint("LEFT", add, "RIGHT", 6, 0)

    nameBox:SetScript("OnEnterPressed", function() add:Click() end)

    -- The buttons hang off the name box rather than the panel's bottom edge, and
    -- the panel takes its height from where they landed: the hint above wraps to
    -- one line or two depending on UI scale, and a fixed height ran the name box
    -- through the buttons whenever it took two.
    panel:SetScript("OnShow", function(self)
        local top, bottom = self:GetTop(), add:GetBottom()
        if top and bottom then self:SetHeight(top - bottom + 8) end
        layoutPanels()
    end)
    panel:SetScript("OnHide", layoutPanels)
    return panel
end

--------------------------------------------------------------------------------
-- Export / import (section 8)
--------------------------------------------------------------------------------

StaticPopupDialogs["RLS_CONFIRM_IMPORT"] = {
    text = "%s",
    button1 = "Replace",
    button2 = CANCEL,
    OnAccept = function(self)
        local payload = self.data
        local ok, why = ns.Roster.ApplyImport(payload.order, payload.chars)
        if ok then
            ns.Print(string.format("imported %d characters.", #payload.order))
            if transferPanel then transferPanel:Hide() end
        else
            ns.Print("import failed: " .. tostring(why))
        end
        Editor.Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function buildTransferPanel(parent)
    local panel = Widgets.Panel(parent, 0.85)
    panel:SetWidth(LIST_WIDTH)
    panel:SetHeight(150)
    panel:Hide()

    local title = Widgets.Label(panel, "Roster string", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -8)

    local hint = Widgets.Label(panel,
        "Copy this to share your roster, or paste one in and press Import.",
        "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    hint:SetWidth(LIST_WIDTH - 20)
    hint:SetJustifyH("LEFT")

    local scroll = CreateFrame("ScrollFrame", "RaidLootSystemTransferScroll", panel,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -6)
    scroll:SetWidth(LIST_WIDTH - 46)
    scroll:SetHeight(58)

    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject("ChatFontNormal")
    box:SetWidth(LIST_WIDTH - 46 - Widgets.SCROLLBAR_GUTTER)
    box:SetHeight(58)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(box)
    panel.box = box

    local importButton = Widgets.Button(panel, "Import", 80, 20, function()
        local order, chars = ns.Roster.ParseImport(box:GetText())
        if not order then
            ns.Print("import refused: " .. tostring(chars))
            return
        end
        local preview = table.concat(order, ", ")
        -- An import replaces the global character table, so the count that matters is
        -- how many characters you have, not how many this campaign ranks.
        local current = 0
        for _ in pairs(ns.Database.Roster().chars) do current = current + 1 end
        local text = string.format("Replace your current roster of %d characters with these %d?"
            .. "\n\n%s", current, #order, preview)
        -- The other campaigns lose every name this import drops, and that loss is
        -- invisible until the raid night you next open one of them.
        local active = ns.Campaign.Active()
        local losing = ns.Roster.ImportLosses(ns.Database.Campaigns(), chars,
            active and active.id)
        if #losing > 0 then
            text = text .. string.format("\n\nThis also drops characters from: %s.",
                table.concat(losing, ", "))
        end
        StaticPopup_Show("RLS_CONFIRM_IMPORT", text, nil, { order = order, chars = chars })
    end)
    importButton:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 8)

    local close = Widgets.Button(panel, "Close", 80, 20, function() panel:Hide() end)
    close:SetPoint("LEFT", importButton, "RIGHT", 6, 0)

    return trackPanel(panel)
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local function build()
    rows, bands = {}, {}

    frame = Widgets.Window("RaidLootSystemHierarchyEditor", "hierarchy",
        "Raid Loot System - Your hierarchy", LIST_WIDTH + 40, START_HEIGHT)

    local hint = Widgets.Label(frame,
        "Drag a row, or use the arrows, to set which characters you most want geared.",
        "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -40)
    hint:SetWidth(LIST_WIDTH)
    hint:SetJustifyH("LEFT")

    local addTarget = Widgets.Button(frame, "Add target", 100, 22, function()
        local ok, why = Roster().AddTarget()
        if not ok then ns.Print(why) end
        Editor.Refresh()
    end)
    addTarget:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)

    local addGroup = Widgets.Button(frame, "Add group", 100, 22, function()
        local added, skipped, reasons = Roster().AddAllInGroup()
        ns.Print(string.format("added %d character(s), skipped %d.", added, skipped))
        for _, reason in ipairs(reasons) do ns.Print("  " .. reason) end
        Editor.Refresh()
    end)
    addGroup:SetPoint("LEFT", addTarget, "RIGHT", 6, 0)

    local addManual = Widgets.Button(frame, "Add by name", 100, 22, function()
        if transferPanel then transferPanel:Hide() end
        -- The guild roster is the only source that answers for an offline character,
        -- and it is only populated once asked for.
        if IsInGuild() then GuildRoster() end
        if manualPanel:IsShown() then manualPanel:Hide() else manualPanel:Show() end
    end)
    addManual:SetPoint("LEFT", addGroup, "RIGHT", 6, 0)

    -- The campaign picker (spec 012 section 13). Prominent, not decorative: editing
    -- the wrong campaign's hierarchy is a silent no-op you would discover next
    -- Tuesday. "Default" is the template of section 7, marked as such.
    frame.pickerLabel = Widgets.Label(frame, "Campaign", "GameFontNormalSmall")
    frame.pickerLabel:SetPoint("TOPLEFT", addTarget, "BOTTOMLEFT", 4, -8)

    frame.picker = Widgets.Dropdown(frame, "RaidLootSystemHierarchyCampaign", 150,
        targetOptions(), function(value)
            target = value
            Editor.Refresh()
        end)
    frame.picker:SetPoint("TOPLEFT", frame.pickerLabel, "BOTTOMLEFT", -16, -2)

    frame.scope = Widgets.Label(frame, "", "GameFontDisableSmall")
    frame.scope:SetPoint("TOPLEFT", frame.picker, "BOTTOMLEFT", 20, 0)
    frame.scope:SetWidth(LIST_WIDTH)
    frame.scope:SetJustifyH("LEFT")

    frame.warning = Widgets.Label(frame, "", "GameFontHighlightSmall")
    frame.warning:SetPoint("TOPLEFT", frame.scope, "BOTTOMLEFT", 0, -6)
    frame.warning:SetWidth(LIST_WIDTH)
    frame.warning:SetJustifyH("LEFT")

    listPanel = Widgets.Panel(frame, 0.35)
    listPanel:SetPoint("TOPLEFT", frame.warning, "BOTTOMLEFT", 0, -6)
    listPanel:SetWidth(LIST_WIDTH)
    listPanel:SetHeight(250)

    local scroll
    scroll, content = Widgets.ScrollArea(listPanel, "RaidLootSystemHierarchyScroll",
        SCROLL_WIDTH, 240)
    scroll:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 6, -6)

    frame.empty = Widgets.Label(frame,
        "Your roster is empty. Add your own character and your bots.",
        "GameFontDisableSmall")
    frame.empty:SetPoint("CENTER", listPanel, "CENTER", 0, 0)

    manualPanel = buildManualPanel(frame)
    manualPanel:SetPoint("TOPLEFT", listPanel, "BOTTOMLEFT", 0, -6)

    transferPanel = buildTransferPanel(frame)
    transferPanel:SetPoint("TOPLEFT", listPanel, "BOTTOMLEFT", 0, -6)

    local exportButton = Widgets.Button(frame, "Export", 80, 22, function()
        manualPanel:Hide()
        local text, err = ns.Roster.Export()
        if not text then
            ns.Print("export failed: " .. tostring(err))
            return
        end
        transferPanel.box:SetText(text)
        transferPanel.box:HighlightText()
        transferPanel.box:SetFocus()
        transferPanel:Show()
    end)
    frame.exportButton = exportButton

    local importButton = Widgets.Button(frame, "Import", 80, 22, function()
        manualPanel:Hide()
        transferPanel.box:SetText("")
        transferPanel.box:SetFocus()
        transferPanel:Show()
    end)
    importButton:SetPoint("LEFT", exportButton, "RIGHT", 6, 0)

    frame:SetScript("OnShow", function()
        Editor.Refresh()
    end)

    -- Redraw when the roster, presence, claims or the raid's tier count change.
    Roster().RegisterListener(function() Editor.Refresh() end)
    ns.Campaign.RegisterListener(function() Editor.Refresh() end)
end

--- Point the editor at one list. Used by the host panel and `/rls campaign`.
function Editor.SetTarget(newTarget)
    target = newTarget
    Editor.Refresh()
end

--- Default the picker to the campaign you are in, so opening the editor after a
-- raid edits the campaign you just raided in (active campaign is sticky, section 13).
local function ensureTarget()
    if target == nil or (target ~= ns.Roster.DEFAULT_TARGET and not ns.Campaign.Get(target)) then
        -- No active campaign (a fresh install, nothing created or joined yet)
        -- edits the template instead -- there is nothing else to point at.
        target = ns.Campaign.Get(ns.Campaign.ActiveId()) and ns.Campaign.ActiveId()
            or ns.Roster.DEFAULT_TARGET
    end
end

function Editor.Toggle()
    if not frame then build() end
    ensureTarget()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:RestorePosition()
        frame:Show()
    end
end

function Editor.Show()
    if not frame then build() end
    ensureTarget()
    frame:RestorePosition()
    frame:Show()
end
