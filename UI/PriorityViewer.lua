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
local TierRoster = ns.TierRoster
local Widgets = ns.Widgets

local ROW_H = 18
local LIST_WIDTH = 360
local SCROLL_WIDTH = LIST_WIDTH - 30
local ROW_INSET = 4
local ROW_WIDTH = SCROLL_WIDTH - ROW_INSET - Widgets.SCROLLBAR_GUTTER
local TIER_W = 30
local BAND_H = 20
local WINDOW_HEIGHT = 440
local LIST_HEIGHT = 300

local frame, content, rows, bands

--------------------------------------------------------------------------------
-- What the client knows
--------------------------------------------------------------------------------

local function DB() return ns.Database.Priority() end

--- Is SK the mode in force? true, false, or nil when no round is open.
--
-- The host reads its own round, a client reads the one the host sent it. A list
-- can sit seeded through a whole ROLL night, and a viewer that does not say so
-- invites the reader to assume tonight's loot is going by these positions.
local function skInForce()
    local round = (ns.Round and ns.Round.current)
        or (ns.Client and ns.Client.round)
        or nil
    if not round or round.state ~= C.ROUND_STATE.OPEN then return nil end
    return round.lootMode == C.LOOT_MODE.SK
end

--- The tier count to draw with, and whether it is real. The hierarchy editor
-- resolves it the same way, through the same call, so the two screens cannot
-- disagree about which tiers are a synced fact and which are a local guess.
local function activeTierCount()
    local client = ns.Client
    if client and client.TierCountInForce then return client.TierCountInForce() end
    return ns.Database.DefaultTierCount(), false
end

--- Resolve every WoW-facing lookup the row model needs, so PriorityList.viewRows
-- stays arithmetic over plain tables (spec 011 section 4).
--
-- A character's tier comes from its position in its OWNER's hierarchy. Read from
-- the campaign's stored member records (spec 013 section 3), so the badges and the
-- bands survive a reload instead of emptying until somebody republishes. What a
-- tier is not is a position on this list: the two decide different halves of a
-- contest (spec 010 section 3). An owner who has submitted nothing to this
-- campaign leaves their characters without a tier, and they band separately.
local function tierIndex(tierCount)
    local out = {}
    for _, member in ipairs(ns.Campaign.Members()) do
        for position, char in ipairs(member.order) do
            out[char] = ns.Tiers.forPosition(position, tierCount)
        end
    end
    return out
end

local function context(order, tierCount)
    local claims = ns.Roster.claims
    local tierOf = tierIndex(tierCount)
    local owners, present, classes, contested, tiers = {}, {}, {}, {}, {}
    for _, name in ipairs(order) do
        local claim = claims[name:lower()]
        local owner = claim and claim.owners[1] or nil
        owners[name] = owner
        present[name] = ns.Roster.IsPresent(name) and true or nil
        classes[name] = ns.Roster.ClassOfAny(name)
        contested[name] = (claim and claim.contested) and true or nil
        tiers[name] = tierOf[name]
    end
    return { owners = owners, present = present, classes = classes,
             contested = contested, tiers = tiers, me = UnitName("player") }
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

    -- The tier sits at the right edge with the name stopping short of it, rather
    -- than after the name: a badge anchored to a variable-width name lands in a
    -- different place on every row, and a centred one drifts under whatever is
    -- beside it.
    row.tier = Widgets.Label(row, "", "GameFontNormalSmall")
    row.tier:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.tier:SetWidth(TIER_W)
    row.tier:SetJustifyH("RIGHT")

    row.name = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.position, "RIGHT", 6, 0)
    row.name:SetWidth(ROW_WIDTH - 32 - TIER_W - 6)
    row.name:SetJustifyH("LEFT")

    rows[index] = row
    return row
end

--- A tier heading. The list is grouped by tier (spec 013 section 6) because a tier
-- is the first gate on every item: a lower tier is never consulted while a higher
-- one can still supply a winner, so the top of the list is not the front of the
-- queue -- the top of T1 is.
local function createBand(index)
    local band = CreateFrame("Frame", nil, content)
    band:SetWidth(ROW_WIDTH)
    band:SetHeight(BAND_H)

    band.text = Widgets.Label(band, "", "GameFontNormalSmall")
    band.text:SetPoint("BOTTOMLEFT", band, "BOTTOMLEFT", 0, 4)

    band.line = band:CreateTexture(nil, "ARTWORK")
    band.line:SetHeight(1)
    band.line:SetPoint("BOTTOMLEFT", band, "BOTTOMLEFT", 0, 1)
    band.line:SetPoint("BOTTOMRIGHT", band, "BOTTOMRIGHT", 0, 1)

    bands[index] = band
    return band
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

function Viewer.Refresh()
    if not frame or not frame:IsShown() then return end

    local db = DB() or {}
    local order = db.order or {}

    -- The header names the campaign, so a screenshot is unambiguous about which
    -- list it shows (spec 012 section 13).
    local label = ns.Campaign.ActiveLabel()
    if #order == 0 then
        frame.header:SetText(string.format("\"%s\": the priority list is not seeded.", label))
        frame.mode:SetText("|cff888888Suicide Kings is unavailable until the master looter "
            .. "seeds it.|r")
        for _, row in ipairs(rows) do row:Hide() end
        for _, band in ipairs(bands) do band:Hide() end
        content:SetHeight(1)
        return
    end

    frame.header:SetText(string.format("\"%s\" - %d characters, version %d, seed %d",
        label, #order, db.version or 0, db.seed or 0))

    local sk = skInForce()
    if sk == nil then
        frame.mode:SetText("|cff888888No round is open. These positions apply to the next one "
            .. "the host opens under SK.|r")
    elseif sk then
        frame.mode:SetText("|cff66ff66The open round is running under SK.|r")
    else
        frame.mode:SetText("|cffffaa00The open round is running under ROLL; these positions "
            .. "are not deciding it.|r")
    end

    local tierCount, tierSynced = activeTierCount()
    local view = PriorityList.viewRows(order, context(order, tierCount))

    -- Grouped by tier, and inside a band still in list order -- which is exactly the
    -- order a round awards in (spec 003 section 5). The position number stays on
    -- every row: it is the number people came to read, and a suicide is announced
    -- in terms of it.
    local groups = TierRoster.groupRows(view, tierCount)

    local y, rowIndex, bandIndex = 0, 0, 0
    for _, group in ipairs(groups) do
        bandIndex = bandIndex + 1
        local band = bands[bandIndex] or createBand(bandIndex)
        band.text:SetText(string.format("|cffe6b422%s|r |cff888888(%d)|r",
            group.label, #group.rows))
        band.line:SetTexture(0.5, 0.4, 0.15, 0.7)
        band:ClearAllPoints()
        band:SetPoint("TOPLEFT", content, "TOPLEFT", ROW_INSET, -y)
        band:Show()
        y = y + BAND_H

        for _, entry in ipairs(group.rows) do
            rowIndex = rowIndex + 1
            local row = rows[rowIndex] or createRow(rowIndex)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", ROW_INSET, -y)

            -- The rank inside this tier, not the global list index: a tier is
            -- walked to exhaustion before the next is consulted, so "third in T1" is
            -- where this character actually stands in the queue for a T1 item.
            --
            -- The colour is still the global near-the-top signal (spec 010 section
            -- 11), which is a fact about the whole list rather than about the band.
            row.position:SetText((entry.aboveMedian and "|cff66ff66#" or "|cffaaaaaa#")
                .. (entry.tierPosition or entry.position) .. "|r")

            local label = Widgets.ColorName(entry.char, entry.class)
                .. " |cff888888(" .. (entry.owner or "unclaimed") .. ")|r"
            if entry.isSelf then label = label .. " |cffaaaaaa*|r" end
            if entry.contested then label = label .. " |cffff4040contested|r" end
            row.name:SetText(label)

            -- Dimmed when the tier count behind it is this client's own default
            -- rather than one the host announced, the same signal the hierarchy
            -- editor gives. Blank when nobody has published the owner's ordering,
            -- because there is no honest number to put there -- those rows are
            -- gathered under their own band rather than shown as Rest.
            row.tier:SetText(entry.tier
                and ((tierSynced and "|cffaaaaaa" or "|cff666666")
                     .. ns.Tiers.label(entry.tier, tierCount) .. "|r")
                or "")

            row:SetAlpha(entry.present and 1 or 0.5)
            row:Show()
            y = y + ROW_H
        end
    end
    for i = rowIndex + 1, #rows do rows[i]:Hide() end
    for i = bandIndex + 1, #bands do bands[i]:Hide() end

    content:SetHeight(math.max(y, 1))
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local function build()
    rows, bands = {}, {}

    frame = Widgets.Window("RaidLootSystemPriorityViewer", "sklist",
        "Raid Loot System - Priority list", LIST_WIDTH + 40, WINDOW_HEIGHT)

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

    -- A suicide mid-round reorders an open window rather than going stale behind
    -- the reader; presence changes regrade the median and the greying.
    ns.Priority.RegisterListener(function() Viewer.Refresh() end)
    ns.Roster.RegisterListener(function() Viewer.Refresh() end)
    ns.Campaign.RegisterListener(function() Viewer.Refresh() end)
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
