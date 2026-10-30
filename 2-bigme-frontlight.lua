-- SPDX-License-Identifier: MIT
--[[
MIT License

Copyright (c) 2026 Robin Bolinsson and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]
-- Bigme LM3630A frontlight compatibility, v0.1.0-beta.2.
-- Standalone KOReader userpatch: no OrbitUI dependency, root or firmware changes.
-- Only the verified hibreak_eea/mt6877/arm64 firmware profile is eligible.
-- Loading performs no device open/ioctl or Android-settings write.

local ok_android, android = pcall(require, "android")
if not ok_android or type(android) ~= "table" or type(android.prop) ~= "table" then return end
local function normalized(v) return type(v) == "string" and v:lower():match("^%s*(.-)%s*$") or "" end
local prop = android.prop
if normalized(prop.manufacturer) ~= "bigme" and normalized(prop.brand) ~= "bigme" then return end
if normalized(prop.model) ~= "hibreak" or normalized(prop.hardware) ~= "mt6877"
    or normalized(prop.product) ~= "hibreak_eea" then return end

local VERSION = "0.1.0-beta.2"
local PROFILE = "hibreak_eea/mt6877/arm64/lm3630a-table80-v1"
local PATH = "/dev/lm3630a"
local LEVELS = { 0,2,20,30,40,50,60,70,80,90,102,108,114,120,126,132,138,144,150,
    156,162,168,174,180,188,192,198,204,206,208,210,212,214,216,218,220,222 }
local CHANNELS = {
    cold = { request=0x7901, index="ColdValue", raw="screen_brightness_cold", preset="LightUser_Brightness" },
    warm = { request=0x7902, index="WarmValue", raw="screen_brightness_warm", preset="LightUser_ColorTemp" },
}
local function log(message)
    local ok, logger = pcall(require, "logger")
    if ok and type(logger) == "table" and type(logger.info) == "function" then
        pcall(logger.info, "[Bigme frontlight " .. VERSION .. "] " .. tostring(message))
    end
end
local warned = false
local function warn(detail)
    log(detail)
    if warned then return end
    warned = true
    local sv = false
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local ok, language = pcall(G_reader_settings.readSetting, G_reader_settings, "language")
        sv = ok and type(language) == "string" and language:lower():match("^sv") ~= nil
    end
    local message = sv
        and "Bigme-ljusstyrning kunde inte användas säkert. Använd Bigmes egen ljusmeny och starta om KOReader. Kontrollera också att KOReader får ändra systeminställningar. Ingen behörighet ändras av patchen.\n\n"
        or "Bigme frontlight control could not be used safely. Use Bigme's own light panel and restart KOReader. Also check that KOReader may modify system settings. This patch changes no permissions.\n\n"
    pcall(function()
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0, function()
            pcall(function()
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{ text=message .. tostring(detail), show_icon=false,
                    dismissable=true, honor_silent_mode=false, sui_native=true })
            end)
        end)
    end)
end
local function index(v)
    return type(v) == "number" and v == v and v >= 0 and v <= 36 and v == math.floor(v) and v or nil
end
local function clamp(v, max)
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
    return math.floor(math.max(0, math.min(max, v)) + 0.5)
end

local installed, setup_error = pcall(function()
    local ffi = require("ffi")
    if ffi.os ~= "Linux" or ffi.arch ~= "arm64" then return end
    require("ffi/posix_h")
    local C = ffi.C
    local open_device, ioctl, close_device = C.open, C.ioctl, C.close
    local getpid = C.getpid
    local owner_pid = tonumber(getpid())
    assert(owner_pid and owner_pid > 0, "Cannot identify main process")
    local function in_owner() return tonumber(getpid()) == owner_pid end
    assert(tonumber(C.O_WRONLY) == 1 and ffi.sizeof("int32_t") == 4, "Unexpected native ABI")
    assert(tonumber(C.getuid()) >= 10000, "Not an ordinary app UID")
    local file = assert(io.open("/proc/self/attr/current", "r"), "Cannot read app security context")
    local read_ok, context = pcall(file.read, file, 256)
    pcall(file.close, file)
    assert(read_ok and type(context) == "string" and context:match("^u:r:untrusted_app[^:]*:"), "Unsupported security context")
    local Device = require("device")
    local AndroidPowerD = require("device/android/powerd")
    assert(Device:isAndroid(), "Not the Android device backend")
    local powerd = Device:getPowerDevice()
    assert(getmetatable(powerd) == AndroidPowerD, "Unsupported PowerD implementation")
    if powerd._bigme_lm3630a then return end -- duplicate installation must not wrap twice
    assert(type(powerd.stateChanged) == "function" and type(powerd.updateResumeFrontlightState) == "function"
        and type(android.jni) == "table"
        and type(android.jni.context) == "function", "Missing KOReader API")
    local activity = assert(android.app and android.app.activity, "No Android activity")
    assert(activity.vm and activity.clazz, "Missing JNI activity handles")

    -- Public Android Settings.System only, not hidden/vendor Java APIs.
    -- Every JNI lookup/call is checked before using its result. All local refs
    -- and Java exceptions are cleaned up, and no Lua error escapes context().
    local function settings(writes)
        if not in_owner() then return nil, "Not the owning KOReader process" end
        local outer_ok, result, failure = pcall(android.jni.context, android.jni, activity.vm, function(jni)
            local env = jni.env
            local api, refs = env[0], {}
            local function checked(value, reference)
                if api.ExceptionCheck(env) ~= 0 then
                    api.ExceptionClear(env)
                    error("Android settings API raised an exception")
                end
                assert(value ~= nil and value ~= ffi.NULL, "Null Android settings API result")
                if reference then refs[#refs+1] = value end
                return value
            end
            local inner_ok, values = pcall(function()
                -- Do NOT call android.canWriteSettings(): its legacy Java target
                -- hasWriteSettingsPermission is absent in current APKs. That
                -- unchecked JNI helper can abort the process, beyond pcall.
                -- Resolve public Android canWrite(Context) and check the ID
                -- BEFORE invocation, both at startup and before later I/O.
                local system = checked(api.FindClass(env, "android/provider/Settings$System"), true)
                local can_write = checked(api.GetStaticMethodID(env, system, "canWrite", "(Landroid/content/Context;)Z"))
                local allowed = api.CallStaticBooleanMethod(env, system, can_write, activity.clazz)
                checked(allowed)
                assert(tonumber(allowed) == 1, "WRITE_SETTINGS is required; no permission was requested or changed")
                local cls = checked(api.GetObjectClass(env, activity.clazz), true)
                local getter = checked(api.GetMethodID(env, cls, "getContentResolver", "()Landroid/content/ContentResolver;"))
                local resolver = checked(api.CallObjectMethod(env, activity.clazz, getter), true)
                local get_int = checked(api.GetStaticMethodID(env, system, "getInt", "(Landroid/content/ContentResolver;Ljava/lang/String;I)I"))
                local put_int
                if writes then
                    put_int = checked(api.GetStaticMethodID(env, system, "putInt", "(Landroid/content/ContentResolver;Ljava/lang/String;I)Z"))
                    for _, item in ipairs(writes) do
                        local name = checked(api.NewStringUTF(env, item[1]), true)
                        local saved = api.CallStaticBooleanMethod(env, system, put_int, resolver, name, ffi.new("int32_t", item[2]))
                        checked(saved)
                        assert(tonumber(saved) == 1, "Android settings write was rejected")
                    end
                end
                local values = {}
                for _, key in ipairs({ "ColdValue", "WarmValue", "screen_brightness_cold", "screen_brightness_warm", "LightMode" }) do
                    local name = checked(api.NewStringUTF(env, key), true)
                    local v = api.CallStaticIntMethod(env, system, get_int, resolver, name, ffi.new("int32_t", -1))
                    checked(v)
                    values[key] = tonumber(v)
                end
                return values
            end)
            if api.ExceptionCheck(env) ~= 0 then api.ExceptionClear(env) end
            for n=#refs,1,-1 do pcall(api.DeleteLocalRef, env, refs[n]) end
            if not inner_ok then return false, tostring(values) end
            return values
        end)
        if not outer_ok then return nil, tostring(result) end
        return result or nil, failure
    end
    local function snapshot(values)
        if type(values) ~= "table" then return nil, "Cannot read Android light settings" end
        local cold, warm = index(values.ColdValue), index(values.WarmValue)
        if not cold or not warm or LEVELS[cold+1] ~= values.screen_brightness_cold
            or LEVELS[warm+1] ~= values.screen_brightness_warm then
            return nil, "Unknown or inconsistent OEM light scale; adjust Bigme's own sliders and restart"
        end
        return { cold=cold, warm=warm, mode=values.LightMode }
    end
    local values, read_error = settings()
    assert(values, read_error)
    local current, scale_error = snapshot(values)
    assert(current, scale_error)
    local status = { version=VERSION, profile=PROFILE, active=true, fault=nil }
    local busy = false
    local remembered
    local function valid_restore(v)
        return type(v) == "table" and v.profile == PROFILE and index(v.cold) and index(v.warm)
            and (v.cold > 0 or v.warm > 0)
    end
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local stored = G_reader_settings:readSetting("bigme_frontlight_restore")
        if valid_restore(stored) then remembered = {cold=stored.cold, warm=stored.warm} end
    end
    local function remember()
        if current.cold > 0 or current.warm > 0 then remembered={cold=current.cold, warm=current.warm} end
    end
    remember()
    local function publish()
        status.cold, status.warm = current.cold, current.warm
        powerd.fl_intensity, powerd.fl_warmth = current.cold, math.floor(current.warm * 100 / 36 + 0.5)
        powerd.is_fl_on = current.cold > 0 or current.warm > 0
    end
    local function fault(message)
        status.fault = tostring(message)
        warn(status.fault)
        return false
    end
    local function refresh()
        if not in_owner() then return false end -- no JNI/UI access in forked thumbnail workers
        if busy or status.fault then return not status.fault end
        local fresh, err = settings()
        if not fresh then return fault(err) end
        local updated, err = snapshot(fresh)
        if not updated then return fault(err) end
        current = updated
        publish()
        return true
    end
    local function native(channel, level)
        if not in_owner() then return nil, "Not the owning KOReader process" end
        local spec = assert(CHANNELS[channel], "Unknown light channel")
        assert(index(level), "Invalid native level")
        local fd, errno, operation, call_error
        local success, why = pcall(function()
            local argument = ffi.new("int32_t[1]", LEVELS[level+1])
            fd = open_device(PATH, 1)
            if fd < 0 then errno, operation, fd = ffi.errno(), "open", nil; return end
            local rc = ioctl(fd, spec.request, argument)
            if rc < 0 then errno, operation = ffi.errno(), "ioctl" end
        end)
        if not success then call_error = tostring(why) end
        if fd ~= nil then
            local closed, rc = pcall(close_device, fd)
            if not closed then call_error = tostring(rc)
            elseif rc < 0 then
                local close_errno = ffi.errno()
                call_error = "close errno=" .. tostring(close_errno)
            end
        end
        if errno then return nil, channel .. " " .. operation .. " errno=" .. tostring(errno) end
        if call_error then return nil, channel .. " " .. call_error end
        return true
    end
    local function set_channel(channel, level)
        if current[channel] == level then return true, false end
        local spec = CHANNELS[channel]
        local ok, err = native(channel, level)
        if not ok then return fault(err) end
        -- Hardware accepted the command. Cache that fact even if persistence
        -- fails; latch the error rather than silently falling back to Generic.
        current[channel] = level
        publish()
        local writes = {{spec.raw, LEVELS[level+1]}, {spec.index, level}}
        if current.mode == 4 then writes[#writes+1] = {spec.preset, level} end
        local updated, err = settings(writes)
        if not updated then return fault(err) end
        local verified, err = snapshot(updated)
        if not verified or verified[channel] ~= level then return fault(err or "OEM light settings did not retain the requested level") end
        if verified.cold ~= current.cold or verified.warm ~= current.warm then
            return fault("Light settings changed concurrently; use Bigme's panel and restart")
        end
        current = verified
        publish()
        return true, true
    end
    local function run(action, no_broadcast, callback)
        if not in_owner() or busy or status.fault or not refresh() then return false end
        busy = true
        local ok, accepted, changed = pcall(action)
        busy = false
        if not ok then return fault(accepted) end
        publish()
        if not accepted then return false end
        if changed and not no_broadcast then pcall(powerd.stateChanged, powerd) end
        if changed and callback then pcall(callback) end
        return changed == true
    end
    local methods = {}
    function methods:frontlightIntensity() refresh(); return current.cold end
    function methods:frontlightIntensityHW() return self:frontlightIntensity() end
    function methods:frontlightWarmth() refresh(); return math.floor(current.warm * 100 / 36 + 0.5) end
    function methods:frontlightWarmthHW() refresh(); return current.warm end
    function methods:toNativeWarmth(v) v=clamp(v,100); return v and math.floor(v*36/100+0.5) or 0 end
    function methods:fromNativeWarmth(v) v=clamp(v,36); return v and math.floor(v*100/36+0.5) or 0 end
    function methods:isFrontlightOn() refresh(); return current.cold > 0 or current.warm > 0 end
    function methods:isFrontlightOnHW() return self:isFrontlightOn() end
    function methods:setIntensity(v, no_broadcast)
        v=clamp(v,36); if not v then return false end
        return run(function()
            local ok, changed=set_channel("cold",v); if ok then remember() end; return ok,changed
        end, no_broadcast)
    end
    function methods:setWarmth(v)
        v=clamp(v,100); if not v then return false end
        local level=math.floor(v*36/100+0.5)
        return run(function()
            local ok, changed=set_channel("warm",level); if ok then remember() end; return ok,changed
        end)
    end
    function methods:setIntensityHW(v) return self:setIntensity(v,true) end
    function methods:setWarmthHW(v) v=clamp(v,36); return v and self:setWarmth(self:fromNativeWarmth(v)) or false end
    function methods:turnOffFrontlight(callback)
        return run(function()
            if current.cold == 0 and current.warm == 0 then return true,false end
            remember()
            assert(G_reader_settings and type(G_reader_settings.saveSetting) == "function", "Cannot remember light levels")
            -- Save BEFORE switching either channel off. This is the only patch
            -- setting, scoped to this firmware profile; no startup restoration.
            G_reader_settings:saveSetting("bigme_frontlight_restore", {profile=PROFILE,cold=remembered.cold,warm=remembered.warm})
            local stored = G_reader_settings:readSetting("bigme_frontlight_restore")
            assert(valid_restore(stored) and stored.cold == remembered.cold and stored.warm == remembered.warm,
                "Cannot verify saved light levels; not switching off")
            if not set_channel("cold",0) then return false end
            if not set_channel("warm",0) then return false end
            return true,true
        end, false, callback)
    end
    function methods:turnOnFrontlight(callback)
        return run(function()
            if current.cold > 0 or current.warm > 0 then return true,false end
            if not remembered then return fault("No previous light levels; set a level using Bigme's own panel first") end
            local target={cold=remembered.cold,warm=remembered.warm}
            if not set_channel("cold",target.cold) then return false end
            if not set_channel("warm",target.warm) then return false end
            remember()
            return true,true
        end, false, callback)
    end
    function methods:toggleFrontlight(callback)
        if self:isFrontlightOn() then return self:turnOffFrontlight(callback) end
        return self:turnOnFrontlight(callback)
    end
    function methods:turnOffFrontlightHW(callback) self:turnOffFrontlight(callback); return true end
    function methods:turnOnFrontlightHW(callback) self:turnOnFrontlight(callback); return true end

    -- Install only after every compatibility check and read has succeeded.
    -- No global Android bridge/class methods or unrelated device capabilities change.
    for name, implementation in pairs(methods) do powerd[name]=implementation end
    powerd.fl_min, powerd.fl_max = 0,36
    powerd.fl_warmth_min, powerd.fl_warmth_max, powerd.warmth_scale = 0,36,100/36
    powerd._bigme_lm3630a = status
    Device.hasFrontlight, Device.hasNaturalLight = function() return true end, function() return true end
    Device.hasNaturalLightMixer, Device.hasNaturalLightApi = function() return false end, function() return false end
    publish()
    powerd.fl_was_on = powerd.is_fl_on
    log("Enabled for " .. PROFILE .. "; startup performed no light command")
end)
if not installed then warn(setup_error) end
