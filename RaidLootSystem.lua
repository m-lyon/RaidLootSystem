-- RaidLootSystem.lua
--
-- Bootstrap: saved variables, module init, slash commands. Loaded last
-- (spec 000 section 3).

local ADDON, ns = ...

local C = ns.Constants

RaidLootSystem = {}          -- the one permitted global besides the saved variables

local PREFIX_TEXT = "|cff66ccffRaid Loot System|r: "

function ns.Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX_TEXT .. tostring(message))
end

--- Off by default. `/rls debug` turns it on for the session.
ns.debugEnabled = false
function ns.Debug(message)
    if ns.debugEnabled then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX_TEXT .. "|cff888888" .. tostring(message) .. "|r")
    end
end

--- Print a line the first time `key` is seen in `seen`, and only to the debug log
-- after that. For warnings a peer can trigger on every message: an unbounded repeat
-- buries the raid's chat (the rule spec 002 section 11 uses). `seen` lives for the
-- login session, so the warning comes back after a reload.
function ns.WarnOnce(seen, key, line)
    if seen[key] then
        ns.Debug(line)
    else
        seen[key] = true
        ns.Print(line)
    end
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function status()
    local campaign = ns.Campaign.Active()
    if campaign then
        ns.Print(string.format("version %s, campaign \"%s\", %d characters in it, tier count %d.",
            C.VERSION, campaign.label, #campaign.hierarchy, ns.Database.DefaultTierCount()))
    else
        ns.Print(string.format(
            "version %s, no campaign yet - create or join one with /rls campaign new.", C.VERSION))
    end

    local contested = ns.Roster.ContestedNames()
    if #contested > 0 then
        ns.Print("contested characters: " .. table.concat(contested, ", ")
            .. ". Nobody can enter these until one claimant removes them.")
    end

    local unclaimed = ns.Roster.UnclaimedGroupMembers()
    if #unclaimed > 0 then
        ns.Print("in the group but in nobody's roster: " .. table.concat(unclaimed, ", "))
    end

    local host = ns.Round.HostName()
    ns.Print("master looter: " .. (host or "nobody - the group is not on master loot")
        .. (ns.Round.IsHost() and " (you host)" or ""))

    local round = ns.Client.round
    if round then
        ns.Print(string.format("round %s: %d item(s), %s.",
            round.id, #round.items, round.state:lower()))
    end
end

local function setTierCount(argument)
    local count = tonumber(argument)
    if not count or count < C.MIN_TIER_COUNT or count > C.MAX_TIER_COUNT then
        ns.Print(string.format("tier count must be between %d and %d.",
            C.MIN_TIER_COUNT, C.MAX_TIER_COUNT))
        return
    end
    local ok, why = ns.Round.ChangeSetting("tierCount", count)
    if not ok then
        ns.Print(why)
        return
    end
    ns.Print("tier count set to " .. math.floor(count) .. ". It applies to the next round.")
end

--------------------------------------------------------------------------------
-- Loot (spec 004). The roll window's setup state (spec 005 section 2) is the screen
-- for these now; the commands remain as the scriptable seam, and as the way in when
-- the window has been closed.
--------------------------------------------------------------------------------

local function lootList()
    local LootDetect = ns.LootDetect
    if LootDetect.scanning then
        ns.Print("still looking these items up; try again in a moment.")
        return
    end

    local items = LootDetect.candidates
    if #items == 0 then
        ns.Print("nothing here is worth rolling for. Open the loot window as master looter, "
            .. "or use /rls roll <item link> for one item.")
    else
        ns.Print(#items .. " candidate(s):")
        for i = 1, #items do
            local item = items[i]
            local marker = item.info and item.info.special and "  [unclassified - anyone may enter]" or ""
            ns.Print(string.format("  %d. %s%s%s", i, ns.LootDetect.Label(item),
                item.count > 1 and (" x" .. item.count) or "", marker))
        end
        ns.Print("/rls start opens a round on the ticked ones.")
        -- And put the window back up: the list is a screen now, not a chat dump.
        if ns.RollWindow then ns.RollWindow.ShowSetup() end
    end

    for _, skip in ipairs(LootDetect.skipped) do
        local why = ns.LootDetect.SKIP_TEXT[skip.reason] or skip.reason
        ns.Print("  not offered (" .. why .. "): " .. ns.LootDetect.Label(skip)
            .. " - /rls roll <link> to roll for it anyway.")
    end
    -- Nothing automatic, but a drop the host hands out by hand: the setup list's
    -- Add item box is where that happens.
    if #items == 0 and ns.RollWindow then ns.RollWindow.ShowSetup() end
end

local function startRound()
    -- The same items the roll window's Start roll button opens on: a host who unticked
    -- rows there must not get them back by typing the command instead.
    local items = (ns.RollWindow and ns.RollWindow.TickedItems()) or ns.LootDetect.candidates
    if #items == 0 then
        ns.Print("there are no ticked candidates. /rls loot to see what was found.")
        return
    end
    -- The same rule the roll window's Start roll button is gated by.
    local hasLootSlot = false
    for _, item in ipairs(items) do
        if item.lootSlot then hasLootSlot = true break end
    end
    local round = ns.Round.current
    local blocker = ns.HostPanel.StartBlocker({
        isHost = ns.Round.IsHost(),
        lootMethod = (GetLootMethod()),
        roundOpen = round ~= nil and round.state == C.ROUND_STATE.OPEN,
        scanning = ns.LootDetect.scanning,
        ticked = #items,
        staleSlots = not ns.LootDetect.windowOpen and hasLootSlot,
    })
    if blocker then
        ns.Print(blocker)
        return
    end
    -- A host cannot disenfranchise anyone without being told (spec 012 section 6).
    ns.Campaigns.GuardOpen(function()
        local ok, why = ns.Round.Open(items)
        if not ok then ns.Print(why) end
    end)
end

local function rollFor(argument)
    if argument == "" then
        ns.Print("give an item link: /rls roll [Shadowmourne]")
        return
    end
    ns.LootDetect.FromLink(argument, function(items)
        if not items then return end
        local ok, why = ns.Round.Open(items)
        if not ok then ns.Print(why) end
    end)
end

--- The quality bar the corpse scan applies (spec 004 section 2). The host panel (spec 006)
-- owns this setting; this is here so the bar can be moved without one.
local function setQuality(argument)
    local ok, why = ns.Round.ChangeSetting("qualityThreshold", tonumber(argument))
    if not ok then
        ns.Print(why)
        return
    end
    ns.Print("only loot of quality " .. tonumber(argument) .. " and above is offered.")
end

--- `/rls campaign ...` (spec 012 section 13).
local function campaignCommand(argument)
    local sub, rest = argument:match("^(%S*)%s*(.-)$")
    sub = (sub or ""):lower()
    local Campaign = ns.Campaign

    if sub == "" then
        Campaign.PrintList()
    elseif sub == "new" then
        if rest == "" then
            ns.Print("give a label: /rls campaign new Tuesday 25")
        else
            ns.Campaigns.ShowCreate(rest)
        end
    elseif sub == "switch" then
        local campaign = Campaign.ByIndex(rest)
        if not campaign then
            ns.Print("no campaign " .. rest .. "; /rls campaign lists them.")
        else
            local ok, why = Campaign.Switch(campaign.id)
            if not ok then ns.Print(why) end
        end
    elseif sub == "rename" then
        local ok, why = Campaign.Rename(Campaign.ActiveId(), rest)
        if not ok then ns.Print(why) else ns.Print("renamed to \"" .. rest .. "\".") end
    elseif sub == "delete" then
        local campaign = Campaign.ByIndex(rest)
        if not campaign then
            ns.Print("no campaign " .. rest .. "; /rls campaign lists them.")
        else
            ns.Campaigns.PromptDelete(campaign.id)
        end
    elseif sub == "invite" then
        local ok, why = Campaign.Invite()
        if not ok then ns.Print(why) end
    elseif sub == "export" then
        ns.Campaigns.ShowExport(Campaign.ActiveId())
    elseif sub == "import" then
        if rest == "" then ns.Campaigns.ShowImport() else ns.Campaigns.Import(rest) end
    else
        ns.Print("/rls campaign [new <label> | switch <n> | rename <label> | delete <n> "
            .. "| invite | export | import <string>]")
    end
end

--- The pending record `/rls deliver <n>` and `/rls abandon <n>` name, or nil with the
-- refusal already printed.
local function pendingByNumber(argument)
    local n = tonumber(argument)
    local record = n and ns.Pending.OutstandingRecords()[n] or nil
    if not record then
        ns.Print("no pending item " .. tostring(argument) .. "; /rls pending lists them.")
    end
    return record
end

-- Every slash command, in the order help lists them. One table so the help and the
-- dispatch cannot drift apart: each command's usage lines sit next to its handler.
-- `usage` is { { "/rls ...", "what it does" }, ... }.
local COMMANDS = {
    { "window", usage = { { "/rls window", "open the roll window" } }, run = function()
        -- A host with nothing else on screen gets the setup list even with no corpse
        -- open, so Add item and Start roll stay reachable from the UI.
        local wantSetup = ns.RollWindow.SetupReachable() or not ns.RollWindow.HasContent()
        if not (wantSetup and ns.RollWindow.ShowSetup(true)) then
            ns.RollWindow.Show()
        end
    end },
    { "hierarchy", usage = { { "/rls hierarchy", "open your hierarchy" } },
      run = function() ns.HierarchyEditor.Toggle() end },
    { "host", usage = { { "/rls host", "open the host panel, or left-click the minimap "
        .. "button while you are master looter" } },
      run = function() ns.HostPanel.Toggle() end },
    { "history", usage = { { "/rls history", "open the history browser" } },
      run = function() ns.HistoryBrowser.Toggle() end },
    { "campaign", usage = {
        { "/rls campaign", "list your campaigns, marking the active one" },
        { "/rls campaign new <label> | switch <n> | rename <label> | delete <n>" },
        { "/rls campaign invite | export | import <string>" },
      }, run = function(argument) campaignCommand(argument) end },
    { "sk", usage = {
        { "/rls sk", "open the priority list window" },
        { "/rls sk list", "print the priority list" },
        { "/rls sk verify", "replay the priority list from its seed and report drift" },
      }, run = function(argument)
        local sub = argument:lower()
        if sub == "verify" then
            ns.Priority.RunVerify()
        elseif sub == "" then
            ns.PriorityViewer.Toggle()
        elseif sub == "list" then
            ns.Priority.PrintList()
        else
            ns.Print("/rls sk for the list window, /rls sk list to print it, "
                .. "/rls sk verify to check it. Seeding and edits are in the host panel.")
        end
    end },
    { "simulate", usage = {
        { "/rls simulate [items=N] [players=N] [scenario=name]", "run the pipeline solo" },
        { "/rls simulate list", "name the scenarios" },
        { "/rls simulate stop", "end a running simulation and restore everything" },
      }, run = function(argument)
        if argument:lower() == "list" then
            ns.Print("scenarios: " .. ns.Simulate.ListScenarios())
        elseif argument:lower() == "stop" then
            ns.Simulate.Stop()
        else
            ns.Simulate.Run(argument)
        end
    end },
    { "pending", usage = { { "/rls pending", "list items you hold for other characters" } },
      run = function() ns.Pending.PrintList() end },
    { "deliver", usage = { { "/rls deliver <n>", "open a trade for pending item n" } },
      run = function(argument)
        local record = pendingByNumber(argument)
        if record then ns.Pending.Deliver(record) end
    end },
    { "abandon", usage = { { "/rls abandon <n>", "give up on pending item n (confirmed)" } },
      run = function(argument)
        local record = pendingByNumber(argument)
        if record then StaticPopup_Show("RLS_CONFIRM_ABANDON", record.winner, nil, record) end
    end },
    { "status", usage = { { "/rls status", "version, roster size, conflicts" } },
      run = function() status() end },
    { "links", usage = {
        { "/rls links off", "announce items by name, so bots do not read a link" },
        { "/rls links on", "announce items as links again" },
      }, run = function(argument)
        -- Whether announcements carry item links (spec 015). On the host panel too;
        -- here because a host whose bots are trading items back wants it off now,
        -- not after finding the tick box.
        local sub = argument:lower()
        if sub == "off" then
            ns.Round.ChangeSetting("plainItemNames", true)
            ns.Print("items are announced by name. Bots no longer read a link in raid chat.")
        elseif sub == "on" then
            ns.Round.ChangeSetting("plainItemNames", false)
            ns.Print("items are announced as links. Your bots may answer one by opening "
                .. "a trade with you.")
        else
            ns.Print(string.format("item links in raid announcements: %s. "
                .. "/rls links off announces names instead.",
                ns.Database.Settings().plainItemNames and "off (names only)" or "on"))
        end
    end },
    { "tiers", usage = {
        { "/rls tiers", "who composes each tier of your campaign" },
        { "/rls tiers <0-5>", "set the tier count you host with" },
      }, run = function(argument)
        -- Bare opens the campaign's tier roster (spec 013 section 5); with a number
        -- it still sets the count a host raids with. Reading who is in a tier and
        -- choosing how many tiers there are are the same subject, so they share the
        -- word rather than inventing a second one for the reading half.
        if argument == "" then
            ns.TierViewer.Toggle()
        else
            setTierCount(argument)
        end
    end },
    { "publish", usage = { { "/rls publish", "resend your roster to the raid" } },
      run = function()
        ns.Roster.Publish()
        ns.Print("roster published.")
    end },
    { "request", usage = { { "/rls request", "ask everyone to resend theirs" } },
      run = function()
        ns.Roster.RequestAll()
        ns.Print("asked everyone to resend their roster.")
    end },
    { "loot", usage = { { "/rls loot", "list what the open corpse has worth rolling for" } },
      run = function() lootList() end },
    { "start", usage = { { "/rls start", "open a round on those items (host)" } },
      run = function() startRound() end },
    { "quality", usage = { { "/rls quality <3|4>",
        "set the quality bar the corpse scan applies (rare/epic)" } },
      run = function(argument) setQuality(argument) end },
    { "roll", usage = { { "/rls roll <link>", "open a round on one item link (host)" } },
      run = function(argument) rollFor(argument) end },
    { "close", usage = { { "/rls close", "resolve the open round now (host)" } },
      run = function()
        if not ns.Round.Close() then
            ns.Print("there is no round of yours to close.")
        end
    end },
    { "cancel", usage = { { "/rls cancel", "cancel the open round (host)" } },
      run = function()
        if not ns.Round.Abort(C.ABORT_REASON.MANUAL) then
            ns.Print("there is no round of yours to cancel.")
        end
    end },
    { "sync", usage = { { "/rls sync", "ask the host to resend the open round" } },
      run = function()
        if ns.Client.RequestSync() then
            ns.Print("asked the host to resend the open round.")
        else
            ns.Print("you asked less than " .. C.SYNC_INTERVAL .. " seconds ago; wait a moment.")
        end
    end },
    { "itemclasses", usage = { { "/rls itemclasses",
        "print this client's item class order (verification)" } },
      run = function() ns.ItemInfo.DumpClasses() end },
    { "debug", usage = { { "/rls debug", "toggle debug messages" } }, run = function()
        ns.debugEnabled = not ns.debugEnabled
        ns.Print("debug messages " .. (ns.debugEnabled and "on" or "off") .. ".")
    end },
}

local COMMAND_BY_NAME = {}
for _, command in ipairs(COMMANDS) do COMMAND_BY_NAME[command[1]] = command end

local function help()
    ns.Print("commands:")
    ns.Print("  /rls              open the window for your role: the loot window over a "
        .. "corpse or during a round, the host panel as master looter otherwise, "
        .. "else your hierarchy")
    for _, command in ipairs(COMMANDS) do
        for _, line in ipairs(command.usage) do
            if line[2] then
                ns.Print(string.format("  %-17s %s", line[1], line[2]))
            else
                ns.Print("  " .. line[1])
            end
        end
    end
end

local function dispatch(input)
    local command, argument = input:match("^(%S*)%s*(.-)$")
    command = (command or ""):lower()

    if command == "" then
        -- The same decision the minimap button makes, from the same function: the
        -- button and a bare /rls have always opened the same window, and two copies of
        -- the rule would drift the first time one of them changed (spec 006 section 3).
        local target = ns.Minimap.PrimaryTarget(ns.Round.IsHost(), ns.RollWindow.HasContent(),
            ns.RollWindow.SetupReachable())
        if target == "HOST" then
            ns.HostPanel.Toggle()
        elseif target == "ROLL" then
            ns.RollWindow.Toggle()
        else
            ns.HierarchyEditor.Toggle()
        end
        return
    end
    local entry = COMMAND_BY_NAME[command]
    if entry then entry.run(argument or "") else help() end
end

SLASH_RAIDLOOTSYSTEM1 = "/rls"
SLASH_RAIDLOOTSYSTEM2 = "/raidloot"
SlashCmdList["RAIDLOOTSYSTEM"] = dispatch

RaidLootSystem.Command = dispatch
RaidLootSystem.ns = ns          -- debugging seam; nothing ships depending on it

--------------------------------------------------------------------------------
-- Load
--------------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(_, event, addonName)
    if event == "ADDON_LOADED" and addonName == ADDON then
        ns.Database.Load()
        -- Spec 000 section 7 asks for one seed at load, but 3.3.5a's Lua
        -- sandbox does not expose math.randomseed -- the client seeds its own
        -- RNG at startup. Guarded so the addon still loads where it is absent.
        if math.randomseed then
            math.randomseed(time())     -- exactly once, spec 000 section 7
        end
    elseif event == "PLAYER_LOGIN" then
        ns.Comms.Init()
        ns.Campaign.Init()
        ns.History.Init()
        ns.Announce.Init()
        ns.Roster.Init()
        ns.ItemInfo.Init()
        ns.LootDetect.Init()
        ns.Round.Init()
        ns.Client.Init()
        ns.Award.Init()
        ns.Pending.Init()
        ns.Priority.Init()
        ns.RollWindow.Init()
        ns.HostPanel.Init()
        ns.Campaigns.Init()
        ns.Minimap.Init()
        ns.Comms.Send(C.OPS.HI, ns.Round.HiBody())
    end
end)
