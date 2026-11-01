--[[--
Updates the plugin from its GitHub releases.

Each release (vX.Y.Z) has knuthplass.koplugin.zip and plugin.json:

    { "version": "X.Y.Z", "file": "knuthplass.koplugin.zip",
      "url": "https://…/knuthplass.koplugin.zip", "sha256": "…" }

The update is unpacked next to the plugin (as knuthplass.koplugin.new,
which KOReader doesn't load) and swapped in by renaming, so a failed
download or unpack leaves the installed plugin as it was. It takes effect
after a restart.
]]

local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
-- Required while KOReader loads the plugin (its folder is on package.path
-- only then).
local Engine = require("knuthplass_engine")

local Updater = {
    repo = "spfenwick/koreader-stuff",
    release_tag = "knuthplass", -- rolling release holding plugin.json
    settings_key = "knuthplass_updates",
    check_interval = 24 * 60 * 60, -- automatic checks, seconds
    max_manifest_size = 64 * 1024,
    max_zip_size = 4 * 1024 * 1024,
    -- What automatic checks do with an update.
    modes = { "off", "notify", "install" },
    default_mode = "notify",
}

-- Settings ------------------------------------------------------------------

function Updater.getSettings()
    return G_reader_settings:readSetting(Updater.settings_key) or {}
end

function Updater.saveSettings(settings)
    G_reader_settings:saveSetting(Updater.settings_key, settings)
end

function Updater.getMode()
    local mode = Updater.getSettings().mode
    for _i, m in ipairs(Updater.modes) do
        if m == mode then return mode end
    end
    return Updater.default_mode
end

function Updater.setMode(mode)
    local settings = Updater.getSettings()
    settings.mode = mode
    Updater.saveSettings(settings)
end

function Updater.modeText(mode)
    if mode == "off" then
        return _("off")
    elseif mode == "install" then
        return _("install")
    end
    return _("notify")
end

-- Versions ------------------------------------------------------------------

--- "1.2.3" or "v1.2.3" → { 1, 2, 3 }, or nil.
function Updater.parseVersion(version)
    if type(version) ~= "string" then return nil end
    local major, minor, patch = version:match("^v?(%d+)%.(%d+)%.(%d+)$")
    if not major then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

--- true if version a is newer than version b (false if either is invalid).
function Updater.isNewer(a, b)
    local va, vb = Updater.parseVersion(a), Updater.parseVersion(b)
    if not va or not vb then return false end
    for i = 1, 3 do
        if va[i] ~= vb[i] then return va[i] > vb[i] end
    end
    return false
end

-- Network -------------------------------------------------------------------

local REDIRECTS = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

--- GET url (following redirects, as GitHub's downloads do) into a string.
-- @return body, or nil and an error message
function Updater.fetch(url, max_size)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local body, err
    for _i = 1, 5 do
        local chunks, size, too_large = {}, 0, false
        local sink = function(chunk, sink_err)
            if chunk then
                size = size + #chunk
                if size > max_size then
                    too_large = true
                    return nil, "too large"
                end
                table.insert(chunks, chunk)
            end
            return 1, sink_err
        end
        local ok, code, headers, status = pcall(function()
            return socket.skip(1, http.request{
                url = url,
                method = "GET",
                sink = sink,
                redirect = false,
                headers = { ["User-Agent"] = "KOReader knuthplass.koplugin" },
            })
        end)
        if not ok then
            err = tostring(code)
            break
        end
        local location = headers and headers.location
        if REDIRECTS[code] and location then
            local next_url = socket_url.absolute(url, location)
            if url:match("^https:") and not next_url:match("^https:") then
                err = "refusing to follow a redirect away from https"
                break
            end
            url = next_url
        elseif code == 200 and not too_large then
            body = table.concat(chunks)
            break
        else
            err = too_large and _("download too large") or tostring(status or code)
            break
        end
    end
    socketutil:reset_timeout()
    if not body and not err then
        err = "too many redirects"
    end
    return body, err
end

--- The newest release's plugin.json, or nil and an error message.
function Updater.fetchManifest()
    local url = T("https://github.com/%1/releases/download/%2/plugin.json", Updater.repo, Updater.release_tag)
    local body, err = Updater.fetch(url, Updater.max_manifest_size)
    if not body then return nil, err end
    local json = require("json")
    local ok, manifest = pcall(json.decode, body)
    if not ok or type(manifest) ~= "table" or not Updater.parseVersion(manifest.version)
            or type(manifest.url) ~= "string" or not manifest.url:match("^https://")
            or type(manifest.sha256) ~= "string" or not manifest.sha256:match("^%x+$")
            or #manifest.sha256 ~= 64 then
        return nil, _("invalid release information")
    end
    return manifest
end

-- Installing ----------------------------------------------------------------

local function writeFile(path, data)
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(data)
    file:close()
    if not ok then return nil, write_err end
    return true
end

local function removeTree(path)
    local lfs = require("libs/libkoreader-lfs")
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        require("ffi/util").purgeDir(path)
    elseif mode then
        os.remove(path)
    end
end

--- A zip entry's path inside the plugin folder, or nil if it's outside it
-- or unsafe. The zip holds one top-level knuthplass.koplugin/ folder.
function Updater.entryPath(path)
    local rel = path:match("^[^/]+%.koplugin/(.*)$")
    if not rel or rel == "" then return nil end
    for component in rel:gmatch("[^/]+") do
        if component == ".." or component == "." then return nil end
    end
    if rel:sub(1, 1) == "/" or rel:find("\\", 1, true) then return nil end
    return rel
end

--- Unpack zip_path into the folder dest.
local function unpack(zip_path, dest)
    local Archiver = require("ffi/archiver")
    local util = require("util")
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        return nil, reader.err or "cannot open the zip"
    end
    local files = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local rel = Updater.entryPath(entry.path)
            if not rel then
                reader:close()
                return nil, T("unexpected file in the zip: %1", entry.path)
            end
            table.insert(files, { path = entry.path, rel = rel })
        end
    end
    for _i, file in ipairs(files) do
        local data = reader:extractToMemory(file.path)
        if not data then
            reader:close()
            return nil, reader.err or file.path
        end
        local target = dest .. "/" .. file.rel
        local dir = target:match("^(.*)/[^/]+$")
        util.makePath(dir)
        local ok, err = writeFile(target, data)
        if not ok then
            reader:close()
            return nil, err
        end
    end
    reader:close()
    return true
end

--- Install the zip data (checked against manifest.sha256) over the plugin
-- at plugin_path.
-- @return true, or nil and an error message
function Updater.install(plugin_path, manifest, zip_data)
    local sha2 = require("ffi/sha2")
    if sha2.sha256(zip_data):lower() ~= manifest.sha256:lower() then
        return nil, _("the download is damaged (checksum mismatch)")
    end
    local staging = plugin_path .. ".new"
    local old = plugin_path .. ".old"
    local zip_path = staging .. ".zip"
    removeTree(staging)
    removeTree(old)
    local ok, err = writeFile(zip_path, zip_data)
    if ok then
        ok, err = unpack(zip_path, staging)
    end
    os.remove(zip_path)
    if ok then
        -- Make sure it's a complete plugin of the advertised version.
        local meta_ok, meta = pcall(dofile, staging .. "/_meta.lua")
        local main = io.open(staging .. "/main.lua", "rb")
        if main then main:close() end
        if not main or not meta_ok or type(meta) ~= "table" or meta.version ~= manifest.version then
            ok, err = nil, _("the download is not a complete plugin")
        end
    end
    if ok then
        ok, err = os.rename(plugin_path, old)
        if ok then
            ok, err = os.rename(staging, plugin_path)
            if not ok then
                os.rename(old, plugin_path)
            end
        end
    end
    removeTree(staging)
    if ok then
        -- The running code is already loaded, so the old files can go.
        removeTree(old)
        return true
    end
    return nil, err or "unknown error"
end

-- UI ------------------------------------------------------------------------

local function showInfo(text, timeout)
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    local widget = InfoMessage:new{ text = text, timeout = timeout }
    UIManager:show(widget)
    UIManager:forceRePaint()
    return widget
end

local function closeWidget(widget)
    if widget then
        require("ui/uimanager"):close(widget)
    end
end

--- Download and install manifest's version over plugin (needs plugin.path).
function Updater.downloadAndInstall(plugin, manifest, quiet)
    local UIManager = require("ui/uimanager")
    local progress = not quiet and showInfo(T(_("Downloading Knuth–Plass justification %1…"), manifest.version))
    local data, err = Updater.fetch(manifest.url, Updater.max_zip_size)
    local ok
    if data then
        ok, err = Updater.install(plugin.path, manifest, data)
    end
    closeWidget(progress)
    if not ok then
        logger.warn("KnuthPlass: update failed:", err)
        if not quiet then
            showInfo(T(_("Could not update Knuth–Plass justification:\n%1"), err))
        end
        return false
    end
    logger.info("KnuthPlass: updated to", manifest.version)
    -- For the rest of this session (any plugin instance).
    Updater.installed = manifest.version
    UIManager:askForRestart(T(_("Knuth–Plass justification has been updated to %1. It will be used after KOReader restarts."), manifest.version))
    return true
end

local function offerUpdate(plugin, manifest, interactive)
    local ConfirmBox = require("ui/widget/confirmbox")
    local UIManager = require("ui/uimanager")
    local dialog
    dialog = ConfirmBox:new{
        text = T(_("Knuth–Plass justification %1 is available (installed: %2)."), manifest.version, plugin.version),
        ok_text = _("Install"),
        cancel_text = _("Later"),
        ok_callback = function()
            Updater.downloadAndInstall(plugin, manifest)
        end,
        other_buttons = not interactive and {{
            {
                text = _("Skip this version"),
                callback = function()
                    local settings = Updater.getSettings()
                    settings.skip = manifest.version
                    Updater.saveSettings(settings)
                    UIManager:close(dialog)
                end,
            },
        }} or nil,
    }
    UIManager:show(dialog)
end

--- Check for updates: the plugin first, then (if the plugin is current)
-- the engine. Interactive checks (from the menu) connect if needed and
-- always report; automatic ones only run when already online and at most
-- once per check_interval, and stay quiet unless there is an update to
-- offer.
function Updater.check(plugin, interactive)
    if not plugin.path or not plugin.version then return end
    -- An update is already waiting for a restart.
    if Updater.installed then
        if interactive then
            showInfo(T(_("Knuth–Plass justification %1 is installed and will be used after KOReader restarts."), Updater.installed))
        end
        return
    end
    local mode = Updater.getMode()
    local settings = Updater.getSettings()
    if not interactive then
        if mode == "off" then return end
        if settings.last_check and os.time() - settings.last_check < Updater.check_interval
                and os.time() >= settings.last_check then
            return
        end
    end

    local function run()
        local progress = interactive and showInfo(_("Checking for updates…"))
        local manifest, err = Updater.fetchManifest()
        local report = {}
        if not manifest then
            logger.warn("KnuthPlass: update check failed:", err)
            table.insert(report, T(_("Plugin: could not check (%1)."), tostring(err)))
        else
            settings = Updater.getSettings()
            settings.last_check = os.time()
            Updater.saveSettings(settings)
            if Updater.isNewer(manifest.version, plugin.version)
                    and (interactive or settings.skip ~= manifest.version) then
                closeWidget(progress)
                if not interactive and mode == "install" then
                    Updater.downloadAndInstall(plugin, manifest, true)
                else
                    offerUpdate(plugin, manifest, interactive)
                end
                -- The engine is checked once the new plugin runs.
                return
            end
            table.insert(report, T(_("Plugin: up to date (%1)."), plugin.version))
        end
        local offered = Engine.check(plugin, interactive, mode, Updater.fetch, report)
        closeWidget(progress)
        if interactive and not offered then
            showInfo(table.concat(report, "\n"))
        end
    end

    local NetworkMgr = require("ui/network/manager")
    if interactive then
        NetworkMgr:runWhenOnline(run)
    elseif NetworkMgr:isWifiOn() and NetworkMgr:isConnected() and NetworkMgr:isOnline() then
        run()
    end
end

return Updater
