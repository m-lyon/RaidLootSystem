-- Modules/Campaign.lua
--
-- Campaigns (spec 012): a permanent, named container for loot state, so one player
-- can belong to several raid groups without their state from one leaking into
-- another. A campaign owns a priority list, the raid leader's host settings and this
-- client's hierarchy. Joining one is by invitation from the master looter.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the
-- `campaign` suite: identity, the membership predicate that is the whole point of
-- the feature (section 10), the hierarchy dialog's row model (section 7), the
-- delete rules (section 11) and export/import (section 12). Timestamps are passed
-- in (spec 000 section 2 applies to the pure half by convention here, as it does in
-- Round and Roster).

local ADDON, ns = ...

ns.Campaign = {}
local Campaign = ns.Campaign

local C = ns.Constants
local Util = ns.Util

local function key(name)
    return type(name) == "string" and name:lower() or nil
end

--------------------------------------------------------------------------------
-- Pure: identity (section 5)
--------------------------------------------------------------------------------

--- "<creatorName>-<timestamp>": the same convention round ids use. Unique without a
-- GUID generator Lua 5.1 does not have, sortable, and readable in a log.
function Campaign.NewId(creator, timestamp)
    return tostring(creator) .. "-" .. tostring(math.floor(timestamp or 0))
end

--- Is this a label a campaign may carry? The wire delimiters and "|" would corrupt
-- a frame, so they are refused here rather than at send time.
-- @return true, or nil plus a reason
function Campaign.ValidLabel(label)
    if type(label) ~= "string" then return nil, "a campaign needs a label" end
    label = Util.trim(label)
    if label == "" then return nil, "a campaign needs a label" end
    if #label > C.MAX_CAMPAIGN_LABEL then
        return nil, "that label is longer than " .. C.MAX_CAMPAIGN_LABEL .. " characters"
    end
    if label:find(C.RESERVED_PATTERN) then
        return nil, "a label cannot contain ^, ~, = or |"
    end
    return true
end

--- Build a campaign record (section 3).
-- @param label     cosmetic and mutable; the host's propagates
-- @param settings  optional host settings; the defaults otherwise
-- @param ctx       { creator, timestamp, hierarchy }
-- @return campaign, or nil plus a reason
function Campaign.New(label, settings, ctx)
    ctx = ctx or {}
    local ok, why = Campaign.ValidLabel(label)
    if not ok then return nil, why end
    settings = settings or {}

    local defaults = C.CAMPAIGN_DEFAULTS
    local host = {}
    for k, v in pairs(defaults.host) do
        -- Spelled out rather than and/or: autoClose is a boolean, and the idiom
        -- cannot carry a false through.
        if settings[k] ~= nil then host[k] = settings[k] else host[k] = v end
    end
    -- A new campaign has no priority list, so Suicide Kings is unreachable in it
    -- until one is seeded (spec 010 section 2). The create dialog greys the control;
    -- this refuses the value however it arrived.
    if host.lootMode ~= C.LOOT_MODE.ROLL then host.lootMode = C.LOOT_MODE.ROLL end
    host.tierCount = Util.clamp(math.floor(tonumber(host.tierCount) or 3),
        C.MIN_TIER_COUNT, C.MAX_TIER_COUNT)
    host.timerSeconds = Util.clamp(math.floor(tonumber(host.timerSeconds) or 180),
        C.MIN_TIMER_SECONDS, C.MAX_TIMER_SECONDS)
    if host.qualityThreshold ~= 3 then host.qualityThreshold = 4 end

    return {
        id = Campaign.NewId(ctx.creator, ctx.timestamp),
        label = Util.trim(label),
        createdAt = math.floor(ctx.timestamp or 0),
        createdBy = ctx.creator,
        hierarchy = Util.copy(ctx.hierarchy or {}),
        host = host,
        priority = Util.deepCopy(defaults.priority),
    }
end

--- Fill in whatever a stored or imported campaign is missing, so every read below
-- can assume the shape of section 3.
function Campaign.Normalise(campaign)
    if type(campaign) ~= "table" then return nil end
    campaign.hierarchy = campaign.hierarchy or {}
    -- Additive, so a campaign stored before spec 013 gains an empty members table
    -- here rather than through a schema bump -- which would rebuild the saved
    -- variables empty (section 3) and take the group's priority list with it.
    campaign.members = campaign.members or {}
    campaign.host = Util.applyDefaults(campaign.host or {}, C.CAMPAIGN_DEFAULTS.host)
    campaign.priority = Util.applyDefaults(campaign.priority or {},
        C.CAMPAIGN_DEFAULTS.priority)
    return campaign
end

--------------------------------------------------------------------------------
-- Pure: submitted hierarchies (spec 013 section 3)
--
-- What each member ranked, for the campaign they ranked it in. The stored copy is
-- a cache of what that member broadcast and nothing else writes it: a hierarchy
-- belongs to the member who submitted it (section 7), so CFG and CSTATE still
-- leave these alone and no host screen edits them.
--------------------------------------------------------------------------------

--- Are a stored record and an incoming one the same player, logged in on two of
-- their own characters?
--
-- The whole premise of the addon is that one player runs several characters, and
-- the saved variables are per account, so all of them share one hierarchy. Keying a
-- record by the character you happen to be logged in on therefore accumulates one
-- record per alt, each holding the same ordering, and the roster draws every
-- character once per alt that has ever logged in.
--
-- The test is mutual: each names the other. Two alts always do, because they share
-- the one hierarchy that lists them both. A stranger who has wrongly put your main
-- in *their* hierarchy does not, because yours does not list them back -- so a
-- mistaken claim stays a contested character, which is loud, instead of silently
-- deleting someone's record.
function Campaign.SameMember(storedPlayer, storedOrder, player, order)
    return Util.indexOf(order or {}, storedPlayer) ~= nil
        and Util.indexOf(storedOrder or {}, player) ~= nil
end

--- Does `order` name `storedPlayer` and extend their stored ordering at the end? That
-- is the same player publishing from an alt the stored ordering does not yet list,
-- which the mutual test cannot see.
function Campaign.AppendsTo(storedPlayer, storedOrder, order)
    storedOrder, order = storedOrder or {}, order or {}
    if #storedOrder == 0 or #order <= #storedOrder then return false end
    if Util.indexOf(order, storedPlayer) == nil then return false end
    for i = 1, #storedOrder do
        if tostring(storedOrder[i]):lower() ~= tostring(order[i]):lower() then return false end
    end
    return true
end

--- Record one member's ordering on a campaign record. Replaces rather than merges:
-- a resubmission is the whole of what that member now ranks, and merging would
-- resurrect a character they had just removed.
-- @return true, or nil plus a reason
function Campaign.RecordMember(campaign, player, order, chars, at)
    if type(campaign) ~= "table" then return nil, "no such campaign" end
    if type(player) ~= "string" or player == "" then return nil, "a record needs a player" end
    campaign.members = campaign.members or {}

    -- One record per player, not one per character they log in on. Clearing on
    -- write also repairs a campaign that already accumulated duplicates: the next
    -- publish from any of the alts collapses them.
    for stored, record in pairs(campaign.members) do
        if stored ~= player
            and (Campaign.SameMember(stored, record.order, player, order)
                 or Campaign.AppendsTo(stored, record.order, order)) then
            campaign.members[stored] = nil
        end
    end

    campaign.members[player] = {
        order = Util.copy(order or {}),
        chars = Util.deepCopy(chars or {}),
        at = at,
    }
    return true
end

--- The submitted hierarchies of a campaign, as TierRoster.bands takes them.
-- Sorted by player so the roster is stable between reads.
function Campaign.MemberList(campaign)
    local out = {}
    for player, record in pairs((campaign or {}).members or {}) do
        out[#out + 1] = { player = player, order = record.order or {},
                          chars = record.chars or {}, at = record.at }
    end
    table.sort(out, function(a, b) return a.player < b.player end)
    return out
end

--------------------------------------------------------------------------------
-- Pure: the membership rule (section 10)
--
-- > A campaign-bearing message is applied to the campaign it names, if you are a
-- > member of that campaign. Otherwise it is dropped and logged -- except CINV,
-- > which is what non-membership is for, and OPEN, which opens the read-only window
-- > of section 6.
--
-- This is the clobber fix, and it is one predicate so that no handler can rederive
-- it differently. A SKLIST from a group you are not in cannot reach your list,
-- because it names a campaign you do not have.
--------------------------------------------------------------------------------

--- Are you a member of this campaign? Membership is implicit: you are in it if you
-- hold a local record of it (section 3).
function Campaign.IsMember(campaigns, campaignId)
    if type(campaigns) ~= "table" then return false end
    if type(campaignId) ~= "string" or campaignId == "" then return false end
    return campaigns[campaignId] ~= nil
end

--- Should a campaign-bearing message be acted on?
-- @return true, or false plus the reason to log
function Campaign.Accepts(campaigns, campaignId, op)
    if type(campaignId) ~= "string" or campaignId == "" then
        return false, "it names no campaign"
    end
    if C.CAMPAIGN_OPEN_TO_NONMEMBERS[op] then return true end
    if Campaign.IsMember(campaigns, campaignId) then return true end
    return false, "you are not in campaign " .. campaignId
end

--------------------------------------------------------------------------------
-- Pure: the hierarchy dialog's row model (section 7)
--
-- One scrolling list of every character in roster.chars. A ticked row is in this
-- campaign; positions are numbered over the ticked rows only, so unticking a row
-- renumbers everything below it and nothing looks like it kept a rank it lost.
--------------------------------------------------------------------------------

--- @param chars      roster.chars: name -> { class, isSelf }
-- @param hierarchy  this campaign's ordering; ticked, in this order, first
-- @return array of { char, included, position, class, isSelf }
function Campaign.HierarchyRows(chars, hierarchy)
    chars = chars or {}
    local rows, seen = {}, {}

    for _, name in ipairs(hierarchy or {}) do
        local k = key(name)
        if chars[name] and not seen[k] then
            seen[k] = true
            rows[#rows + 1] = { char = name, included = true }
        end
    end

    -- Unticked characters keep their row and can be re-ticked, so a character can
    -- never become unreachable by having been unticked once.
    local rest = {}
    for name in pairs(chars) do
        if not seen[key(name)] then rest[#rest + 1] = name end
    end
    table.sort(rest, function(a, b) return a:lower() < b:lower() end)
    for _, name in ipairs(rest) do
        rows[#rows + 1] = { char = name, included = false }
    end

    return Campaign.Renumber(rows, chars)
end

--- Position is a rank among ticked rows only.
function Campaign.Renumber(rows, chars)
    chars = chars or {}
    local position = 0
    for _, row in ipairs(rows) do
        local entry = chars[row.char] or {}
        row.class = entry.class
        row.isSelf = entry.isSelf and true or false
        if row.included then
            position = position + 1
            row.position = position
        else
            row.position = nil
        end
    end
    return rows
end

function Campaign.SetIncluded(rows, index, included, chars)
    local row = rows[index]
    if not row then return rows end
    row.included = included and true or false
    return Campaign.Renumber(rows, chars)
end

--- Move a row, shifting the rest. Rows carry their own order; ticked rows are not
-- forced above unticked ones, because a row that jumps when you tick it reads as a
-- bug rather than as a rule.
function Campaign.MoveRow(rows, from, to, chars)
    if not Util.move(rows, from, to) then return rows end
    return Campaign.Renumber(rows, chars)
end

--- The hierarchy these rows describe: the ticked characters, in row order.
function Campaign.HierarchyOf(rows)
    local out = {}
    for _, row in ipairs(rows or {}) do
        if row.included then out[#out + 1] = row.char end
    end
    return out
end

--------------------------------------------------------------------------------
-- Pure: lifecycle rules (section 11)
--------------------------------------------------------------------------------

--- Why this campaign cannot be deleted, or nil.
--
-- Being the active one, or the only one, no longer blocks: a client with no
-- campaign at all is a state the addon supports (section 5, revised), so
-- deleting the last one leaves you in the template and nothing else. What is
-- still refused is deleting a campaign with live state pointing into it.
-- @param ctx { inGroup, pendingIds = { [campaignId] = true }, openRoundCampaignId }
function Campaign.DeleteBlocker(campaignId, ctx)
    ctx = ctx or {}
    if ctx.inGroup then
        -- Deleting is local and silent: no op carries it, so the other members keep
        -- the campaign, its priority list and its log, and find out only when the
        -- next round opens somewhere they are not members and their roll window
        -- comes up read-only. That is a raid night lost to a misclick, and the list
        -- it costs is the one the group has been building for weeks. So deletion is
        -- an out-of-group action. Nothing is given up by waiting: a campaign nobody
        -- wants can simply be left unused, and a new one is one click away.
        return "you are in a group. Leave the raid first -- deleting a campaign "
            .. "other members are in strands them on it."
    end
    if (ctx.pendingIds or {})[campaignId] then
        -- An in-flight item with a live clock whose failure path needs the very list
        -- it would restore into (section 14). Refused outright, not warned about.
        return "an undelivered item was won in it. Deliver or abandon it first."
    end
    if campaignId ~= nil and campaignId == ctx.openRoundCampaignId then
        -- The round resolves against this campaign's list and its award restores
        -- into it. Deleting it mid-round also takes the host settings every close
        -- path reads out from under them.
        return "a round is open in it. Close or cancel it first."
    end
    return nil
end

--- "Delete 'Alt Run'? Its priority list of 23 characters and 140 logged changes
-- cannot be recovered." A confirmation names what is lost (section 11).
function Campaign.DeleteText(campaign)
    local priority = campaign.priority or {}
    return string.format("Delete \"%s\"? Its priority list of %d characters and %d logged "
        .. "changes cannot be recovered. History keeps every award it made.",
        campaign.label or campaign.id, #(priority.order or {}), #(priority.log or {}))
end

--- Who in the raid is not in this campaign (section 6). The host is warned, not
-- overridden: a host cannot disenfranchise two people without being told.
-- @param members  array of player names in the raid running the addon
-- @param peers    player -> campaignId, from HI
-- @param me       this client's name, always a member of its own active campaign
function Campaign.NonMembers(members, peers, campaignId, me)
    peers = peers or {}
    local out = {}
    for _, name in ipairs(members or {}) do
        if not (me and key(name) == key(me)) and peers[name] ~= campaignId then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end

--- "3/5 joined", with the names of the two who have not.
function Campaign.JoinedSummary(members, peers, campaignId, me)
    local missing = Campaign.NonMembers(members, peers, campaignId, me)
    local total = #(members or {})
    return { joined = total - #missing, total = total, missing = missing }
end

--------------------------------------------------------------------------------
-- Pure: export and import (section 12)
--------------------------------------------------------------------------------

--- The campaign id, label, host settings and full priority list. Not the hierarchy,
-- which is personal and per client.
function Campaign.Encode(campaign)
    local body, err = ns.Serialize.encodeCampaign(campaign)
    if not body then return nil, err end
    return C.CAMPAIGN_EXPORT_PREFIX .. body
end

--- Parse an import string without applying it. Rejected whole on any failure.
-- @return campaign, or nil plus a reason
function Campaign.ParseImport(text)
    if type(text) ~= "string" then return nil, "nothing to import" end
    text = Util.trim(text)
    if text == "" then return nil, "nothing to import" end

    local prefix = C.CAMPAIGN_EXPORT_PREFIX
    if text:sub(1, #prefix) ~= prefix then
        return nil, "this is not a RaidLootSystem campaign string"
    end
    local campaign, why = ns.Serialize.decodeCampaign(text:sub(#prefix + 1))
    if not campaign then return nil, why end

    local ok, badLabel = Campaign.ValidLabel(campaign.label)
    if not ok then return nil, badLabel end
    return Campaign.Normalise(campaign)
end

--- The dialog text for an import that would overwrite a campaign already held
-- (section 12): no merge, ever, so the reader is comparing two versions.
function Campaign.OverwriteText(stored, incoming)
    return string.format("You already have \"%s\". Replace its priority list (version %d, "
        .. "%d characters) with the imported one (version %d, %d characters)? "
        .. "Your hierarchy is kept. There is no merge; this is a whole replacement.",
        stored.label or stored.id,
        (stored.priority or {}).version or 0, #((stored.priority or {}).order or {}),
        (incoming.priority or {}).version or 0, #((incoming.priority or {}).order or {}))
end

--------------------------------------------------------------------------------
-- WoW-facing. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

local listeners = {}
local labelCache = {}          -- campaignId -> label learned from CINV, HI or OPEN

local function DB() return ns.Database.db or ns.Database.Load() end

function Campaign.RegisterListener(fn)
    listeners[#listeners + 1] = fn
end

local function fireChanged()
    for _, fn in ipairs(listeners) do fn() end
    if ns.HostPanel then ns.HostPanel.Refresh() end
    if ns.HierarchyEditor then ns.HierarchyEditor.Refresh() end
    if ns.PriorityViewer then ns.PriorityViewer.Refresh() end
    if ns.TierViewer then ns.TierViewer.Refresh() end
    if ns.RollWindow then ns.RollWindow.Refresh() end
end

Campaign.FireChanged = fireChanged

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

function Campaign.All()
    return DB().campaigns
end

--- Every campaign, sorted by creation then label, so the pickers and `/rls campaign`
-- number them the same way.
function Campaign.List()
    local out = {}
    for _, campaign in pairs(Campaign.All()) do out[#out + 1] = campaign end
    table.sort(out, function(a, b)
        if (a.createdAt or 0) ~= (b.createdAt or 0) then
            return (a.createdAt or 0) < (b.createdAt or 0)
        end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

function Campaign.Get(campaignId)
    return Campaign.All()[campaignId]
end

function Campaign.ActiveId()
    return DB().activeCampaign
end

--- The campaign every read of `host` and `priority` goes through (section 9), or
-- nil when the player has never created or joined one. Database.lua owns the
-- accessors that call this, so a future scoping change stays a single-file
-- problem, and every one of those accessors is nil-safe for exactly this case.
function Campaign.Active()
    local db = DB()
    local campaign = db.campaigns[db.activeCampaign]
    if campaign then return Campaign.Normalise(campaign) end

    -- A campaign that vanished under us (a delete race, a hand-edited saved file):
    -- point at any campaign rather than hand a caller nil host settings.
    local list = Campaign.List()
    if list[1] then
        db.activeCampaign = list[1].id
        return Campaign.Normalise(list[1])
    end
    return nil
end

function Campaign.IsMemberOf(campaignId)
    return Campaign.IsMember(Campaign.All(), campaignId)
end

--- Should this message be acted on? Logs the drop, so a foreign SKLIST is visible
-- in `/rls debug` rather than silent.
function Campaign.AcceptsMessage(op, campaignId, sender)
    local ok, why = Campaign.Accepts(Campaign.All(), campaignId, op)
    if not ok then
        ns.Debug(string.format("dropped %s from %s: %s", tostring(op), tostring(sender),
            tostring(why)))
    end
    return ok
end

--- A campaign's label for display: ours if we have it, else whatever CINV, HI or a
-- host's OPEN told us, else the opaque id.
function Campaign.LabelFor(campaignId)
    if not campaignId or campaignId == "" then return "no campaign" end
    local campaign = Campaign.Get(campaignId)
    if campaign then return campaign.label or campaignId end
    return labelCache[campaignId] or campaignId
end

function Campaign.RememberLabel(campaignId, label)
    if campaignId and campaignId ~= "" and label and label ~= "" then
        labelCache[campaignId] = label
        -- The host's label is authoritative and there is no local override
        -- (section 5), so a member adopts it on receipt.
        local campaign = Campaign.Get(campaignId)
        if campaign and campaign.label ~= label then
            campaign.label = label
            fireChanged()
        end
    end
end

function Campaign.ActiveLabel()
    local campaign = Campaign.Active()
    return campaign and campaign.label or "no campaign"
end

--------------------------------------------------------------------------------
-- Creating and switching
--------------------------------------------------------------------------------

local function store(campaign)
    local db = DB()
    db.campaigns[campaign.id] = campaign
    return campaign
end

--- Create locally and unannounced (section 11): a campaign does not exist for
-- anybody else until a host opens a round in it or invites the raid to it.
-- @return campaign, or nil plus a reason
function Campaign.Create(label, settings, hierarchy)
    local campaign, why = Campaign.New(label, settings, {
        creator = UnitName("player"), timestamp = time(),
        hierarchy = hierarchy or ns.Database.Roster().defaultHierarchy,
    })
    if not campaign then return nil, why end
    -- Two campaigns created in the same second by the same player would share an id.
    while Campaign.Get(campaign.id) do
        campaign.id = campaign.id .. "x"
    end
    store(campaign)
    fireChanged()
    return campaign
end

--- Switching is deliberate and sticky: after a raid your active campaign stays
-- whatever you last raided in (section 13).
function Campaign.Switch(campaignId)
    local campaign = Campaign.Get(campaignId)
    if not campaign then return false, "no such campaign." end
    local db = DB()
    if db.activeCampaign == campaignId then return true end
    db.activeCampaign = campaignId
    -- Claims are per campaign (section 8), so what other players published for the
    -- campaign we left says nothing about this one.
    ns.Roster.ResetPublished()
    ns.Roster.Publish()
    -- Peers republish on a roster event or a request, and everyone already in this
    -- campaign has no reason to send one. Without this ask, the claim index stays
    -- empty and every entry is rejected as NOT_PUBLISHED (spec 012 section 8).
    ns.Roster.RequestAll()
    ns.Print(string.format("campaign: %s.", campaign.label or campaign.id))
    fireChanged()
    return true
end

--- Host only, propagating on the next CINV / OPEN / HI, and announced (section 11).
function Campaign.Rename(campaignId, label)
    local campaign = Campaign.Get(campaignId)
    if not campaign then return false, "no such campaign." end
    local ok, why = Campaign.ValidLabel(label)
    if not ok then return false, why end
    local was = campaign.label
    campaign.label = Util.trim(label)
    labelCache[campaign.id] = campaign.label
    if ns.Round.IsHost() and ns.Announce then
        ns.Announce.Emit("PRIORITY", { text = string.format("campaign \"%s\" renamed to \"%s\"",
            was, campaign.label) })
        Campaign.Invite(campaignId)
    end
    fireChanged()
    return true
end

--- Campaign ids named by an undelivered pending record (section 11 and 14).
local function pendingCampaigns()
    local out = {}
    for _, record in ipairs(ns.Pending.OutstandingRecords()) do
        if record.campaignId then out[record.campaignId] = true end
    end
    return out
end

--- The round whose campaign is off limits: the host's own, while it is still
-- running. A closed or aborted round is left in `Round.current` for the panel to
-- show, and blocks nothing.
local function openRoundCampaign()
    local round = ns.Round and ns.Round.current
    if not round then return nil end
    if round.state ~= C.ROUND_STATE.OPEN and round.state ~= C.ROUND_STATE.RESOLVING then
        return nil
    end
    return round.campaignId
end

--- Being in a party or a raid at all, by the 3.3.5a pair of counts -- there is no
-- IsInGroup on this client, and a raid reports zero party members.
local function inGroup()
    return GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0
end

--- Store one member's ordering against the campaign it names (spec 013 section 3).
-- Called for our own publish and for every ROSTER we accept; the timestamp is what
-- lets the roster say how old a band is.
-- @return true, or nil plus a reason
-- @param at  when this ordering was submitted; now by default. A refused change
--            passes the stored timestamp through, because nothing was submitted.
-- @param keepAt  take `at` as given, even nil, rather than defaulting it to now
function Campaign.RecordHierarchy(campaignId, player, order, chars, at, keepAt)
    local campaign = Campaign.Get(campaignId)
    if not campaign then return nil, "no such campaign" end
    if not keepAt then at = at or time() end
    local ok, why = Campaign.RecordMember(campaign, player, order, chars, at)
    if not ok then return nil, why end
    -- Deliberately no fireChanged: this runs on every ROSTER, which the group
    -- events fire often, and the roster path already tells its own listeners when
    -- the active campaign's claims are rebuilt. Refreshing four windows per
    -- received message would cost more than the one screen this feeds.
    return true
end

--- Has this campaign run a round yet (spec 014)?
--
-- "Mid-campaign" has to mean something a client can answer on its own, and every
-- member records a history entry for every round it saw, tagged with the campaign.
-- So: a campaign with history has started. Before that it is being set up, and
-- everyone arranges their characters freely -- a lock that engaged the moment a
-- campaign was created would make an on-by-default setting unusable.
--
-- A member who joined late has no history for it and is free until their first
-- raid in it, which is the same rule read from their side and the right answer.
function Campaign.HasStarted(campaignId)
    if not campaignId or campaignId == "" then return false end
    for _, record in ipairs(ns.History and ns.History.Records() or {}) do
        -- A simulated record must never outlive its simulation (spec 009): counting
        -- one here would leave a never-raided campaign permanently locked once
        -- /rls simulate had run in it, even after Simulate.finish() cleans up.
        -- An aborted round ran nothing, so it does not begin a campaign either.
        if record.campaignId == campaignId and not record.simulated
            and record.outcome ~= "ABORTED" then return true end
    end
    return false
end

--- Is this campaign's hierarchy locked for its members right now? The host setting
-- says whether the campaign locks at all; the history says whether it has begun.
function Campaign.HierarchyLocked(campaignId)
    campaignId = campaignId or Campaign.ActiveId()
    local campaign = Campaign.Get(campaignId)
    if not campaign or campaign.host.lockHierarchy == false then return false end
    -- The host stamps `started` when the first round resolves and it rides on CFG and
    -- CSTATE, so a member who joined mid-campaign -- including one who takes master
    -- looter -- reads the same answer as everyone else. Own history still counts,
    -- for a group whose host predates the flag.
    if campaign.host.started then return true end
    return Campaign.HasStarted(campaignId)
end

--- Mark a campaign as begun (spec 014). Called when a round resolves; the flag then
-- travels with CFG and CSTATE.
function Campaign.MarkStarted(campaignId)
    local campaign = Campaign.Get(campaignId or Campaign.ActiveId())
    if not campaign then return false end
    Campaign.Normalise(campaign).host.started = true
    return true
end

--- Drop one member's stored ordering. For the simulator, whose fake players publish
-- into the real active campaign and must leave nothing behind in it (spec 009).
function Campaign.ForgetMember(campaignId, player)
    local campaign = Campaign.Get(campaignId)
    if not campaign or not campaign.members then return end
    campaign.members[player] = nil
end

--- The ordering one member last submitted to a campaign, or nil.
--
-- Records are keyed per player, not per character, so an incoming ordering matches
-- its stored record under the same mutual-naming rule RecordMember collapses alts
-- with: a member who published as one of their characters last week and from
-- another this week still has one record, and the lock check has to find it.
-- @param order the incoming ordering, when there is one
function Campaign.StoredOrder(campaignId, player, order)
    local campaign = Campaign.Get(campaignId)
    local members = campaign and campaign.members
    if not members then return nil end
    local record = members[player]
    if record then return record.order end
    if not order then return nil end
    for stored, other in pairs(members) do
        if Campaign.SameMember(stored, other.order, player, order) then return other.order end
    end
    return nil
end

--- Stored records, other than the player's own, whose ordering shares any character
-- with an incoming one that names the record's player. One-way on purpose, unlike
-- SameMember: under a lock a member publishing from a character their stored ordering
-- does not rank matches neither lookup StoredOrder makes, and would otherwise record a
-- re-rank unchecked (spec 014). An ordering that does not name the record's player is
-- someone else's, and a character both rank stays a contested claim, not a refusal.
-- Sorted by player so a refusal names the same record every time.
function Campaign.OverlappingOrders(campaign, player, order)
    local out = {}
    for stored, record in pairs((campaign or {}).members or {}) do
        if stored ~= player and Util.indexOf(order or {}, stored) then
            for _, name in ipairs(order or {}) do
                if Util.indexOf(record.order or {}, name) then
                    out[#out + 1] = { player = stored, order = record.order }
                    break
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.player < b.player end)
    return out
end

--- When one member's stored ordering was recorded, under the same matching rule
-- StoredOrder uses, or nil.
function Campaign.StoredAt(campaignId, player, order)
    local campaign = Campaign.Get(campaignId)
    local members = campaign and campaign.members
    if not members then return nil end
    local record = members[player]
    if record then return record.at end
    if not order then return nil end
    for stored, other in pairs(members) do
        if Campaign.SameMember(stored, other.order, player, order) then return other.at end
    end
    return nil
end

--- One member's stored character table, under the same matching rule StoredOrder
-- uses, or nil.
function Campaign.StoredChars(campaignId, player, order)
    local campaign = Campaign.Get(campaignId)
    local members = campaign and campaign.members
    if not members then return nil end
    local record = members[player]
    if record then return record.chars end
    if not order then return nil end
    for stored, other in pairs(members) do
        if Campaign.SameMember(stored, other.order, player, order) then return other.chars end
    end
    return nil
end

--- The submitted hierarchies of one campaign, active by default.
function Campaign.Members(campaignId)
    return Campaign.MemberList(Campaign.Get(campaignId or Campaign.ActiveId()))
end

--- char -> tier, from what each member submitted for this campaign (spec 013
-- section 3). Stored, so the bands are right after a reload rather than empty until
-- somebody republishes. A character's tier comes from its position in its OWNER's
-- hierarchy, never from a position on the priority list (spec 010 section 3), and an
-- owner who has submitted nothing leaves their characters without one. The two
-- priority-list surfaces share this so they cannot band the same list differently.
function Campaign.TierIndex(tierCount, campaignId)
    local out = {}
    for _, member in ipairs(Campaign.Members(campaignId)) do
        for position, char in ipairs(member.order) do
            out[char:lower()] = ns.Tiers.forPosition(position, tierCount)
        end
    end
    return out
end

function Campaign.DeleteRefusal(campaignId)
    return Campaign.DeleteBlocker(campaignId, {
        inGroup = inGroup(),
        pendingIds = pendingCampaigns(),
        openRoundCampaignId = openRoundCampaign(),
    })
end

--- History survives untouched: a deleted campaign does not un-happen the awards it
-- made, and records keep their campaignId and campaignLabel (section 11).
function Campaign.Delete(campaignId)
    local campaign = Campaign.Get(campaignId)
    if not campaign then return false, "no such campaign." end
    local blocker = Campaign.DeleteRefusal(campaignId)
    if blocker then return false, "that campaign cannot be deleted: " .. blocker end
    labelCache[campaignId] = campaign.label
    local db = DB()
    local wasActive = db.activeCampaign == campaignId
    db.campaigns[campaignId] = nil
    ns.Print(string.format("campaign \"%s\" deleted. Its history records are kept.",
        campaign.label or campaignId))

    -- Deleting the one you were in lands you in whatever is left, or in none at
    -- all. Written here rather than left to Campaign.Active's self-heal because
    -- ActiveId is a raw read: a stale id would name a campaign that is gone.
    -- Claims are per campaign (section 8), so the index the deleted one built
    -- says nothing about where you land.
    if wasActive then
        local remaining = Campaign.List()[1]
        db.activeCampaign = remaining and remaining.id or ""
        ns.Roster.ResetPublished()
        if remaining then
            ns.Print(string.format("campaign: %s.", remaining.label or remaining.id))
            ns.Roster.Publish()
            ns.Roster.RequestAll()
        else
            ns.Print("you are in no campaign now. /rls campaign new <label> makes one.")
        end
    end
    fireChanged()
    return true
end

--------------------------------------------------------------------------------
-- Import (section 12)
--------------------------------------------------------------------------------

--- Apply a parsed import. The UI confirms an overwrite first; this executes it.
-- @param hierarchy  used only when the campaign is new to this client
function Campaign.ApplyImport(incoming, hierarchy)
    local stored = Campaign.Get(incoming.id)
    if stored then
        -- The fork repair: a whole replacement of the list, never a merge.
        stored.label = incoming.label
        stored.host = incoming.host
        stored.priority = incoming.priority
        fireChanged()
        return true, false
    end
    incoming.hierarchy = Util.copy(hierarchy or ns.Database.Roster().defaultHierarchy)
    store(Campaign.Normalise(incoming))
    fireChanged()
    return true, true
end

function Campaign.Export(campaignId)
    local campaign = Campaign.Get(campaignId or Campaign.ActiveId())
    if not campaign then return nil, "no such campaign." end
    return Campaign.Encode(campaign)
end

--------------------------------------------------------------------------------
-- Inviting and joining (section 6)
--------------------------------------------------------------------------------

--- Host only: broadcast CINV. Every client that is not already a member shows the
-- join dialog; members dismiss it without showing anything, so re-inviting reaches
-- only non-members.
function Campaign.Invite(campaignId)
    if not ns.Round.IsHost() then return false, "only the master looter can invite." end
    local campaign = Campaign.Get(campaignId or Campaign.ActiveId())
    if not campaign then return false, "no such campaign." end
    local ok, why = ns.Comms.Send(C.OPS.CINV, ns.Serialize.encodeCinv(campaign.id, campaign.label))
    if not ok then return false, why end
    ns.Print(string.format("invited the raid to \"%s\".", campaign.label))
    return true
end

local function onCinv(sender, body)
    local msg, why = ns.Serialize.decodeCinv(body)
    if not msg then
        ns.Debug("unreadable CINV: " .. tostring(why))
        return
    end
    if not ns.Round.IsAuthoritative(sender) then
        ns.Debug("dropped CINV from " .. tostring(sender) .. ", who is not the master looter")
        return
    end
    Campaign.RememberLabel(msg.campaignId, msg.label)
    if ns.Comms.IsSelf(sender) then return end
    -- A CINV for a campaign this client is already in shows nothing.
    if Campaign.IsMemberOf(msg.campaignId) then return end
    if ns.Campaigns then
        ns.Campaigns.ShowInvite(sender, msg.campaignId, msg.label)
    else
        ns.Print(string.format("%s invited you to the campaign \"%s\". Open /rls campaign to join.",
            tostring(sender), msg.label))
    end
end

--- Accept an invitation. Confirming the hierarchy is what makes you a member, not
-- pressing Join, so this is called from the hierarchy dialog's confirm and nowhere
-- else. Nothing is stored on refusal: no campaign record, no ignore-list entry.
function Campaign.Join(campaignId, label, hierarchy)
    if Campaign.IsMemberOf(campaignId) then return false, "you are already in that campaign." end
    if #(hierarchy or {}) == 0 then
        -- A member whose hierarchy is empty could enter nothing and would be shown
        -- no reason why (section 6).
        return false, "tick at least one character: a campaign you have no characters in "
            .. "would let you enter nothing."
    end
    local campaign = {
        id = campaignId,
        label = label or Campaign.LabelFor(campaignId),
        createdAt = time(),
        createdBy = nil,
        hierarchy = Util.copy(hierarchy),
    }
    store(Campaign.Normalise(campaign))
    ns.Print(string.format("you joined \"%s\".", campaign.label))
    Campaign.Switch(campaignId)
    fireChanged()
    return true
end

--------------------------------------------------------------------------------
-- Who else is in it (section 6)
--------------------------------------------------------------------------------

--- Raid members running the addon whose HI named a different campaign.
function Campaign.NonMembersInRaid(campaignId)
    campaignId = campaignId or Campaign.ActiveId()
    local members = {}
    for _, member in ipairs(ns.Roster.GroupMembers()) do
        if member.name and ns.Round.peers[member.name] then members[#members + 1] = member.name end
    end
    return Campaign.NonMembers(members, ns.Round.peerCampaign, campaignId, UnitName("player"))
end

function Campaign.Joined(campaignId)
    campaignId = campaignId or Campaign.ActiveId()
    local members = {}
    for _, member in ipairs(ns.Roster.GroupMembers()) do
        if member.name and ns.Round.peers[member.name] then members[#members + 1] = member.name end
    end
    return Campaign.JoinedSummary(members, ns.Round.peerCampaign, campaignId, UnitName("player"))
end

--------------------------------------------------------------------------------
-- Slash commands (section 13)
--------------------------------------------------------------------------------

function Campaign.PrintList()
    local active = Campaign.ActiveId()
    ns.Print("campaigns:")
    for i, campaign in ipairs(Campaign.List()) do
        ns.Print(string.format(
            "  %d. %s%s  |cff888888(%d on the list, %d of your characters)|r",
            i, campaign.label or campaign.id,
            campaign.id == active and "  |cff66ff66[active]|r" or "",
            #((campaign.priority or {}).order or {}), #(campaign.hierarchy or {})))
    end
    ns.Print("/rls campaign switch <n>, new <label>, rename <label>, delete <n>, invite, "
        .. "export, import <string>")
end

function Campaign.ByIndex(n)
    return Campaign.List()[tonumber(n) or 0]
end

function Campaign.Init()
    -- A fresh install starts with no campaign at all: only the template (spec 012
    -- section 5, revised). The first campaign is whatever the player creates or
    -- joins; nothing is provisioned for them.
    ns.Comms.RegisterHandler(C.OPS.CINV, onCinv)
end
