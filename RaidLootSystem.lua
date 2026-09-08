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

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function status()
    local roster = ns.Database.Roster()
    ns.Print(string.format("version %s, %d characters in your roster, tier count %d.",
        C.VERSION, #roster.order, ns.Database.DefaultTierCount()))

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
-- Loot (spec 004). The host panel (spec 006) will own these; until it exists they are
-- the seam that makes detection and rounds usable and demonstrable.
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
        ns.Print("/rls start opens a round on all of them.")
    end

    for _, skip in ipairs(LootDetect.skipped) do
        local why = ns.LootDetect.SKIP_TEXT[skip.reason] or skip.reason
        ns.Print("  not offered (" .. why .. "): " .. ns.LootDetect.Label(skip)
            .. " - /rls roll <link> to roll for it anyway.")
    end
end

local function startRound()
    local items = ns.LootDetect.candidates
    if #items == 0 then
        ns.Print("there are no candidates. /rls loot to see what was found.")
        return
    end
    local ok, why = ns.Round.Open(items)
    if not ok then ns.Print(why) end
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

local function help()
    ns.Print("commands:")
    ns.Print("  /rls              open the roll window, or your hierarchy when no round is live")
    ns.Print("  /rls window       open the roll window")
    ns.Print("  /rls hierarchy    open your hierarchy")
    ns.Print("  /rls host         open the host panel (master looter)")
    ns.Print("  /rls history      open the history browser")
    ns.Print("  /rls sk list      print the priority list")
    ns.Print("  /rls sk verify    replay the priority list from its seed and report drift")
    ns.Print("  /rls simulate [items=N] [players=N] [scenario=name]  run the pipeline solo")
    ns.Print("  /rls simulate stop   end a running simulation and restore everything")
    ns.Print("  /rls pending      list items you hold for other characters")
    ns.Print("  /rls deliver <n>  open a trade for pending item n")
    ns.Print("  /rls abandon <n>  give up on pending item n (confirmed)")
    ns.Print("  /rls status       version, roster size, conflicts")
    ns.Print("  /rls tiers <0-5>  set the tier count you host with")
    ns.Print("  /rls publish      resend your roster to the raid")
    ns.Print("  /rls request      ask everyone to resend theirs")
    ns.Print("  /rls loot         list what the open corpse has worth rolling for")
    ns.Print("  /rls start        open a round on those items (host)")
    ns.Print("  /rls quality <3|4> set the quality bar the corpse scan applies (rare/epic)")
    ns.Print("  /rls roll <link>  open a round on one item link (host)")
    ns.Print("  /rls close        resolve the open round now (host)")
    ns.Print("  /rls cancel       cancel the open round (host)")
    ns.Print("  /rls sync         ask the host to resend the open round")
    ns.Print("  /rls itemclasses  print this client's item class order (verification)")
    ns.Print("  /rls debug        toggle debug messages")
end

local function dispatch(input)
    local command, argument = input:match("^(%S*)%s*(.-)$")
    command = (command or ""):lower()

    if command == "" then
        if ns.RollWindow.HasContent() then
            ns.RollWindow.Toggle()
        else
            ns.HierarchyEditor.Toggle()
        end
    elseif command == "window" then
        ns.RollWindow.Show()
    elseif command == "hierarchy" then
        ns.HierarchyEditor.Toggle()
    elseif command == "host" then
        ns.HostPanel.Toggle()
    elseif command == "history" then
        ns.HistoryBrowser.Toggle()
    elseif command == "simulate" then
        if argument:lower() == "list" then
            ns.Print("scenarios: " .. ns.Simulate.ListScenarios())
        elseif argument:lower() == "stop" then
            ns.Simulate.Stop()
        else
            ns.Simulate.Run(argument)
        end
    elseif command == "sk" then
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
    elseif command == "pending" then
        ns.Pending.PrintList()
    elseif command == "deliver" then
        local n = tonumber(argument)
        local record = n and ns.Pending.OutstandingRecords()[n] or nil
        if not record then
            ns.Print("no pending item " .. tostring(argument) .. "; /rls pending lists them.")
        else
            ns.Pending.Deliver(record)
        end
    elseif command == "abandon" then
        local n = tonumber(argument)
        local record = n and ns.Pending.OutstandingRecords()[n] or nil
        if not record then
            ns.Print("no pending item " .. tostring(argument) .. "; /rls pending lists them.")
        else
            StaticPopup_Show("RLS_CONFIRM_ABANDON", record.winner, nil, record)
        end
    elseif command == "status" then
        status()
    elseif command == "tiers" then
        setTierCount(argument)
    elseif command == "publish" then
        ns.Roster.Publish()
        ns.Print("roster published.")
    elseif command == "request" then
        ns.Roster.RequestAll()
        ns.Print("asked everyone to resend their roster.")
    elseif command == "loot" then
        lootList()
    elseif command == "start" then
        startRound()
    elseif command == "quality" then
        setQuality(argument)
    elseif command == "roll" then
        rollFor(argument)
    elseif command == "itemclasses" then
        ns.ItemInfo.DumpClasses()
    elseif command == "close" then
        if not ns.Round.Close() then
            ns.Print("there is no round of yours to close.")
        end
    elseif command == "cancel" then
        if not ns.Round.Abort(C.ABORT_REASON.MANUAL) then
            ns.Print("there is no round of yours to cancel.")
        end
    elseif command == "sync" then
        if ns.Client.RequestSync() then
            ns.Print("asked the host to resend the open round.")
        else
            ns.Print("you asked less than " .. C.SYNC_INTERVAL .. " seconds ago; wait a moment.")
        end
    elseif command == "debug" then
        ns.debugEnabled = not ns.debugEnabled
        ns.Print("debug messages " .. (ns.debugEnabled and "on" or "off") .. ".")
    else
        help()
    end
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
        ns.Minimap.Init()
        ns.Comms.Send(C.OPS.HI, C.VERSION)
    end
end)
