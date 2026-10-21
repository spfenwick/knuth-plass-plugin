--[[--
Settings for Knuth–Plass paragraph line breaking in CREngine.

Everything lives in this plugin so that stock KOReader files stay untouched:
the engine properties are set directly on the document, values are stored
per book as copt_<name>, defaults as copt_<name> in the global settings, and
each setting is a Dispatcher action so gestures and Profiles can use it.

The plugin only activates when the CREngine in use knows these properties.
With a stock engine it stays out of the way.
--]]--

local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local C_ = _.pgettext
local T = require("ffi/util").template

-- A Knuth-capable engine fills in a default for this property when a
-- document view is created; a stock engine returns an empty string.
local CAPABILITY_PROPERTY = "crengine.style.justify.tolerance"

local KnuthPlass = WidgetContainer:extend{
    name = "knuthplass",
    is_doc_only = true,
}

local function knuthOnly(self)
    return self.values.line_breaking_mode == 1
end

local options = {
    {
        name = "line_breaking_mode",
        event = "SetLineBreakingMode",
        title = _("Line breaking"),
        default = 1,
        values = { 0, 1 },
        labels = { C_("Line breaking", "greedy"), C_("Line breaking", "Knuth–Plass") },
        properties = { "crengine.style.line.breaking.mode" },
        info = _([[Choose how justified text is split into lines.

- greedy: KOReader's standard line-by-line strategy.
- Knuth–Plass: chooses the line breaks of each paragraph together, so that word spacing is as even as possible across the whole paragraph.

Knuth–Plass falls back to greedy for paragraphs with images, floats, inline boxes, bidirectional or CJK text.]]),
    },
    {
        name = "justification_word_spacing",
        event = "SetJustificationWordSpacing",
        title = _("Word-space limits"),
        default = { 25, 35 },
        values = { { 25, 35 }, { 33, 50 }, { 40, 75 } },
        labels = {
            C_("Justification spacing", "tight"),
            C_("Justification spacing", "balanced"),
            C_("Justification spacing", "loose"),
        },
        properties = {
            "crengine.style.justify.space.shrink.percent",
            "crengine.style.justify.space.stretch.percent",
        },
        enabled_func = knuthOnly,
        left_text = _("Max −"), left_min = 0, left_max = 100, left_step = 1, left_hold_step = 5,
        right_text = _("Max +"), right_min = 0, right_max = 200, right_step = 1, right_hold_step = 5,
        unit = "%", signed = true,
        info = _([[Maximum contraction and expansion of every adjustable word space, as percentages of its natural width. All spaces on one line receive the same width.]]),
    },
    {
        name = "justification_letter_spacing",
        event = "SetJustificationLetterSpacing",
        title = _("Letter-space limits"),
        default = { 1, 0 },
        values = { { 0, 0 }, { 1, 0 } },
        labels = {
            C_("Letter spacing", "off"),
            C_("Letter spacing", "−1% fallback"),
        },
        properties = {
            "crengine.style.justify.tracking.shrink.percent",
            "crengine.style.justify.tracking.stretch.percent",
        },
        enabled_func = knuthOnly,
        left_text = _("Max −"), left_min = 0, left_max = 20, left_step = 1, left_hold_step = 2,
        right_text = _("Max +"), right_min = 0, right_max = 0, right_step = 1, right_hold_step = 2,
        unit = "%", signed = true,
        info = _([[Maximum negative letter spacing, used when a line cannot fit after word spaces reach their minimum, and for the tiny overshoot from rounding equal word spaces upward. Letters are never expanded.

Only used with best kerning (HarfBuzz).]]),
    },
    {
        name = "justification_tracking_smoothness",
        event = "SetJustificationTrackingSmoothness",
        title = _("Letter-space smoothness"),
        default = 50,
        values = { 0, 25, 50, 100 },
        labels = {
            C_("Adjacent-line letter spacing", "off"),
            C_("Adjacent-line letter spacing", "strict"),
            C_("Adjacent-line letter spacing", "smooth"),
            C_("Adjacent-line letter spacing", "relaxed"),
        },
        properties = { "crengine.style.justify.tracking.delta.max.bp" },
        enabled_func = knuthOnly,
        value_min = 0, value_max = 1000, value_step = 5, value_hold_step = 25,
        info = _([[Maximum change in letter spacing between consecutive justified lines, in basis points. 50 means 0.50 percentage points. Off removes the limit.]]),
    },
    {
        name = "justification_tolerance",
        event = "SetJustificationTolerance",
        title = _("Fit tolerance"),
        default = { 100, 200 },
        values = { { 50, 100 }, { 100, 200 }, { 200, 500 } },
        labels = {
            C_("Fit tolerance", "strict"),
            C_("Fit tolerance", "balanced"),
            C_("Fit tolerance", "forgiving"),
        },
        properties = {
            "crengine.style.justify.pretolerance",
            "crengine.style.justify.tolerance",
        },
        enabled_func = knuthOnly,
        left_text = _("Normal"), left_min = 0, left_max = 10000, left_step = 10, left_hold_step = 100,
        right_text = _("Emergency"), right_min = 0, right_max = 10000, right_step = 10, right_hold_step = 100,
        info = _([[Knuth badness limits. The emergency tolerance is used only when no solution fits the normal one, together with emergency stretch. If neither finds a solution, a last pass accepts looser lines rather than giving up on the paragraph. Lower values reject uneven lines more aggressively.]]),
    },
    {
        name = "justification_line_penalty",
        event = "SetJustificationLinePenalty",
        title = _("Line-quality penalties"),
        default = { 10, 10000 },
        values = { { 10, 5000 }, { 10, 10000 }, { 10, 20000 } },
        labels = {
            C_("Line quality", "relaxed"),
            C_("Line quality", "balanced"),
            C_("Line quality", "smooth"),
        },
        properties = {
            "crengine.style.justify.line.penalty",
            "crengine.style.justify.adjacent.demerits",
        },
        enabled_func = knuthOnly,
        left_text = _("Line"), left_min = 0, left_max = 10000, left_step = 1, left_hold_step = 10,
        right_text = _("Adjacent fit"), right_min = 0, right_max = 100000, right_step = 100, right_hold_step = 1000,
        info = _([[Base penalty for every line (higher values prefer fewer lines), and extra demerits for neighbouring lines whose spacing differs sharply (one very tight next to one very loose).]]),
    },
    {
        name = "justification_line_limits",
        event = "SetJustificationLineLimits",
        title = _("Emergency & ending"),
        default = { 6, 33 },
        values = { { 6, 0 }, { 6, 33 }, { 8, 50 } },
        labels = {
            C_("Paragraph ending", "natural"),
            C_("Paragraph ending", "balanced"),
            C_("Paragraph ending", "long"),
        },
        properties = {
            "crengine.style.justify.emergency.stretch.percent",
            "crengine.style.justify.last.line.min.percent",
        },
        enabled_func = knuthOnly,
        left_text = _("Emergency"), left_min = 0, left_max = 100, left_step = 1, left_hold_step = 5,
        right_text = _("Ending min"), right_min = 0, right_max = 100, right_step = 1, right_hold_step = 5,
        unit = "%",
        info = _([[Emergency stretch is extra flexibility, as a percentage of the line width, used only when the normal pass cannot find a solution. Ending minimum prefers a final line at least this percentage of the line width.]]),
    },
    {
        name = "justification_hyphen_penalty",
        event = "SetJustificationHyphenPenalty",
        title = _("Hyphen penalties"),
        default = { 0, 0 },
        values = { { 0, 0 }, { 1000, 1000 }, { 3000, 3000 }, { 10000, 10000 } },
        labels = {
            C_("Hyphen penalty", "free"),
            C_("Hyphen penalty", "light"),
            C_("Hyphen penalty", "moderate"),
            C_("Hyphen penalty", "strong"),
        },
        properties = {
            "crengine.style.justify.hyphen.penalty",
            "crengine.style.justify.explicit.hyphen.penalty",
        },
        enabled_func = knuthOnly,
        left_text = _("Hyphenation"), left_min = 0, left_max = 100000, left_step = 100, left_hold_step = 1000,
        right_text = _("Explicit"), right_min = 0, right_max = 100000, right_step = 100, right_hold_step = 1000,
        info = _([[Cost of ending a line at a hyphenation point, and at a hyphen already in the text. Higher values mean fewer hyphenated lines, at the price of less even spacing. Values below about 1000 have little effect.

A penalty only chooses between layouts that fit the word-space limits: where a line cannot be filled without breaking a word, the hyphen stays. Looser word-space limits leave more room to avoid hyphens.]]),
    },
    {
        name = "justification_hyphen_demerits",
        event = "SetJustificationHyphenDemerits",
        title = _("Repeated-hyphen penalties"),
        default = { 0, 0 },
        values = { { 0, 0 }, { 1000000, 500000 }, { 3000000, 1500000 }, { 10000000, 5000000 } },
        labels = {
            C_("Repeated hyphens", "free"),
            C_("Repeated hyphens", "light"),
            C_("Repeated hyphens", "moderate"),
            C_("Repeated hyphens", "strong"),
        },
        properties = {
            "crengine.style.justify.double.hyphen.demerits",
            "crengine.style.justify.final.hyphen.demerits",
        },
        enabled_func = knuthOnly,
        left_text = _("Consecutive"), left_min = 0, left_max = 10000000, left_step = 10000, left_hold_step = 100000,
        right_text = _("Before last"), right_min = 0, right_max = 10000000, right_step = 10000, right_hold_step = 100000,
        info = _([[Extra demerits for two hyphenated lines in a row, and for hyphenating the second-to-last line of a paragraph. Values below about 1000000 have little effect.]]),
    },
}

local options_by_name = {}
for _i, option in ipairs(options) do
    options_by_name[option.name] = option
end

local function copy(value)
    return type(value) == "table" and util.tableDeepCopy(value) or value
end

local function same(a, b)
    if type(a) == "table" and type(b) == "table" then
        return util.tableEquals(a, b)
    end
    return a == b
end

local function formatValue(option, value)
    for i, preset in ipairs(option.values) do
        if same(preset, value) then
            return option.labels[i]
        end
    end
    if type(value) == "table" then
        if option.signed then
            return T("−%1% / +%2%", value[1], value[2])
        elseif option.unit == "%" then
            return T("%1% / %2%", value[1], value[2])
        end
        return T("%1 / %2", value[1], value[2])
    end
    if option.name == "justification_tracking_smoothness" then
        return string.format("%.2f%%", value / 100)
    end
    return tostring(value)
end

local function validValue(option, value)
    if type(option.default) == "table" then
        if type(value) ~= "table" or type(value[1]) ~= "number" or type(value[2]) ~= "number" then
            return nil
        end
    elseif type(value) ~= "number" then
        return nil
    end
    return value
end

function KnuthPlass:init()
    self.values = {}
    self.active = false
    self:onDispatcherRegisterActions()
    -- Only reflowable (CREngine) documents have these settings.
    if self.ui.rolling then
        self.ui.menu:registerToMainMenu(self)
    end
end

function KnuthPlass:onDispatcherRegisterActions()
    for _i, option in ipairs(options) do
        Dispatcher:registerAction(option.name, {
            category = "string",
            event = option.event,
            title = option.title,
            args = option.values,
            toggle = option.labels,
            configurable = { name = option.name, values = option.values },
            rolling = true,
        })
    end
end

function KnuthPlass:engineSupported()
    local document = self.ui.document
    if not (self.ui.rolling and document and document._document) then
        return false
    end
    local probe = document._document:getStringProperty(CAPABILITY_PROPERTY)
    return probe ~= nil and probe ~= ""
end

function KnuthPlass:readValue(config, option)
    local value = validValue(option, config:readSetting("copt_" .. option.name))
    if value == nil then
        value = validValue(option, G_reader_settings:readSetting("copt_" .. option.name))
    end
    if value == nil then
        value = option.default
    end
    return copy(value)
end

function KnuthPlass:applyOption(option, value)
    local cre = self.ui.document._document
    if #option.properties == 1 then
        cre:setIntProperty(option.properties[1], value)
    else
        cre:setIntProperty(option.properties[1], value[1])
        cre:setIntProperty(option.properties[2], value[2])
    end
end

-- Runs after the core reader modules have read their settings (plugins are
-- registered after them) and before the document is first rendered.
function KnuthPlass:onReadSettings(config)
    self.active = self:engineSupported()
    if not self.active then
        if self.ui.rolling then
            logger.info("Knuth–Plass: this CREngine has no Knuth–Plass support; plugin inactive")
        end
        return
    end
    for _i, option in ipairs(options) do
        local value = self:readValue(config, option)
        self.values[option.name] = value
        -- Keeping the value in configurable lets ReaderConfig save it with
        -- the book (as copt_<name>) and Profiles capture it.
        self.ui.document.configurable[option.name] = copy(value)
        self:applyOption(option, value)
    end
end

function KnuthPlass:onReaderReady()
    if self.active then
        self:hookProfiles()
    end
end

-- Let Profiles' "create from current book settings" include our settings.
-- Applying a profile needs nothing extra: each setting is a Dispatcher action.
function KnuthPlass:hookProfiles()
    local profiles = self.ui.profiles
    if not profiles or profiles._knuth_plass_hooked
            or type(profiles.getProfileFromCurrentBookSettings) ~= "function" then
        return
    end
    local original = profiles.getProfileFromCurrentBookSettings
    profiles.getProfileFromCurrentBookSettings = function(plugin, new_name)
        local profile = original(plugin, new_name)
        if not plugin.ui.rolling or type(profile) ~= "table" or type(profile.settings) ~= "table" then
            return profile
        end
        local order = profile.settings.order or {}
        for _i, option in ipairs(options) do
            local value = self.values[option.name]
            if value ~= nil and not util.arrayContains(order, option.name) then
                table.insert(order, option.name)
                profile[option.name] = copy(value)
            end
        end
        profile.settings.order = order
        return profile
    end
    profiles._knuth_plass_hooked = true
end

function KnuthPlass:setValue(name, value, quiet)
    local option = options_by_name[name]
    if not option or not self.active then return end
    value = validValue(option, value)
    if value == nil then return end
    value = copy(value)
    self.values[name] = value
    self.ui.document.configurable[name] = copy(value)
    self.ui.doc_settings:saveSetting("copt_" .. name, copy(value))
    self:applyOption(option, value)
    self.ui:handleEvent(Event:new("UpdatePos"))
    if not quiet then
        Notification:notify(T(_("%1: %2"), option.title, formatValue(option, value)))
    end
    return true
end

function KnuthPlass:makeDefault(name, value)
    local option = options_by_name[name]
    G_reader_settings:saveSetting("copt_" .. name, copy(value))
    Notification:notify(T(_("Default %1: %2"), option.title, formatValue(option, value)))
end

function KnuthPlass:showPairWidget(option)
    local DoubleSpinWidget = require("ui/widget/doublespinwidget")
    local value = self.values[option.name]
    UIManager:show(DoubleSpinWidget:new{
        title_text = option.title,
        info_text = option.info,
        width_factor = 0.8,
        left_text = option.left_text,
        left_value = value[1],
        left_min = option.left_min,
        left_max = option.left_max,
        left_step = option.left_step,
        left_hold_step = option.left_hold_step,
        left_default = option.default[1],
        right_text = option.right_text,
        right_value = value[2],
        right_min = option.right_min,
        right_max = option.right_max,
        right_step = option.right_step,
        right_hold_step = option.right_hold_step,
        right_default = option.default[2],
        unit = option.unit,
        keep_shown_on_apply = true,
        callback = function(left, right)
            self:setValue(option.name, { left, right })
        end,
        extra_text = _("Set as default"),
        extra_callback = function(left, right)
            self:makeDefault(option.name, { left, right })
        end,
    })
end

function KnuthPlass:showSingleWidget(option)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = option.title,
        info_text = option.info,
        width_factor = 0.7,
        value = self.values[option.name],
        value_min = option.value_min,
        value_max = option.value_max,
        value_step = option.value_step,
        value_hold_step = option.value_hold_step,
        default_value = option.default,
        keep_shown_on_apply = true,
        callback = function(widget)
            self:setValue(option.name, widget.value)
        end,
        extra_text = _("Set as default"),
        extra_callback = function(widget)
            self:makeDefault(option.name, widget.value)
        end,
    })
end

function KnuthPlass:showInfo(option)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = option.info })
end

function KnuthPlass:getOptionMenu(option)
    local menu = {}
    for i, preset in ipairs(option.values) do
        table.insert(menu, {
            text = option.labels[i],
            radio = true,
            checked_func = function()
                return same(self.values[option.name], preset)
            end,
            callback = function()
                self:setValue(option.name, preset)
            end,
            hold_callback = function()
                self:makeDefault(option.name, preset)
            end,
        })
    end
    if option.left_text or option.value_min then
        table.insert(menu, {
            text_func = function()
                return T(_("Custom… (%1)"), formatValue(option, self.values[option.name]))
            end,
            callback = function()
                if type(option.default) == "table" then
                    self:showPairWidget(option)
                else
                    self:showSingleWidget(option)
                end
            end,
        })
    end
    menu[#menu].separator = true
    if option.info then
        table.insert(menu, {
            text = _("About this setting"),
            keep_menu_open = true,
            callback = function()
                self:showInfo(option)
            end,
        })
    end
    return menu
end

function KnuthPlass:getMenuTable()
    local menu = {}
    for _i, option in ipairs(options) do
        local item = {
            text_func = function()
                return T(_("%1: %2"), option.title, formatValue(option, self.values[option.name]))
            end,
            sub_item_table_func = function()
                return self:getOptionMenu(option)
            end,
        }
        if option.enabled_func then
            item.enabled_func = function()
                return option.enabled_func(self)
            end
        end
        -- Group: mode, spacing, line quality, then hyphenation.
        item.separator = option.name == "line_breaking_mode"
            or option.name == "justification_tracking_smoothness"
            or option.name == "justification_line_limits"
            or option.name == "justification_hyphen_demerits"
        table.insert(menu, item)
    end
    table.insert(menu, {
        text = _("Long-press a preset to make it the default for new books."),
        enabled = false,
    })
    return menu
end

function KnuthPlass:addToMainMenu(menu_items)
    menu_items.knuth_plass = {
        text_func = function()
            if not self.active then
                return _("Knuth–Plass justification (unavailable)")
            end
            return T(_("Line breaking: %1"),
                formatValue(options_by_name.line_breaking_mode, self.values.line_breaking_mode))
        end,
        sorting_hint = "typeset",
        enabled_func = function()
            return self.active
        end,
        sub_item_table_func = function()
            return self:getMenuTable()
        end,
    }
end

-- Dispatcher / gesture / Profiles events.
for _i, option in ipairs(options) do
    KnuthPlass["on" .. option.event] = function(self, value)
        return self:setValue(option.name, value)
    end
end

return KnuthPlass
