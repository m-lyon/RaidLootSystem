-- UI/HostPanel.lua
--
-- The master looter's control surface (spec 006): raid settings, batch candidates,
-- roster health, the live batch, and the loot-still-on-corpse banner. Only reachable
-- while this client holds master looter; losing it closes the panel.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the
-- `hostpanel` suite: why Start roll is disabled, why a setting is frozen, and the
-- addon-status rows. The frame code renders those answers.
--
-- The priority-list section (spec 010 section 10) is built by Modules/PriorityList
-- when it exists; until then the panel says so in its place.

local ADDON, ns = ...

ns.HostPanel = {}
local HostPanel = ns.HostPanel

local C = ns.Constants

--------------------------------------------------------------------------------
-- Pure: preconditions and explanations (section 3)
--------------------------------------------------------------------------------

--- Why Start roll is disabled, or nil when it may be pressed.
-- @param ctx { isHost, lootMethod, batchOpen, scanning, ticked }
function HostPanel.StartBlocker(ctx)
    ctx = ctx or {}
    if not ctx.isHost then
        if ctx.lootMethod ~= "master" then
            return "The group is not on master loot."
        end
        return "You are not the master looter."
    end
    if ctx.batchOpen then return "A batch is already open. Close or cancel it first." end
    if ctx.scanning then return "Still looking the loot up." end
    if (ctx.ticked or 0) == 0 then return "No items are ticked." end
    return nil
end

local FROZEN_SETTING = { tierCount = true, timerSeconds = true, lootMode = true }

--- Why a setting cannot be changed right now, or nil.
function HostPanel.SettingBlocker(key, batchOpen)
    if FROZEN_SETTING[key] and batchOpen then
        return "Frozen while a batch is open. Your change would apply to the next one."
    end
    return nil
end

--- The inline note under the tier-count slider.
function HostPanel.TierExplanation(tierCount, lootMode)
    if (tierCount or 0) > 0 then return "" end
    if lootMode == C.LOOT_MODE.SK then
        return "No tiers -- the priority list decides every item."
    end
    return "Flat roll -- no priorities."
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

local frame, content
local settings, candidates, health, priority, live, banner
local candidateRows, healthRows, liveRows = {}, {}, {}
local ticked = {}                   -- itemIdx -> false when the host unticked it
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
    for _, panel in ipairs({ banner, settings, candidates, health, priority, live }) do
        if panel:IsShown() then
            panel:ClearAllPoints()
            panel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            y = y + panel:GetHeight() + 6
        end
    end
    content:SetHeight(math.max(y, 1))
end

--------------------------------------------------------------------------------
-- Raid settings (section 3)
--------------------------------------------------------------------------------

local function change(key, value)
    local ok, why = ns.Session.ChangeSetting(key, value)
    if not ok then ns.Print(why) end
    HostPanel.Refresh()
end

local function buildSettings(parent)
    local panel = section(parent, "Raid settings", 214)

    panel.tier = Widgets.Slider(panel, "RaidLootSystemHostTierSlider", "Tier count",
        C.MIN_TIER_COUNT, C.MAX_TIER_COUNT, 1, function(value)
            change("tierCount", math.floor(value + 0.5))
        end)
    panel.tier:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -40)

    panel.tierNote = Widgets.Label(panel, "", "GameFontDisableSmall")
    panel.tierNote:SetPoint("TOPLEFT", panel.tier, "BOTTOMLEFT", 0, -12)
    panel.tierNote:SetWidth(200)
    panel.tierNote:SetJustifyH("LEFT")

    panel.timer = Widgets.Slider(panel, "RaidLootSystemHostTimerSlider", "Entry timer (s)",
        C.MIN_TIMER_SECONDS, C.MAX_TIMER_SECONDS, 15, function(value)
            change("timerSeconds", math.floor(value / 15 + 0.5) * 15)
        end)
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
    local batchOpen = ns.Session.current ~= nil
        and ns.Session.current.state == C.SESSION_STATE.OPEN
    local frozen = HostPanel.SettingBlocker("tierCount", batchOpen)

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
        or "Seconds a batch stays open. Announced to the raid.")
end

--------------------------------------------------------------------------------
-- Batch candidates (section 3)
--------------------------------------------------------------------------------

local function tickedItems()
    local items = {}
    for _, item in ipairs(ns.LootDetect.candidates) do
        if ticked[item.idx] ~= false then items[#items + 1] = item end
    end
    return items
end

local function startRoll()
    local items = tickedItems()
    local ok, why = ns.Session.Open(items)
    if not ok then ns.Print(why) end
    HostPanel.Refresh()
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
    local panel = section(parent, "Batch candidates", 120)

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
        ticked[row.itemIdx] = (self:GetChecked() == 1)
        HostPanel.Refresh()
    end)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(16)
    row.icon:SetHeight(16)
    row.icon:SetPoint("LEFT", row.check, "RIGHT", 2, 0)

    row.label = CreateFrame("Button", nil, row)
    row.label:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.label:SetWidth(INNER - 130)
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

    row.right = Widgets.Label(row, "", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
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
        row.itemString = item.itemString
        row.link = item.info and item.info.link
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", candidates.list, "TOPLEFT", 0, -(n - 1) * ROW_H)
        row.check:SetChecked(ticked[item.idx] ~= false)
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

    local session = ns.Session.current
    local blocker = HostPanel.StartBlocker({
        isHost = ns.Session.IsHost(),
        lootMethod = (GetLootMethod()),
        batchOpen = session ~= nil and session.state == C.SESSION_STATE.OPEN,
        scanning = LootDetect.scanning,
        ticked = #tickedItems(),
    })
    if blocker then candidates.start:Disable() else candidates.start:Enable() end
    Widgets.Tooltip(candidates.start, "Start roll",
        blocker or string.format("Open a batch on the %d ticked item(s).", #tickedItems()))

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
            line("|cffff4040Contested:|r " .. name .. " -- claimed by "
                .. table.concat(claim and claim.owners or {}, ", "))
        end
    end

    local unclaimed = Roster.UnclaimedGroupMembers()
    if #unclaimed == 0 then
        line("|cff66ff66Everyone in the group is claimed.|r")
    else
        line("|cffffaa00Unclaimed:|r " .. table.concat(unclaimed, ", "))
    end

    for _, row in ipairs(HostPanel.AddonStatus(Roster.GroupMembers(), ns.Session.peers, C.VERSION)) do
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
    panel.note:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -4)
    panel.note:SetWidth(INNER - 20)
    panel.note:SetJustifyH("LEFT")
    return panel
end

local function refreshPriority()
    if ns.PriorityList and ns.PriorityList.RefreshSection then
        ns.PriorityList.RefreshSection(priority)
        return
    end
    local order = DB().Priority().order
    priority.note:SetText(#order == 0
        and "Not seeded. Suicide Kings is unavailable until the list exists."
        or string.format("%d characters, version %d.", #order, DB().Priority().version or 0))
end

--------------------------------------------------------------------------------
-- Live batch (section 3)
--------------------------------------------------------------------------------

local function buildLive(parent)
    -- Abort discards submitted entries, so it is confirmed (spec 000 section 8).
    StaticPopupDialogs["RLS_CONFIRM_ABORT"] = {
        text = "Cancel the open batch? Every submitted entry is discarded.",
        button1 = "Cancel batch",
        button2 = "Keep it",
        OnAccept = function()
            if not ns.Session.Abort(C.ABORT_REASON.MANUAL) then
                ns.Print("there is no batch of yours to cancel.")
            end
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    local panel = section(parent, "Live batch", 100)

    panel.countdown = Widgets.Label(panel, "", "GameFontNormal")
    panel.countdown:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -8)

    panel.list = CreateFrame("Frame", nil, panel)
    panel.list:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -6)
    panel.list:SetWidth(INNER - 20)
    panel.list:SetHeight(1)

    panel.close = Widgets.Button(panel, "Close now", 90, 22, function()
        if not ns.Session.Close() then ns.Print("there is no batch of yours to close.") end
    end)
    panel.close:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 8)
    Widgets.Tooltip(panel.close, "Close now", "Resolve immediately with what has been submitted.")

    panel.extend = Widgets.Button(panel, "Extend", 80, 22, function()
        local ok, why = ns.Session.Extend(C.EXTEND_SECONDS)
        if not ok then ns.Print(why) end
    end)
    panel.extend:SetPoint("LEFT", panel.close, "RIGHT", 6, 0)
    Widgets.Tooltip(panel.extend, "Extend", "Add " .. C.EXTEND_SECONDS .. " seconds. Announced.")

    panel.abort = Widgets.Button(panel, "Abort", 80, 22, function()
        StaticPopup_Show("RLS_CONFIRM_ABORT")
    end)
    panel.abort:SetPoint("LEFT", panel.extend, "RIGHT", 6, 0)
    Widgets.Tooltip(panel.abort, "Abort", "Cancel the batch and discard every entry. Confirmed.")

    return panel
end

local function refreshLive()
    local session = ns.Session.current
    local open = session ~= nil and session.state == C.SESSION_STATE.OPEN
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

    local outstanding = ns.Session.OutstandingPlayers()
    local submitted = ns.Session.SubmittedNames(session)
    line(string.format("%d submitted%s", #submitted,
        #outstanding > 0 and (", waiting on " .. table.concat(outstanding, ", ")) or ", everyone is in"))
    for _, count in ipairs(ns.Session.EntryCounts(session)) do
        local item = ns.Session.ItemByIdx(session, count.idx)
        line("  " .. ns.LootDetect.Label(item),
            count.count == 0 and "|cffff6060no entries|r"
            or string.format("%d entr%s", count.count, count.count == 1 and "y" or "ies"))
    end
    for i = n + 1, #liveRows do liveRows[i]:Hide() end

    live.list:SetHeight(n * ROW_H)
    live:SetHeight(34 + n * ROW_H + 40)
end

local function refreshCountdown()
    local session = ns.Session.current
    if not session or session.state ~= C.SESSION_STATE.OPEN then return end
    local left = session.endsAt - GetTime()
    local text = ns.RollWindow.FormatCountdown(left)
    if left <= C.COUNTDOWN_WARN_SECONDS then text = "|cffffaa00" .. text .. "|r" end
    live.countdown:SetText(text)
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
        .. "  -- a despawned corpse takes them with it.")
    banner:Show()
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

local function build()
    frame = Widgets.Window("RaidLootSystemHostPanel", "host",
        "Raid Loot System -- Host panel", WIDTH, 620)

    local scroll
    scroll, content = Widgets.ScrollArea(frame, "RaidLootSystemHostScroll", INNER + 4, 560)
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -40)

    banner = buildBanner(content)
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
        if not ns.Session.IsHost() then
            -- Losing master looter closes the panel (section 2).
            ns.Print("you are no longer the master looter; the host panel closed.")
            frame:Hide()
            return
        end
        refreshCountdown()
        refreshBanner()
        layoutSections()
    end)
end

function HostPanel.Refresh()
    if not frame or not frame:IsShown() then return end
    refreshSettings()
    refreshCandidates()
    refreshHealth()
    refreshPriority()
    refreshLive()
    refreshCountdown()
    refreshBanner()
    layoutSections()
end

function HostPanel.Show()
    if not ns.Session.IsHost() then
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
    ns.Session.RegisterListener(function() HostPanel.Refresh() end)
    ns.LootDetect.RegisterListener(function()
        ticked = {}                          -- a new list means a fresh set of ticks
        HostPanel.Refresh()
    end)
    ns.Roster.RegisterListener(function() HostPanel.Refresh() end)
end
