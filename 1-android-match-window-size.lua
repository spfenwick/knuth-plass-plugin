--[[
KOReader user patch: size KOReader's screen to the actual Android window,
re-checked whenever the window changes (e.g. folding/unfolding).

Why: the Android launcher measures the camera cutout once, when the window is
first attached, and subtracts it from getScreenWidth()/getScreenHeight() for
the rest of the session. KOReader sizes its screen buffer from those values
and copies it into the full window, so on a foldable the value measured on one
screen is wrong for the other (e.g. a cutout-sized black bar down the side of
the main screen after starting on the cover screen).

What this patch does instead:
  * Uses the real size of the native window (ANativeWindow_getWidth/Height)
    as KOReader's screen size. That size already reflects whatever Android
    does with the cutout: if Android letterboxes the camera strip, the window
    is smaller; if the app may draw around the camera, it is the full screen.
    So it works with either camera-cutout setting, on either screen.
  * Before every blit, checks whether the window size still matches
    KOReader's buffer, and if not, resizes KOReader on the next UI tick. This
    catches window changes that arrive after Android's configuration-change
    event, which KOReader alone would miss.

Install: copy to <koreader data dir>/patches/ and restart KOReader.
This file replaces the earlier "1-android-full-window.lua"; delete that file
so the two don't both run.
User patches are disabled in the F-Droid build of KOReader.
--]]

local ok, android = pcall(require, "android")
if not ok or type(android) ~= "table" or android.app == nil
   or android.lib == nil or android.getScreenWidth == nil then
    return -- not running on Android: nothing to do
end

local logger = require("logger")

-- Current native window size, or nil if there is no window right now.
local function windowSize()
    local win = android.app.window
    if win == nil then return nil end
    local w = android.lib.ANativeWindow_getWidth(win)
    local h = android.lib.ANativeWindow_getHeight(win)
    if w and h and w > 0 and h > 0 then
        return w, h
    end
end

-- Use the window size wherever KOReader asks for the screen size; fall back
-- to the launcher's own values if there is no window.
local orig_w, orig_h = android.getScreenWidth, android.getScreenHeight
android.getScreenWidth = function()
    local w = windowSize()
    return w or orig_w()
end
android.getScreenHeight = function()
    local _, h = windowSize()
    return h or orig_h()
end

-- android.screen was filled in when the android module loaded, before this
-- patch ran; refresh it before KOReader creates its screen buffer.
android.screen.width = android.getScreenWidth()
android.screen.height = android.getScreenHeight()

-- Same steps KOReader's Android device code runs on a configuration change.
local function resizeKOReader(screen)
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    screen:resize() -- re-reads android.getScreenWidth/Height (patched above)
    local new_size = screen:getSize()
    logger.info("userpatch: window changed, resizing screen to", new_size)
    UIManager:broadcastEvent(Event:new("SetDimensions", new_size))
    UIManager:broadcastEvent(Event:new("ScreenResize", new_size))
    UIManager:broadcastEvent(Event:new("RedrawCurrentPage"))
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:reinit(FileManager.instance.path,
            FileManager.instance.focused_file)
    end
end

local AndroidFB = require("ffi/framebuffer_android")
local orig_updateWindow = AndroidFB._updateWindow
local resize_pending = false

function AndroidFB:_updateWindow()
    local w, h = windowSize()
    if w and not resize_pending
       and (w ~= android.screen.width or h ~= android.screen.height) then
        -- Only use UIManager once KOReader has loaded it; requiring it from
        -- here during startup could create a circular require.
        local UIManager = package.loaded["ui/uimanager"]
        if type(UIManager) == "table" and UIManager.nextTick then
            resize_pending = true
            UIManager:nextTick(function()
                resize_pending = false
                local nw, nh = windowSize()
                if nw and (nw ~= android.screen.width or nh ~= android.screen.height) then
                    resizeKOReader(self)
                end
            end)
        end
    end
    return orig_updateWindow(self)
end

logger.info("userpatch: screen follows native window size; now",
            android.screen.width, "x", android.screen.height)
