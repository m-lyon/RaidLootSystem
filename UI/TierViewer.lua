-- UI/TierViewer.lua
--
-- The campaign tier roster (spec 013 section 5): who composes each tier, for every
-- player rather than only the master looter. Read-only, like the priority viewer.
--
-- Sourced from the campaign's stored member hierarchies rather than from the
-- priority list, so it answers under ROLL and before any list is seeded -- which is
-- when a group is most likely to be arguing about tiers.

local ADDON, ns = ...

ns.TierViewer = {}
local Viewer = ns.TierViewer

local TierRoster = ns.TierRoster
local Tiers = ns.Tiers
local Widgets = ns.Widgets
local Client = ns.Client

local ROW_H = 18
local BAND_H = 20
local LIST_WIDTH = 360
local SCROLL_WIDTH = LIST_WIDTH - 30
local ROW_INSET = 4
local ROW_WIDTH = SCROLL_WIDTH - ROW_INSET - Widgets.SCROLLBAR_GUTTER
local WINDOW_HEIGHT = 460
local LIST_HEIGHT = 320

local frame, content, rows, bands

-- Which campaign is on screen. The roster outlives the raid now, so this is not
-- pinned to the active campaign: a player comparing two campaigns out of game is
-- the case the storage exists for.
local target

--------------------------------------------------------------------------------
-- What the client knows
--------------------------------------------------------------------------------

local function campaignOnScreen()
    if target and ns.Campaign.Get(target) then return ns.Campaign.Get(target) end
    target = ns.Campaign.ActiveId()
    return ns.Campaign.Get(target)
end

local function campaignOptions()
    local options = {}
    for i, c in ipairs(ns.Campaign.List()) do
        options[i] = { value = c.id, text = c.label or c.id }
    end
    return options
end

--- Everyone announcing this campaign in HI, plus ourselves when we are in it, which
-- is who TierRoster.missing measures the stored records against. Empty out of a
-- raid, so nobody is reported missing merely for being offline.
local function announced(campaignId)
    local out = {}
    for player, id in pairs((ns.Round and ns.Round.peerCampaign) or {}) do
        if id == campaignId then out[#out + 1] = player end
    end
    local me = UnitName("player")
    if me and campaignId == ns.Campaign.ActiveId() then out[#out + 1] = me end
    return out
end

--- "tonight", "3 days ago" -- how old a submitted ordering is. A band built from a
-- hierarchy submitted weeks ago is still a fact, but a reader has to be able to
-- tell it from one submitted this evening.
local function ageOf(at)
    if not at then return "at an unknown time" end
    local days = math.floor((time() - at) / 86400)
    if days <= 0 then return "today" end
    if days == 1 then return "yesterday" end
    return days .. " days ago"
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function createRow(index)
    local row = CreateFrame("Frame", nil, content)
    row:SetWidth(ROW_WIDTH)
    row:SetHeight(ROW_H)
    row:EnableMouse(true)

    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetWidth(10)
    row.dot:SetHeight(10)
    row.dot:SetPoint("LEFT", row, "LEFT", 2, 0)

    row.name = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row, "LEFT", 18, 0)
    row.name:SetWidth(ROW_WIDTH - 22)
    row.name:SetJustifyH("LEFT")

    rows[index] = row
    return row
end

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

    local campaign = campaignOnScreen()
    frame.picker:SetOptions(campaignOptions())
    frame.picker:SetValue(target or "")

    for _, row in ipairs(rows) do row:Hide() end
    for _, band in ipairs(bands) do band:Hide() end

    if not campaign then
        frame.header:SetText("|cffffcc00No campaign. /rls campaign new <label> makes one.|r")
        frame.footer:SetText("")
        content:SetHeight(1)
        return
    end

    -- Resolved the same way the hierarchy editor and the priority viewer resolve it,
    -- through the same call, so a round open with a frozen count never draws a
    -- different band count here than it decides with (spec 011 section 4).
    local tierCount, tierSynced = Client.TierCountInForce(campaign.id)
    local members = ns.Campaign.MemberList(campaign)
    local tierLabel = tierCount > 0 and (tierCount .. " tiers, then Rest") or "flat roll, no tiers"
    frame.header:SetText(string.format("\"%s\" -- %s%s|r.", campaign.label or campaign.id,
        tierSynced and "|cffaaaaaa" or "|cff666666", tierLabel))

    local present = {}
    for _, member in ipairs(members) do
        for _, char in ipairs(member.order) do
            present[char] = ns.Roster.IsPresent(char) and true or nil
        end
    end

    local model = TierRoster.bands(members, tierCount,
        { present = present, me = UnitName("player") })

    local y, rowIndex, bandIndex = 0, 0, 0
    for _, group in ipairs(model) do
        bandIndex = bandIndex + 1
        local band = bands[bandIndex] or createBand(bandIndex)
        band.text:SetText(string.format("|cffe6b422%s|r |cff888888(%d)|r",
            group.label, #group.rows))
        band.line:SetTexture(0.5, 0.4, 0.15, 0.7)
        band:ClearAllPoints()
        band:SetPoint("TOPLEFT", content, "TOPLEFT", ROW_INSET, -y)
        band:Show()
        y = y + BAND_H

        -- An empty tier is drawn, and says so. A campaign at 3 tiers where nobody
        -- has a third character has an unfilled T3, which is not the same thing as
        -- a two-tier campaign, and renumbering would present it as one.
        if #group.rows == 0 then
            rowIndex = rowIndex + 1
            local row = rows[rowIndex] or createRow(rowIndex)
            row.dot:SetTexture(nil)
            row.name:SetText("|cff666666nobody has ranked a character here|r")
            Widgets.Tooltip(row, group.label, "No member has ranked this many characters.")
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", ROW_INSET, -y)
            row:Show()
            y = y + ROW_H
        end

        for _, entry in ipairs(group.rows) do
            rowIndex = rowIndex + 1
            local row = rows[rowIndex] or createRow(rowIndex)

            Widgets.SetDotPresent(row.dot, entry.present)
            local label = Widgets.ColorName(entry.char, entry.class)
                .. " |cff888888(" .. tostring(entry.owner) .. ")|r"
            if entry.isSelf then label = label .. " |cffaaaaaa*|r" end
            row.name:SetText(label)

            Widgets.Tooltip(row, entry.char, string.format(
                "%s ranked this character %d in their hierarchy, submitted %s. %s",
                tostring(entry.owner), entry.position, ageOf(entry.at),
                entry.present and "In the raid." or "Not in the raid."))

            row:SetAlpha(entry.present and 1 or 0.6)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", ROW_INSET, -y)
            row:Show()
            y = y + ROW_H
        end
    end

    local missing = TierRoster.missing(announced(campaign.id), members)
    if #missing > 0 then
        frame.footer:SetText(string.format("|cffffaa00Not submitted: %s.|r |cff888888Their "
            .. "characters are in no tier until they publish a hierarchy.|r",
            table.concat(missing, ", ")))
    elseif #members == 0 then
        frame.footer:SetText("|cff888888Nobody has submitted a hierarchy for this campaign "
            .. "yet.|r")
    else
        frame.footer:SetText("|cff888888A tier decides who competes for an item before any "
            .. "roll or list position does.|r")
    end

    content:SetHeight(math.max(y, 1))
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local function build()
    rows, bands = {}, {}

    frame = Widgets.Window("RaidLootSystemTierViewer", "tiers",
        "Raid Loot System - Tiers", LIST_WIDTH + 40, WINDOW_HEIGHT)

    frame.picker = Widgets.Dropdown(frame, "RaidLootSystemTierViewerCampaign", 150,
        campaignOptions(), function(value)
            target = value
            Viewer.Refresh()
        end)
    frame.picker:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -36)

    frame.header = Widgets.Label(frame, "", "GameFontNormalSmall")
    frame.header:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -66)
    frame.header:SetWidth(LIST_WIDTH)
    frame.header:SetJustifyH("LEFT")

    local listPanel = Widgets.Panel(frame, 0.35)
    listPanel:SetPoint("TOPLEFT", frame.header, "BOTTOMLEFT", 0, -8)
    listPanel:SetWidth(LIST_WIDTH)
    listPanel:SetHeight(LIST_HEIGHT + 12)

    local scroll
    scroll, content = Widgets.ScrollArea(listPanel, "RaidLootSystemTierViewerScroll",
        SCROLL_WIDTH, LIST_HEIGHT)
    scroll:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 6, -6)

    frame.footer = Widgets.Label(frame, "", "GameFontDisableSmall")
    frame.footer:SetPoint("TOPLEFT", listPanel, "BOTTOMLEFT", 0, -8)
    frame.footer:SetWidth(LIST_WIDTH)
    frame.footer:SetJustifyH("LEFT")

    frame:SetScript("OnShow", function() Viewer.Refresh() end)

    -- A member publishing mid-raid moves someone between tiers, and presence
    -- changes regrade the dots.
    ns.Roster.RegisterListener(function() Viewer.Refresh() end)
    ns.Campaign.RegisterListener(function() Viewer.Refresh() end)
end

--- Point the roster at one campaign, for the host panel's button.
function Viewer.SetTarget(campaignId)
    target = campaignId
    Viewer.Refresh()
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
