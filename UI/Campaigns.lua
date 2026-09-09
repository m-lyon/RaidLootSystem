-- UI/Campaigns.lua
--
-- The dialogs campaigns need (spec 012 sections 6, 7, 11 and 12): the invitation,
-- the hierarchy dialog that confirming makes you a member with, the create dialog,
-- rename, delete, and the export/import box.
--
-- The host panel and the hierarchy editor own their own campaign controls; this
-- file owns everything modal, because those dialogs are reachable from several
-- screens and from `/rls campaign`.

local ADDON, ns = ...

ns.Campaigns = {}
local Campaigns = ns.Campaigns

local C = ns.Constants
local Campaign = ns.Campaign

local WIDTH = 380
local ROW_H = 22
local LIST_HEIGHT = 260

local Widgets                        -- resolved in Init: UI/ files load after Modules/

local hierarchyFrame, createFrame, transferFrame
local pendingInvite                  -- { campaignId, label, from } while the dialog is up

--------------------------------------------------------------------------------
-- The invitation (section 6)
--
-- Ignore stores NOTHING: no campaign record, no ignore-list entry, no duration.
-- Re-inviting is the entire recovery mechanism, which deletes a whole class of
-- questions (how long does an ignore last, where are ignored campaigns listed)
-- and the state they would have needed. Escape is identical to Ignore.
--------------------------------------------------------------------------------

StaticPopupDialogs["RLS_CAMPAIGN_INVITE"] = {
    text = "%s",
    button1 = "Join",
    button2 = "Ignore",
    OnAccept = function(self)
        local invite = self.data
        Campaigns.ShowHierarchy(invite.campaignId, invite.label, "join")
    end,
    OnCancel = function() pendingInvite = nil end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function Campaigns.ShowInvite(sender, campaignId, label)
    pendingInvite = { campaignId = campaignId, label = label, from = sender }
    StaticPopup_Show("RLS_CAMPAIGN_INVITE",
        string.format("%s invites you to the campaign \"%s\".\n\nJoining keeps its priority list "
            .. "and settings separate from your other groups.", tostring(sender), label),
        nil, pendingInvite)
end

--------------------------------------------------------------------------------
-- The hierarchy dialog (section 7)
--
-- One scrolling list of every character in roster.chars: a checkbox for inclusion,
-- a position numbered over the ticked rows only, and up/down buttons. Seeded from
-- roster.defaultHierarchy, so the default is usually right and confirming is one
-- click. Cancelling leaves you a NON-MEMBER (on join) or abandons the campaign
-- entirely (on create) -- nothing is written either way.
--------------------------------------------------------------------------------

local rows = {}
local model = {}                     -- Campaign.HierarchyRows output, live
local mode                           -- "join" | "create" | "edit"
local target                         -- { campaignId, label, settings }

local function charsTable()
    return ns.Database.Roster().chars
end

local function refreshHierarchy()
    if not hierarchyFrame or not hierarchyFrame:IsShown() then return end
    local content = hierarchyFrame.content

    for i, entry in ipairs(model) do
        local row = rows[i]
        if not row then
            row = CreateFrame("Frame", nil, content)
            row:SetWidth(hierarchyFrame.rowWidth)
            row:SetHeight(ROW_H)

            row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            row.check:SetWidth(20)
            row.check:SetHeight(20)
            row.check:SetPoint("LEFT", row, "LEFT", 0, 0)
            row.check:SetScript("OnClick", function(self)
                model = Campaign.SetIncluded(model, row.index, self:GetChecked() == 1, charsTable())
                refreshHierarchy()
            end)

            row.position = Widgets.Label(row, "", "GameFontNormalSmall")
            row.position:SetPoint("LEFT", row.check, "RIGHT", 4, 0)
            row.position:SetWidth(22)
            row.position:SetJustifyH("RIGHT")

            row.name = Widgets.Label(row, "", "GameFontHighlightSmall")
            row.name:SetPoint("LEFT", row.position, "RIGHT", 6, 0)
            row.name:SetWidth(hierarchyFrame.rowWidth - 110)
            row.name:SetJustifyH("LEFT")

            row.down = Widgets.IconButton(row, "down", 18, 16, function()
                model = Campaign.MoveRow(model, row.index, row.index + 1, charsTable())
                refreshHierarchy()
            end)
            row.down:SetPoint("RIGHT", row, "RIGHT", -2, 0)

            row.up = Widgets.IconButton(row, "up", 18, 16, function()
                model = Campaign.MoveRow(model, row.index, row.index - 1, charsTable())
                refreshHierarchy()
            end)
            row.up:SetPoint("RIGHT", row.down, "LEFT", -2, 0)

            rows[i] = row
        end

        row.index = i
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -(i - 1) * ROW_H)
        row.check:SetChecked(entry.included)
        row.position:SetText(entry.position and tostring(entry.position) or "|cff666666-|r")
        local label = Widgets.ColorName(entry.char, entry.class)
        if entry.isSelf then label = label .. " |cff888888(you)|r" end
        if not entry.included then label = "|cff777777" .. entry.char .. "|r" end
        row.name:SetText(label)
        row:SetAlpha(entry.included and 1 or 0.6)
        if i > 1 then row.up:Enable() else row.up:Disable() end
        if i < #model then row.down:Enable() else row.down:Disable() end
        row:Show()
    end
    for i = #model + 1, #rows do rows[i]:Hide() end

    content:SetHeight(math.max(#model * ROW_H, 1))
    hierarchyFrame.note:SetText(string.format("%d of %d characters are in this campaign.",
        #Campaign.HierarchyOf(model), #model))
end

local function confirmHierarchy()
    local hierarchy = Campaign.HierarchyOf(model)

    if mode == "join" then
        local ok, why = Campaign.Join(target.campaignId, target.label, hierarchy)
        if not ok then
            ns.Print(why)
            return
        end
    elseif mode == "create" then
        if #hierarchy == 0 then
            ns.Print("tick at least one character: a campaign you have no characters in "
                .. "would let you enter nothing.")
            return
        end
        local campaign, why = Campaign.Create(target.label, target.settings, hierarchy)
        if not campaign then
            ns.Print(why)
            return
        end
        Campaign.Switch(campaign.id)
        ns.Print(string.format("campaign \"%s\" created.", campaign.label))
    else
        local list = ns.Roster.HierarchyList(target.campaignId)
        if list then
            for i = #list, 1, -1 do list[i] = nil end
            for i, name in ipairs(hierarchy) do list[i] = name end
            if target.campaignId == Campaign.ActiveId() then ns.Roster.Publish() end
            Campaign.FireChanged()
        end
    end

    pendingInvite = nil
    hierarchyFrame:Hide()
end

local function buildHierarchy()
    hierarchyFrame = Widgets.Window("RaidLootSystemCampaignHierarchy", "campaignhierarchy",
        "Raid Loot System - Characters in this campaign", WIDTH, LIST_HEIGHT + 160)
    hierarchyFrame.rowWidth = WIDTH - 60 - Widgets.SCROLLBAR_GUTTER

    hierarchyFrame.hint = Widgets.Label(hierarchyFrame,
        "Tick the characters that play in this campaign, and rank them. Positions count "
        .. "the ticked rows only. An unticked character takes no part here and can be "
        .. "ticked again at any time.", "GameFontDisableSmall")
    hierarchyFrame.hint:SetPoint("TOPLEFT", hierarchyFrame, "TOPLEFT", 20, -40)
    hierarchyFrame.hint:SetWidth(WIDTH - 40)
    hierarchyFrame.hint:SetJustifyH("LEFT")

    local panel = Widgets.Panel(hierarchyFrame, 0.35)
    panel:SetPoint("TOPLEFT", hierarchyFrame.hint, "BOTTOMLEFT", 0, -46)
    panel:SetWidth(WIDTH - 40)
    panel:SetHeight(LIST_HEIGHT + 12)

    local scroll
    scroll, hierarchyFrame.content = Widgets.ScrollArea(panel,
        "RaidLootSystemCampaignHierarchyScroll", WIDTH - 52, LIST_HEIGHT)
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -6)

    hierarchyFrame.note = Widgets.Label(hierarchyFrame, "", "GameFontDisableSmall")
    hierarchyFrame.note:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 0, -6)

    hierarchyFrame.confirm = Widgets.Button(hierarchyFrame, "Confirm", 100, 22, confirmHierarchy)
    hierarchyFrame.confirm:SetPoint("TOPLEFT", hierarchyFrame.note, "BOTTOMLEFT", 0, -8)

    hierarchyFrame.cancel = Widgets.Button(hierarchyFrame, "Cancel", 100, 22, function()
        hierarchyFrame:Hide()
    end)
    hierarchyFrame.cancel:SetPoint("LEFT", hierarchyFrame.confirm, "RIGHT", 8, 0)

    -- Escape on this dialog is identical to Ignore (section 6): you are not a member,
    -- and a create in progress is abandoned entirely. Nothing was written to get here.
    hierarchyFrame:SetScript("OnHide", function()
        if mode == "join" and pendingInvite then
            ns.Print(string.format("you did not join \"%s\". Nothing was saved; ask the master "
                .. "looter to invite you again if that was a misclick.", tostring(target.label)))
        elseif mode == "create" then
            ns.Print("the campaign was not created.")
        end
        pendingInvite = nil
        mode = nil
    end)
end

--- @param how  "join" (an invitation), "create" (a new campaign) or "edit"
function Campaigns.ShowHierarchy(campaignId, label, how, settings)
    if not hierarchyFrame then buildHierarchy() end
    mode = how or "edit"
    target = { campaignId = campaignId, label = label, settings = settings }

    local seed
    if mode == "edit" then
        seed = ns.Roster.HierarchyList(campaignId) or {}
        hierarchyFrame.titleText:SetText("Characters in \"" .. tostring(label) .. "\"")
    else
        -- Seeded from the global template rather than from whichever campaign is
        -- active: active campaign is sticky, and seeding from it would silently hand
        -- your alt-run priorities to a new campaign (section 7).
        seed = ns.Database.DefaultHierarchy()
        hierarchyFrame.titleText:SetText(mode == "join"
            and ("Joining \"" .. tostring(label) .. "\"")
            or ("New campaign \"" .. tostring(label) .. "\""))
    end

    model = Campaign.HierarchyRows(charsTable(), seed)
    hierarchyFrame:RestorePosition()
    hierarchyFrame:Show()
    refreshHierarchy()
end

--------------------------------------------------------------------------------
-- Create (section 11)
--
-- Campaign settings only. Nothing personal belongs here: a hierarchy is a user
-- choice and a campaign's settings are a raid leader's, and every other member sets
-- a hierarchy for this campaign having never seen this dialog at all.
--------------------------------------------------------------------------------

local function buildCreate()
    createFrame = Widgets.Window("RaidLootSystemCampaignCreate", "campaignnew",
        "Raid Loot System - New campaign", WIDTH, 260)

    local y = -44
    local function caption(text, offset)
        local label = Widgets.Label(createFrame, text, "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", createFrame, "TOPLEFT", 20, offset)
        return label
    end

    caption("Label", y)
    createFrame.label = Widgets.EditBox(createFrame, 220, 20)
    createFrame.label:SetPoint("TOPLEFT", createFrame, "TOPLEFT", 90, y + 2)

    y = y - 30
    createFrame.tier = Widgets.Slider(createFrame, "RaidLootSystemCampaignTier", "Tier count",
        C.MIN_TIER_COUNT, C.MAX_TIER_COUNT, 1, function() end,
        function(value) createFrame.tier.text:SetText("Tier count: " .. math.floor(value + 0.5)) end)
    createFrame.tier:SetPoint("TOPLEFT", createFrame, "TOPLEFT", 30, y - 10)

    y = y - 60
    createFrame.timer = Widgets.Slider(createFrame, "RaidLootSystemCampaignTimer", "Entry timer",
        C.MIN_TIMER_SECONDS, C.MAX_TIMER_SECONDS, 15, function() end,
        function(value)
            createFrame.timer.text:SetText("Entry timer: "
                .. (math.floor(value / 15 + 0.5) * 15) .. "s")
        end)
    createFrame.timer:SetPoint("TOPLEFT", createFrame, "TOPLEFT", 30, y - 10)

    y = y - 56
    caption("Quality", y)
    createFrame.quality = Widgets.Dropdown(createFrame, "RaidLootSystemCampaignQuality", 100,
        C.QUALITY_CHOICES, function() end)
    createFrame.quality:SetPoint("TOPLEFT", createFrame, "TOPLEFT", 80, y + 4)

    -- Loot mode is fixed at Roll and greyed: spec 010 section 2 makes SK selectable
    -- only once a list exists, and a new campaign has none.
    createFrame.mode = Widgets.Label(createFrame,
        "Loot mode: Roll  |cff888888(seed a priority list to enable Suicide Kings)|r",
        "GameFontDisableSmall")
    createFrame.mode:SetPoint("TOPLEFT", createFrame, "TOPLEFT", 20, y - 30)
    createFrame.mode:SetWidth(WIDTH - 40)
    createFrame.mode:SetJustifyH("LEFT")

    createFrame.next = Widgets.Button(createFrame, "Next", 100, 22, function()
        local label = ns.Util.trim(createFrame.label:GetText() or "")
        local ok, why = Campaign.ValidLabel(label)
        if not ok then
            ns.Print(why)
            return
        end
        local settings = {
            tierCount = math.floor(createFrame.tier:GetValue() + 0.5),
            timerSeconds = math.floor(createFrame.timer:GetValue() / 15 + 0.5) * 15,
            qualityThreshold = createFrame.quality.selected or 4,
            lootMode = C.LOOT_MODE.ROLL,
        }
        createFrame:Hide()
        Campaigns.ShowHierarchy(nil, label, "create", settings)
    end)
    createFrame.next:SetPoint("BOTTOMLEFT", createFrame, "BOTTOMLEFT", 20, 14)

    createFrame.cancel = Widgets.Button(createFrame, "Cancel", 100, 22, function()
        createFrame:Hide()
    end)
    createFrame.cancel:SetPoint("LEFT", createFrame.next, "RIGHT", 8, 0)
end

function Campaigns.ShowCreate(label)
    if not createFrame then buildCreate() end
    createFrame.label:SetText(label or "")
    createFrame.tier:SetValueQuiet(3)
    createFrame.tier.text:SetText("Tier count: 3")
    createFrame.timer:SetValueQuiet(180)
    createFrame.timer.text:SetText("Entry timer: 180s")
    createFrame.quality:SetValue(4)
    createFrame:RestorePosition()
    createFrame:Show()
end

--------------------------------------------------------------------------------
-- Rename and delete (section 11)
--------------------------------------------------------------------------------

StaticPopupDialogs["RLS_CAMPAIGN_RENAME"] = {
    text = "Rename \"%s\" to what?",
    button1 = "Rename",
    button2 = CANCEL,
    hasEditBox = true,
    OnShow = function(self)
        local box = self.editBox or _G[self:GetName() .. "EditBox"]
        if box then box:SetText(self.data and self.data.label or "") end
    end,
    OnAccept = function(self)
        local box = self.editBox or _G[self:GetName() .. "EditBox"]
        local ok, why = Campaign.Rename(self.data.campaignId, box and box:GetText() or "")
        if not ok then ns.Print(why) end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["RLS_CAMPAIGN_DELETE"] = {
    text = "%s",
    button1 = "Delete",
    button2 = CANCEL,
    OnAccept = function(self)
        local ok, why = Campaign.Delete(self.data)
        if not ok then ns.Print(why) end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function Campaigns.PromptRename(campaignId)
    local campaign = Campaign.Get(campaignId)
    if not campaign then return end
    StaticPopup_Show("RLS_CAMPAIGN_RENAME", campaign.label, nil,
        { campaignId = campaignId, label = campaign.label })
end

function Campaigns.PromptDelete(campaignId)
    local campaign = Campaign.Get(campaignId)
    if not campaign then return end
    local blocker = Campaign.DeleteRefusal(campaignId)
    if blocker then
        ns.Print(string.format("\"%s\" cannot be deleted: %s", campaign.label, blocker))
        return
    end
    StaticPopup_Show("RLS_CAMPAIGN_DELETE", Campaign.DeleteText(campaign), nil, campaignId)
end

--------------------------------------------------------------------------------
-- Opening a round with non-members present (section 6)
--
-- The host is warned, not overridden. It does not auto-invite: joining stays a
-- deliberate act with a person behind it. It is also the fat-finger check -- a host
-- who made a new campaign instead of picking the existing one gets 0/5 joined and a
-- warning naming the entire raid.
--------------------------------------------------------------------------------

-- "Open anyway" is button3 rather than button2 so that Escape -- which fires the
-- button2 path -- cancels. A dialog whose safest key opens the round anyway would
-- be worse than no dialog.
StaticPopupDialogs["RLS_CAMPAIGN_NONMEMBERS"] = {
    text = "%s",
    button1 = "Invite them",
    button2 = CANCEL,
    button3 = "Open anyway",
    OnAccept = function(self) Campaign.Invite(self.data.campaignId) end,
    OnAlt = function(self) self.data.proceed() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

--- Run `proceed` unless the raid holds non-members, in which case warn first.
-- @return true when it ran straight away
function Campaigns.GuardOpen(proceed)
    local missing = Campaign.NonMembersInRaid()
    if #missing == 0 then
        proceed()
        return true
    end
    StaticPopup_Show("RLS_CAMPAIGN_NONMEMBERS", string.format(
        "%s %s not in \"%s\" and would roll on nothing.\n\nInvite them, or open the round anyway.",
        table.concat(missing, ", "), #missing == 1 and "is" or "are", Campaign.ActiveLabel()),
        nil, { campaignId = Campaign.ActiveId(), proceed = proceed })
    return false
end

--------------------------------------------------------------------------------
-- Export and import (section 12)
--------------------------------------------------------------------------------

StaticPopupDialogs["RLS_CAMPAIGN_OVERWRITE"] = {
    text = "%s",
    button1 = "Replace",
    button2 = CANCEL,
    OnAccept = function(self)
        Campaign.ApplyImport(self.data)
        ns.Print("the campaign was replaced by the imported copy.")
        if transferFrame then transferFrame:Hide() end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function buildTransfer()
    transferFrame = Widgets.Window("RaidLootSystemCampaignTransfer", "campaigntransfer",
        "Raid Loot System - Campaign string", WIDTH + 60, 260)

    transferFrame.hint = Widgets.Label(transferFrame,
        "Copy this to share the campaign's list and settings, or paste one in and press "
        .. "Import. It carries no hierarchy: yours stays yours.", "GameFontDisableSmall")
    transferFrame.hint:SetPoint("TOPLEFT", transferFrame, "TOPLEFT", 20, -40)
    transferFrame.hint:SetWidth(WIDTH + 20)
    transferFrame.hint:SetJustifyH("LEFT")

    local scroll = CreateFrame("ScrollFrame", "RaidLootSystemCampaignTransferScroll",
        transferFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", transferFrame.hint, "BOTTOMLEFT", 0, -12)
    scroll:SetWidth(WIDTH + 6)
    scroll:SetHeight(120)

    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject("ChatFontNormal")
    box:SetWidth(WIDTH + 6 - Widgets.SCROLLBAR_GUTTER)
    box:SetHeight(120)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(box)
    transferFrame.box = box

    transferFrame.import = Widgets.Button(transferFrame, "Import", 90, 22, function()
        Campaigns.Import(box:GetText())
    end)
    transferFrame.import:SetPoint("BOTTOMLEFT", transferFrame, "BOTTOMLEFT", 20, 14)

    local close = Widgets.Button(transferFrame, "Close", 90, 22, function()
        transferFrame:Hide()
    end)
    close:SetPoint("LEFT", transferFrame.import, "RIGHT", 8, 0)
end

function Campaigns.ShowExport(campaignId)
    if not transferFrame then buildTransfer() end
    local text, why = Campaign.Export(campaignId)
    if not text then
        ns.Print("export failed: " .. tostring(why))
        return
    end
    transferFrame:RestorePosition()
    transferFrame:Show()
    transferFrame.box:SetText(text)
    transferFrame.box:HighlightText()
    transferFrame.box:SetFocus()
end

function Campaigns.ShowImport()
    if not transferFrame then buildTransfer() end
    transferFrame:RestorePosition()
    transferFrame:Show()
    transferFrame.box:SetText("")
    transferFrame.box:SetFocus()
end

--- Parse, then either create (with the hierarchy dialog) or confirm an overwrite.
function Campaigns.Import(text)
    local incoming, why = Campaign.ParseImport(text)
    if not incoming then
        ns.Print("import refused: " .. tostring(why))
        return false
    end
    local stored = Campaign.Get(incoming.id)
    if stored then
        -- The fork repair. Refused unless confirmed, with both versions named.
        StaticPopup_Show("RLS_CAMPAIGN_OVERWRITE", Campaign.OverwriteText(stored, incoming),
            nil, incoming)
        return true
    end
    Campaign.ApplyImport(incoming)
    ns.Print(string.format("imported \"%s\" (%d characters, version %d).", incoming.label,
        #incoming.priority.order, incoming.priority.version))
    if transferFrame then transferFrame:Hide() end
    Campaigns.ShowHierarchy(incoming.id, incoming.label, "edit")
    return true
end

function Campaigns.Init()
    Widgets = ns.Widgets
end
