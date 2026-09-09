-- UI/HostPanel.lua
--
-- The master looter's control surface (spec 006): raid settings, round candidates,
-- roster health, the live round, and the loot-still-on-corpse banner. Only reachable
-- while this client holds master looter; losing it closes the panel.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the
-- `hostpanel` suite: why Start roll is disabled, why a setting is frozen, and the
-- addon-status rows. The frame code renders those answers.
--
-- The priority-list section (spec 010 section 10) is built by Modules/PriorityList
-- into the frame this file reserves for it.

local ADDON, ns = ...

ns.HostPanel = {}
local HostPanel = ns.HostPanel

local C = ns.Constants

--------------------------------------------------------------------------------
-- Pure: preconditions and explanations (section 3)
--------------------------------------------------------------------------------

--- Why Start roll is disabled, or nil when it may be pressed.
-- @param ctx { isHost, lootMethod, roundOpen, scanning, ticked }
function HostPanel.StartBlocker(ctx)
    ctx = ctx or {}
    if not ctx.isHost then
        if ctx.lootMethod ~= "master" then
            return "The group is not on master loot."
        end
        return "You are not the master looter."
    end
    if ctx.roundOpen then return "A round is already open. Close or cancel it first." end
    if ctx.scanning then return "Still looking the loot up." end
    if (ctx.ticked or 0) == 0 then return "No items are ticked." end
    return nil
end

local FROZEN_SETTING = { tierCount = true, timerSeconds = true, lootMode = true }

--- Why a setting cannot be changed right now, or nil.
function HostPanel.SettingBlocker(key, roundOpen)
    if FROZEN_SETTING[key] and roundOpen then
        return "Frozen while a round is open. Your change would apply to the next one."
    end
    return nil
end

--- The inline note under the tier-count slider.
function HostPanel.TierExplanation(tierCount, lootMode)
    if (tierCount or 0) > 0 then return "" end
    if lootMode == C.LOOT_MODE.SK then
        return "No tiers - the priority list decides every item."
    end
    return "Flat roll - no priorities."
end

--- One row per raid member: their addon version, or "not running".
-- @param members  array of { name }
-- @param peers    player -> version, from HI
-- @param version  this client's version, to flag drift
-- @return array of { name, status, drift }, in member order
function HostPanel.AddonStatus(members, peers, version)
    local out = {}
    for i, member in ipairs(members or {}) do
        local theirs = peers and peers[member.name] or nil
        out[i] = {
            name = member.name,
            status = theirs or "not running",
            drift = theirs ~= nil and theirs ~= version,
        }
    end
    return out
end

--- The loot-mode dropdown's options, with SK disabled until the list is seeded
-- (spec 010 section 5): there is no half-configured SK state to explain.
function HostPanel.LootModeOptions(seeded)
    return {
        { value = C.LOOT_MODE.ROLL, text = "Roll" },
        { value = C.LOOT_MODE.SK, text = "Suicide Kings", disabled = not seeded,
          tooltipTitle = seeded and nil or "Not yet available",
          tooltip = seeded and nil or "Seed the priority list to enable Suicide Kings." },
    }
end

--------------------------------------------------------------------------------
-- WoW-facing. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

local Widgets = ns.Widgets          -- nil under the fixture runner, which never renders

local WIDTH = 480
local INNER = WIDTH - 60
local ROW_H = 20
local PAD = 16
-- The scroll bar hangs off this scroll area's own right edge, which by default
-- lines it up almost flush with the window's border, past the close button.
-- Trim the viewport a bit further so the bar sits back underneath the button.
local SCROLL_RIGHT_TRIM = 14

local frame, content
local settings, candidates, health, priority, live, banner, pending, awaiting, campaign
local candidateRows, healthRows, liveRows, pendingRows, awaitingRows = {}, {}, {}, {}, {}
local ticked = {}                   -- itemId -> false when the host unticked it. Keyed by
                                    -- id, not idx: a rebuild renumbers idx.
local refreshAccumulator = 0

local function DB() return ns.Database end

--------------------------------------------------------------------------------
-- Building blocks
--------------------------------------------------------------------------------

local function section(parent, title, height)
    local panel = Widgets.Panel(parent, 0.3)
    panel:SetWidth(INNER)
    panel:SetHeight(height)
    panel.title = Widgets.Label(panel, title, "GameFontNormal")
    panel.title:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -8)
    return panel
end

--- A pooled one-line row: a label on the left, optional text on the right.
local function textRow(pool, parent, i)
    local row = pool[i]
    if row then return row end
    row = CreateFrame("Frame", nil, parent)
    row:SetWidth(INNER - 20)
    row:SetHeight(ROW_H)
    row.left = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.left:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.left:SetWidth(INNER - 120)
    row.left:SetJustifyH("LEFT")
    row.right = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.right:SetJustifyH("RIGHT")
    pool[i] = row
    return row
end

local function layoutSections()
    local y = 0
    for _, panel in ipairs({ banner, awaiting, pending, campaign, settings, candidates,
                             health, priority, live }) do
        if panel:IsShown() then
            panel:ClearAllPoints()
            panel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            y = y + panel:GetHeight() + 6
        end
    end
    content:SetHeight(math.max(y, 1))
end

--------------------------------------------------------------------------------
-- Campaign (spec 012 section 13)
--
-- Which campaign this client is in, who else has joined it, and the whole
-- lifecycle. Every host setting below now reads and writes THIS campaign's `host`
-- table, so switching snaps them all over.
--------------------------------------------------------------------------------

local function campaignOptions()
    local options = {}
    for i, c in ipairs(ns.Campaign.List()) do
        options[i] = { value = c.id, text = c.label or c.id }
    end
    return options
end

--- Delete needs its own picker: the switcher above cannot serve double duty, because
-- selecting in it *is* switching, and section 11 refuses to delete the campaign you
-- are in. Undeletable campaigns are listed and greyed with the reason on the tooltip
-- rather than hidden -- "why is mine not in the list" is a worse question than being
-- told why not.
local function deletableOptions()
    local options = { { value = "", text = "Delete which?" } }
    for _, c in ipairs(ns.Campaign.List()) do
        local blocker = ns.Campaign.DeleteRefusal(c.id)
        options[#options + 1] = {
            value = c.id,
            text = c.label or c.id,
            disabled = blocker ~= nil,
            tooltipTitle = blocker and (c.label or c.id) or nil,
            tooltip = blocker,
        }
    end
    return options
end

-- Where the note starts, measured from the panel's top: title, picker, the button
-- row, then the delete picker. The note wraps to an unpredictable number of lines,
-- so the section's own height is computed from it in refreshCampaign rather than
-- guessed here -- layoutSections stacks panels by GetHeight, so a section that
-- under-reports overlaps the one below it.
local NOTE_TOP = 122

local function buildCampaign(parent)
    local panel = section(parent, "Campaign", NOTE_TOP + 30)

    panel.picker = Widgets.Dropdown(panel, "RaidLootSystemHostCampaign", 150,
        campaignOptions(), function(value)
            local ok, why = ns.Campaign.Switch(value)
            if not ok then ns.Print(why) end
            HostPanel.Refresh()
        end)
    panel.picker:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -24)

    panel.joined = Widgets.Label(panel, "", "GameFontHighlightSmall")
    panel.joined:SetPoint("TOPLEFT", panel, "TOPLEFT", 190, -30)
    panel.joined:SetWidth(INNER - 200)
    panel.joined:SetJustifyH("LEFT")

    panel.invite = Widgets.Button(panel, "Invite raid", 90, 20, function()
        local ok, why = ns.Campaign.Invite()
        if not ok then ns.Print(why) end
    end)
    panel.invite:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -58)
    Widgets.Tooltip(panel.invite, "Invite raid to campaign",
        "Everyone not already in it is offered the campaign. Re-inviting is how a "
        .. "misclicked Ignore is recovered: refusing stores nothing.")

    local function small(text, tip, onClick, anchor)
        local b = Widgets.Button(panel, text, 62, 20, onClick)
        b:SetPoint("LEFT", anchor, "RIGHT", 4, 0)
        Widgets.Tooltip(b, text, tip)
        return b
    end

    panel.new = small("New", "Create a campaign: settings, then which of your characters "
        .. "play in it.", function() ns.Campaigns.ShowCreate() end, panel.invite)
    panel.rename = small("Rename", "Rename this campaign. The new label reaches everyone on the "
        .. "next invite or round.", function()
            ns.Campaigns.PromptRename(ns.Campaign.ActiveId())
        end, panel.new)
    panel.export = small("Export", "A string carrying this campaign's id, settings and priority "
        .. "list, for repairing a fork.", function()
            ns.Campaigns.ShowExport(ns.Campaign.ActiveId())
        end, panel.rename)
    panel.import = small("Import", "Paste a campaign string. Importing one you already have is "
        .. "refused unless you confirm the overwrite.", function()
            ns.Campaigns.ShowImport()
        end, panel.export)

    panel.deleteLabel = Widgets.Label(panel, "Delete", "GameFontNormalSmall")
    panel.deleteLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -88)

    panel.delete = Widgets.Dropdown(panel, "RaidLootSystemHostCampaignDelete", 150,
        deletableOptions(), function(value)
            -- SetValue has already run with the chosen id, so put the prompt back
            -- before the confirmation opens: this control picks a target, it is not
            -- a selection that persists.
            panel.delete:SetValue("")
            if value ~= "" then ns.Campaigns.PromptDelete(value) end
        end)
    -- No frame-level tooltip: a UIDropDownMenuTemplate frame has no mouse enabled, so
    -- Widgets.Tooltip would never fire on it. The per-option tooltips carry the reason
    -- a given campaign cannot be deleted, which is the part worth reading anyway.
    panel.delete:SetPoint("TOPLEFT", panel, "TOPLEFT", 50, -84)

    panel.note = Widgets.Label(panel, "", "GameFontDisableSmall")
    panel.note:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -NOTE_TOP)
    panel.note:SetWidth(INNER - 24)
    panel.note:SetJustifyH("LEFT")
    return panel
end

local function refreshCampaign()
    local active = ns.Campaign.Active()
    campaign.picker:SetOptions(campaignOptions())
    campaign.picker:SetValue(active.id)

    local joined = ns.Campaign.Joined(active.id)
    if joined.total <= 1 then
        campaign.joined:SetText("|cff888888No one else is running the addon here.|r")
    elseif #joined.missing == 0 then
        campaign.joined:SetText(string.format("|cff66ff66%d/%d joined.|r",
            joined.joined, joined.total))
    else
        campaign.joined:SetText(string.format("|cffffaa00%d/%d joined|r |cff888888- not in it: %s|r",
            joined.joined, joined.total, table.concat(joined.missing, ", ")))
    end

    campaign.delete:SetOptions(deletableOptions())
    campaign.delete:SetValue("")

    campaign.note:SetText(string.format(
        "Tier count, timer, quality and loot mode below belong to \"%s\". "
        .. "Its priority list holds %d characters.", active.label,
        #(active.priority.order or {})))

    -- Measured after SetText, so a note that wraps to two lines is not clipped and
    -- does not overlap the section below.
    campaign:SetHeight(NOTE_TOP + math.max(campaign.note:GetHeight(), 12) + 10)
end

--------------------------------------------------------------------------------
-- Raid settings (section 3)
--------------------------------------------------------------------------------

local function change(key, value)
    local ok, why = ns.Round.ChangeSetting(key, value)
    if not ok then ns.Print(why) end
    HostPanel.Refresh()
end

local function buildSettings(parent)
    local panel = section(parent, "Raid settings", 214)

    panel.tier = Widgets.Slider(panel, "RaidLootSystemHostTierSlider", "Tier count",
        C.MIN_TIER_COUNT, C.MAX_TIER_COUNT, 1,
        function(value) change("tierCount", math.floor(value + 0.5)) end,
        function(value) panel.tier.text:SetText("Tier count: " .. math.floor(value + 0.5)) end)
    panel.tier:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -40)

    panel.tierNote = Widgets.Label(panel, "", "GameFontDisableSmall")
    panel.tierNote:SetPoint("TOPLEFT", panel.tier, "BOTTOMLEFT", 0, -12)
    panel.tierNote:SetWidth(200)
    panel.tierNote:SetJustifyH("LEFT")

    local function timerValue(value) return math.floor(value / 15 + 0.5) * 15 end
    panel.timer = Widgets.Slider(panel, "RaidLootSystemHostTimerSlider", "Entry timer (s)",
        C.MIN_TIMER_SECONDS, C.MAX_TIMER_SECONDS, 15,
        function(value) change("timerSeconds", timerValue(value)) end,
        function(value) panel.timer.text:SetText("Entry timer: " .. timerValue(value) .. "s") end)
    panel.timer:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -104)

    panel.quality = Widgets.Dropdown(panel, "RaidLootSystemHostQuality", 110,
        C.QUALITY_CHOICES, function(value) change("qualityThreshold", value) end)
    panel.quality:SetPoint("TOPLEFT", panel, "TOPLEFT", 220, -34)
    panel.qualityLabel = Widgets.Label(panel, "Quality threshold", "GameFontNormalSmall")
    panel.qualityLabel:SetPoint("BOTTOMLEFT", panel.quality, "TOPLEFT", 16, 0)

    panel.verbosity = Widgets.Dropdown(panel, "RaidLootSystemHostVerbosity", 110, {
        { value = C.VERBOSITY.OFF, text = "Off" },
        { value = C.VERBOSITY.SUMMARY, text = "Summary" },
        { value = C.VERBOSITY.VERBOSE, text = "Verbose" },
    }, function(value) change("verbosity", value) end)
    panel.verbosity:SetPoint("TOPLEFT", panel.quality, "BOTTOMLEFT", 0, -16)
    panel.verbosityLabel = Widgets.Label(panel, "Chat verbosity", "GameFontNormalSmall")
    panel.verbosityLabel:SetPoint("BOTTOMLEFT", panel.verbosity, "TOPLEFT", 16, 0)

    panel.lootMode = Widgets.Dropdown(panel, "RaidLootSystemHostLootMode", 110,
        HostPanel.LootModeOptions(false), function(value) change("lootMode", value) end)
    panel.lootMode:SetPoint("TOPLEFT", panel.verbosity, "BOTTOMLEFT", 0, -16)
    panel.lootModeLabel = Widgets.Label(panel, "Loot mode", "GameFontNormalSmall")
    panel.lootModeLabel:SetPoint("BOTTOMLEFT", panel.lootMode, "TOPLEFT", 16, 0)

    panel.autoClose = Widgets.CheckBox(panel, "RaidLootSystemHostAutoClose",
        "Auto-close when everyone is in", function(checked) change("autoClose", checked) end)
    panel.autoClose:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -170)

    panel.frozen = Widgets.Label(panel, "", "GameFontHighlightSmall")
    panel.frozen:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 12, 6)
    panel.frozen:SetWidth(INNER - 24)
    panel.frozen:SetJustifyH("LEFT")

    return panel
end

local function refreshSettings()
    local host = DB().Host()
    local roundOpen = ns.Round.current ~= nil
        and ns.Round.current.state == C.ROUND_STATE.OPEN
    local frozen = HostPanel.SettingBlocker("tierCount", roundOpen)

    settings.tier:SetValueQuiet(host.tierCount or 3)
    settings.timer:SetValueQuiet(host.timerSeconds or 180)
    settings.tier.text:SetText("Tier count: " .. (host.tierCount or 3))
    settings.timer.text:SetText("Entry timer: " .. (host.timerSeconds or 180) .. "s")
    settings.tierNote:SetText(HostPanel.TierExplanation(host.tierCount, host.lootMode))
    settings.quality:SetValue(host.qualityThreshold or 4)
    settings.verbosity:SetValue(DB().Settings().verbosity or C.VERBOSITY.SUMMARY)
    settings.lootMode:SetOptions(HostPanel.LootModeOptions(#DB().Priority().order > 0))
    settings.lootMode:SetValue(host.lootMode or C.LOOT_MODE.ROLL)
    settings.autoClose:SetChecked(host.autoClose and true or false)

    -- 3.3.5a: sliders and dropdowns are enabled or disabled by their own calls.
    if frozen then
        settings.tier:Disable()
        settings.timer:Disable()
        UIDropDownMenu_DisableDropDown(settings.lootMode)
        settings.frozen:SetText("|cffffaa00" .. frozen .. "|r")
    else
        settings.tier:Enable()
        settings.timer:Enable()
        UIDropDownMenu_EnableDropDown(settings.lootMode)
        settings.frozen:SetText("")
    end
    Widgets.Tooltip(settings.tier, "Tier count", frozen
        or "How many hierarchy positions count as distinct tiers. Announced to the raid.")
    Widgets.Tooltip(settings.timer, "Entry timer", frozen
        or "Seconds a round stays open. Announced to the raid.")
end

--------------------------------------------------------------------------------
-- Round candidates (section 3)
--------------------------------------------------------------------------------

local function tickKey(item)
    return (item.info and item.info.itemId) or item.itemString
end

local function tickedItems()
    local items = {}
    for _, item in ipairs(ns.LootDetect.candidates) do
        if ticked[tickKey(item)] ~= false then items[#items + 1] = item end
    end
    return items
end

local function startRoll()
    local items = tickedItems()
    -- A raid member who is not in this campaign would roll on nothing, so the host
    -- is warned and names them before the round opens (spec 012 section 6).
    ns.Campaigns.GuardOpen(function()
        local ok, why = ns.Round.Open(items)
        if not ok then ns.Print(why) end
        HostPanel.Refresh()
    end)
end

local function addItem(link)
    if not link or link == "" then
        ns.Print("give an item link: paste one, shift-click one, or drop a bag item on the box.")
        return
    end
    ns.LootDetect.AddCandidate(link, function(added)
        if added then
            candidates.addBox:SetText("")
            HostPanel.Refresh()
        end
    end)
end

--- A bag item dropped on the add box or its button.
local function receiveCursorItem()
    local kind, _, link = GetCursorInfo()
    if kind == "item" and link then
        ClearCursor()
        addItem(link)
        return true
    end
    return false
end

local function buildCandidates(parent)
    local panel = section(parent, "Round candidates", 120)

    panel.hint = Widgets.Label(panel, "", "GameFontDisableSmall")
    panel.hint:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -2)
    panel.hint:SetWidth(INNER - 20)
    panel.hint:SetJustifyH("LEFT")

    panel.list = CreateFrame("Frame", nil, panel)
    panel.list:SetPoint("TOPLEFT", panel.hint, "BOTTOMLEFT", 0, -4)
    panel.list:SetWidth(INNER - 20)
    panel.list:SetHeight(1)

    panel.addBox = Widgets.EditBox(panel, 200, 20)
    panel.addBox:SetScript("OnEnterPressed", function(self) addItem(self:GetText()) end)
    panel.addBox:SetScript("OnReceiveDrag", receiveCursorItem)
    panel.addBox:SetScript("OnMouseDown", function() receiveCursorItem() end)
    panel.addButton = Widgets.Button(panel, "Add item", 80, 20, function()
        if not receiveCursorItem() then addItem(panel.addBox:GetText()) end
    end)
    panel.addButton:SetPoint("LEFT", panel.addBox, "RIGHT", 4, 0)
    panel.addButton:SetScript("OnReceiveDrag", receiveCursorItem)
    Widgets.Tooltip(panel.addButton, "Add item",
        "Add an item the filter left out: paste or shift-click a link into the box, "
        .. "or drop an item from your bags here.")

    panel.start = Widgets.Button(panel, "Start roll", 100, 22, startRoll)
    panel.start:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 8)
    panel.addBox:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 12, 8)

    return panel
end

local function candidateRow(i)
    local row = candidateRows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, candidates.list)
    row:SetWidth(INNER - 20)
    row:SetHeight(ROW_H)

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetWidth(20)
    row.check:SetHeight(20)
    row.check:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.check:SetScript("OnClick", function(self)
        ticked[row.tickKey] = (self:GetChecked() == 1)
        HostPanel.Refresh()
    end)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(16)
    row.icon:SetHeight(16)
    row.icon:SetPoint("LEFT", row.check, "RIGHT", 2, 0)

    row.label = CreateFrame("Button", nil, row)
    row.label:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.label:SetWidth(INNER - 150)
    row.label:SetHeight(ROW_H)
    row.label.text = Widgets.Label(row.label, "", "GameFontHighlightSmall")
    row.label.text:SetAllPoints()
    row.label.text:SetJustifyH("LEFT")
    row.label:SetScript("OnEnter", function(self)
        if not row.itemString then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(row.itemString)
        GameTooltip:Show()
    end)
    row.label:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.label:SetScript("OnClick", function()
        if row.link and IsShiftKeyDown() then ChatEdit_InsertLink(row.link) end
    end)

    row.remove = Widgets.IconButton(row, "remove", 16, 16, function()
        ns.LootDetect.RemoveCandidate(row.itemId)
    end)
    row.remove:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    Widgets.Tooltip(row.remove, "Remove",
        "Take this item out of the round. Add it again by link if you change your mind.")

    row.right = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", row.remove, "LEFT", -4, 0)
    row.right:SetJustifyH("RIGHT")
    candidateRows[i] = row
    return row
end

local QUALITY_NAME = { [0] = "poor", "common", "uncommon", "rare", "epic", "legendary" }

local function refreshCandidates()
    local LootDetect = ns.LootDetect
    local items = LootDetect.candidates
    local n = 0

    for _, item in ipairs(items) do
        n = n + 1
        local row = candidateRow(n)
        row.itemIdx = item.idx
        row.tickKey = tickKey(item)
        row.itemString = item.itemString
        row.itemId = item.info and item.info.itemId
        row.link = item.info and item.info.link
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", candidates.list, "TOPLEFT", 0, -(n - 1) * ROW_H)
        row.check:SetChecked(ticked[row.tickKey] ~= false)
        row.icon:SetTexture(item.info and item.info.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local label = LootDetect.Label(item)
        if item.count > 1 then label = label .. " |cffffcc00x" .. item.count .. "|r" end
        if item.info and item.info.special then label = label .. " |cffffcc00*|r" end
        row.label.text:SetText(label)
        local quality = item.info and item.info.quality
        local where = item.lootSlot and ("slot " .. item.lootSlot) or "by link"
        row.right:SetText("|cff888888" .. (QUALITY_NAME[quality] or "?") .. ", " .. where .. "|r")
        row:Show()
    end
    for i = n + 1, #candidateRows do candidateRows[i]:Hide() end

    if LootDetect.scanning then
        candidates.hint:SetText("Looking the loot up...")
    elseif #items == 0 then
        candidates.hint:SetText("Nothing here is worth rolling for. Open a corpse as master looter, "
            .. "or add an item below.")
    else
        local skipped = #LootDetect.skipped
        candidates.hint:SetText(skipped > 0
            and string.format("%d skipped by the filter (quality, not equippable). Add one below.", skipped)
            or "")
    end

    local round = ns.Round.current
    local blocker = HostPanel.StartBlocker({
        isHost = ns.Round.IsHost(),
        lootMethod = (GetLootMethod()),
        roundOpen = round ~= nil and round.state == C.ROUND_STATE.OPEN,
        scanning = LootDetect.scanning,
        ticked = #tickedItems(),
    })
    if blocker then candidates.start:Disable() else candidates.start:Enable() end
    Widgets.Tooltip(candidates.start, "Start roll",
        blocker or string.format("Open a round on the %d ticked item(s).", #tickedItems()))

    local listH = math.max(n, 1) * ROW_H
    candidates.list:SetHeight(listH)
    candidates:SetHeight(48 + listH + 40)
end

--------------------------------------------------------------------------------
-- Roster health (section 3)
--------------------------------------------------------------------------------

local function buildHealth(parent)
    local panel = section(parent, "Roster health", 80)
    panel.request = Widgets.Button(panel, "Request rosters", 120, 20, function()
        ns.Roster.RequestAll()
        ns.Print("asked everyone to resend their roster.")
    end)
    panel.request:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -6)
    Widgets.Tooltip(panel.request, "Request rosters",
        "Ask every client to resend its roster, for when someone has just fixed a claim.")
    panel.list = CreateFrame("Frame", nil, panel)
    panel.list:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -6)
    panel.list:SetWidth(INNER - 20)
    panel.list:SetHeight(1)
    return panel
end

local function refreshHealth()
    local Roster = ns.Roster
    local n = 0
    local function line(left, right)
        n = n + 1
        local row = textRow(healthRows, health.list, n)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", health.list, "TOPLEFT", 0, -(n - 1) * ROW_H)
        row.left:SetText(left)
        row.right:SetText(right or "")
        row:Show()
    end

    local contested = Roster.ContestedNames()
    if #contested == 0 then
        line("|cff66ff66No contested characters.|r")
    else
        for _, name in ipairs(contested) do
            local claim = Roster.claims[name:lower()]
            line("|cffff4040Contested:|r " .. name .. " - claimed by "
                .. table.concat(claim and claim.owners or {}, ", "))
        end
    end

    local unclaimed = Roster.UnclaimedGroupMembers()
    if #unclaimed == 0 then
        line("|cff66ff66Everyone in the group is claimed.|r")
    else
        line("|cffffaa00Unclaimed:|r " .. table.concat(unclaimed, ", "))
    end

    for _, row in ipairs(HostPanel.AddonStatus(Roster.GroupMembers(), ns.Round.peers, C.VERSION)) do
        local colour = row.status == "not running" and "|cff888888"
            or (row.drift and "|cffffaa00" or "|cffaaaaaa")
        line("  " .. row.name, colour .. row.status .. "|r")
    end

    for i = n + 1, #healthRows do healthRows[i]:Hide() end
    health.list:SetHeight(n * ROW_H)
    health:SetHeight(34 + n * ROW_H + 8)
end

--------------------------------------------------------------------------------
-- Priority list (spec 010 section 10 builds it; this is its place)
--------------------------------------------------------------------------------

local function buildPriority(parent)
    local panel = section(parent, "Priority list", 50)
    panel.note = Widgets.Label(panel, "", "GameFontDisableSmall")
    -- The Verify/Reseed buttons (added later, in Priority.RefreshSection) sit at
    -- the same height as a tight offset here would put this text; push it down
    -- a few more pixels so the buttons don't clip it.
    panel.note:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -8)
    panel.note:SetWidth(INNER - 20)
    panel.note:SetJustifyH("LEFT")
    return panel
end

local function refreshPriority()
    if ns.Priority then
        ns.Priority.RefreshSection(priority)
        return
    end
    local order = DB().Priority().order
    priority.note:SetText(#order == 0
        and "Not seeded. Suicide Kings is unavailable until the list exists."
        or string.format("%d characters, version %d.", #order, DB().Priority().version or 0))
end

--------------------------------------------------------------------------------
-- Live round (section 3)
--------------------------------------------------------------------------------

local function buildLive(parent)
    -- Abort discards submitted entries, so it is confirmed (spec 000 section 8).
    StaticPopupDialogs["RLS_CONFIRM_ABORT"] = {
        text = "Cancel the open round? Every submitted entry is discarded.",
        button1 = "Cancel round",
        button2 = "Keep it",
        OnAccept = function()
            if not ns.Round.Abort(C.ABORT_REASON.MANUAL) then
                ns.Print("there is no round of yours to cancel.")
            end
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    local panel = section(parent, "Live round", 100)

    panel.countdown = Widgets.Label(panel, "", "GameFontNormal")
    panel.countdown:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -8)

    panel.list = CreateFrame("Frame", nil, panel)
    panel.list:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -6)
    panel.list:SetWidth(INNER - 20)
    panel.list:SetHeight(1)

    panel.close = Widgets.Button(panel, "Close now", 90, 22, function()
        if not ns.Round.Close() then ns.Print("there is no round of yours to close.") end
    end)
    panel.close:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 8)
    Widgets.Tooltip(panel.close, "Close now", "Resolve immediately with what has been submitted.")

    panel.extend = Widgets.Button(panel, "Extend", 80, 22, function()
        local ok, why = ns.Round.Extend(C.EXTEND_SECONDS)
        if not ok then ns.Print(why) end
    end)
    panel.extend:SetPoint("LEFT", panel.close, "RIGHT", 6, 0)
    Widgets.Tooltip(panel.extend, "Extend", "Add " .. C.EXTEND_SECONDS .. " seconds. Announced.")

    panel.abort = Widgets.Button(panel, "Abort", 80, 22, function()
        StaticPopup_Show("RLS_CONFIRM_ABORT")
    end)
    panel.abort:SetPoint("LEFT", panel.extend, "RIGHT", 6, 0)
    Widgets.Tooltip(panel.abort, "Abort", "Cancel the round and discard every entry. Confirmed.")

    return panel
end

local function refreshLive()
    local round = ns.Round.current
    local open = round ~= nil and round.state == C.ROUND_STATE.OPEN
    if not open then
        live:Hide()
        return
    end
    live:Show()

    local n = 0
    local function line(left, right)
        n = n + 1
        local row = textRow(liveRows, live.list, n)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", live.list, "TOPLEFT", 0, -(n - 1) * ROW_H)
        row.left:SetText(left)
        row.right:SetText(right or "")
        row:Show()
    end

    local outstanding = ns.Round.OutstandingPlayers()
    local submitted = ns.Round.SubmittedNames(round)
    line(string.format("%d submitted%s", #submitted,
        #outstanding > 0 and (", waiting on " .. table.concat(outstanding, ", ")) or ", everyone is in"))
    for _, count in ipairs(ns.Round.EntryCounts(round)) do
        local item = ns.Round.ItemByIdx(round, count.idx)
        line("  " .. ns.LootDetect.Label(item),
            count.count == 0 and "|cffff6060no entries|r"
            or string.format("%d entr%s", count.count, count.count == 1 and "y" or "ies"))
    end
    for i = n + 1, #liveRows do liveRows[i]:Hide() end

    live.list:SetHeight(n * ROW_H)
    live:SetHeight(34 + n * ROW_H + 40)
end

local function refreshCountdown()
    local round = ns.Round.current
    if not round or round.state ~= C.ROUND_STATE.OPEN then return end
    local left = round.endsAt - GetTime()
    local text = ns.RollWindow.FormatCountdown(left)
    if left <= C.COUNTDOWN_WARN_SECONDS then text = "|cffffaa00" .. text .. "|r" end
    live.countdown:SetText(text)
end

--------------------------------------------------------------------------------
-- Awaiting award (spec 007 section 4)
--
-- The roll window's results view is where awards are normally made, but it is a
-- window like any other and closing it used to leave the host with no route back
-- to an unawarded item. This is that route, and it outlives the results view: it
-- is keyed off the award records, so a round from two kills ago still lists here.
--------------------------------------------------------------------------------

local function buildAwaiting(parent)
    local panel = section(parent, "Awaiting award", 60)
    panel.list = CreateFrame("Frame", nil, panel)
    panel.list:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -6)
    panel.list:SetWidth(INNER - 20)
    panel.list:SetHeight(1)
    panel:Hide()
    return panel
end

local function awaitingRow(i)
    local row = awaitingRows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, awaiting.list)
    row:SetWidth(INNER - 20)
    row:SetHeight(ROW_H)

    row.left = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.left:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.left:SetWidth(INNER - 190)
    row.left:SetJustifyH("LEFT")

    row.award = Widgets.Button(row, "Award", 64, 18, function()
        if not row.record then return end
        ns.Award.Prompt(row.record.roundId, row.record.itemIdx, row.record.copy,
            IsShiftKeyDown())
    end)
    row.award:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.award:RegisterForClicks("LeftButtonUp")
    Widgets.Tooltip(row.award, "Award",
        "Give the item to the winner. Click for the corpse (master loot); shift-click to take "
        .. "it into your bags and trade it instead.")

    row.status = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.status:SetPoint("RIGHT", row.award, "LEFT", -6, 0)
    row.status:SetJustifyH("RIGHT")
    awaitingRows[i] = row
    return row
end

local function refreshAwaiting()
    local records = ns.Award.OutstandingRecords()
    if #records == 0 then
        awaiting:Hide()
        return
    end
    awaiting:Show()
    for i, record in ipairs(records) do
        local row = awaitingRow(i)
        row.record = record
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", awaiting.list, "TOPLEFT", 0, -(i - 1) * ROW_H)
        local info = ns.ItemInfo.Get(record.itemString)
        row.left:SetText((info.link or info.name or record.itemString) .. " for "
            .. record.char .. " |cff888888(" .. tostring(record.owner or "?") .. ")|r")
        -- A plain AWAITING record says nothing: the button already says what to do.
        -- A failed or lost one has to explain itself or the row looks stuck.
        row.status:SetText(record.delivery == C.DELIVERY.AWAITING and ""
            or ("|cffff6060" .. ns.Award.StatusText(record) .. "|r"))
        row:Show()
    end
    for i = #records + 1, #awaitingRows do awaitingRows[i]:Hide() end
    awaiting.list:SetHeight(#records * ROW_H)
    awaiting:SetHeight(34 + #records * ROW_H + 8)
end

--------------------------------------------------------------------------------
-- Pending deliveries (spec 007 section 5)
--------------------------------------------------------------------------------

local function buildPending(parent)
    local panel = section(parent, "Pending deliveries", 60)
    panel.list = CreateFrame("Frame", nil, panel)
    panel.list:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -6)
    panel.list:SetWidth(INNER - 20)
    panel.list:SetHeight(1)
    panel:Hide()
    return panel
end

local function pendingRow(i)
    local row = pendingRows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, pending.list)
    row:SetWidth(INNER - 20)
    row:SetHeight(ROW_H)
    row.left = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.left:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.left:SetWidth(INNER - 190)
    row.left:SetJustifyH("LEFT")
    row.deliver = Widgets.Button(row, "Deliver", 64, 18, function()
        if row.record then ns.Pending.Deliver(row.record) end
    end)
    row.deliver:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    Widgets.Tooltip(row.deliver, "Deliver",
        "Open a trade with the winner and place the item. They must be within 11 yards.")
    row.done = Widgets.Button(row, "Done", 44, 18, function()
        if row.record then
            StaticPopup_Show("RLS_CONFIRM_DELIVERED", ns.LootDetect.Label({ info = ns.ItemInfo.Get(row.record.itemString) }),
                row.record.winner, row.record)
        end
    end)
    row.done:SetPoint("RIGHT", row.deliver, "LEFT", -4, 0)
    Widgets.Tooltip(row.done, "Mark delivered", "You handed it over yourself. Confirmed.")
    row.abandon = Widgets.Button(row, "Abandon", 64, 18, function()
        if row.record then StaticPopup_Show("RLS_CONFIRM_ABANDON", row.record.winner, nil, row.record) end
    end)
    row.abandon:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    Widgets.Tooltip(row.abandon, "Abandon",
        "Give up on this delivery. The item stays with you and the history says so. Confirmed.")
    row.left2 = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.left2:SetPoint("RIGHT", row.done, "LEFT", -6, 0)
    row.left2:SetJustifyH("RIGHT")
    pendingRows[i] = row
    return row
end

local URGENCY_COLOUR = { ok = "|cffaaaaaa", amber = "|cffffaa00", red = "|cffff4040",
                         expired = "|cff888888" }

local function refreshPending()
    local records = ns.Pending.OutstandingRecords()
    if #records == 0 then
        pending:Hide()
        return
    end
    pending:Show()
    local now = time()
    for i, record in ipairs(records) do
        local row = pendingRow(i)
        row.record = record
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", pending.list, "TOPLEFT", 0, -(i - 1) * ROW_H)
        local info = ns.ItemInfo.Get(record.itemString)
        row.left:SetText((info.link or info.name or record.itemString) .. " for "
            .. record.winner .. " |cff888888(" .. tostring(record.owner or "?") .. ")|r")
        local left, urgency = ns.Pending.TimeLeft(record, now)
        row.left2:SetText(URGENCY_COLOUR[urgency] .. left .. "|r")
        -- An expired item cannot be traded; the only actions left are Done and Abandon.
        if urgency == "expired" then
            row.deliver:Hide()
            row.abandon:Show()
        else
            row.abandon:Hide()
            row.deliver:Show()
        end
        row:Show()
    end
    for i = #records + 1, #pendingRows do pendingRows[i]:Hide() end
    pending.list:SetHeight(#records * ROW_H)
    pending:SetHeight(34 + #records * ROW_H + 8)
end

--------------------------------------------------------------------------------
-- Loot still on corpse (section 3, spec 004 section 3)
--------------------------------------------------------------------------------

local function buildBanner(parent)
    local panel = Widgets.Panel(parent, 0.5)
    panel:SetWidth(INNER)
    panel:SetHeight(40)
    panel:SetBackdropBorderColor(1, 0.7, 0.2, 0.9)
    panel.text = Widgets.Label(panel, "", "GameFontHighlightSmall")
    panel.text:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -8)
    panel.text:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 6)
    panel.text:SetJustifyH("LEFT")
    panel.text:SetJustifyV("TOP")
    panel:Hide()
    return panel
end

local function refreshBanner()
    local items = ns.LootDetect.UnresolvedItems()
    if #items == 0 then
        banner:Hide()
        return
    end
    local labels = {}
    for i, item in ipairs(items) do labels[i] = ns.LootDetect.Label(item) end
    banner.text:SetText("|cffffaa00Still on the corpse:|r " .. table.concat(labels, " ")
        .. "  - a despawned corpse takes them with it.")
    banner:Show()
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

local function build()
    frame = Widgets.Window("RaidLootSystemHostPanel", "host",
        "Raid Loot System - Host panel", WIDTH, 620)

    local scroll
    scroll, content = Widgets.ScrollArea(frame, "RaidLootSystemHostScroll",
        INNER + Widgets.SCROLLBAR_GUTTER - SCROLL_RIGHT_TRIM, 560)
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -40)

    StaticPopupDialogs["RLS_CONFIRM_ABANDON"] = {
        text = "Give up on delivering to %s? The item stays in your bags and the history records the failure.",
        button1 = "Abandon",
        button2 = CANCEL,
        OnAccept = function(self) ns.Pending.Abandon(self.data) end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    StaticPopupDialogs["RLS_CONFIRM_DELIVERED"] = {
        text = "Mark %s as delivered to %s? This updates the history record.",
        button1 = "Delivered",
        button2 = CANCEL,
        OnAccept = function(self) ns.Pending.MarkDelivered(self.data) end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    banner = buildBanner(content)
    awaiting = buildAwaiting(content)
    pending = buildPending(content)
    campaign = buildCampaign(content)
    settings = buildSettings(content)
    candidates = buildCandidates(content)
    health = buildHealth(content)
    priority = buildPriority(content)
    live = buildLive(content)

    -- Shift-clicking a link while the add box has focus puts it there, the way it
    -- would go into a chat box.
    local insertLink = ChatEdit_InsertLink
    ChatEdit_InsertLink = function(text)
        if candidates.addBox:HasFocus() then
            candidates.addBox:Insert(text)
            return true
        end
        return insertLink(text)
    end

    frame:SetScript("OnShow", function() HostPanel.Refresh() end)
    frame:SetScript("OnUpdate", function(_, elapsed)
        refreshAccumulator = refreshAccumulator + elapsed
        if refreshAccumulator < 0.5 then return end
        refreshAccumulator = 0
        if not ns.Round.IsHost() then
            -- Losing master looter closes the panel (section 2).
            ns.Print("you are no longer the master looter; the host panel closed.")
            frame:Hide()
            return
        end
        refreshCountdown()
        refreshBanner()
        refreshAwaiting()
        refreshPending()
        layoutSections()
    end)
end

function HostPanel.Refresh()
    if not frame or not frame:IsShown() then return end
    refreshCampaign()
    refreshSettings()
    refreshCandidates()
    refreshHealth()
    refreshPriority()
    refreshLive()
    refreshCountdown()
    refreshBanner()
    refreshAwaiting()
    refreshPending()
    layoutSections()
end

function HostPanel.Show()
    if not ns.Round.IsHost() then
        local method = GetLootMethod()
        ns.Print(method == "master"
            and "the host panel is only for the master looter."
            or "the host panel needs the group on master loot, with you as master looter.")
        return false
    end
    if not frame then build() end
    frame:RestorePosition()
    frame:Show()
    HostPanel.Refresh()
    return true
end

function HostPanel.Toggle()
    if frame and frame:IsShown() then frame:Hide() else HostPanel.Show() end
end

function HostPanel.IsShown()
    return frame ~= nil and frame:IsShown()
end

function HostPanel.Init()
    ns.Round.RegisterListener(function() HostPanel.Refresh() end)
    ns.LootDetect.RegisterListener(function(_, newScan)
        -- A new corpse means a fresh set of ticks; a rebuild of the same one (a manual
        -- add, a lost slot, a moved quality bar) keeps what the host unticked.
        if newScan then ticked = {} end
        HostPanel.Refresh()
    end)
    ns.Roster.RegisterListener(function() HostPanel.Refresh() end)
    ns.Campaign.RegisterListener(function() HostPanel.Refresh() end)
end
