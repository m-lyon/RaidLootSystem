-- UI/Minimap.lua
--
-- LibDataBroker launcher plus the minimap button.

local ADDON, ns = ...

ns.Minimap = {}
local Minimap = ns.Minimap

local BUTTON_NAME = "LibDBIcon10_RaidLootSystem"   -- LibDBIcon names its button so
local pulseFrame
local pulseElapsed = 0

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
            elseif IsShiftKeyDown() or not ns.RollWindow.HasContent() then
                ns.HierarchyEditor.Toggle()
            else
                -- A live round, or the last result, is what the button is for.
                ns.RollWindow.Toggle()
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("Raid Loot System")
            if ns.RollWindow.HasContent() then
                tooltip:AddLine("Left-click: the roll window", 1, 1, 1)
                tooltip:AddLine("Shift-click: your hierarchy", 1, 1, 1)
            else
                tooltip:AddLine("Left-click: your hierarchy", 1, 1, 1)
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
