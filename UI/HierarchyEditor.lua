-- UI/HierarchyEditor.lua
--
-- The hierarchy editor (spec 001 section 7): one ordered list of the player's
-- characters, with tier bands drawn between rows so the ranking is concrete.

local ADDON, ns = ...

ns.HierarchyEditor = {}
local Editor = ns.HierarchyEditor

local C = ns.Constants
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
local SCROLL_WIDTH = LIST_WIDTH - 30
local ROW_INSET = 4
local ROW_WIDTH = SCROLL_WIDTH - ROW_INSET - Widgets.SCROLLBAR_GUTTER

local PANEL_GAP = 6
local BOTTOM_MARGIN = 16
local START_HEIGHT = 470        -- provisional; layoutPanels measures the real one

local frame, content, rows, bands
local listPanel, manualPanel, transferPanel
local dragIndex
local layoutPanels

local function Roster() return ns.Roster end

--------------------------------------------------------------------------------
-- Tier count in force
--
-- In a raid with an active host this is the raid's count; outside one it is the
-- client's stored default, so the display is never blank.
--------------------------------------------------------------------------------

local function activeTierCount()
    local client = ns.Client
    if client and client.TierCount then
        local count = client.TierCount()
        if count then return count, "set by the raid" end
    end
    return ns.Database.DefaultTierCount(), "your default, no raid host"
end

local function batchIsOpen()
    local client = ns.Client
    return client ~= nil and client.IsOpen ~= nil and client.IsOpen() == true
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function moveRow(from, to)
    local ok, why = Roster().Move(from, to)
    if not ok and why then ns.Print(why) end
    Editor.Refresh()
end

--- Which position is the cursor over? Used to land a drag.
local function positionUnderCursor()
    local _, cursorY = GetCursorPosition()
    cursorY = cursorY / UIParent:GetEffectiveScale()

    local order = Roster().Order()
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

    row.position = Widgets.Label(row, "", "GameFontNormalSmall")
    row.position:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.position:SetWidth(18)
    row.position:SetJustifyH("RIGHT")

    row.dot = Widgets.Dot(row, 10)
    row.dot:SetPoint("LEFT", row, "LEFT", 28, 0)

    row.name = Widgets.Label(row, "", "GameFontNormal")
    row.name:SetPoint("LEFT", row, "LEFT", 44, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWidth(130)

    row.badge = Widgets.Label(row, "", "GameFontNormalSmall")
    row.badge:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
    row.badge:SetWidth(34)

    row.remove = Widgets.IconButton(row, "remove", 20, 20, function()
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
        local target = positionUnderCursor()
        if target > dragIndex then target = target - 1 end
        target = Util.clamp(target, 1, #Roster().Order())
        if target ~= dragIndex then moveRow(dragIndex, target) end
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

    local roster = ns.Database.Roster()
    local order, chars = roster.order, roster.chars
    local tierCount, source = activeTierCount()

    frame.tierText:SetText(string.format("Tier count: %d  (%s)", tierCount, source))
    frame.warning:SetText(batchIsOpen()
        and "|cffffcc00A roll is open. Entries you already submitted keep the tiers they had at submit time.|r"
        or "")

    for _, band in ipairs(bands) do band:Hide() end
    for _, row in ipairs(rows) do row:Hide() end

    local y, bandIndex = 0, 0
    for i = 1, #order do
        local name = order[i]
        local entry = chars[name] or {}
        local row = rows[i]
        if not row then
            row = createRow(i)
            rows[i] = row
        end

        row.index = i
        row.charName = name
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", ROW_INSET, -y)
        row.position:SetText(tostring(i))

        local label = Widgets.ColorName(name, entry.class)
        if entry.isSelf then label = label .. " |cff888888(you)|r" end
        row.name:SetText(label)

        local tier = Tiers.forPosition(i, tierCount)
        row.badge:SetText("|cffaaaaaa" .. Tiers.label(tier, tierCount) .. "|r")

        local present = Roster().IsPresent(name)
        Widgets.SetDotPresent(row.dot, present)

        -- Presence and conflicts are the two reasons a row is not enterable, so
        -- the row tooltip states them rather than leaving the dot unexplained.
        local enterable, _, reason = Roster().Enterable(name)
        Widgets.Tooltip(row, name, enterable
            and (present and "In the raid and enterable." or "Enterable.")
            or reason)

        -- 3.3.5a has no Button:SetEnabled.
        if i > 1 then row.up:Enable() else row.up:Disable() end
        if i < #order then row.down:Enable() else row.down:Disable() end
        row:Show()

        y = y + ROW_HEIGHT + ROW_GAP

        -- A band separator wherever the next position falls into another tier.
        local nextTier = Tiers.forPosition(i + 1, tierCount)
        if i < #order and nextTier ~= tier then
            bandIndex = bandIndex + 1
            local band = bands[bandIndex]
            if not band then
                band = createBand()
                bands[bandIndex] = band
            end
            local heavy = Tiers.isRest(nextTier, tierCount)
            band.line:SetHeight(heavy and 2 or 1)
            if heavy then
                band.line:SetTexture(0.9, 0.7, 0.2, 0.9)
                band.text:SetText("|cffe6b422Rest below|r")
            else
                band.line:SetTexture(0.5, 0.5, 0.5, 0.6)
                band.text:SetText("|cff888888" .. Tiers.label(tier, tierCount) .. "|r")
            end
            band:ClearAllPoints()
            band:SetPoint("TOPLEFT", content, "TOPLEFT", ROW_INSET, -y)
            band:Show()
            y = y + BAND_HEIGHT
        end
    end

    if #order == 0 then
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

function layoutPanels()
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
    panel:SetHeight(76)
    panel:Hide()

    local title = Widgets.Label(panel, "Add a character by name", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -8)

    local nameBox = Widgets.EditBox(panel, 150, 20)
    nameBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -26)

    local dropdown = CreateFrame("Frame", "RaidLootSystemClassDropdown", panel, "UIDropDownMenuTemplate")
    dropdown:SetPoint("LEFT", nameBox, "RIGHT", -8, -2)
    panel.class = C.CLASSES[1]

    local function onSelect(self)
        panel.class = self.value
        UIDropDownMenu_SetSelectedValue(dropdown, self.value)
        UIDropDownMenu_SetText(dropdown, self.value)
    end

    UIDropDownMenu_Initialize(dropdown, function()
        for _, class in ipairs(C.CLASSES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.value, info.func = class, class, onSelect
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(dropdown, 110)
    UIDropDownMenu_SetSelectedValue(dropdown, panel.class)
    UIDropDownMenu_SetText(dropdown, panel.class)

    local add = Widgets.Button(panel, "Add", 70, 20, function()
        local name = Util.titleCase(nameBox:GetText() or "")
        local ok, why = Roster().Add(name, panel.class, false)
        if not ok then
            ns.Print(why)
        else
            nameBox:SetText("")
            panel:Hide()
        end
        Editor.Refresh()
    end)
    add:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 8)

    local cancel = Widgets.Button(panel, "Cancel", 70, 20, function() panel:Hide() end)
    cancel:SetPoint("LEFT", add, "RIGHT", 6, 0)

    nameBox:SetScript("OnEnterPressed", function() add:Click() end)
    return trackPanel(panel)
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
        local current = #ns.Database.Roster().order
        StaticPopup_Show("RLS_CONFIRM_IMPORT",
            string.format("Replace your current roster of %d characters with these %d?\n\n%s",
                current, #order, preview),
            nil, { order = order, chars = chars })
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

    frame.tierText = Widgets.Label(frame, "", "GameFontNormalSmall")
    frame.tierText:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -40)

    local hint = Widgets.Label(frame,
        "Drag a row, or use the arrows, to set which characters you most want geared.",
        "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", frame.tierText, "BOTTOMLEFT", 0, -4)
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
        if manualPanel:IsShown() then manualPanel:Hide() else manualPanel:Show() end
    end)
    addManual:SetPoint("LEFT", addGroup, "RIGHT", 6, 0)

    frame.warning = Widgets.Label(frame, "", "GameFontHighlightSmall")
    frame.warning:SetPoint("TOPLEFT", addTarget, "BOTTOMLEFT", 0, -6)
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
end

function Editor.Toggle()
    if not frame then build() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:RestorePosition()
        frame:Show()
    end
end

function Editor.Show()
    if not frame then build() end
    frame:RestorePosition()
    frame:Show()
end
