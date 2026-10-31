-- Exercises knuthplass.koplugin against stubbed KOReader modules.

-- KOReader puts the plugin's folder on package.path while loading it.
package.path = "knuthplass.koplugin/?.lua;" .. package.path

local function stub(name, value)
    package.loaded[name] = value
end

local registered_actions = {}
stub("dispatcher", {
    registerAction = function(_, name, value)
        registered_actions[name] = value
    end,
})
stub("ui/event", {
    new = function(_, name, ...)
        return { name = name, args = { ... } }
    end,
})
local notifications = {}
stub("ui/widget/notification", {
    notify = function(_, text)
        table.insert(notifications, text)
    end,
})
local shown = {}
local scheduled = {}
stub("ui/uimanager", {
    show = function(_, widget) table.insert(shown, widget) end,
    setDirty = function() end,
    scheduleIn = function(_, delay, fn) table.insert(scheduled, { delay = delay, fn = fn }) end,
})
stub("ffi/blitbuffer", { COLOR_LIGHT_GRAY = "lightgray" })
local ButtonDialog = {}
function ButtonDialog:extend(o)
    return setmetatable(o or {}, { __index = self })
end
function ButtonDialog:new(o)
    o.reinits = 0
    return setmetatable(o, { __index = self })
end
function ButtonDialog:reinit() self.reinits = self.reinits + 1 end
function ButtonDialog:getAddedWidgetAvailableWidth() return 500 end
function ButtonDialog:addWidget(widget) self.added = widget end
function ButtonDialog:onClose()
    if self.tap_close_callback then self.tap_close_callback() end
    self.closed = true
end
stub("device", { screen = { getWidth = function() return 1000 end } })
stub("ui/size", { padding = { large = 10 } })
stub("ui/widget/titlebar", { new = function(_, o) return o end })
stub("ui/font", { getFace = function(_, name, size) return { name = name, size = size } end })
stub("ui/widget/textwidget", {
    new = function(_, o)
        return setmetatable(o, { __index = {
            getSize = function(self) return { w = 10, h = self.face.size + 6 } end,
            isTruncated = function() return false end,
            free = function() end,
        } })
    end,
})
function ButtonDialog:getScrolledOffset() return "offset" end
function ButtonDialog:setScrolledOffset(offset) self.offset = offset end
stub("ui/widget/buttondialog", ButtonDialog)
stub("ui/widget/confirmbox", { new = function(_, o) return o end })
stub("logger", { info = function() end, dbg = function() end })
stub("ffi/util", {
    template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end,
})

local function deepcopy(o)
    if type(o) ~= "table" then return o end
    local c = {}
    for k, v in pairs(o) do c[k] = deepcopy(v) end
    return c
end
local function equals(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equals(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
stub("util", {
    tableDeepCopy = deepcopy,
    tableEquals = equals,
    arrayContains = function(t, v)
        for i, x in ipairs(t) do if x == v then return i end end
        return false
    end,
})
local gettext = setmetatable({ pgettext = function(_, s) return s end }, {
    __call = function(_, s) return s end,
})
stub("gettext", gettext)

local WidgetContainer = {}
function WidgetContainer:extend(o)
    o = o or {}
    setmetatable(o, { __index = self })
    return o
end
function WidgetContainer:new(o)
    o = o or {}
    setmetatable(o, { __index = self })
    if o.init then o:init() end
    return o
end
stub("ui/widget/container/widgetcontainer", WidgetContainer)

local function settings(values)
    local store = values or {}
    return {
        store = store,
        readSetting = function(_, key) return store[key] end,
        saveSetting = function(_, key, value) store[key] = value end,
        delSetting = function(_, key) store[key] = nil end,
    }
end

-- probe: what the engine returns for the Knuth–Plass capability property;
-- ragged: whether it also has the ragged text properties.
local function makeUI(probe, ragged)
    local cre = { props = {} }
    function cre:getStringProperty(name)
        if name == "crengine.style.justify.tolerance" then
            return probe
        end
        if ragged and name == "crengine.style.ragged.width.percent" then
            return "15"
        end
        return ""
    end
    function cre:setIntProperty(name, value)
        assert(type(value) == "number", name)
        self.props[name] = value
    end
    local events = {}
    local menu_registered = false
    local ui = {
        rolling = {},
        document = { _document = cre, configurable = {} },
        doc_settings = settings(),
        menu = { registerToMainMenu = function() menu_registered = true end },
        handleEvent = function(_, event) table.insert(events, event.name) end,
    }
    return ui, cre, events, function() return menu_registered end
end

local Plugin = dofile("knuthplass.koplugin/main.lua")

-- Stock engine: inactive, nothing applied, events ignored.
G_reader_settings = settings()
do
    local ui, cre = makeUI("")
    local plugin = Plugin:new{ ui = ui }
    plugin:onReadSettings(ui.doc_settings)
    assert(plugin.active == false)
    assert(next(cre.props) == nil)
    assert(plugin:onSetLineBreakingMode(1) == nil)
    assert(next(cre.props) == nil)
end

-- Knuth engine: defaults applied before rendering.
do
    local ui, cre, _, menu_registered = makeUI("200")
    local plugin = Plugin:new{ ui = ui }
    assert(menu_registered())
    plugin:onReadSettings(ui.doc_settings)
    assert(plugin.active)
    assert(cre.props["crengine.style.line.breaking.mode"] == 1)
    assert(cre.props["crengine.style.justify.space.shrink.percent"] == 25)
    assert(cre.props["crengine.style.justify.space.stretch.percent"] == 35)
    assert(cre.props["crengine.style.justify.hyphen.penalty"] == 3000)
    assert(cre.props["crengine.style.justify.explicit.hyphen.penalty"] == 3000)
    assert(cre.props["crengine.style.justify.double.hyphen.demerits"] == 36000000)
    assert(cre.props["crengine.style.justify.final.hyphen.demerits"] == 18000000)
    assert(cre.props["crengine.style.justify.tracking.delta.max.bp"] == 50)
    -- Page-level and kerning settings belong to other builds.
    assert(cre.props["crengine.style.justify.refinement.passes"] == nil)
    assert(cre.props["crengine.page.center.nearly.full"] == nil)
    assert(cre.props["font.fractional.positioning"] == nil)
    -- Every engine property the plugin owns.
    local count = 0
    for _ in pairs(cre.props) do count = count + 1 end
    assert(count == 16, count)
    assert(equals(ui.document.configurable.justification_tolerance, { 100, 200 }))
end

-- Per-book values beat global defaults; invalid values fall back.
G_reader_settings = settings{
    copt_justification_tolerance = { 50, 100 },
    copt_line_breaking_mode = 0,
}
do
    local ui, cre = makeUI("200")
    ui.doc_settings = settings{
        copt_line_breaking_mode = 1,
        copt_justification_hyphen_penalty = { 500, 300 },
        copt_justification_word_spacing = "garbage",
    }
    local plugin = Plugin:new{ ui = ui }
    plugin:onReadSettings(ui.doc_settings)
    assert(cre.props["crengine.style.line.breaking.mode"] == 1)
    assert(cre.props["crengine.style.justify.pretolerance"] == 50)
    assert(cre.props["crengine.style.justify.hyphen.penalty"] == 500)
    assert(cre.props["crengine.style.justify.explicit.hyphen.penalty"] == 300)
    assert(cre.props["crengine.style.justify.space.shrink.percent"] == 25)
end

-- Changing a setting stores it with the book, applies it, and re-renders.
G_reader_settings = settings()
do
    local ui, cre, events = makeUI("200")
    local plugin = Plugin:new{ ui = ui }
    plugin:onReadSettings(ui.doc_settings)
    -- (The strong preset needs an engine whose cap is 1000000000.)
    assert(plugin:onSetJustificationHyphenDemerits({ 400000000, 200000000 }))
    assert(cre.props["crengine.style.justify.double.hyphen.demerits"] == 400000000)
    assert(plugin:onSetJustificationHyphenDemerits({ 10000, 5000 }))
    assert(cre.props["crengine.style.justify.double.hyphen.demerits"] == 10000)
    assert(cre.props["crengine.style.justify.final.hyphen.demerits"] == 5000)
    assert(equals(ui.doc_settings.store.copt_justification_hyphen_demerits, { 10000, 5000 }))
    assert(events[#events] == "UpdatePos")
    assert(plugin:onSetJustificationWordSpacing({ 40, 75 }))
    assert(cre.props["crengine.style.justify.space.stretch.percent"] == 75)
    assert(plugin:onSetLineBreakingMode("bad") == nil)
    assert(plugin:onSetLineBreakingMode(0))
    assert(cre.props["crengine.style.line.breaking.mode"] == 0)
    assert(#notifications > 0)

    -- Set as default goes to the global settings only.
    plugin:makeDefault("justification_hyphen_penalty", { 50, 50 })
    assert(equals(G_reader_settings.store.copt_justification_hyphen_penalty, { 50, 50 }))
    assert(ui.doc_settings.store.copt_justification_hyphen_penalty == nil)

    -- The menu entry opens the dialog.
    local items = {}
    plugin:addToMainMenu(items)
    local entry = items.knuth_plass
    assert(entry.text_func() == "Line breaking: greedy")
    assert(entry.sub_item_table_func == nil)
    entry.callback()
    local dialog = shown[#shown]
    assert(dialog == plugin.dialog)

    -- One row per setting, as in the bottom menu: its name in a left
    -- column, then its presets (and "…"). findRow returns the presets.
    local function findRow(buttons, heading)
        for _, row in ipairs(buttons) do
            if row[1].text == heading then
                return { select(2, unpack(row)) }
            end
        end
    end
    assert(#dialog.buttons == 12, #dialog.buttons)
    assert(dialog.width_factor == 0.95)
    -- Every button of a setting row has the same height (one line of a
    -- name) and its own id; names share one column width, without a
    -- separator before the presets.
    local ids = {}
    for i = 1, 9 do
        local name = dialog.buttons[i][1]
        assert(name.setting_name and name.width == 237 and name.no_vertical_sep, i)
        for _, button in ipairs(dialog.buttons[i]) do
            assert(button.id and not ids[button.id], button.id)
            ids[button.id] = true
            assert(button.height == 20 + 6)
            assert(button.numbers == nil and not button.two_line)
        end
    end
    for i, row in ipairs(dialog.buttons) do
        for _, button in ipairs(row) do
            assert(type(button.text) == "string" and button.callback, i)
        end
    end
    -- In greedy mode only the mode row is enabled.
    assert(findRow(dialog.buttons, "Line breaking")[2].enabled == true)
    assert(findRow(dialog.buttons, "Fit tolerance")[1].enabled == false)
    -- (Names of disabled settings are grayed but still open their help.)
    assert(dialog.buttons[2][1].text == "Word-space limits" and dialog.buttons[2][1].dimmed)
    assert(not dialog.buttons[1][1].dimmed)
    -- The current preset is highlighted.
    local mode_row = findRow(dialog.buttons, "Line breaking")
    assert(mode_row[1].background and not mode_row[2].background)
    local ws = findRow(dialog.buttons, "Word-space limits") -- {40, 75} is the "loose" preset
    assert(ws[3].background and not ws[#ws].background)

    -- Tapping a preset applies it and refreshes the dialog in place.
    local count = #notifications
    mode_row[2].callback()
    assert(cre.props["crengine.style.line.breaking.mode"] == 1)
    assert(#notifications == count) -- the dialog shows the change itself
    assert(dialog.reinits == 1 and dialog.offset == "offset")
    assert(findRow(dialog.buttons, "Fit tolerance")[1].enabled == true)
    assert(findRow(dialog.buttons, "Line breaking")[2].background)
    assert(entry.text_func() == "Line breaking: Knuth–Plass")

    plugin:setValue("justification_tolerance", { 70, 300 }, true)
    local tol_row = findRow(dialog.buttons, "Fit tolerance")
    assert(tol_row and tol_row[#tol_row].text == "…" and tol_row[#tol_row].background)

    -- Each preset shows just its name, the default marked with a star.
    local function texts(row)
        local t = {}
        for i, button in ipairs(row) do
            t[i] = button.text
        end
        return table.concat(t, "|")
    end
    assert(texts(findRow(dialog.buttons, "Line breaking")) == "greedy|Knuth–Plass ★")
    assert(texts(tol_row) == "strict|balanced ★|forgiving|…", texts(tol_row))
    assert(texts(findRow(dialog.buttons, "Word-space limits"))
        == "tight ★|balanced|loose|…")
    -- A custom default marks "…".
    local hyph_row = findRow(dialog.buttons, "Hyphen penalties")
    assert(hyph_row and texts(hyph_row) == "free|light|moderate|strong|… ★", texts(hyph_row))
    assert(texts(findRow(dialog.buttons, "Repeated-hyphen penalties"))
        == "free|light|moderate ★|strong|…")
    assert(texts(findRow(dialog.buttons, "Letter-space smoothness"))
        == "off|strict|smooth ★|relaxed|…")
    assert(texts(findRow(dialog.buttons, "Letter-space limits"))
        == "off|fallback ★|…")

    -- Long-press makes a preset the default and refreshes the dialog.
    local reinits = dialog.reinits
    tol_row[1].hold_callback()
    assert(equals(G_reader_settings.store.copt_justification_tolerance, { 50, 100 }))
    assert(dialog.reinits == reinits + 1)
    tol_row = findRow(dialog.buttons, "Fit tolerance")
    assert(texts(tol_row) == "strict ★|balanced|forgiving|…", texts(tol_row))
    -- Long-press on "…" makes the current custom value the default.
    tol_row[#tol_row].hold_callback()
    assert(equals(G_reader_settings.store.copt_justification_tolerance, { 70, 300 }))
    tol_row = findRow(dialog.buttons, "Fit tolerance")
    assert(texts(tol_row) == "strict|balanced|forgiving|… ★", texts(tol_row))
    -- "…" has no long-press when the current value is a preset.
    assert(findRow(dialog.buttons, "Line breaking")[1].hold_callback ~= nil)
    local ws_row = findRow(dialog.buttons, "Word-space limits")
    assert(ws_row[#ws_row].hold_callback == nil)

    -- Long-press on a name restores the built-in default.
    for _, row in ipairs(dialog.buttons) do
        if row[1].text == "Fit tolerance" then row[1].hold_callback() break end
    end
    assert(G_reader_settings.store.copt_justification_tolerance == nil)
    tol_row = findRow(dialog.buttons, "Fit tolerance")
    assert(texts(tol_row) == "strict|balanced ★|forgiving|…", texts(tol_row))

    -- "Reset all defaults" asks first, then clears every default.
    local reset = dialog.buttons[#dialog.buttons][1]
    assert(reset.text == "Reset all defaults" and reset.enabled)
    reset.callback()
    local confirm = shown[#shown]
    assert(confirm.ok_callback)
    assert(G_reader_settings.store.copt_justification_hyphen_penalty ~= nil)
    confirm.ok_callback()
    assert(next(G_reader_settings.store) == nil)
    assert(findRow(dialog.buttons, "Hyphen penalties") ~= nil)
    assert(dialog.buttons[#dialog.buttons][1].enabled == false)

    -- The title bar has a ✕ that closes the dialog.
    local title_bar = dialog.added
    assert(title_bar.title == "Knuth–Plass justification" and title_bar.width == 500)
    assert(title_bar.parent == dialog)
    title_bar.close_callback()
    assert(dialog.closed and plugin.dialog == nil)
    assert(plugin:onShowKnuthPlassDialog())
    assert(plugin.dialog and shown[#shown] == plugin.dialog)

    -- Profiles: captured settings are appended to the stock list.
    ui.profiles = {
        ui = ui,
        getProfileFromCurrentBookSettings = function(_, name)
            return { settings = { name = name, order = { "font_size" } }, font_size = 22 }
        end,
    }
    plugin:onReaderReady()
    local profile = ui.profiles:getProfileFromCurrentBookSettings("test")
    assert(profile.font_size == 22)
    assert(profile.line_breaking_mode == 1)
    assert(equals(profile.justification_word_spacing, { 40, 75 }))
    assert(equals(profile.justification_hyphen_demerits, { 10000, 5000 }))
    -- Hooking twice must not wrap twice.
    plugin:onReaderReady()
    assert(#ui.profiles:getProfileFromCurrentBookSettings("again").settings.order == #profile.settings.order)
end

-- Every setting is a Dispatcher action whose event the plugin handles.
local action_count = 0
for name, action in pairs(registered_actions) do
    action_count = action_count + 1
    assert(type(Plugin["on" .. action.event]) == "function", name)
    assert(action.rolling, name)
    if name == "knuth_plass_dialog" then
        assert(action.category == "none")
    else
        assert(action.category == "string", name)
        assert(#action.args == #action.toggle, name)
        if name == "justification_hyphen_penalty" then
            assert(action.toggle[1] == "free" and action.toggle[3] == "moderate (3k/3k)", action.toggle[3])
        end
    end
end
assert(action_count == 11, action_count)

-- Ragged text: only offered by engines that have it.
G_reader_settings = settings()
do
    -- A Knuth engine without it (above, too): not applied, not shown.
    local ui, cre = makeUI("200", false)
    local plugin = Plugin:new{ ui = ui }
    plugin:onReadSettings(ui.doc_settings)
    assert(plugin.active)
    assert(cre.props["crengine.style.ragged.width.percent"] == nil)
    assert(plugin:onSetRaggedText({ 10, 100 }) == nil)
    assert(cre.props["crengine.style.ragged.width.percent"] == nil)
    assert(ui.doc_settings.store.copt_ragged_text == nil)
    assert(ui.document.configurable.ragged_text == nil)
    for _, row in ipairs(plugin:getDialogButtons()) do
        assert(not row[1].text:find("Ragged text", 1, true), row[1].text)
    end
end
do
    local ui, cre = makeUI("200", true)
    ui.doc_settings = settings{ copt_ragged_text = { 12, 300 } }
    local plugin = Plugin:new{ ui = ui }
    plugin:onReadSettings(ui.doc_settings)
    -- Every engine property the plugin owns, now with ragged text.
    local count = 0
    for _ in pairs(cre.props) do count = count + 1 end
    assert(count == 18, count)
    assert(cre.props["crengine.style.ragged.width.percent"] == 12)
    assert(cre.props["crengine.style.ragged.hyphen.penalty"] == 300)
    -- Its row comes last among the settings, with "…" selected.
    local buttons = plugin:getDialogButtons()
    assert(#buttons == 13, #buttons)
    assert(buttons[10][1].text == "Ragged text", buttons[10][1].text)
    local labels = {}
    for i, button in ipairs(buttons[10]) do labels[i] = button.text end
    assert(table.concat(labels, "|") == "Ragged text|greedy|even|balanced ★|fewer hyphens|…",
        table.concat(labels, "|"))
    assert(buttons[10][#buttons[10]].background) -- {12, 300} is custom
    -- Presets apply both properties and are saved with the book.
    buttons[10][2].callback()
    assert(cre.props["crengine.style.ragged.width.percent"] == 0)
    assert(cre.props["crengine.style.ragged.hyphen.penalty"] == 100)
    assert(equals(ui.doc_settings.store.copt_ragged_text, { 0, 100 }))
    assert(plugin:onSetRaggedText({ 15, 200 }))
    assert(cre.props["crengine.style.ragged.hyphen.penalty"] == 200)
    assert(notifications[#notifications] == "Ragged text: fewer hyphens (15%/200)", notifications[#notifications])
    -- Profiles capture it.
    ui.profiles = {
        ui = ui,
        getProfileFromCurrentBookSettings = function(_, name)
            return { settings = { name = name, order = {} } }
        end,
    }
    plugin:onReaderReady()
    local profile = ui.profiles:getProfileFromCurrentBookSettings("ragged")
    assert(equals(profile.ragged_text, { 15, 200 }))
end

do
    -- The release workflow and the updater read the version from _meta.lua.
    stub("gettext", function(s) return s end)
    local meta = dofile("knuthplass.koplugin/_meta.lua")
    assert(type(meta.version) == "string" and meta.version:match("^%d+%.%d+%.%d+$"), tostring(meta.version))
end

-- Updater: versions, zip paths, the dialog row and the automatic check.
do
    local Updater = require("knuthplass_updater")
    assert(Updater.parseVersion("v1.2.3")[3] == 3)
    assert(Updater.parseVersion("1.2") == nil and Updater.parseVersion(nil) == nil)
    assert(Updater.isNewer("0.10.0", "0.9.9"))
    assert(Updater.isNewer("v1.0.0", "0.9.9"))
    assert(not Updater.isNewer("0.1.0", "0.1.0"))
    assert(not Updater.isNewer("0.1.0", "0.2.0"))
    assert(not Updater.isNewer("junk", "0.1.0"))

    assert(Updater.entryPath("knuthplass.koplugin/main.lua") == "main.lua")
    assert(Updater.entryPath("knuthplass.koplugin/sub/x.lua") == "sub/x.lua")
    assert(Updater.entryPath("knuthplass.koplugin/") == nil)
    assert(Updater.entryPath("main.lua") == nil)
    assert(Updater.entryPath("knuthplass.koplugin/../evil.lua") == nil)
    assert(Updater.entryPath("knuthplass.koplugin/a/../../evil.lua") == nil)

    G_reader_settings = settings()
    assert(Updater.getMode() == "notify")
    Updater.setMode("bogus")
    assert(Updater.getMode() == "notify")

    -- The dialog row cycles the mode.
    local ui = makeUI("200")
    local plugin = Plugin:new{ ui = ui, version = "0.1.0", path = "/plugins/knuthplass.koplugin" }
    plugin:onReadSettings(ui.doc_settings)
    plugin:showDialog()
    local rows = plugin.dialog.buttons
    local row = rows[#rows - 1]
    assert(row[1].text == "Check for updates (0.1.0)", row[1].text)
    assert(row[2].text == "Automatic updates: notify", row[2].text)
    row[2].callback()
    assert(Updater.getMode() == "install")
    rows = plugin.dialog.buttons
    assert(rows[#rows - 1][2].text == "Automatic updates: install", rows[#rows - 1][2].text)
    rows[#rows - 1][2].callback()
    assert(Updater.getMode() == "off")

    -- Opening a book schedules one automatic check per session; with
    -- automatic updates off it returns without touching the network.
    scheduled = {}
    Updater.scheduled = nil
    plugin:onReaderReady()
    plugin:onReaderReady()
    assert(#scheduled == 1, #scheduled)
    scheduled[1].fn()
    assert(G_reader_settings.store.knuthplass_updates.last_check == nil)
end

print("plugin tests passed")
