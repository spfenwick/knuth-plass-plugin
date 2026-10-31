--[[--
Installs the Knuth–Plass CREngine (libs/libkoreader-cre.so) built by the
plugin repository's "Build engine" workflow.

The library only has to agree with the rest of KOReader where they meet
(cre.cpp's Lua API and the shared libraries it links), so the manifest lists
builds by a fingerprint of those parts of koreader-base, and maps each
koreader-base it has seen to one. A device finds its koreader-base from the
commit in its version string through the GitHub API. If the manifest has no
entry for it, the newest build is offered instead. Either way, before
installing, the library is loaded in a child process (which fails if a
library or symbol it needs is missing), and must provide every function of
the running engine (which KOReader's Lua code may call).

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
--   pending     = { commit, id, rev, attempts, start_with = { value } }
--                 an installed engine not yet seen working
--   stock_rev   = the KOReader version libkoreader-cre.so.stock is from
--   bad         = { [build id @ revision] = true }: builds that failed with
--                 this KOReader version, not offered again
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
    if not body then
        return nil, T(_("looking up KOReader %1 on GitHub: %2"), ref, tostring(err))
    end
    local ok, info = pcall(require("json").decode, body)
    if not ok or type(info) ~= "table" or type(info.sha) ~= "string" or not info.sha:match("^%x+$") then
        return nil, _("could not find this KOReader's koreader-base")
    end
    state = Engine.getState()
    state.base_cache = { rev = rev, base = info.sha }
    Engine.saveState(state)
    return info.sha
end

local function validBuild(build)
    return type(build) == "table" and type(build.url) == "string" and build.url:match("^https://")
        and type(build.sha256) == "string" and #build.sha256 == 64 and build.sha256:match("^%x+$")
        and type(build.commit) == "string" and build.commit ~= ""
        and true or false
end

--- The manifest's build for this koreader-base and target, and true; or,
-- with no build listed for this koreader-base, the newest one for target
-- and false; or nil.
function Engine.findBuild(manifest, base, target)
    if type(manifest) ~= "table" or manifest.schema ~= 2 or type(manifest.builds) ~= "table" then
        return nil
    end
    local fingerprint = type(manifest.bases) == "table" and manifest.bases[base]
    local builds = fingerprint and manifest.builds[fingerprint]
    local build = type(builds) == "table" and builds[target]
    if validBuild(build) then
        return build, true
    end
    local newest
    for _fp, per_target in pairs(manifest.builds) do
        build = type(per_target) == "table" and per_target[target]
        if validBuild(build) and (not newest or tostring(build.built) > tostring(newest.built)) then
            newest = build
        end
    end
    if newest then
        return newest, false
    end
    return nil
end

--- What identifies a build (the same crengine commit is built per fingerprint).
function Engine.buildId(build)
    return build.commit .. "/" .. tostring(build.file)
end

local function badKey(id)
    return id .. "@" .. tostring(Engine.revision())
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
            state.bad[badKey(state.pending.id or state.pending.commit)] = true
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

--- Check the downloaded library against the manifest.
function Engine.verifyDownload(build, data)
    local sha2 = require("ffi/sha2")
    if (build.size and #data ~= build.size) or sha2.sha256(data):lower() ~= build.sha256:lower() then
        return nil, _("the download is damaged (checksum mismatch)")
    end
    -- An ELF shared library, not an error page.
    if data:sub(1, 4) ~= "\127ELF" then
        return nil, _("the download is not a library")
    end
    return true
end

--- Install build (data is the downloaded library) over the running engine.
-- running_is_standard: the running engine is KOReader's own, so it is kept
-- as libkoreader-cre.so.stock (otherwise an existing copy is kept).
-- @return true, or nil and an error message
function Engine.install(build, data, running_is_standard)
    local ok, err = Engine.verifyDownload(build, data)
    if not ok then return nil, err end
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
    ok, err = replaceFile(lib, data)
    if not ok then return nil, err end
    local pending = { commit = build.commit, id = Engine.buildId(build), rev = rev, attempts = 0 }
    forceFileBrowserStart(pending)
    state.pending = pending
    Engine.saveState(state)
    -- This session still runs the old engine: only a restart can prove it.
    Engine.guard_active = false
    logger.info("KnuthPlass: installed engine", build.commit)
    return true
end

-- Compatibility ---------------------------------------------------------------

-- The metatables cre.cpp registers: its methods on documents and images.
local CRE_METATABLES = { "credocument", "creimage" }

--- The functions a cre module provides (KOReader's Lua code calls them):
-- { ["cre.name"] = true, ["credocument:name"] = true, … }
function Engine.creApi(module, registry)
    local api = {}
    if type(module) == "table" then
        for name, value in pairs(module) do
            if type(value) == "function" then api["cre." .. name] = true end
        end
    end
    for _i, mt_name in ipairs(CRE_METATABLES) do
        local mt = registry[mt_name]
        if type(mt) == "table" then
            for name, value in pairs(mt) do
                if type(value) == "function" then api[mt_name .. ":" .. name] = true end
            end
        end
    end
    return api
end

--- Load the library at path in a child process.
-- @return its API (see creApi), or nil and an error message
function Engine.probeLibrary(path)
    local ffiutil = require("ffi/util")
    local pid, read_fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        -- The running engine's tables would hide what the new one lacks.
        local registry = debug.getregistry()
        for _i, mt_name in ipairs(CRE_METATABLES) do registry[mt_name] = nil end
        package.loaded.cre = nil
        rawset(_G, "cre", nil)
        -- Resolves every symbol now: fails if one is missing.
        local open, err = package.loadlib(path, "luaopen_cre")
        local out
        if not open then
            out = "ERR " .. tostring(err)
        else
            local ok, module = pcall(open)
            if not ok then
                out = "ERR " .. tostring(module)
            else
                if type(module) ~= "table" then module = package.loaded.cre end
                local names = {}
                for name in pairs(Engine.creApi(module, registry)) do table.insert(names, name) end
                out = "OK\n" .. table.concat(names, "\n")
            end
        end
        ffiutil.writeToFD(write_fd, out, true)
    end, true)
    if not pid then
        return nil, tostring(read_fd)
    end
    -- Give it 20 seconds.
    local done = false
    for _i = 1, 200 do
        if ffiutil.isSubProcessDone(pid) then
            done = true
            break
        end
        ffiutil.usleep(100000)
    end
    if not done then
        ffiutil.terminateSubProcess(pid)
        ffiutil.isSubProcessDone(pid, true)
        ffiutil.readAllFromFD(read_fd)
        return nil, _("loading it took too long")
    end
    local out = ffiutil.readAllFromFD(read_fd)
    if out:sub(1, 3) == "OK\n" then
        local api = {}
        for name in out:sub(4):gmatch("[^\n]+") do api[name] = true end
        return api
    elseif out:sub(1, 4) == "ERR " then
        return nil, out:sub(5)
    end
    return nil, _("it crashed when loaded")
end

--- Check that the library (data) works with this KOReader: it loads, and
-- provides every function the running engine does.
-- @return true, or nil and an error message
function Engine.checkCompatible(data)
    -- Next to the engine, so it finds the same libraries.
    local probe = Engine.libPath() .. ".probe"
    local ok, err = writeFile(probe, data)
    if not ok then return nil, err end
    local api
    api, err = Engine.probeLibrary(probe)
    os.remove(probe)
    if not api then
        return nil, T(_("it doesn't load with this KOReader (%1)"), tostring(err))
    end
    local running = package.loaded["libs/libkoreader-cre"]
    if running then
        local missing = {}
        for name in pairs(Engine.creApi(running, debug.getregistry())) do
            if not api[name] then table.insert(missing, name) end
        end
        if #missing > 0 then
            table.sort(missing)
            return nil, T(_("it lacks functions this KOReader uses (%1)"), table.concat(missing, ", "))
        end
    end
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
        ok, err = Engine.verifyDownload(build, data)
    end
    if ok then
        ok, err = Engine.checkCompatible(data)
        if not ok then
            -- Don't offer it again with this KOReader version.
            local state = Engine.getState()
            state.bad = state.bad or {}
            state.bad[badKey(Engine.buildId(build))] = true
            Engine.saveState(state)
        end
    end
    if ok then
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

local function offerInstall(plugin, build, exact, current_build, fetch, interactive)
    local ConfirmBox = require("ui/widget/confirmbox")
    local UIManager = require("ui/uimanager")
    local text
    if current_build == "" and not plugin.active then
        text = T(_("This KOReader's engine has no Knuth–Plass line breaking. Install the Knuth–Plass engine %1?"), build.commit)
    else
        text = T(_("Knuth–Plass engine %1 is available (installed: %2)."), build.commit, Engine.buildText(current_build))
    end
    if not exact then
        text = text .. "\n\n" .. T(_("It was built for another KOReader version (%1). It will be checked against this one before it's installed."), tostring(build.koreader))
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
    -- Which devices have builds is up to the manifest.
    local target = Engine.target()
    if not target then
        table.insert(report, _("Engine: no builds for this device."))
        return false
    end
    -- Without its koreader-base (a KOReader built from a commit GitHub's
    -- koreader repository doesn't have, say), the newest build is offered:
    -- it's checked against the running engine before it's installed.
    local base, base_err = Engine.baseCommit(fetch)
    if not base then
        logger.warn("KnuthPlass: cannot find koreader-base:", base_err)
    end
    local manifest, err = Engine.fetchManifest(fetch)
    if not manifest then
        logger.warn("KnuthPlass: engine check failed:", err)
        table.insert(report, T(_("Engine: could not download the list of builds (%1)."), tostring(err)))
        return false
    end
    local build, exact = Engine.findBuild(manifest, base or "", target)
    if not build then
        table.insert(report, T(_("Engine: no builds for this device (%1)."), target))
        return false
    end
    if build.commit == current_build then
        table.insert(report, T(_("Engine: up to date (%1)."), current_build))
        return false
    end
    local state = Engine.getState()
    if state.bad and state.bad[badKey(Engine.buildId(build))] then
        table.insert(report, T(_("Engine: build %1 didn't work with this KOReader version, so it isn't offered again."), build.commit))
        return false
    end
    if not interactive and state.skip == build.commit then
        return false
    end
    if not interactive and mode == "install" then
        return Engine.downloadAndInstall(plugin, build, current_build, fetch, true)
    end
    offerInstall(plugin, build, exact, current_build, fetch, interactive)
    return true
end

return Engine
