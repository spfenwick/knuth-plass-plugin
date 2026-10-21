-- Exercises knuthplass.koplugin against stubbed KOReader modules.

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
stub("ui/uimanager", { show = function() end })
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
    }
end

local function makeUI(probe)
    local cre = { props = {} }
    function cre:getStringProperty(name)
        if name == "crengine.style.justify.tolerance" then
            return probe
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
    assert(cre.props["crengine.style.justify.hyphen.penalty"] == 0)
    assert(cre.props["crengine.style.justify.final.hyphen.demerits"] == 0)
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

    -- The menu builds and every label renders; parameters are greyed out
    -- in greedy mode.
    local items = {}
    plugin:addToMainMenu(items)
    local entry = items.knuth_plass
    assert(entry.text_func() == "Line breaking: greedy")
    for _, item in ipairs(entry.sub_item_table_func()) do
        assert(type(item.text or item.text_func()) == "string")
        if item.sub_item_table_func then
            for _, sub in ipairs(item.sub_item_table_func()) do
                assert(type(sub.text or sub.text_func()) == "string")
            end
        end
        if item.enabled_func then
            assert(item.enabled_func() == false)
        end
    end
    plugin:setValue("line_breaking_mode", 1, true)
    assert(entry.text_func() == "Line breaking: Knuth–Plass")

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
    assert(action.rolling and action.category == "string", name)
    assert(#action.args == #action.toggle, name)
end
assert(action_count == 9, action_count)

print("plugin tests passed")
