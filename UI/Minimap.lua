-- UI/Minimap.lua
--
-- LibDataBroker launcher plus the minimap button.

local ADDON, ns = ...

ns.Minimap = {}
local Minimap = ns.Minimap

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
            else
                ns.HierarchyEditor.Toggle()
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("Raid Loot System")
            tooltip:AddLine("Left-click: your hierarchy", 1, 1, 1)
            tooltip:AddLine("Right-click: republish your roster", 1, 1, 1)
            local contested = ns.Roster.ContestedNames()
            if #contested > 0 then
                tooltip:AddLine("Contested: " .. table.concat(contested, ", "), 1, 0.3, 0.3)
            end
        end,
    })

    icon:Register("RaidLootSystem", launcher, ns.Database.Settings().minimap)
end
