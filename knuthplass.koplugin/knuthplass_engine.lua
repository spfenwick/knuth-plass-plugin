--[[--
Installs the Knuth–Plass CREngine (libs/libkoreader-cre.so) built by the
plugin repository's "Build engine" workflow.

The library has to match the koreader-base it runs with, so the manifest
lists builds by koreader-base commit and device (KOReader's OTA model). A
device finds its base from the commit in its version string through the
GitHub API.

Installing keeps the standard engine as libkoreader-cre.so.stock and swaps
the new one in by renaming. Until a book has opened with the new engine,
a guard (installed by main.lua as KOReader starts) counts engine starts:
if the engine fails to load, or KOReader stops twice before a book opened
with it, the standard engine is put back. For the guard to run before the
engine loads, KOReader starts in the file browser (not the last book)
until then.
]]

local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Engine = {
    manifest_url = "https://github.com/spfenwick/knuth-plass-plugin/releases/download/engine/manifest.json",
    base_api_url = "https://api.github.com/repos/koreader/koreader/contents/base?ref=%1",
    settings_key = "knuthplass_engine",
    build_property = "crengine.knuth.plass.build",
    max_manifest_size = 256 * 1024,
    max_lib_size = 16 * 1024 * 1024,
    -- Engine starts allowed before a book has opened with a new engine.
    max_attempts = 2,
}

-- State ---------------------------------------------------------------------
--
-- G_reader_settings[settings_key]:
--   pending     = { commit, rev, attempts, start_with = { value } }
--                 an installed engine not yet seen working
--   stock_rev   = the KOReader version libkoreader-cre.so.stock is from
--   bad         = { [commit] = true }: builds that failed, never offered again
--   rolled_back = { commit, reason }: to tell the user once
--   skip        = a build the user chose to skip
--   base_cache  = { rev, base }: this KOReader's koreader-base commit

function Engine.getState()
    return G_reader_settings:readSetting(Engine.settings_key) or {}
end

--- Save, and write to disk at once (the engine may be about to crash).
function Engine.saveState(state)
    G_reader_settings:saveSetting(Engine.settings_key, state)
    if G_reader_settings.flush then
        G_reader_settings:flush()
    end
end

-- Device and version ----------------------------------------------------------

function Engine.revision()
    local ok, Version = pcall(require, "version")
    return ok and Version:getCurrentRevision() or nil
end

--- The git ref of this KOReader's koreader repository commit: the commit in
-- a nightly's version (v2026.07.2-299-g8012773_2026-10-30 → 8012773), or a
-- release's tag (v2026.07.1).
function Engine.koreaderRef(rev)
    if type(rev) ~= "string" then return nil end
    local commit = rev:match("%-%d+%-g(%x+)")
    if commit then return commit end
    return rev:match("^(v%d+%.%d+[%.%d]*)$") or rev:match("^(v%d+%.%d+[%.%d]*)_")
end

--- KOReader's name for this device's builds (kobo, kobov5, kindlehf, …).
function Engine.target()
    local ok, Device = pcall(require, "device")
    if not ok or not Device.otaModel then return nil end
    local ok_model, model = pcall(Device.otaModel, Device)
    return ok_model and model or nil
end

function Engine.libPath()
    local lfs = require("libs/libkoreader-lfs")
    return lfs.currentdir() .. "/libs/libkoreader-cre.so"
end

--- The build commit the open document's engine reports: "" for an engine
-- without it (the standard one, or an early Knuth–Plass build).
function Engine.installedBuild(document)
    local cre = document and document._document
    if not cre or not cre.getStringProperty then return nil end
    local ok, value = pcall(cre.getStringProperty, cre, Engine.build_property)
    return ok and value or ""
end

-- Network ---------------------------------------------------------------------

--- This KOReader's koreader-base commit (cached per version).
function Engine.baseCommit(fetch)
    local rev = Engine.revision()
    local state = Engine.getState()
    if state.base_cache and state.base_cache.rev == rev then
        return state.base_cache.base
    end
    local ref = Engine.koreaderRef(rev)
    if not ref then
        return nil, T(_("unknown KOReader version: %1"), tostring(rev))
    end
    local body, err = fetch(T(Engine.base_api_url, ref), 64 * 1024)
    if not body then return nil, err end
    local ok, info = pcall(require("json").decode, body)
    if not ok or type(info) ~= "table" or type(info.sha) ~= "string" or not info.sha:match("^%x+$") then
        return nil, _("could not find this KOReader's koreader-base")
    end
    state = Engine.getState()
    state.base_cache = { rev = rev, base = info.sha }
    Engine.saveState(state)
    return info.sha
end

--- The manifest's build for this base and target, or nil.
function Engine.findBuild(manifest, base, target)
    local builds = type(manifest) == "table" and type(manifest.builds) == "table" and manifest.builds[base]
    local build = type(builds) == "table" and builds[target]
    if type(build) ~= "table" or type(build.url) ~= "string" or not build.url:match("^https://")
            or type(build.sha256) ~= "string" or #build.sha256 ~= 64 or not build.sha256:match("^%x+$")
            or type(build.commit) ~= "string" or build.commit == "" then
        return nil
    end
    return build
end

function Engine.fetchManifest(fetch)
    local body, err = fetch(Engine.manifest_url, Engine.max_manifest_size)
    if not body then return nil, err end
    local ok, manifest = pcall(require("json").decode, body)
    if not ok or type(manifest) ~= "table" then
        return nil, _("invalid engine information")
    end
    return manifest
end

-- Files -----------------------------------------------------------------------

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function writeFile(path, data)
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(data)
    local closed, close_err = file:close()
    if not ok or not closed then
        os.remove(path)
        return nil, write_err or close_err
    end
    return true
end

--- Put data at path by writing a temporary file and renaming it over path
-- (a running KOReader keeps the old library it has loaded).
local function replaceFile(path, data)
    local tmp = path .. ".new"
    local ok, err = writeFile(tmp, data)
    if not ok then return nil, err end
    ok, err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return nil, err
    end
    return true
end

-- Start-up guard -------------------------------------------------------------

-- Start in the file browser while a new engine is unproven, so plugins (and
-- the guard) load before the engine does.
local function forceFileBrowserStart(pending)
    local start_with = G_reader_settings:readSetting("start_with")
    if start_with == "last" then
        pending.start_with = { value = start_with }
        G_reader_settings:saveSetting("start_with", "filemanager")
    end
end

local function restoreStartWith(pending)
    if pending and pending.start_with then
        -- Unless the user has chosen something else in the meantime.
        if G_reader_settings:readSetting("start_with") == "filemanager" then
            G_reader_settings:saveSetting("start_with", pending.start_with.value)
        end
    end
end

--- Put the standard engine back.
-- @return true, or nil and an error message
function Engine.restoreStock(reason)
    local state = Engine.getState()
    local lib = Engine.libPath()
    local stock = readFile(lib .. ".stock")
    if not stock then
        return nil, _("there is no copy of the standard engine")
    end
    if state.stock_rev ~= Engine.revision() then
        return nil, _("the copy of the standard engine is from another KOReader version")
    end
    local ok, err = replaceFile(lib, stock)
    if not ok then return nil, err end
    if state.pending then
        restoreStartWith(state.pending)
        if reason then
            state.bad = state.bad or {}
            state.bad[state.pending.commit] = true
            state.rolled_back = { commit = state.pending.commit, reason = reason }
        end
        state.pending = nil
    end
    Engine.saveState(state)
    logger.info("KnuthPlass: restored the standard engine:", reason)
    return true
end

function Engine.hasStock()
    local file = io.open(Engine.libPath() .. ".stock", "rb")
    if file then file:close() end
    return file ~= nil and Engine.getState().stock_rev == Engine.revision()
end

--- Called once as KOReader loads the plugin. While a new engine is
-- unproven, counts engine starts and puts the standard engine back when
-- the new one fails.
function Engine.installGuard()
    local state = Engine.getState()
    local pending = state.pending
    if not pending then return end
    if pending.rev ~= Engine.revision() then
        -- KOReader was updated, which replaced the library.
        restoreStartWith(pending)
        state.pending = nil
        Engine.saveState(state)
        return
    end
    Engine.guard_active = true
    local CreDocument = require("document/credocument")
    local engineInit = CreDocument.engineInit
    CreDocument.engineInit = function(...)
        CreDocument.engineInit = engineInit
        state = Engine.getState()
        if not state.pending then
            return engineInit(...)
        end
        state.pending.attempts = (state.pending.attempts or 0) + 1
        Engine.saveState(state)
        if state.pending.attempts > Engine.max_attempts then
            Engine.restoreStock(_("KOReader stopped before a book opened with it"))
        end
        local ok, cre = pcall(engineInit, ...)
        if ok then return cre end
        logger.warn("KnuthPlass: the new engine failed to load:", cre)
        if Engine.restoreStock(T(_("it failed to load: %1"), tostring(cre))) then
            return engineInit(...)
        end
        error(cre)
    end
end

--- Called when a book has opened: a pending engine that reports its build
-- has proved itself.
function Engine.verify(build)
    if not Engine.guard_active then return end
    local state = Engine.getState()
    if state.pending and build == state.pending.commit then
        logger.info("KnuthPlass: engine", build, "works")
        restoreStartWith(state.pending)
        state.pending = nil
        Engine.saveState(state)
    end
    Engine.guard_active = false
end

--- A rollback to tell the user about (once).
function Engine.takeRollback()
    local state = Engine.getState()
    local rolled_back = state.rolled_back
    if rolled_back then
        state.rolled_back = nil
        Engine.saveState(state)
    end
    return rolled_back
end

-- Installing ------------------------------------------------------------------

--- Install build (data is the downloaded library) over the running engine.
-- running_is_standard: the running engine is KOReader's own, so it is kept
-- as libkoreader-cre.so.stock (otherwise an existing copy is kept).
-- @return true, or nil and an error message
function Engine.install(build, data, running_is_standard)
    local sha2 = require("ffi/sha2")
    if (build.size and #data ~= build.size) or sha2.sha256(data):lower() ~= build.sha256:lower() then
        return nil, _("the download is damaged (checksum mismatch)")
    end
    -- An ELF shared library, not an error page.
    if data:sub(1, 4) ~= "\127ELF" then
        return nil, _("the download is not a library")
    end
    local lib = Engine.libPath()
    local state = Engine.getState()
    local rev = Engine.revision()
    if running_is_standard then
        local current = readFile(lib)
        if not current then
            return nil, _("cannot read the current engine")
        end
        local ok, err = writeFile(lib .. ".stock", current)
        if not ok then return nil, err end
        state.stock_rev = rev
    end
    local ok, err = replaceFile(lib, data)
    if not ok then return nil, err end
    local pending = { commit = build.commit, rev = rev, attempts = 0 }
    forceFileBrowserStart(pending)
    state.pending = pending
    Engine.saveState(state)
    -- This session still runs the old engine: only a restart can prove it.
    Engine.guard_active = false
    logger.info("KnuthPlass: installed engine", build.commit)
    return true
end

-- UI --------------------------------------------------------------------------

local function showInfo(text, timeout)
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    local widget = InfoMessage:new{ text = text, timeout = timeout }
    UIManager:show(widget)
    UIManager:forceRePaint()
    return widget
end

local function closeWidget(widget)
    if widget then require("ui/uimanager"):close(widget) end
end

function Engine.buildText(build)
    if build == nil then return _("unknown") end
    if build == "" then return _("standard") end
    return build
end

function Engine.downloadAndInstall(plugin, build, current_build, fetch, quiet)
    local UIManager = require("ui/uimanager")
    local progress = not quiet and showInfo(T(_("Downloading the Knuth–Plass engine %1…"), build.commit))
    local data, err = fetch(build.url, Engine.max_lib_size)
    local ok
    if data then
        -- An engine without the Knuth–Plass settings is KOReader's own.
        ok, err = Engine.install(build, data, current_build == "" and not plugin.active)
    end
    closeWidget(progress)
    if not ok then
        logger.warn("KnuthPlass: engine install failed:", err)
        if not quiet then
            showInfo(T(_("Could not install the Knuth–Plass engine:\n%1"), err))
        end
        return false
    end
    plugin.installed_engine = build.commit
    UIManager:askForRestart(T(_("The Knuth–Plass engine %1 has been installed. It will be used after KOReader restarts.\n\nUntil a book has opened with it, KOReader starts in the file browser, and if it fails the standard engine is put back."), build.commit))
    return true
end

local function offerInstall(plugin, build, current_build, fetch, interactive)
    local ConfirmBox = require("ui/widget/confirmbox")
    local UIManager = require("ui/uimanager")
    local text
    if current_build == "" and not plugin.active then
        text = T(_("This KOReader's engine has no Knuth–Plass line breaking. Install the Knuth–Plass engine %1?"), build.commit)
    else
        text = T(_("Knuth–Plass engine %1 is available (installed: %2)."), build.commit, Engine.buildText(current_build))
    end
    local dialog
    dialog = ConfirmBox:new{
        text = text,
        ok_text = _("Install"),
        cancel_text = _("Later"),
        ok_callback = function()
            Engine.downloadAndInstall(plugin, build, current_build, fetch)
        end,
        other_buttons = not interactive and {{
            {
                text = _("Skip this build"),
                callback = function()
                    local state = Engine.getState()
                    state.skip = build.commit
                    Engine.saveState(state)
                    UIManager:close(dialog)
                end,
            },
        }} or nil,
    }
    UIManager:show(dialog)
end

--- Check for an engine build for this device and KOReader version.
-- Appends status lines to report (for interactive checks).
-- @return true if it offered or installed an update
function Engine.check(plugin, interactive, mode, fetch, report)
    if plugin.installed_engine then
        table.insert(report, T(_("Engine: %1 is installed and will be used after KOReader restarts."), plugin.installed_engine))
        return false
    end
    local current_build = Engine.installedBuild(plugin.ui and plugin.ui.document)
    if current_build == nil then return false end
    local target = Engine.target()
    if target ~= "kobo" then
        table.insert(report, T(_("Engine: no builds for this device (%1)."), tostring(target)))
        return false
    end
    local base, err = Engine.baseCommit(fetch)
    local manifest
    if base then
        manifest, err = Engine.fetchManifest(fetch)
    end
    if not manifest then
        logger.warn("KnuthPlass: engine check failed:", err)
        table.insert(report, T(_("Engine: could not check (%1)."), tostring(err)))
        return false
    end
    local build = Engine.findBuild(manifest, base, target)
    if not build then
        table.insert(report, T(_("Engine: no build for this KOReader version yet (koreader-base %1)."), base:sub(1, 12)))
        return false
    end
    if build.commit == current_build then
        table.insert(report, T(_("Engine: up to date (%1)."), current_build))
        return false
    end
    local state = Engine.getState()
    if state.bad and state.bad[build.commit] then
        table.insert(report, T(_("Engine: build %1 failed on this device before, so it isn't offered again."), build.commit))
        return false
    end
    if not interactive and state.skip == build.commit then
        return false
    end
    if not interactive and mode == "install" then
        return Engine.downloadAndInstall(plugin, build, current_build, fetch, true)
    end
    offerInstall(plugin, build, current_build, fetch, interactive)
    return true
end

return Engine
