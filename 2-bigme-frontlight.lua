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
-- Bigme LM3630A frontlight compatibility, v0.1.0-beta.3.
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

local VERSION = "0.1.0-beta.3"
local PROFILE = "hibreak_eea/mt6877/arm64/lm3630a-table80-v1"
local PATH = "/dev/lm3630a"
local LEVELS = { 0,2,20,30,40,50,60,70,80,90,102,108,114,120,126,132,138,144,150,
    156,162,168,174,180,188,192,198,204,206,208,210,212,214,216,218,220,222 }
local CHANNELS = {
    cold = { request=0x7901, index="ColdValue", raw="screen_brightness_cold", preset="LightUser_Brightness" },
    warm = { request=0x7902, index="WarmValue", raw="screen_brightness_warm", preset="LightUser_ColorTemp" },
}
local report_path, report_owner
local function log(message)
    local ok, logger = pcall(require, "logger")
    if ok and type(logger) == "table" and type(logger.info) == "function" then
        pcall(logger.info, "[Bigme frontlight " .. VERSION .. "] " .. tostring(message))
    end
    -- Bounded support trace (legacy filename retained for upgrade continuity);
    -- no books/account files are read, and child thumbnail workers cannot log.
    if report_path and report_owner and report_owner() then
        local file
        pcall(function()
            file = assert(io.open(report_path,"a"))
            local size=file:seek("end")
            if size and size < 262144 then
                file:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. " | " .. VERSION .. " | "
                    .. tostring(message):gsub("[%z\1-\31\127]"," "):sub(1,2048) .. "\n")
            end
        end)
        if file then pcall(file.close,file) end
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
        and "Bigme-ljusstyrning stoppades. Sluta justera ljuset här. Välj önskade nivåer i Bigmes egen ljusmeny och inaktivera ljuspatchen. Behåll bigme-frontlight-local-test.log. Ingen automatisk återställning eller behörighetsändring görs.\n\n"
        or "Bigme frontlight control stopped. Stop adjusting lights here. Set the desired levels using Bigme's own panel and disable this patch. Keep bigme-frontlight-local-test.log. No automatic restoration or permission change is made.\n\n"
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
    if powerd._bigme_lm3630a then
        assert(powerd._bigme_lm3630a.version==VERSION,"Another Bigme driver is already active; disable old copies and restart")
        return -- duplicate loading of this exact version must not wrap twice
    end
    assert(type(powerd.stateChanged) == "function" and type(powerd.updateResumeFrontlightState) == "function"
        and type(android.jni) == "table"
        and type(android.jni.context) == "function", "Missing KOReader API")
    local activity = assert(android.app and android.app.activity, "No Android activity")
    assert(activity.vm and activity.clazz, "Missing JNI activity handles")
    local DataStorage = require("datastorage")
    report_path = assert(DataStorage:getDataDir(),"No KOReader data directory") .. "/bigme-frontlight-local-test.log"
    report_owner = in_owner
    log("SESSION profile=" .. PROFILE .. "; no startup light command or Android settings write")
    for _,filename in ipairs({"2-bigme-frontlight-access-diagnostic.lua","2-bigme-frontlight-manual-test.lua",
        "2-bigme-frontlight-warm-test.lua","2-bigme-settings-readonly-diagnostic.lua",
        "2-bigme-settings-provider-test.lua","2-bigme-settings-provider-roundtrip.lua"}) do
        local other=io.open(DataStorage:getDataDir() .. "/patches/" .. filename,"rb")
        if other then other:close(); error("Disable earlier diagnostic patch before using driver: " .. filename,0) end
    end

    -- Checked public JNI calls. Read only permitted Settings.System indices;
    -- write only the six fixed light keys through the verified OEM provider.
    local function settings(writes)
        if not in_owner() then return nil, "Not the owning KOReader process" end
        local outer_ok, result, failure = pcall(android.jni.context, android.jni, activity.vm, function(jni)
            local env = jni.env
            local api, refs = env[0], {}
            local stage="JNI context"
            local function nonnull(v) return v ~= nil and v ~= ffi.NULL end
            local function keep(v) if nonnull(v) then refs[#refs+1]=v end; return v end
            local function clear_secondary()
                if api.ExceptionCheck(env) ~= 0 then api.ExceptionClear(env); return false end
                return true
            end
            local function exception_text()
                local throwable=keep(api.ExceptionOccurred(env)); api.ExceptionClear(env)
                if not nonnull(throwable) then return "Java exception (object unavailable)" end
                local chars, string_ref
                local formatted, value=pcall(function()
                    local cls=keep(api.GetObjectClass(env,throwable))
                    assert(clear_secondary() and nonnull(cls),"Throwable class unavailable")
                    local method=api.GetMethodID(env,cls,"toString","()Ljava/lang/String;")
                    assert(clear_secondary() and nonnull(method),"Throwable.toString unavailable")
                    string_ref=keep(api.CallObjectMethodA(env,throwable,method,nil))
                    assert(clear_secondary() and nonnull(string_ref),"Throwable string unavailable")
                    local length=tonumber(api.GetStringUTFLength(env,string_ref))
                    assert(clear_secondary() and length and length>=0,"Throwable UTF length unavailable")
                    chars=api.GetStringUTFChars(env,string_ref,nil)
                    assert(clear_secondary() and nonnull(chars),"Throwable UTF characters unavailable")
                    return ffi.string(chars,math.min(length,2048)):gsub("[%z\1-\31\127]"," ")
                end)
                if nonnull(chars) then pcall(api.ReleaseStringUTFChars,env,string_ref,chars) end
                clear_secondary()
                return formatted and value or ("Java exception; Throwable unavailable: " .. tostring(value))
            end
            local function step(name,fn,reference,nullable)
                assert(in_owner(),"Not the owning KOReader process")
                stage=name
                local value=fn()
                if reference then keep(value) end
                if api.ExceptionCheck(env) ~= 0 then error(exception_text(),0) end
                if not nullable then assert(nonnull(value),"Null Android API result") end
                return value
            end
            local function args(values)
                if #values==0 then return nil end
                local out=ffi.new("jvalue[?]",#values)
                for i,item in ipairs(values) do out[i-1][item[1]]=item[2] end
                return out
            end
            local function class(name)
                return step("FindClass("..name..")",function() return api.FindClass(env,name) end,true)
            end
            local function object_class(object)
                return step("GetObjectClass",function() return api.GetObjectClass(env,object) end,true)
            end
            local function method(cls,name,sig,static)
                return step("GetMethodID("..name..")",function()
                    if static then return api.GetStaticMethodID(env,cls,name,sig) end
                    return api.GetMethodID(env,cls,name,sig)
                end)
            end
            local function str(value)
                return step("NewStringUTF("..value..")",function() return api.NewStringUTF(env,value) end,true)
            end
            local function string_value(ref)
                if not nonnull(ref) then return nil end
                local chars
                local got,value=pcall(function()
                    local length=tonumber(step("GetStringUTFLength",function() return api.GetStringUTFLength(env,ref) end))
                    assert(length and length>=0 and length<=2048,"Unexpected provider metadata length")
                    step("GetStringUTFChars",function() chars=api.GetStringUTFChars(env,ref,nil); return chars end)
                    return ffi.string(chars,length)
                end)
                if nonnull(chars) then pcall(api.ReleaseStringUTFChars,env,ref,chars) end
                if not got then error(value,0) end
                return value
            end
            local inner_ok, values = pcall(function()
                if api.ExceptionCheck(env) ~= 0 then
                    stage="pre-existing Java exception"; error(exception_text(),0)
                end
                -- Never call the obsolete unchecked android.canWriteSettings().
                local system=class("android/provider/Settings$System")
                local can_write=method(system,"canWrite","(Landroid/content/Context;)Z",true)
                local allowed=step("Settings.System.canWrite",function()
                    return api.CallStaticBooleanMethodA(env,system,can_write,args({{"l",activity.clazz}}))
                end)
                assert(tonumber(allowed)==1,"WRITE_SETTINGS is required; no permission was requested or changed")
                local activity_cls=object_class(activity.clazz)
                local get_resolver=method(activity_cls,"getContentResolver","()Landroid/content/ContentResolver;")
                local resolver=step("Activity.getContentResolver",function()
                    return api.CallObjectMethodA(env,activity.clazz,get_resolver,nil)
                end,true)
                local get_int=method(system,"getInt","(Landroid/content/ContentResolver;Ljava/lang/String;I)I",true)
                local get_pm=method(activity_cls,"getPackageManager","()Landroid/content/pm/PackageManager;")
                local pm=step("Activity.getPackageManager",function() return api.CallObjectMethodA(env,activity.clazz,get_pm,nil) end,true)
                local resolve=method(object_class(pm),"resolveContentProvider","(Ljava/lang/String;I)Landroid/content/pm/ProviderInfo;")
                local authority=str("com.xrz.SettingProvider")
                local info=step("PackageManager.resolveContentProvider",function()
                    return api.CallObjectMethodA(env,pm,resolve,args({{"l",authority},{"i",0}}))
                end,true)
                local info_cls=object_class(info)
                local function field(obj,cls,name,sig,kind,nullable)
                    local id=step("GetFieldID("..name..")",function() return api.GetFieldID(env,cls,name,sig) end)
                    return step("GetField("..name..")",function()
                        if kind=="int" then return api.GetIntField(env,obj,id) end
                        if kind=="bool" then return api.GetBooleanField(env,obj,id) end
                        return api.GetObjectField(env,obj,id)
                    end,kind=="object",nullable)
                end
                local package=string_value(field(info,info_cls,"packageName","Ljava/lang/String;","object"))
                local name=string_value(field(info,info_cls,"name","Ljava/lang/String;","object"))
                local actual_authority=string_value(field(info,info_cls,"authority","Ljava/lang/String;","object"))
                assert(package=="com.xrz.settings" and name=="com.xrz.settings.provider.SettingProvider"
                    and actual_authority=="com.xrz.SettingProvider","Unexpected provider identity")
                assert(tonumber(field(info,info_cls,"exported","Z","bool"))==1
                    and tonumber(field(info,info_cls,"enabled","Z","bool"))==1,"Provider not exported/enabled")
                local app_info=field(info,info_cls,"applicationInfo","Landroid/content/pm/ApplicationInfo;","object")
                local flags=tonumber(field(app_info,object_class(app_info),"flags","I","int"))
                assert(flags and require("bit").band(flags,129)~=0,"Provider owner is not a system application")
                for _,key in ipairs({"readPermission","writePermission"}) do
                    local permission=string_value(field(info,info_cls,key,"Ljava/lang/String;","object",true))
                    if permission and permission~="" then
                        local check=method(activity_cls,"checkSelfPermission","(Ljava/lang/String;)I")
                        local permission_ref=str(permission)
                        local granted=tonumber(step("Activity.checkSelfPermission",function()
                            return api.CallIntMethodA(env,activity.clazz,check,args({{"l",permission_ref}}))
                        end))
                        assert(granted==0,"Provider permission not granted; no request or change made")
                    end
                end
                if writes then
                    local uri_cls=class("android/net/Uri")
                    local parse=method(uri_cls,"parse","(Ljava/lang/String;)Landroid/net/Uri;",true)
                    local uri_text=str("content://com.xrz.SettingProvider")
                    local uri=step("Uri.parse",function()
                        return api.CallStaticObjectMethodA(env,uri_cls,parse,args({{"l",uri_text}}))
                    end,true)
                    local bundle_cls=class("android/os/Bundle")
                    local constructor=method(bundle_cls,"<init>","()V")
                    local put_string=method(bundle_cls,"putString","(Ljava/lang/String;Ljava/lang/String;)V")
                    local put_int=method(bundle_cls,"putInt","(Ljava/lang/String;I)V")
                    local call=method(object_class(resolver),"call","(Landroid/net/Uri;Ljava/lang/String;Ljava/lang/String;Landroid/os/Bundle;)Landroid/os/Bundle;")
                    local call_method=str("setting_put_data_system")
                    local name_key,type_key,value_key=str("name"),str("type"),str("value")
                    local bundles,seen={},{}
                    for i,item in ipairs(writes) do
                        local key,level=item[1],item[2]
                        local raw=key==CHANNELS.cold.raw or key==CHANNELS.warm.raw
                        local readable=key==CHANNELS.cold.index or key==CHANNELS.warm.index
                            or key==CHANNELS.cold.preset or key==CHANNELS.warm.preset
                        assert((raw or readable) and not seen[key],"Forbidden or repeated settings write")
                        assert(type(level)=="number" and level==math.floor(level),"Noninteger settings write")
                        if raw then
                            local found=false
                            for _,v in ipairs(LEVELS) do if level==v then found=true; break end end
                            assert(found,"Raw value outside verified OEM table")
                        else assert(index(level),"Invalid readable level") end
                        seen[key]=true
                        local bundle=step("Bundle.<init>",function() return api.NewObjectA(env,bundle_cls,constructor,nil) end,true)
                        local key_ref=str(key)
                        step("Bundle.putString(name)",function()
                            api.CallVoidMethodA(env,bundle,put_string,args({{"l",name_key},{"l",key_ref}}))
                        end,false,true)
                        step("Bundle.putInt(type)",function()
                            api.CallVoidMethodA(env,bundle,put_int,args({{"l",type_key},{"i",1}}))
                        end,false,true)
                        step("Bundle.putInt(value)",function()
                            api.CallVoidMethodA(env,bundle,put_int,args({{"l",value_key},{"i",level}}))
                        end,false,true)
                        bundles[i]=bundle
                    end
                    -- All IDs/arguments are validated before any provider write.
                    for i,item in ipairs(writes) do
                        log("SYNC BEGIN provider "..item[1].."="..item[2])
                        local reply=step("ContentResolver.call("..item[1]..")",function()
                            return api.CallObjectMethodA(env,resolver,call,args({{"l",uri},{"l",call_method},{"l",ffi.NULL},{"l",bundles[i]}}))
                        end,true,true)
                        log("SYNC CALL RETURNED "..item[1].."="..item[2].." reply="..tostring(nonnull(reply)).."; not proof of persistence")
                    end
                end
                local values={}
                local function read(key)
                    local key_ref=str(key)
                    values[key]=tonumber(step("Settings.System.getInt("..key..")",function()
                        return api.CallStaticIntMethodA(env,system,get_int,args({{"l",resolver},{"l",key_ref},{"i",-1}}))
                    end))
                end
                -- Android denies raw-key reads. Do not infer a raw readback.
                for _,key in ipairs({"ColdValue","WarmValue","LightMode"}) do read(key) end
                if values.LightMode==4 then read("LightUser_Brightness"); read("LightUser_ColorTemp") end
                return values
            end)
            if api.ExceptionCheck(env) ~= 0 then api.ExceptionClear(env) end
            for n=#refs,1,-1 do pcall(api.DeleteLocalRef,env,refs[n]) end
            if api.ExceptionCheck(env) ~= 0 then api.ExceptionClear(env) end
            if not inner_ok then return false, stage..": "..tostring(values) end
            return values
        end)
        if not outer_ok then return nil,tostring(result) end
        return result or nil,failure
    end
    local function snapshot(values)
        if type(values) ~= "table" then return nil, "Cannot read Android light settings" end
        local cold, warm = index(values.ColdValue), index(values.WarmValue)
        if not cold or not warm then
            return nil, "Unknown OEM light level; adjust Bigme's own sliders and restart"
        end
        local mode=values.LightMode
        if type(mode)~="number" or mode~=math.floor(mode) or mode<0 or mode>4 then return nil,"Unknown OEM light mode" end
        if mode==4 and (not index(values.LightUser_Brightness) or not index(values.LightUser_ColorTemp)) then
            return nil,"Unknown custom-preset level"
        end
        return {cold=cold,warm=warm,mode=mode,preset_cold=values.LightUser_Brightness,preset_warm=values.LightUser_ColorTemp}
    end
    local values, read_error = settings()
    assert(values, read_error)
    local current, scale_error = snapshot(values)
    assert(current, scale_error)
    local status = { version=VERSION, profile=PROFILE, active=true, fault=nil,write_preflight=false,log_path=report_path,
        write_backend="oem-provider",raw_verified=false }
    local busy = false
    local preflight_mode
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
        log("HARDWARE BEGIN " .. channel .. " index=" .. level .. " raw=" .. LEVELS[level+1])
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
        log("HARDWARE ACCEPTED " .. channel .. " index=" .. level)
        return true
    end
    local function write_preflight()
        if preflight_mode==current.mode then return true end
        -- Only upon a requested change, never on startup/getters. Check all
        -- necessary writes with the CURRENT indices/presets before any ioctl.
        -- Raw keys are write-only here: accepted writes are not claimed to be
        -- raw readback or a physical light observation.
        log("PREFLIGHT BEGIN current cold=" .. current.cold .. " warm=" .. current.warm .. " mode=" .. current.mode)
        local writes={
            {CHANNELS.cold.raw,LEVELS[current.cold+1]}, {CHANNELS.warm.raw,LEVELS[current.warm+1]},
            {CHANNELS.cold.index,current.cold}, {CHANNELS.warm.index,current.warm},
        }
        if current.mode==4 then
            writes[#writes+1]={CHANNELS.cold.preset,current.preset_cold}
            writes[#writes+1]={CHANNELS.warm.preset,current.preset_warm}
        end
        local values,err=settings(writes)
        if not values then return fault("Write preflight failed before hardware: " .. tostring(err)) end
        local verified,why=snapshot(values)
        if not verified then return fault(why) end
        if verified.cold~=current.cold or verified.warm~=current.warm or verified.mode~=current.mode
            or verified.preset_cold~=current.preset_cold or verified.preset_warm~=current.preset_warm then
            return fault("Settings changed during write preflight; no hardware command sent")
        end
        preflight_mode=current.mode; status.write_preflight=true
        log("PREFLIGHT RETURNED; readable indices/presets match; raw persistence and physical result unverified")
        return true
    end
    local function set_channel(channel, level)
        if current[channel] == level then return true, false end
        if not write_preflight() then return false end
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
        if verified.mode ~= current.mode then return fault("Light mode changed concurrently; use Bigme's panel and restart") end
        if verified.mode==4 then
            local requested=channel=="cold" and verified.preset_cold or verified.preset_warm
            local untouched=channel=="cold" and verified.preset_warm or verified.preset_cold
            local previous=channel=="cold" and current.preset_warm or current.preset_cold
            if requested~=level or untouched~=previous then return fault("Custom-preset synchronization did not retain the requested level") end
        end
        current = verified
        publish()
        log("VERIFIED readable cold=" .. current.cold .. " warm=" .. current.warm .. " mode=" .. current.mode .. "; raw readback unavailable")
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
    log("READY cold=" .. current.cold .. " warm=" .. current.warm .. " mode=" .. current.mode .. "; raw readback disabled; startup performed no light command")
end)
if not installed then warn(setup_error) end
