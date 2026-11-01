--[[--
Settings sync: push and pull KOReader's settings with rclone.

Replaces the PushSettings.sh / PullSettings.sh / PushTweaks.sh /
PullTweaks.sh scripts, using the same rclone folder and remote layout (see
rclonesync_sync.lua). Pushes save KOReader's settings first; pulled settings
files are put in place on the next start, before anything reads them.
--]]--

local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
-- A name of its own: plugins share package.loaded.
local Sync = require("rclonesync_sync")

local SETTINGS_KEY = "rclonesync"

local function options()
    return G_reader_settings:readSetting(SETTINGS_KEY) or {}
end

-- Runs as KOReader loads its plugins, before any of them is started, so
-- settings pulled last time are in place before their plugins read them.
local startup
do
    local source = debug.getinfo(1, "S").source
    local plugin_path = source:match("^@(.*)/[^/]+$")
    local ok, err = pcall(function()
        local ctx = Sync.context(options(), plugin_path)
        if ctx and Sync.isPending(ctx) then
            Sync.prepareBinary(ctx)
            local applied = Sync.applyPending(ctx)
            startup = { ok = applied, log = Sync.logPath(ctx) }
            logger.info("Settings sync: applied pulled settings:", applied)
        end
    end)
    if not ok then
        logger.warn("Settings sync: applying pulled settings:", err)
        startup = { ok = false }
    end
end

local RcloneSync = WidgetContainer:extend{
    name = "rclonesync",
    is_doc_only = false,
}

local ACTIONS = {
    { id = "push", event = "RcloneSyncPush", title = _("Push settings") },
    { id = "pull", event = "RcloneSyncPull", title = _("Pull settings") },
    { id = "push_tweaks", event = "RcloneSyncPushTweaks", title = _("Push style tweaks") },
    { id = "pull_tweaks", event = "RcloneSyncPullTweaks", title = _("Pull style tweaks") },
}

function RcloneSync:onDispatcherRegisterActions()
    for __, action in ipairs(ACTIONS) do
        Dispatcher:registerAction("rclonesync_" .. action.id, {
            category = "none",
            event = action.event,
            title = T(_("Settings sync: %1"), action.title),
            general = true,
        })
    end
end

function RcloneSync:init()
    self.settings = options()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if startup and not startup.shown then
        startup.shown = true
        UIManager:nextTick(function()
            if startup.ok then
                Notification:notify(_("Pulled settings applied."))
            else
                UIManager:show(InfoMessage:new{
                    text = T(_("Settings sync couldn't put the pulled settings in place. They'll be tried again at the next start.\n\nLog: %1"),
                        startup.log or "?"),
                })
            end
        end)
    end
end

function RcloneSync:onRcloneSyncPush() self:run("push", false) return true end
function RcloneSync:onRcloneSyncPull() self:run("pull", false) return true end
function RcloneSync:onRcloneSyncPushTweaks() self:run("push", true) return true end
function RcloneSync:onRcloneSyncPullTweaks() self:run("pull", true) return true end

function RcloneSync:save()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

function RcloneSync:context()
    local ctx, err, paths = Sync.context(self.settings, self.path)
    if ctx then return ctx end
    local text
    if err == "no_binary" then
        text = T(_("rclone wasn't found at %1 or on the PATH."), paths[1])
    else
        text = T(_("No rclone folder was found. Put rclone and rclone.conf in one of:\n\n%1\n\nor choose the folder in Settings sync → rclone folder."),
            table.concat(paths, "\n"))
    end
    UIManager:show(InfoMessage:new{ text = text })
end

function RcloneSync:showLog(title, text)
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = title,
        text = text ~= "" and text or _("(no output)"),
        monospace_font = true,
        justified = false,
    })
end

function RcloneSync:run(direction, tweaks_only)
    local ctx = self:context()
    if not ctx then return end
    if direction == "push" and not tweaks_only and not ctx.dry_run and Sync.isPending(ctx) then
        UIManager:askForRestart(_("Pulled settings are waiting to be put in place at the next start. Pushing now would send the old ones back to the remote.\n\nRestart KOReader first?"))
        return
    end
    NetworkMgr:runWhenOnline(function()
        if direction == "push" then
            -- So what's pushed is what's in use.
            UIManager:broadcastEvent(Event:new("FlushSettings"))
            G_reader_settings:flush()
        end
        Trapper:wrap(function()
            if not Sync.prepareBinary(ctx) then
                UIManager:show(InfoMessage:new{ text = T(_("Couldn't copy rclone to %1."), ctx.binary) })
                return
            end
            local verb = direction == "push" and _("Pushing to %1…") or _("Pulling from %1…")
            local completed, output = Trapper:dismissablePopen(Sync.script(ctx, direction, tweaks_only),
                T(verb, ctx.remote))
            if not completed then
                Notification:notify(_("Stopped waiting for rclone. It may still finish in the background."))
                return
            end
            Sync.saveLog(ctx, output or "")
            local result = Sync.parse(output, direction)
            if result.pending then Sync.setPending(ctx) end
            self:report(ctx, direction, result, output or "")
        end)
    end)
end

function RcloneSync:report(ctx, direction, result, output)
    if result.failed then
        self:showLog(_("Sync failed"), output)
    elseif ctx.dry_run then
        self:showLog(T(_("Dry run: %1 changes"), result.changes), output)
    elseif result.restart then
        UIManager:askForRestart(T(_("Pulled %1 changes. They take effect after KOReader restarts."), result.changes))
    elseif result.changes == 0 then
        Notification:notify(_("Already up to date."))
    elseif direction == "push" then
        Notification:notify(T(_("Pushed %1 changes."), result.changes))
    else
        Notification:notify(T(_("Pulled %1 changes."), result.changes))
    end
end

function RcloneSync:chooseRemoteMenu()
    local ctx = Sync.context(self.settings, self.path)
    local items = {}
    for __, name in ipairs(ctx and Sync.remotes(ctx) or {}) do
        table.insert(items, {
            text = name,
            radio = true,
            checked_func = function() return ctx.remote == name end,
            callback = function()
                self.settings.remote = name
                ctx.remote = name
                self:save()
            end,
        })
    end
    if #items == 0 then
        table.insert(items, { text = _("No remotes in rclone.conf"), enabled = false })
    end
    return items
end

function RcloneSync:editRoot(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Folder on the remote"),
        input = self.settings.root or "/KOReader/Settings",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local root = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    self.settings.root = root ~= "" and root or nil
                    self:save()
                    UIManager:close(dialog)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function RcloneSync:chooseRcloneDir(touchmenu_instance)
    local PathChooser = require("ui/widget/pathchooser")
    local ctx = Sync.context(self.settings, self.path)
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        path = ctx and ctx.rclone_dir or Sync.dataDir(),
        onConfirm = function(path)
            self.settings.rclone_dir = path
            self:save()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

function RcloneSync:menu()
    local function action(text, direction, tweaks_only)
        return {
            text = text,
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                self:run(direction, tweaks_only)
            end,
        }
    end
    local ctx = Sync.context(self.settings, self.path)
    local items = {
        action(_("Push settings"), "push", false),
        action(_("Pull settings"), "pull", false),
        action(_("Push style tweaks only"), "push", true),
        action(_("Pull style tweaks only"), "pull", true),
    }
    items[#items].separator = true
    if ctx and Sync.isPending(ctx) then
        table.insert(items, {
            text = _("Discard pulled settings waiting for a restart"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                os.remove(Sync.pendingPath(ctx))
                Notification:notify(_("Pulled settings discarded."))
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
            separator = true,
        })
    end
    table.insert(items, {
        text_func = function()
            local c = Sync.context(self.settings, self.path)
            return T(_("Remote: %1"), c and c.remote or "?")
        end,
        sub_item_table_func = function() return self:chooseRemoteMenu() end,
    })
    table.insert(items, {
        text_func = function()
            return T(_("Folder on remote: %1"), self.settings.root or "/KOReader/Settings")
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance) self:editRoot(touchmenu_instance) end,
    })
    table.insert(items, {
        text_func = function()
            local c = Sync.context(self.settings, self.path)
            return T(_("rclone folder: %1"), c and c.rclone_dir or _("not found"))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance) self:chooseRcloneDir(touchmenu_instance) end,
    })
    table.insert(items, {
        text = _("Dry run (show what would change)"),
        checked_func = function() return self.settings.dry_run == true end,
        keep_menu_open = true,
        callback = function()
            self.settings.dry_run = not self.settings.dry_run or nil
            self:save()
        end,
        separator = true,
    })
    table.insert(items, {
        text = _("Show last log"),
        callback = function()
            local c = Sync.context(self.settings, self.path)
            local log = c and Sync.readLog(c)
            self:showLog(_("Settings sync log"), log or _("No sync has run yet."))
        end,
    })
    return items
end

function RcloneSync:addToMainMenu(menu_items)
    menu_items.rclonesync = {
        text = _("Settings sync"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:menu() end,
    }
end

return RcloneSync
