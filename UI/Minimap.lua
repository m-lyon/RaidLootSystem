-- UI/Minimap.lua
--
-- LibDataBroker launcher plus the minimap button.

local ADDON, ns = ...

ns.Minimap = {}
local Minimap = ns.Minimap

local BUTTON_NAME = "LibDBIcon10_RaidLootSystem"   -- LibDBIcon names its button so
local pulseFrame
local pulseElapsed = 0

--------------------------------------------------------------------------------
-- Pure: what a click opens (spec 006 section 3, spec 005 section 6)
--------------------------------------------------------------------------------

--- Which window a plain left-click opens.
--
-- The button gives you the window your role wants. A master looter's is the host
-- panel: it is where a round is opened, watched, closed and awarded, and until now
-- `/rls host` was its only way in, which is no way in at all for anyone who has not
-- read the slash command list.
--
-- The roll window is not lost to a host. It opens itself on OPEN and again on the
-- results (005 section 2), and ctrl-click reaches it whenever it has something to
-- show. Nothing else moves: shift is the hierarchy and right is a republish, exactly
-- as before.
-- @return "HOST", "ROLL" or "HIERARCHY"
function Minimap.PrimaryTarget(isHost, hasContent)
    if isHost then return "HOST" end
    if hasContent then return "ROLL" end
    return "HIERARCHY"
end

--- Which window a ctrl-left-click opens, or nil when the chord does nothing.
-- It exists for the one window the host's primary click displaces, so it is offered
-- only when there is a roll window worth opening and something else has the click.
function Minimap.CtrlTarget(isHost, hasContent)
    if isHost and hasContent then return "ROLL" end
    return nil
end

--------------------------------------------------------------------------------
-- WoW-facing. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

--- Fade the button in and out while a round is open and this player is not in
-- (spec 005 section 6). Checked on a light throttle; nothing to do most of the time.
local sinceCheck = 0
local attention = false

local function pulse(_, elapsed)
    pulseElapsed = pulseElapsed + elapsed
    sinceCheck = sinceCheck + elapsed
    if sinceCheck >= 0.1 then
        sinceCheck = 0
        attention = ns.RollWindow ~= nil and ns.RollWindow.NeedsAttention()
    end
    local button = _G[BUTTON_NAME]
    if not button then return end
    if attention then
        button:SetAlpha(0.55 + 0.45 * math.abs(math.sin(pulseElapsed * 3)))
    elseif button:GetAlpha() ~= 1 then
        button:SetAlpha(1)
    end
end

local LABELS = {
    HOST = "the host panel",
    ROLL = "the roll window",
    HIERARCHY = "your hierarchy",
}

function Minimap.Init()
    local ldb = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
    local icon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)
    if not ldb or not icon then return end

    local launcher = ldb:NewDataObject("RaidLootSystem", {
        type = "launcher",
        icon = "Interface\\Icons\\INV_Misc_Gem_Pearl_03",
        OnClick = function(_, button)
            if button == "RightButton" then
                ns.Roster.Publish()
                ns.Print("republished your roster.")
                return
            end
            if IsShiftKeyDown() then
                ns.HierarchyEditor.Toggle()
                return
            end
            local isHost, hasContent = ns.Round.IsHost(), ns.RollWindow.HasContent()
            local target
            if IsControlKeyDown() then target = Minimap.CtrlTarget(isHost, hasContent) end
            -- Ctrl with nothing behind it falls through rather than doing nothing: a
            -- held modifier should never turn the button into a dead click.
            if not target then target = Minimap.PrimaryTarget(isHost, hasContent) end
            if target == "HOST" then
                ns.HostPanel.Toggle()
            elseif target == "ROLL" then
                ns.RollWindow.Toggle()
            else
                ns.HierarchyEditor.Toggle()
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("Raid Loot System")
            local isHost, hasContent = ns.Round.IsHost(), ns.RollWindow.HasContent()
            -- Always says what the click will do right now, rather than listing chords
            -- that may not apply: the primary action changes with your role.
            tooltip:AddLine("Left-click: " .. LABELS[Minimap.PrimaryTarget(isHost, hasContent)],
                1, 1, 1)
            local ctrl = Minimap.CtrlTarget(isHost, hasContent)
            if ctrl then
                tooltip:AddLine("Ctrl-click: " .. LABELS[ctrl], 1, 1, 1)
            end
            if Minimap.PrimaryTarget(isHost, hasContent) ~= "HIERARCHY" then
                tooltip:AddLine("Shift-click: your hierarchy", 1, 1, 1)
            end
            tooltip:AddLine("Right-click: republish your roster", 1, 1, 1)
            if ns.RollWindow.NeedsAttention() then
                tooltip:AddLine("A round is open and you have not submitted.", 1, 0.8, 0.2)
            end
            local contested = ns.Roster.ContestedNames()
            if #contested > 0 then
                tooltip:AddLine("Contested: " .. table.concat(contested, ", "), 1, 0.3, 0.3)
            end
        end,
    })

    icon:Register("RaidLootSystem", launcher, ns.Database.Settings().minimap)

    pulseFrame = CreateFrame("Frame")
    pulseFrame:SetScript("OnUpdate", pulse)
end
