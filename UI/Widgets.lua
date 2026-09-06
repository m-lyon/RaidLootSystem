-- UI/Widgets.lua
--
-- Shared frame factories. Frames are created in Lua; there is no XML
-- (spec 000 section 8).

local ADDON, ns = ...

ns.Widgets = {}
local Widgets = ns.Widgets

local BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

local THIN_BACKDROP = {
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

--- Class colour for an enUS class file name, defaulting to white.
function Widgets.ClassColor(class)
    local colors = RAID_CLASS_COLORS
    local color = class and colors and colors[class]
    if not color then return 1, 1, 1 end
    return color.r, color.g, color.b
end

function Widgets.ColorName(name, class)
    local r, g, b = Widgets.ClassColor(class)
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), name)
end

--------------------------------------------------------------------------------
-- Windows
--------------------------------------------------------------------------------

--- A movable, closable window whose position is remembered in saved variables.
-- @param key identifies the stored position (spec 000 section 4, settings.windows)
function Widgets.Window(globalName, key, title, width, height)
    local f = CreateFrame("Frame", globalName, UIParent)
    f:SetWidth(width)
    f:SetHeight(height)
    f:SetBackdrop(BACKDROP)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    f:Hide()

    f.titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.titleText:SetPoint("TOP", f, "TOP", 0, -16)
    f.titleText:SetText(title)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    local function savePosition()
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint()
        local state = ns.Database.WindowState(key)
        state.point, state.relPoint, state.x, state.y = point, relPoint, x, y
    end

    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", savePosition)

    --- Restore the remembered position, or centre the window on first use.
    function f:RestorePosition()
        local state = ns.Database.WindowState(key)
        self:ClearAllPoints()
        if state.point then
            self:SetPoint(state.point, UIParent, state.relPoint, state.x, state.y)
        else
            self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
    end

    tinsert(UISpecialFrames, globalName)      -- Escape closes it
    return f
end

--------------------------------------------------------------------------------
-- Controls
--------------------------------------------------------------------------------

function Widgets.Button(parent, text, width, height, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetWidth(width)
    b:SetHeight(height or 22)
    b:SetText(text)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

--- The art for Widgets.IconButton. Text glyphs ("^", "v", "X") render at
-- whatever weight the font gives them and never look like a matched set, so the
-- row controls use the same Blizzard art the rest of the UI does. The
-- scroll-arrow files carry a slice of the scroll-bar track around the arrow;
-- the crop is the one FrameXML's UIPanelScrollUpButtonTemplate uses.
local ICON_ART = {
    up = {
        normal    = "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up",
        pushed    = "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down",
        disabled  = "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Disabled",
        highlight = "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Highlight",
        crop      = { 0.20, 0.80, 0.25, 0.75 },
    },
    down = {
        normal    = "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up",
        pushed    = "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down",
        disabled  = "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Disabled",
        highlight = "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Highlight",
        crop      = { 0.20, 0.80, 0.25, 0.75 },
    },
    -- Built from UIPanelCloseButton rather than named textures, so the row's
    -- remove button is the same glyph as the window close button whatever art
    -- the template happens to carry.
    remove = { template = "UIPanelCloseButton" },
}

--- A textured button: `kind` is a key of ICON_ART ("up", "down", "remove").
-- Enable/Disable swap in the disabled art where the set has one.
function Widgets.IconButton(parent, kind, width, height, onClick)
    local art = ICON_ART[kind]
    local b = CreateFrame("Button", nil, parent, art.template)
    b:SetWidth(width)
    b:SetHeight(height or width)

    local function skin(setter, getter, file, blend)
        if not file then return end
        b[setter](b, file, blend)
        local t = b[getter](b)
        if t and art.crop then
            t:SetTexCoord(art.crop[1], art.crop[2], art.crop[3], art.crop[4])
        end
    end

    skin("SetNormalTexture", "GetNormalTexture", art.normal)
    skin("SetPushedTexture", "GetPushedTexture", art.pushed)
    skin("SetDisabledTexture", "GetDisabledTexture", art.disabled)
    skin("SetHighlightTexture", "GetHighlightTexture", art.highlight, "ADD")

    -- UIPanelCloseButton ships an OnClick that hides the parent; ours replaces it.
    b:SetScript("OnClick", onClick)
    return b
end

function Widgets.Label(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetText(text or "")
    return fs
end

function Widgets.EditBox(parent, width, height)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetWidth(width)
    e:SetHeight(height or 20)
    e:SetAutoFocus(false)
    e:SetFontObject("ChatFontNormal")
    e:SetTextInsets(6, 6, 0, 0)
    e:SetBackdrop(THIN_BACKDROP)
    e:SetBackdropColor(0, 0, 0, 0.6)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

--- A labelled slider. `onChange(value)` fires once, when the user lets go: a drag
-- passes through every step, and a setting that broadcasts and announces on each
-- would spam the raid. `onPreview(value)` fires on every step, for the label.
-- SetValueQuiet moves the slider without firing either, for refreshes.
function Widgets.Slider(parent, globalName, label, minValue, maxValue, step, onChange, onPreview)
    local s = CreateFrame("Slider", globalName, parent, "OptionsSliderTemplate")
    s:SetWidth(180)
    s:SetHeight(16)
    s:SetMinMaxValues(minValue, maxValue)
    s:SetValueStep(step)
    _G[globalName .. "Low"]:SetText(tostring(minValue))
    _G[globalName .. "High"]:SetText(tostring(maxValue))
    s.text = _G[globalName .. "Text"]
    s.text:SetText(label)
    s.quiet = false
    s:SetScript("OnValueChanged", function(self, value)
        if self.quiet then return end
        self.dirty = true
        if onPreview then onPreview(value) end
    end)
    s:SetScript("OnMouseUp", function(self)
        if not self.dirty then return end
        self.dirty = false
        onChange(self:GetValue())
    end)
    function s:SetValueQuiet(value)
        self.quiet = true
        self:SetValue(value)
        self.quiet = false
        self.dirty = false
    end
    return s
end

--- A dropdown over `options`, each { value, text, disabled, tooltipTitle, tooltip }.
-- `onSelect(value)` fires on user selection only; SetValue moves it without firing.
function Widgets.Dropdown(parent, globalName, width, options, onSelect)
    local d = CreateFrame("Frame", globalName, parent, "UIDropDownMenuTemplate")
    d.options = options

    UIDropDownMenu_Initialize(d, function()
        for _, opt in ipairs(d.options) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.value = opt.text, opt.value
            info.disabled = opt.disabled
            info.tooltipTitle, info.tooltipText = opt.tooltipTitle, opt.tooltip
            info.checked = (opt.value == d.selected)
            info.func = function(self)
                d:SetValue(self.value)
                onSelect(self.value)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(d, width)

    function d:SetValue(value)
        self.selected = value
        UIDropDownMenu_SetSelectedValue(self, value)
        local text
        for _, opt in ipairs(self.options) do
            if opt.value == value then text = opt.text end
        end
        UIDropDownMenu_SetText(self, text or tostring(value))
    end

    function d:SetOptions(newOptions)
        self.options = newOptions
    end
    return d
end

--- A labelled check box. `onClick(checked)` fires on user clicks only.
function Widgets.CheckBox(parent, globalName, label, onClick)
    local c = CreateFrame("CheckButton", globalName, parent, "UICheckButtonTemplate")
    c:SetWidth(24)
    c:SetHeight(24)
    c.text = _G[globalName .. "Text"]
    c.text:SetText(label)
    c:SetScript("OnClick", function(self) onClick(self:GetChecked() == 1) end)
    return c
end

--- A bordered panel, used for list backgrounds and badges.
function Widgets.Panel(parent, alpha)
    local p = CreateFrame("Frame", nil, parent)
    p:SetBackdrop(THIN_BACKDROP)
    p:SetBackdropColor(0, 0, 0, alpha or 0.4)
    p:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    return p
end

--- How far a child of a Widgets.ScrollArea must stay clear of its right edge.
-- UIPanelScrollFrameTemplate anchors its scroll bar to the scroll frame's
-- TOPRIGHT at x = -6, so the bar sits *over* the last few pixels of the scroll
-- area; anything drawn out to the full width ends up underneath it.
Widgets.SCROLLBAR_GUTTER = 22

--- A scrolling content area. Returns the scroll frame and the content frame to
-- parent rows to.
-- The scroll frame is named because UIPanelScrollFrameTemplate builds its
-- scroll bar as "$parentScrollBar".
function Widgets.ScrollArea(parent, globalName, width, height)
    local scroll = CreateFrame("ScrollFrame", globalName, parent, "UIPanelScrollFrameTemplate")
    scroll:SetWidth(width)
    scroll:SetHeight(height)

    local content = CreateFrame("Frame", globalName and (globalName .. "Content") or nil, scroll)
    content:SetWidth(width)
    content:SetHeight(height)
    scroll:SetScrollChild(content)
    return scroll, content
end

--- A one-pixel horizontal rule, optionally labelled. Used for tier bands.
function Widgets.Separator(parent, label, heavy)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(heavy and 2 or 1)
    if heavy then
        line:SetTexture(0.9, 0.7, 0.2, 0.9)
    else
        line:SetTexture(0.5, 0.5, 0.5, 0.6)
    end

    local text
    if label then
        text = Widgets.Label(parent, label, "GameFontNormalSmall")
    end
    return line, text
end

--- A small coloured dot, used for raid presence.
function Widgets.Dot(parent, size)
    local t = parent:CreateTexture(nil, "OVERLAY")
    t:SetTexture("Interface\\COMMON\\Indicator-Green")
    t:SetWidth(size or 12)
    t:SetHeight(size or 12)
    return t
end

function Widgets.SetDotPresent(dot, present)
    if present then
        dot:SetTexture("Interface\\COMMON\\Indicator-Green")
        dot:SetAlpha(1)
    else
        dot:SetTexture("Interface\\COMMON\\Indicator-Gray")
        dot:SetAlpha(0.7)
    end
end

--- Attach a tooltip to any frame.
function Widgets.Tooltip(frame, title, body)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        if body then GameTooltip:AddLine(body, nil, nil, nil, true) end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
