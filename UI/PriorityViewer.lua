-- UI/PriorityViewer.lua
--
-- The read-only priority list (spec 011): the same order the host panel edits,
-- drawn for every player. No controls, not even disabled ones -- a greyed-out
-- Move button on a raider's screen implies the permission exists somewhere
-- (spec 011 section 7).

local ADDON, ns = ...

ns.PriorityViewer = {}
local Viewer = ns.PriorityViewer

local C = ns.Constants
local PriorityList = ns.PriorityList
local Widgets = ns.Widgets

local ROW_H = 18
local LIST_WIDTH = 360
local SCROLL_WIDTH = LIST_WIDTH - 30
local ROW_INSET = 4
local ROW_WIDTH = SCROLL_WIDTH - ROW_INSET - Widgets.SCROLLBAR_GUTTER
local WINDOW_HEIGHT = 440
local LIST_HEIGHT = 300

local frame, content, rows

--------------------------------------------------------------------------------
-- What the client knows
--------------------------------------------------------------------------------

local function DB() return ns.Database.Priority() end

--- Is SK the mode in force? true, false, or nil when no batch is open.
--
-- The host reads its own session, a client reads the one the host sent it. A list
-- can sit seeded through a whole ROLL night, and a viewer that does not say so
-- invites the reader to assume tonight's loot is going by these positions.
local function skInForce()
    local session = (ns.Session and ns.Session.current)
        or (ns.Client and ns.Client.session)
        or nil
    if not session or session.state ~= C.SESSION_STATE.OPEN then return nil end
    return session.lootMode == C.LOOT_MODE.SK
end

--- Resolve every WoW-facing lookup the row model needs, so PriorityList.viewRows
-- stays arithmetic over plain tables (spec 011 section 4).
local function context(order)
    local claims = ns.Roster.claims
    local owners, present, classes, contested = {}, {}, {}, {}
    for _, name in ipairs(order) do
        local claim = claims[name:lower()]
        owners[name] = claim and claim.owners[1] or nil
        present[name] = ns.Roster.IsPresent(name) and true or nil
        classes[name] = ns.Roster.ClassOfAny(name)
        contested[name] = (claim and claim.contested) and true or nil
    end
    return { owners = owners, present = present, classes = classes,
             contested = contested, me = UnitName("player") }
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function createRow(index)
    local row = CreateFrame("Frame", nil, content)
    row:SetWidth(ROW_WIDTH)
    row:SetHeight(ROW_H)

    row.position = Widgets.Label(row, "", "GameFontNormalSmall")
    row.position:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.position:SetWidth(26)
    row.position:SetJustifyH("RIGHT")

    row.name = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.position, "RIGHT", 6, 0)
    row.name:SetWidth(ROW_WIDTH - 32)
    row.name:SetJustifyH("LEFT")

    rows[index] = row
    return row
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

function Viewer.Refresh()
    if not frame or not frame:IsShown() then return end

    local db = DB()
    local order = db.order or {}

    if #order == 0 then
        frame.header:SetText("The priority list is not seeded.")
        frame.mode:SetText("|cff888888Suicide Kings is unavailable until the master looter "
            .. "seeds it.|r")
        for _, row in ipairs(rows) do row:Hide() end
        content:SetHeight(1)
        return
    end

    frame.header:SetText(string.format("%d characters, version %d, seed %d",
        #order, db.version or 0, db.seed or 0))

    local sk = skInForce()
    if sk == nil then
        frame.mode:SetText("|cff888888No batch is open. These positions apply to the next one "
            .. "the host opens under SK.|r")
    elseif sk then
        frame.mode:SetText("|cff66ff66The open batch is running under SK.|r")
    else
        frame.mode:SetText("|cffffaa00The open batch is running under ROLL; these positions "
            .. "are not deciding it.|r")
    end

    local view = PriorityList.viewRows(order, context(order))
    for i, entry in ipairs(view) do
        local row = rows[i] or createRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", ROW_INSET, -(i - 1) * ROW_H)

        -- Above the median of who is actually here is the thing people want at a
        -- glance, so it colours the number itself (spec 010 section 11).
        row.position:SetText((entry.aboveMedian and "|cff66ff66#" or "|cffaaaaaa#")
            .. entry.position .. "|r")

        local label = Widgets.ColorName(entry.char, entry.class)
            .. " |cff888888(" .. (entry.owner or "unclaimed") .. ")|r"
        if entry.isSelf then label = label .. " |cffaaaaaa*|r" end
        if entry.contested then label = label .. " |cffff4040contested|r" end
        row.name:SetText(label)

        row:SetAlpha(entry.present and 1 or 0.5)
        row:Show()
    end
    for i = #view + 1, #rows do rows[i]:Hide() end

    content:SetHeight(math.max(#view * ROW_H, 1))
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local function build()
    rows = {}

    frame = Widgets.Window("RaidLootSystemPriorityViewer", "sklist",
        "Raid Loot System -- Priority list", LIST_WIDTH + 40, WINDOW_HEIGHT)

    frame.header = Widgets.Label(frame, "", "GameFontNormalSmall")
    frame.header:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -40)

    frame.mode = Widgets.Label(frame, "", "GameFontDisableSmall")
    frame.mode:SetPoint("TOPLEFT", frame.header, "BOTTOMLEFT", 0, -4)
    frame.mode:SetWidth(LIST_WIDTH)
    frame.mode:SetJustifyH("LEFT")

    local listPanel = Widgets.Panel(frame, 0.35)
    listPanel:SetPoint("TOPLEFT", frame.mode, "BOTTOMLEFT", 0, -8)
    listPanel:SetWidth(LIST_WIDTH)
    listPanel:SetHeight(LIST_HEIGHT + 12)

    local scroll
    scroll, content = Widgets.ScrollArea(listPanel, "RaidLootSystemPriorityViewerScroll",
        SCROLL_WIDTH, LIST_HEIGHT)
    scroll:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 6, -6)

    frame.footer = Widgets.Label(frame,
        "Read-only. The master looter edits the list; every change is announced.",
        "GameFontDisableSmall")
    frame.footer:SetPoint("TOPLEFT", listPanel, "BOTTOMLEFT", 0, -8)
    frame.footer:SetWidth(LIST_WIDTH)
    frame.footer:SetJustifyH("LEFT")

    frame:SetScript("OnShow", function() Viewer.Refresh() end)

    -- A suicide mid-batch reorders an open window rather than going stale behind
    -- the reader; presence changes regrade the median and the greying.
    ns.Priority.RegisterListener(function() Viewer.Refresh() end)
    ns.Roster.RegisterListener(function() Viewer.Refresh() end)
end

function Viewer.Show()
    if not frame then build() end
    frame:RestorePosition()
    frame:Show()
    Viewer.Refresh()
end

function Viewer.Toggle()
    if frame and frame:IsShown() then frame:Hide() else Viewer.Show() end
end

function Viewer.IsShown()
    return frame ~= nil and frame:IsShown()
end
