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

    local host = ns.Session.HostName()
    ns.Print("master looter: " .. (host or "nobody -- the group is not on master loot")
        .. (ns.Session.IsHost() and " (you host)" or ""))

    local session = ns.Client.session
    if session then
        ns.Print(string.format("batch %s: %d item(s), %s.",
            session.id, #session.items, session.state:lower()))
    end
end

local function setTierCount(argument)
    local count = tonumber(argument)
    if not count or count < C.MIN_TIER_COUNT or count > C.MAX_TIER_COUNT then
        ns.Print(string.format("tier count must be between %d and %d.",
            C.MIN_TIER_COUNT, C.MAX_TIER_COUNT))
        return
    end
    ns.Database.Host().tierCount = math.floor(count)
    ns.Print("tier count set to " .. math.floor(count) .. ". It applies to the next batch.")
    ns.HierarchyEditor.Refresh()
end

local function help()
    ns.Print("commands:")
    ns.Print("  /rls              open your hierarchy")
    ns.Print("  /rls status       version, roster size, conflicts")
    ns.Print("  /rls tiers <0-5>  set the tier count you host with")
    ns.Print("  /rls publish      resend your roster to the raid")
    ns.Print("  /rls request      ask everyone to resend theirs")
    ns.Print("  /rls close        resolve the open batch now (host)")
    ns.Print("  /rls cancel       cancel the open batch (host)")
    ns.Print("  /rls sync         ask the host to resend the open batch")
    ns.Print("  /rls debug        toggle debug messages")
end

local function dispatch(input)
    local command, argument = input:match("^(%S*)%s*(.-)$")
    command = (command or ""):lower()

    if command == "" then
        ns.HierarchyEditor.Toggle()
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
    elseif command == "close" then
        if not ns.Session.Close() then
            ns.Print("there is no batch of yours to close.")
        end
    elseif command == "cancel" then
        if not ns.Session.Abort(C.ABORT_REASON.MANUAL) then
            ns.Print("there is no batch of yours to cancel.")
        end
    elseif command == "sync" then
        if ns.Client.RequestSync() then
            ns.Print("asked the host to resend the open batch.")
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
        math.randomseed(time())         -- exactly once, spec 000 section 7
    elseif event == "PLAYER_LOGIN" then
        ns.Comms.Init()
        ns.Roster.Init()
        ns.Session.Init()
        ns.Client.Init()
        ns.Minimap.Init()
        ns.Comms.Send(C.OPS.HI, C.VERSION)
    end
end)
