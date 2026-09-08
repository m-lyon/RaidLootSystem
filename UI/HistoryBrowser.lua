-- UI/HistoryBrowser.lua
--
-- The history window (spec 008 section 5): batches newest-first, each expandable to
-- the same results table the roll window shows; filters; the per-character summary;
-- and export to a selectable text box (section 6).
--
-- No pure half: every decision here is made by Modules/History.lua, which is
-- fixture-tested. This file lays the answers out.

local ADDON, ns = ...

ns.HistoryBrowser = {}
local Browser = ns.HistoryBrowser

local C = ns.Constants
local Widgets = ns.Widgets

local WIDTH = 600
local INNER = WIDTH - 60
-- Rows stop short of the scroll frame's right edge; the bar the template builds
-- overhangs it, and the batch badge is right-aligned into exactly that strip.
local SCROLL_WIDTH = INNER - 30
local ROW_WIDTH = SCROLL_WIDTH - Widgets.SCROLLBAR_GUTTER
local ROW_H = 22
local LIST_H = 300
local ICON = 16

-- The export and summary panels drop in below the buttons that open them, so
-- the window is measured to end just under whichever is open rather than being
-- guessed at: too short and the panel hangs through the frame, too tall and
-- there is dead space under the list when none is.
local PANEL_GAP = 8
local BOTTOM_MARGIN = 16
local START_HEIGHT = 640        -- provisional; layoutPanels measures the real one

local frame, content, filters, exportPanel, summaryPanel
local layoutPanels
local batchRows, detail, detailRows = {}, nil, {}
local expandedKey
local filtered = {}

local function DB() return ns.Database end

local function labelOf(itemString)
    local info = ns.ItemInfo.Get(itemString)
    return info.link or info.name or itemString
end

local function nameOf(itemString)
    local info = ns.ItemInfo.Get(itemString)
    return info.name or itemString
end

local function formatDate(ts)
    if not ts then return "?" end
    return date("%Y-%m-%d %H:%M", ts)
end

local function keyOf(record)
    return record.sessionId .. (record.recordedAsHost and "/host" or "/client")
end

--------------------------------------------------------------------------------
-- Filters (section 5)
--------------------------------------------------------------------------------

local function currentFilter()
    local roster
    if filters.mine:GetChecked() == 1 then
        roster = {}
        for _, name in ipairs(DB().Roster().order) do roster[name:lower()] = true end
    end
    local days = tonumber(filters.days:GetText())
    return {
        char = filters.char:GetText(),
        owner = filters.owner:GetText(),
        item = filters.item:GetText(),
        since = days and (time() - days * 86400) or nil,
        roster = roster,
        includeSimulated = filters.simulated:GetChecked() == 1,
        labelOf = nameOf,
    }
end

local function buildFilters(parent)
    local panel = Widgets.Panel(parent, 0.3)
    panel:SetWidth(INNER)
    panel:SetHeight(78)

    local function field(label, x, y, width)
        local caption = Widgets.Label(panel, label, "GameFontNormalSmall")
        caption:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
        local box = Widgets.EditBox(panel, width, 18)
        box:SetPoint("TOPLEFT", caption, "BOTTOMLEFT", 0, -2)
        box:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
            Browser.Refresh()
        end)
        return box
    end

    panel.char = field("Character", 10, -6, 110)
    panel.owner = field("Player", 130, -6, 110)
    panel.item = field("Item", 250, -6, 150)
    panel.days = field("Last N days", 410, -6, 60)

    panel.mine = Widgets.CheckBox(panel, "RaidLootSystemHistoryMine", "My roster only",
        function() Browser.Refresh() end)
    panel.mine:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 6, 2)

    panel.simulated = Widgets.CheckBox(panel, "RaidLootSystemHistorySimulated", "Show simulated",
        function() Browser.Refresh() end)
    panel.simulated:SetPoint("LEFT", panel.mine, "RIGHT", 110, 0)

    panel.apply = Widgets.Button(panel, "Apply", 70, 20, function() Browser.Refresh() end)
    panel.apply:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 6)
    return panel
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

local function batchRow(i)
    local row = batchRows[i]
    if row then return row end
    row = CreateFrame("Button", nil, content)
    row:SetWidth(ROW_WIDTH)
    row:SetHeight(ROW_H)
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints()
    row.highlight:SetTexture(1, 1, 1, 0.05)

    row.when = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.when:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.when:SetWidth(100)
    row.when:SetJustifyH("LEFT")

    row.where = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.where:SetPoint("LEFT", row.when, "RIGHT", 4, 0)
    row.where:SetWidth(190)
    row.where:SetJustifyH("LEFT")

    row.icons = {}
    for j = 1, 6 do
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(ICON)
        icon:SetHeight(ICON)
        icon:SetPoint("LEFT", row.where, "RIGHT", 4 + (j - 1) * (ICON + 2), 0)
        row.icons[j] = icon
    end

    row.badge = Widgets.Label(row, "", "GameFontNormalSmall")
    row.badge:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.badge:SetJustifyH("RIGHT")

    row:SetScript("OnClick", function(self)
        expandedKey = (expandedKey == self.key) and nil or self.key
        Browser.Refresh()
    end)
    batchRows[i] = row
    return row
end

local function badgeFor(record)
    if record.outcome == "ABORTED" then
        return "|cffff6060aborted|r"
    end
    local pending, failed = 0, 0
    for _, item in ipairs(record.items) do
        for _, a in ipairs(item.awards) do
            if a.delivery == C.DELIVERY.PENDING then pending = pending + 1 end
            if a.delivery == C.DELIVERY.FAILED or a.delivery == C.DELIVERY.LOST then failed = failed + 1 end
        end
    end
    local text = "|cff66ff66resolved|r"
    if pending > 0 then text = text .. " |cffffaa00" .. pending .. " pending|r" end
    if failed > 0 then text = text .. " |cffff6060" .. failed .. " failed|r" end
    if record.simulated then text = text .. " |cff888888sim|r" end
    if not record.recordedAsHost then text = text .. " |cff888888(client)|r" end
    return text
end

local function ensureDetail()
    if detail then return detail end
    detail = CreateFrame("Frame", nil, content)
    detail:SetWidth(ROW_WIDTH - 8)
    detail:SetHeight(1)
    return detail
end

function Browser.Refresh()
    if not frame or not frame:IsShown() then return end
    filtered = ns.History.Filter(ns.History.Records(), currentFilter())

    local y = 0
    local n = 0
    for _, record in ipairs(filtered) do
        n = n + 1
        local row = batchRow(n)
        row.key = keyOf(record)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        row.when:SetText(formatDate(record.timestamp))
        row.where:SetText((record.zone or "?") .. " / " .. (record.source or "?"))
        for j, icon in ipairs(row.icons) do
            local item = record.items[j]
            if item then
                icon:SetTexture(ns.ItemInfo.Get(item.itemString).icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                icon:Show()
            else
                icon:Hide()
            end
        end
        row.badge:SetText(badgeFor(record))
        row:Show()
        y = y + ROW_H

        if row.key == expandedKey then
            local panel = ensureDetail()
            panel:ClearAllPoints()
            panel:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
            local view = ns.History.ToView(record)
            for _, item in ipairs(view.items) do item.label = labelOf(item.itemString) end
            -- Delivery state is the host's (section 2); a client's record has none to show.
            if record.recordedAsHost then
                view.awardRecord = function(itemIdx, copy)
                    for _, r in ipairs(view.results) do
                        if r.itemIdx == itemIdx and r.award and r.award.copy == copy then return r.award end
                    end
                    return nil
                end
            end
            view.host = false
            local height = ns.RollWindow.RenderResults(panel, detailRows, view)
            panel:SetHeight(math.max(height, 1))
            panel:Show()
            y = y + height + 6
        end
    end
    for i = n + 1, #batchRows do batchRows[i]:Hide() end
    if detail and not expandedKey then detail:Hide() end
    if detail and expandedKey then
        local found = false
        for _, record in ipairs(filtered) do if keyOf(record) == expandedKey then found = true end end
        if not found then detail:Hide() end
    end

    frame.empty:SetText(#filtered == 0 and "No batches match." or "")
    frame.count:SetText(string.format("%d batch%s", #filtered, #filtered == 1 and "" or "es"))
    content:SetHeight(math.max(y, 1))
    layoutPanels()
end

--------------------------------------------------------------------------------
-- Export (section 6) and the character summary (section 5)
--------------------------------------------------------------------------------

local function buildTextPanel(parent, title)
    local panel = Widgets.Panel(parent, 0.85)
    panel:SetWidth(INNER)
    panel:SetHeight(180)
    panel:Hide()

    panel.title = Widgets.Label(panel, title, "GameFontNormalSmall")
    panel.title:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -8)

    local scroll = CreateFrame("ScrollFrame", "RaidLootSystemHistoryExportScroll" .. title:gsub("%W", ""),
        panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -6)
    scroll:SetWidth(INNER - 46)
    scroll:SetHeight(120)

    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject("ChatFontNormal")
    box:SetWidth(INNER - 46 - Widgets.SCROLLBAR_GUTTER)
    box:SetHeight(120)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(box)
    panel.box = box

    panel.close = Widgets.Button(panel, "Close", 70, 20, function() panel:Hide() end)
    panel.close:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 6)

    -- Both panels share the slot, so either appearing or going resizes the window.
    panel:SetScript("OnShow", layoutPanels)
    panel:SetScript("OnHide", layoutPanels)
    return panel
end

--- Size the window to end below whichever text panel is open, or below the
-- export buttons when neither is.
function layoutPanels()
    if not frame or not frame.exportRow then return end

    local anchor = frame.exportRow
    if exportPanel and exportPanel:IsShown() then anchor = exportPanel end
    if summaryPanel and summaryPanel:IsShown() then anchor = summaryPanel end

    -- Everything down to here hangs off the frame's top edge, so this distance
    -- holds however the window is anchored on screen.
    local top, bottom = frame:GetTop(), anchor:GetBottom()
    if top and bottom then
        frame:SetHeight(top - bottom + BOTTOM_MARGIN)
    end
end

local function showText(panel, title, text)
    if summaryPanel then summaryPanel:Hide() end
    if exportPanel then exportPanel:Hide() end
    panel.title:SetText(title)
    panel.box:SetText(text)
    panel.box:HighlightText()
    panel.box:SetFocus()
    panel:Show()
end

local function exportText()
    local text = ns.History.ExportText(filtered, { labelOf = nameOf, formatDate = formatDate })
    ns.History.MarkExported(filtered)
    showText(exportPanel, string.format("Plain text, %d batch(es). Ctrl-C to copy.", #filtered), text)
end

local function exportCSV()
    local text = ns.History.ExportCSV(filtered, { nameOf = nameOf })
    ns.History.MarkExported(filtered)
    showText(exportPanel, string.format("CSV, one row per entry, %d batch(es). Ctrl-C to copy.", #filtered), text)
end

local function characterSummary()
    local char = ns.Util.trim(filters.char:GetText() or "")
    if char == "" then
        ns.Print("type a character name in the Character box first.")
        return
    end
    local won = ns.History.CharacterSummary(ns.History.Records(), char)
    local lines = {}
    for _, w in ipairs(won) do
        lines[#lines + 1] = string.format("%s  %s  %s / %s%s", formatDate(w.timestamp),
            nameOf(w.itemString), w.zone or "?", w.source or "?",
            w.delivery and (" - " .. w.delivery:lower()) or "")
    end
    if #lines == 0 then lines[1] = char .. " has not been awarded anything." end
    showText(summaryPanel, string.format("%s: %d item(s) won", char, #won), table.concat(lines, "\n"))
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

local function build()
    frame = Widgets.Window("RaidLootSystemHistoryBrowser", "history",
        "Raid Loot System - History", WIDTH, START_HEIGHT)

    filters = buildFilters(frame)
    filters:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -40)

    frame.count = Widgets.Label(frame, "", "GameFontHighlightSmall")
    frame.count:SetPoint("TOPLEFT", filters, "BOTTOMLEFT", 4, -4)

    local listPanel = Widgets.Panel(frame, 0.35)
    listPanel:SetPoint("TOPLEFT", filters, "BOTTOMLEFT", 0, -20)
    listPanel:SetWidth(INNER)
    listPanel:SetHeight(LIST_H + 12)

    local scroll
    scroll, content = Widgets.ScrollArea(listPanel, "RaidLootSystemHistoryScroll", SCROLL_WIDTH, LIST_H)
    scroll:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 6, -6)

    frame.empty = Widgets.Label(frame, "", "GameFontDisableSmall")
    frame.empty:SetPoint("CENTER", listPanel, "CENTER", 0, 0)

    local exportTextButton = Widgets.Button(frame, "Export text", 100, 22, exportText)
    exportTextButton:SetPoint("TOPLEFT", listPanel, "BOTTOMLEFT", 0, -8)
    frame.exportRow = exportTextButton
    Widgets.Tooltip(exportTextButton, "Export text",
        "The batches shown, one line per award, for pasting into Discord.")

    local exportCSVButton = Widgets.Button(frame, "Export CSV", 100, 22, exportCSV)
    exportCSVButton:SetPoint("LEFT", exportTextButton, "RIGHT", 6, 0)
    Widgets.Tooltip(exportCSVButton, "Export CSV",
        "The batches shown, one row per entry, for a spreadsheet.")

    local summaryButton = Widgets.Button(frame, "Character summary", 130, 22, characterSummary)
    summaryButton:SetPoint("LEFT", exportCSVButton, "RIGHT", 6, 0)
    Widgets.Tooltip(summaryButton, "Character summary",
        "Everything the character in the Character box has won, with dates.")

    exportPanel = buildTextPanel(frame, "Export")
    exportPanel:SetPoint("TOPLEFT", exportTextButton, "BOTTOMLEFT", 0, -PANEL_GAP)
    summaryPanel = buildTextPanel(frame, "Summary")
    summaryPanel:SetPoint("TOPLEFT", exportTextButton, "BOTTOMLEFT", 0, -PANEL_GAP)

    frame:SetScript("OnShow", function() Browser.Refresh() end)
    ns.History.RegisterListener(function() Browser.Refresh() end)
end

function Browser.Show()
    if not frame then build() end
    frame:RestorePosition()
    frame:Show()
    Browser.Refresh()
end

function Browser.Toggle()
    if frame and frame:IsShown() then frame:Hide() else Browser.Show() end
end
