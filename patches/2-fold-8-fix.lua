-- 2-fold-8-fix.lua
-- Repository: https://github.com/titandrive/koreader.things
--
-- Lets Android handle all four user-enabled sensor orientations on the
-- Samsung Fold 8 while respecting Android's Auto rotate setting.
-- KOReader normally turns its rotation modes into fixed Android orientation
-- requests. On the Fold's landscape-native inner display, Samsung treats that
-- request as SENSOR_LANDSCAPE, which prevents portrait sensor rotations.
-- It also keeps KOReader's text and UI scale stable when switching between
-- the 1248px-wide cover display and the larger inner display. KOReader
-- normally bases that scale on the shortest pixel dimension, which makes
-- everything about 48% larger after unfolding even though both panels are
-- 420 dpi.
--
-- INSTALLATION:
--   Copy this file into koreader/patches/, then restart KOReader.

local Device = require("device")

if Device:isAndroid() then
    local android = require("android")
    local ffi = require("ffi")
    local C = ffi.C
    local UIManager = require("ui/uimanager")
    local _ = require("gettext")

    local model = tostring(android.prop.model or "")
    local product = tostring(android.prop.product or "")
    local device = tostring(android.prop.device or "")
    local is_fold8 = model == "SM-F971U1"
        or product == "h8quew"
        or device == "h8q"

    if is_fold8 and not Device.screen._foldable_full_sensor_rotation then
        Device.screen._foldable_full_sensor_rotation = true
        local cover_short_edge = 1248
        local original_scaleBySize = Device.screen.scaleBySize
        local auto_rotation_setting = "foldable_full_sensor_rotation"
        local original_setRotationMode = Device.screen.setRotationMode
        local original_broadcastEvent = UIManager.broadcastEvent
        local android_full_user = 13 -- ActivityInfo.SCREEN_ORIENTATION_FULL_USER

        -- Preserve the cover display's physical scale on the inner display.
        -- Run KOReader's own implementation against a proxy whose dimensions
        -- are capped at the Fold 8 cover screen's short edge. This retains its
        -- DPI-override behavior and rounding without changing layout bounds.
        local scale_proxy = setmetatable({
            getWidth = function()
                return math.min(Device.screen:getWidth(), cover_short_edge)
            end,
            getHeight = function()
                return math.min(Device.screen:getHeight(), cover_short_edge)
            end,
        }, { __index = Device.screen })

        function Device.screen:scaleBySize(px)
            return original_scaleBySize(scale_proxy, px)
        end

        -- android-luajit-launcher currently validates orientation values only
        -- through FULL_SENSOR (10), although its Java bridge accepts FULL_USER
        -- (13). Reuse the bridge captured by android.orientation.set.
        local orientation_jni
        for index = 1, 10 do
            local name, value = debug.getupvalue(android.orientation.set, index)
            if not name then break end
            if name == "JNI" then
                orientation_jni = value
                break
            end
        end

        local function setFullUserOrientation()
            if orientation_jni then
                orientation_jni:context(android.app.activity.vm, function(jni)
                    jni:callVoidMethod(
                        android.app.activity.clazz,
                        "setScreenOrientation",
                        "(I)V",
                        ffi.new("int32_t", android_full_user)
                    )
                end)
            else
                -- USER honors the system lock, but may be limited to fewer
                -- sensor positions on older Android versions.
                android.orientation.set(C.ASCREEN_ORIENTATION_USER)
            end
        end

        if G_reader_settings:readSetting(auto_rotation_setting) == nil then
            G_reader_settings:saveSetting(auto_rotation_setting, true)
        end

        function Device.screen:setRotationMode(mode)
            if G_reader_settings:isTrue(auto_rotation_setting) then
                setFullUserOrientation()
                return
            end
            original_setRotationMode(self, mode)
        end

        -- Startup restores call onSetRotationMode directly, while explicit
        -- rotation controls (including Zen UI quick settings) broadcast this
        -- event. This lets manual choices disable auto mode without a fragile
        -- startup timer.
        UIManager.broadcastEvent = function(self, event, ...)
            if event and event.handler == "onSetRotationMode"
                    and G_reader_settings:isTrue(auto_rotation_setting) then
                G_reader_settings:saveSetting(auto_rotation_setting, false)
            end
            return original_broadcastEvent(self, event, ...)
        end

        local function patchRotationMenu(rotation_menu)
            local original_sub_item_table_func = rotation_menu.sub_item_table_func
            if type(original_sub_item_table_func) ~= "function" then
                return rotation_menu
            end

            rotation_menu.sub_item_table_func = function(...)
                local items = original_sub_item_table_func(...)
                local first_rotation_item

                for index, item in ipairs(items) do
                    if item.radio then
                        first_rotation_item = first_rotation_item or index
                        local original_callback = item.callback
                        item.callback = function(...)
                            G_reader_settings:saveSetting(auto_rotation_setting, false)
                            return original_callback(...)
                        end
                    end
                end

                if first_rotation_item then
                    table.insert(items, first_rotation_item, {
                        text = _("Auto rotate (all orientations)"),
                        radio = true,
                        checked_func = function()
                            return G_reader_settings:isTrue(auto_rotation_setting)
                        end,
                        callback = function(touchmenu_instance)
                            G_reader_settings:saveSetting(auto_rotation_setting, true)
                            setFullUserOrientation()
                            touchmenu_instance:closeMenu()
                        end,
                    })
                end

                return items
            end
            return rotation_menu
        end

        -- KOReader's FileManagerMenu and ReaderMenu load
        -- common_settings_menu_table.lua with dofile(), which in turn loads
        -- screen_rotation_menu_table.lua with dofile(). Each menu build gets a
        -- fresh table, so require()-based patching never reaches the menu that
        -- is displayed. Patch the result every time that file is loaded.
        local original_dofile = dofile
        dofile = function(path, ...)
            local result = original_dofile(path, ...)
            if type(path) == "string"
                    and path:match("screen_rotation_menu_table%.lua$")
                    and type(result) == "table" then
                return patchRotationMenu(result)
            end
            return result
        end

        if G_reader_settings:isTrue(auto_rotation_setting) then
            setFullUserOrientation()
        end
        android.LOGI("Fold 8: enabled full-sensor rotation and stable display scaling")
    end
end
