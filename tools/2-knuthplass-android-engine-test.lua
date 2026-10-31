--[[--
Knuth–Plass plugin: a one-off test of the Android engine build
(libkoreader-cre.so with crengine and its libraries built in).

1. Copy the engine to koreader/libkoreader-cre-android-arm64.so
2. Copy this file to koreader/patches/ (direct-download KOReader; F-Droid
   builds don't run user patches) and restart KOReader.

It runs once: the report goes to koreader/knuthplass-android-engine-test.txt
and a summary is shown. Delete the report to run it again; delete this file
and the engine when you're done.

It copies the engine to <app folder>/knuthplass-test/ and loads it in
KOReader (without starting it). Then, in child processes, it opens a sample
document with KOReader's own document code, as the reader would, and lays
it out and draws its first page: with KOReader's own engine, then with the
new one (greedy line breaking: should match KOReader's), then with the new
one with Knuth–Plass line breaking (should differ). Nothing is installed.

(For a dry run on desktop Linux: set KNUTHPLASS_TEST_LIB to an engine.)
]]

local ok_android, android = pcall(require, "android")
if not ok_android then android = nil end
local test_lib_env = os.getenv("KNUTHPLASS_TEST_LIB")
if not android and not test_lib_env then return end

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local ffi = require("ffi")

local data_dir = DataStorage:getFullDataDir() or DataStorage:getDataDir()
local report_path = data_dir .. "/knuthplass-android-engine-test.txt"
do
    local f = io.open(report_path, "rb")
    if f then f:close() return end
end

local lines, summary = {}, {}
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    table.insert(lines, table.concat(parts, " "))
end

local function size(path) return lfs.attributes(path, "size") end

local function copy(src, dst)
    os.remove(dst)
    local input, err = io.open(src, "rb")
    if not input then return nil, err end
    local data = input:read("*a")
    input:close()
    local output
    output, err = io.open(dst, "wb")
    if not output then return nil, err end
    output:write(data)
    output:close()
    return true
end

pcall(ffi.cdef, "int chmod(const char *path, unsigned int mode);")

local src, private_dir, standard
if android then
    src = data_dir .. "/libkoreader-cre-android-arm64.so"
    private_dir = android.dir:match("^(.*)/[^/]+$") .. "/knuthplass-test"
    standard = android.nativeLibraryDir .. "/libkoreader-monolibtic.so"
else
    src = test_lib_env
    private_dir = data_dir .. "/knuthplass-test"
    standard = lfs.currentdir() .. "/libs/libkoreader-cre.so"
end
local lib = private_dir .. "/libkoreader-cre.so"
local sample = private_dir .. "/sample.html"

local SAMPLE = [[<html><head><title>Sample</title></head><body>
<h1>Sample</h1>
%s
</body></html>]]
local PARAGRAPH = [[<p style="text-align: justify">It was the best of times, it was the worst of
times, it was the age of wisdom, it was the age of foolishness, it was the epoch of belief, it was
the epoch of incredulity, it was the season of Light, it was the season of Darkness, it was the
spring of hope, it was the winter of despair, we had everything before us, we had nothing before
us, we were all going direct to Heaven, we were all going direct the other way; in short, the period
was so far like the present period, that some of its noisiest authorities insisted on its being
received, for good or for evil, in the superlative degree of comparison only.</p>
]]

-- In a child process: open the sample with KOReader's document code and
-- the engine at path, in the given line breaking mode (nil: don't set it).
local function render(path, mode)
    local ffiutil = require("ffi/util")
    local pid, read_fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local out
        local ok, err = pcall(function()
            local open, load_err = package.loadlib(path, "luaopen_cre")
            if not open then error("loadlib: " .. tostring(load_err)) end
            package.loaded.cre = nil
            local cre = open()
            if type(cre) ~= "table" then cre = package.loaded.cre end
            package.loaded["libs/libkoreader-cre"] = cre
            -- A fresh copy of KOReader's document module, using this engine.
            package.loaded["document/credocument"] = nil
            local CreDocument = require("document/credocument")
            local doc = CreDocument:new{ file = sample }
            if mode then
                doc._document:setIntProperty("crengine.style.line.breaking.mode", mode)
            end
            doc:setupDefaultView()
            if not doc:loadDocument() then error("couldn't load the sample") end
            doc:render()
            local pages = doc:getPageCount()
            local Screen = require("device").screen
            local w, h = Screen:getWidth(), Screen:getHeight()
            local Blitbuffer = require("ffi/blitbuffer")
            local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
            bb:fill(Blitbuffer.COLOR_WHITE)
            doc:drawCurrentViewByPage(bb, 0, 0, { x = 0, y = 0, w = w, h = h }, 1)
            local dark = 0
            for y = 0, h - 1, 2 do
                for x = 0, w - 1, 2 do
                    if bb:getPixel(x, y):getColor8().a < 128 then dark = dark + 1 end
                end
            end
            local build = doc._document:getStringProperty("crengine.knuth.plass.build") or ""
            out = string.format("OK pages=%d ink=%d build=%s", pages, dark, build ~= "" and build or "(none)")
        end)
        if not ok then out = "ERR " .. tostring(err) end
        ffiutil.writeToFD(write_fd, out, true)
    end, true)
    if not pid then return "ERR fork: " .. tostring(read_fd) end
    for _i = 1, 900 do
        if ffiutil.isSubProcessDone(pid) then
            local out = ffiutil.readAllFromFD(read_fd)
            return out ~= "" and out or "ERR the child crashed"
        end
        ffiutil.usleep(100000)
    end
    ffiutil.terminateSubProcess(pid)
    ffiutil.isSubProcessDone(pid, true)
    ffiutil.readAllFromFD(read_fd)
    return "ERR timed out"
end

local function run()
    say("Knuth-Plass Android engine test")
    say("date:", os.date("%Y-%m-%d %H:%M:%S"))
    if android then
        local ok_sdk, sdk = pcall(function() return android.app.activity.sdkVersion end)
        say("Android SDK level:", ok_sdk and sdk or "?", "| device:", android.prop.manufacturer, android.prop.model)
    end
    local ok_rev, rev = pcall(function() return require("version"):getCurrentRevision() end)
    say("KOReader:", ok_rev and rev or "?", "| arch:", jit.arch)
    say("engine:", src, "| size:", size(src))
    say("KOReader's own:", standard, "| size:", size(standard))
    if not size(src) then
        say("RESULT: no engine at", src)
        table.insert(summary, "No engine found at " .. src)
        return
    end
    lfs.mkdir(private_dir)
    local ok, err = copy(src, lib)
    if not ok then
        say("copy failed:", err)
        table.insert(summary, "Copy failed: " .. tostring(err))
        return
    end
    pcall(function() return ffi.C.chmod(lib, 292) end) -- 0444
    local f = io.open(sample, "wb")
    f:write(string.format(SAMPLE, PARAGRAPH:rep(12)))
    f:close()

    local open, load_err = package.loadlib(lib, "luaopen_cre")
    say("load in KOReader:", open and "OK" or ("FAILED " .. tostring(load_err)))
    table.insert(summary, "Load: " .. (open and "OK" or "FAILED"))
    if not open then return end

    local results = {
        { "KOReader's own, greedy", render(standard, 0) },
        { "new engine, greedy", render(lib, 0) },
        { "new engine, Knuth-Plass", render(lib, 1) },
    }
    for _i, r in ipairs(results) do
        say(r[1] .. ":", r[2])
        table.insert(summary, r[1] .. ": " .. r[2])
    end
    local own, greedy, kp = results[1][2], results[2][2], results[3][2]
    local function strip(s) return (s:gsub(" build=.*", "")) end
    local verdict
    if own:sub(1, 2) ~= "OK" or greedy:sub(1, 2) ~= "OK" or kp:sub(1, 2) ~= "OK" then
        verdict = "FAILED (see above)"
    elseif strip(own) ~= strip(greedy) then
        verdict = "DIFFERENT: greedy layout doesn't match KOReader's own"
    elseif strip(kp) == strip(greedy) then
        verdict = "WORKS, but Knuth-Plass gave the same layout as greedy"
    else
        verdict = "WORKS"
    end
    say("RESULT:", verdict)
    table.insert(summary, "Result: " .. verdict)

    os.remove(lib)
    os.remove(sample)
    lfs.rmdir(private_dir)
end

local ok, err = pcall(run)
if not ok then
    say("ERROR:", err)
    table.insert(summary, "Error: " .. tostring(err))
end
local f = io.open(report_path, "wb")
if f then
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
end

local UIManager = require("ui/uimanager")
UIManager:nextTick(function()
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = "Knuth–Plass Android engine test:\n\n" .. table.concat(summary, "\n")
            .. "\n\nFull report: " .. report_path,
    })
end)
