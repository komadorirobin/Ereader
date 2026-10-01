-- Loads the unmodified BookOrbit plugin. Storage, transport and KOReader UI are fake.
local plugin_dir = assert(arg[1], "usage: luajit tests/bookorbit_undo_patch_test.lua PLUGIN_DIR")
package.path = plugin_dir .. "/?.lua;" .. package.path
local function noop() end
local function equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function object(methods)
    local cls = methods or {}
    cls.__index = cls
    function cls:new(attrs) return setmetatable(attrs or {}, self) end
    return cls
end
local function preload(name, value) package.preload[name] = function() return value end end
local function settings(data)
    return {
        data = data or {},
        readSetting = function(self, key, default) local v = self.data[key]; if v == nil then return default end; return v end,
        saveSetting = function(self, key, value) self.data[key] = value end,
        delSetting = function(self, key) self.data[key] = nil end,
        isTrue = function(self, key) return self.data[key] == true end,
        flush = noop,
    }
end
local function dump(value)
    if type(value) ~= "table" then return tostring(value) end
    local keys, parts = {}, {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. dump(value[key]) end
    return table.concat(parts, ";")
end

-- Real hashes of real source, rather than accepting any source in the mock.
local digests, tampered = {}, false
for _, filename in ipairs({ "main", "bookorbit_api", "bookorbit_book_sync", "bookorbit_sweep",
        "bookorbit_main_menu", "bookorbit_sync_coordinator", "bookorbit_sync_job_runner",
        "bookorbit_lifecycle_outbox", "bookorbit_progress_sync" }) do
    local path = plugin_dir .. "/" .. filename .. ".lua"
    local f = assert(io.open(path, "rb"))
    local source = f:read("*a"); f:close()
    local quoted_path = "'" .. path:gsub("'", "'\\''") .. "'"
    local command = "openssl dgst -md5 " .. quoted_path
    if filename == "main" then
        source = source:gsub('(local PLUGIN_VERSION = )"[^"\n]+"', '%1"<release>"', 1)
        command = [[sed -E 's/(local PLUGIN_VERSION = )"[^"]+"/\1"<release>"/' ]] .. quoted_path .. " | openssl dgst -md5"
    end
    local pipe = assert(io.popen(command))
    digests[source] = assert(pipe:read("*a"):match("= (%x+)"))
    assert(pipe:close())
end
preload("ffi/sha2", { md5 = function(source) return not tampered and digests[source] or "changed" end })
local now, tasks, messages, errors, actions = 1800000000, {}, {}, {}, {}
os.time = function() return now end
local UIManager = {
    scheduleIn = function(self, delay, fn) tasks[#tasks + 1] = { delay = delay, fn = fn } end,
    nextTick = function(self, fn) self:scheduleIn(0, fn) end,
    unschedule = noop, setDirty = noop, broadcastEvent = noop,
    show = function(self, widget) messages[#messages + 1] = widget end,
}
local connected = true
preload("ui/uimanager", UIManager)
preload("ui/network/manager", {
    isConnected = function() return connected end,
    willRerunWhenConnected = function() return not connected end,
})
preload("ui/trapper", { wrap = function(self, fn) fn() end, isWrapped = function() return false end })
preload("logger", { dbg = noop, info = noop, warn = noop, err = function(...) errors[#errors + 1] = {...} end })
preload("device", { model = "mock", hasSeamlessWifiToggle = function() return false end, hasWifiRestore = function() return false end })
preload("dispatcher", { registerAction = function(self, name, action) actions[name] = action end })
preload("gettext", function(s) return s end)
preload("dump", dump)
preload("ffi/util", { template = function(s) return s end })
preload("ui/time", { now = function() return now end, s = function(n) return n end })
preload("optmath", { roundPercent = function(n) return n end })
preload("libs/libkoreader-lfs", { attributes = function() return nil end })
preload("datastorage", { getSettingsDir = function() return "/mock" end })
preload("util", { trim = function(s) return s end, fixUtf8 = function(s) return s end })
preload("ui/event", { new = function(self, name, payload) return { name = name, payload = payload } end })
for _, name in ipairs({ "infomessage", "notification", "confirmbox", "buttondialog", "inputdialog", "multiinputdialog" }) do
    preload("ui/widget/" .. name, object({ notify = noop }))
end
preload("ui/widget/booklist", { setBookInfoCacheProperty = noop })
for _, name in ipairs({ "socket", "socket.http", "socketutil", "ltn12", "rapidjson", "pluginshare",
        "bookorbit_annotations", "bookorbit_bookmarks", "bookorbit_catalog", "bookorbit_highlight_summary",
        "bookorbit_menu_pin", "bookorbit_open_annotation_scheduler", "bookorbit_transfer_policy",
        "bookorbit_transfer_progress", "bookorbit_proxy", "bookorbit_download_transfer",
        "bookorbit_highlight_diagnostics" }) do
    preload(name, {})
end
local outbox_enqueues = 0
local outbox = { nextEntry = noop, enqueue = function() outbox_enqueues = outbox_enqueues + 1; return {} end }
preload("bookorbit_lifecycle_outbox", { open = function() return outbox end })
preload("bookorbit_stats_reader", { cachedIdentity = function() return {}, true end, primeIdentity = noop })
preload("bookorbit_state", { isMatchFresh = function() return true end })
preload("bookorbit_state_manager", { session = function() return { getBook = function() return {} end } end })
local ds
preload("docsettings", { open = function() return ds end, getSidecarDir = function() return "/mock" end, findSidecarFile = noop })
local history = { hist = {}, getIndexByFile = noop, removeItemByPath = noop, addItem = noop }
preload("readhistory", history)
local WidgetContainer = object()
function WidgetContainer:extend(attrs)
    attrs.__index = attrs
    setmetatable(attrs, { __index = self })
    function attrs:new(o) setmetatable(o, self); o:init(); return o end
    return attrs
end
preload("ui/widget/container/widgetcontainer", WidgetContainer)
local creates = 0
local PluginLoader = { createPluginInstance = function(self, cls, attrs)
    creates = creates + 1
    return pcall(cls.new, cls, attrs)
end }
preload("pluginloader", PluginLoader)
local Opening = dofile("2-bookorbit-undo-opening.lua")
assert(not package.loaded.bookorbit_api, "patch loading must not load a disabled plugin")

local function loadPlugin()
    local cls = assert(loadfile(plugin_dir .. "/main.lua"))()
    cls.path = plugin_dir
    -- KOReader sandboxes event handlers into callable tables before the factory.
    for name, method in pairs(cls) do
        if name:match("^on") and type(method) == "function" then
            cls[name] = setmetatable({}, { __call = function(_sandbox, ...) return method(...) end })
        end
    end
    return cls
end
local cls = loadPlugin()
local Api, BookSync, Sweep = require("bookorbit_api"), require("bookorbit_book_sync"), require("bookorbit_sweep")
Api.canForkSubprocess = function() return false end
local requests, reply = {}, nil
Api.requestBlocking = function(self, method, path, body)
    requests[#requests + 1] = { method = method, path = path, body = body }
    if reply then return reply(method, path, body) end
    return { phase = path:match("/commit$") and "committed" or "active" }
end
local function reset()
    tasks, messages, requests, reply, errors, outbox_enqueues = {}, {}, {}, nil, {}, 0
    G_reader_settings = settings({ device_id = "test-device", bookorbit = {
        server_url = "https://example.test/api/v1", username = "user", userkey = "fake",
        settings_version = 1, auto_sync = true, annotation_sync = false, pages_before_update = 10,
        catalog_auto_open = "off", update_check_last_at = now,
    } })
    ds = settings({ summary = { rating = 4 }, partial_md5_checksum = string.rep("a", 32) })
    return {
        document = { file = "/books/test.epub", info = { has_pages = true } }, doc_settings = ds,
        annotation = { annotations = {} }, page = 1,
        menu = { registerToMainMenu = noop },
        getCurrentPage = function(self) return self.page end,
        paging = { getLastPercent = function() return 0.01 end, getLastProgress = function() return "1" end },
    }
end
local function newInstance(class, ui)
    local ok, result = PluginLoader:createPluginInstance(class or cls, { ui = ui or reset() })
    assert(ok, tostring(result))
    return result
end
local function open()
    local ui = reset()
    local app = newInstance(cls, ui)
    app:onDocSettingsLoad(ds)
    ds:readSetting("summary").status = "reading"
    app:onReaderReady()
    return app, assert(Opening.record(app))
end

assert(Opening.checkCompatibility(cls))
cls.PLUGIN_VERSION = "1.5.6"
assert(Opening.checkCompatibility(cls), "a release number alone must not disable a compatible plugin")
cls.PLUGIN_VERSION = "1.5.5"
tampered = true
assert(not Opening.checkCompatibility(cls), "same version with modified source must not be accepted")
tampered = false
local orig_method = cls._onPageUpdate
cls._onPageUpdate = nil
assert(not Opening.checkCompatibility(cls))
cls._onPageUpdate = orig_method
local app, row = open()
equal(actions.bookorbit_undo_opening.event, "BookOrbitUndoOpening", "action installed before init")
assert(actions.bookorbit_sync_now, "stock actions preserved")
equal(app.onPageUpdate, cls._onPageUpdate, "bound handler uses patched function")
equal(row.before.status, nil, "snapshot predates automatic reading status")
local count = creates
local request_hook = Api.request
newInstance(cls, app.ui)
equal(creates, count + 1)
equal(Api.request, request_hook, "shared wrappers installed only once")
newInstance(loadPlugin(), app.ui)
equal(Api.request, request_hook, "fresh class must not stack shared API wrappers")

local menu = {}
app:addToMainMenu(menu)
equal(menu.bookorbit.sub_item_table[1].id, "undo_opening")
local undo_items = 0
for _, item in ipairs(app:dashboardMenuItems()) do if item.id == "undo_opening" then undo_items = undo_items + 1 end end
equal(undo_items, 1, "dashboard exposes the same undo action")
app:matchOpenBookForAutoSync() -- callback is optional in the stock API.
equal(requests[1].path, "/koreader/plugin/openings")
equal(row.phase, "active")
local callback_called = false
app:matchOpenBookForAutoSync(function(matched) callback_called = matched end)
assert(callback_called)
equal(#requests, 1, "matching again reuses the opening")

local client = app:newClient()
local _, err = client:request("PUT", "/koreader/syncs/progress", { document = row.digest })
equal(err, "opening_held")
_, err = client:request("POST", "/koreader/plugin/book-states", { books = {{ hash = row.digest }} })
equal(err, "opening_held")
_, err = client:uploadPageStats({{ hash = row.digest, events = {{ startTime = now }} }})
equal(err, "opening_held")
equal(#requests, 1, "protected writes never reach transport")
assert(client:request("GET", "/koreader/syncs/progress/" .. row.digest))
assert(client:request("PUT", "/koreader/syncs/progress", { document = "another-book" }))
assert(client:request("POST", "/koreader/plugin/match-check", { books = {{ hash = row.digest }} }))
equal(#requests, 4, "reads, identity matching, and other books continue normally")
equal(BookSync.capture(app), nil)
app:onSuspend()
equal(outbox_enqueues, 0, "suspend cannot queue a provisional reading")
app:requestSweep(true, "manual")
equal(messages[#messages].text, "Undo the accidental opening, or continue reading it, before syncing the whole library.")
assert(not app:getSyncCoordinator():isBusy(), "refused sweep releases coordinator")

local original_run, jobs_ran = nil, 0
local job = { family = "progress_push", run = function() jobs_ran = jobs_ran + 1 end }
original_run = job.run
app:submitSyncJob(job)
equal(job.run, original_run, "patch does not mutate caller's write job")
equal(job.async, nil)
equal(jobs_ran, 1)
equal(#errors, 0)
app.ui.page = 2
app:onPageUpdate(2)
equal(row.phase, "done", "first page turn commits through the real coordinator")
equal(requests[#requests].path, "/koreader/plugin/openings/commit")
assert(not app:getSyncCoordinator():isBusy())
assert(BookSync.capture(app), "ordinary snapshot capture resumes after commit")
Sweep.running = true
equal(Sweep.run({ api = app:apiOpts(), interactive = true }), false)
equal(messages[#messages].text, "BookOrbit sync is already running.", "unheld sweeps reach stock code")
Sweep.running = false

-- The actual menu confirmation uses the stock coordinator, closes before restore,
-- and must not leave a close/suspend snapshot that could recreate the reading.
app, row = open()
app:matchOpenBookForAutoSync()
local closed, filemanager_shown = 0, 0
app.ui.onClose = function(self)
    closed = closed + 1
    ds:saveSetting("percent_finished", 0.01)
    ds:saveSetting("last_page", self.page)
    app:onCloseDocument()
    self.document = nil
end
app.ui.showFileManager = function() filemanager_shown = filemanager_shown + 1 end
reply = function(method, path, body)
    equal(path, "/koreader/plugin/openings/undo")
    equal(body.id, row.id)
    return { phase = "undone", hardcoverPending = false }
end
app:onBookOrbitUndoOpening()
assert(messages[#messages].ok_callback, "gesture/menu must ask for confirmation")
equal(row.phase, "active", "showing confirmation is not itself an undo")
messages[#messages].ok_callback()
equal(#errors, 0, dump(errors))
equal(row.phase, "undone")
equal(closed, 1); equal(filemanager_shown, 1)
equal(ds:readSetting("summary").status, "new")
equal(ds:readSetting("summary").rating, 4)
equal(ds:readSetting("percent_finished"), nil)
equal(outbox_enqueues, 0, "undo close must never queue stale progress")
assert(not app:getSyncCoordinator():isBusy(), "undo completes its coordinator job")
equal(#errors, 0, "undo errors must not be swallowed by the runner")

app, row = open()
connected = false
app.ui.page = 2
app:onPageUpdate(2)
equal(row.phase, "committing")
equal(#requests, 0, "offline page turn must not attempt network")
connected = true
app:onNetworkConnected()
equal(row.phase, "done", "network reconnect reconciles held opening")
equal(#requests, 2)
app, row = open()
app:onCloseDocument()
assert(row.after_close and row.closed_at)
equal(outbox_enqueues, 0, "close cannot queue a provisional reading")

-- Excluded intervals survive restart and are isolated by book AND account.
row.phase = "undone"
local account = Opening.account(app.settings)
account.ignored_stats[row.digest] = {{ 10, 20 }}
client = app:newClient()
local batch = {
    { hash = row.digest, events = {{ startTime = 9 }, { startTime = 10 }, { startTime = 20 }, { startTime = 21 }} },
    { hash = "other", events = {{ startTime = 15 }} },
}
reply = function(method, path, body)
    equal(path, "/koreader/plugin/page-stats")
    equal(#body.books[1].events, 2)
    equal(#body.books[2].events, 1)
    return { results = {{ hash = row.digest, watermark = 21 }, { hash = "other", watermark = 15 }} }
end
local result = assert(client:uploadPageStats(batch))
equal(result.results[1].watermark, 21)
equal(#batch[1].events, 4, "caller's statistics remain unchanged")
reply = function() return nil, 503, { reason = "unavailable" } end
local failed, code, detail = client:uploadPageStats(batch)
equal(failed, nil); equal(code, 503); equal(detail.reason, "unavailable")
reply = function() return { results = {{ hash = "other", watermark = 15 }} } end
result = client:uploadPageStats(batch)
equal(#result.results, 1, "missing server acknowledgement must never skip submitted real events")
local before = #requests
result = client:uploadPageStats({{ hash = row.digest, events = {{ startTime = 10 }, { startTime = 20 }} }})
equal(result.results[1].watermark, 20, "locally excluded-only batch acknowledged without transport")
equal(#requests, before)
local other = Api.new({ server_url = client.server_url, username = "another-user" })
local filtered = Opening.filterStats(other, batch)
equal(#filtered[1].events, 4, "excluded stats never leak between accounts")

-- Unknown versions may run normally only before any protected data exists.
local unknown = loadPlugin()
unknown.PLUGIN_VERSION = "9.0.0"
unknown._onPageUpdate = nil
count = creates
local ok = PluginLoader:createPluginInstance(unknown, { ui = app.ui })
equal(ok, false)
equal(creates, count, "excluded stats block unknown plugin BEFORE init")
local ui = reset()
local plain = newInstance(unknown, ui)
equal(plain.onBookOrbitUndoOpening, nil, "unknown clean plugin has no partial undo hooks")
assert(plain:isLoggedIn(), "ordinary sync stays available when there is nothing to protect")
G_reader_settings:saveSetting("bookorbit_openings", { old_account = { ignored_stats = {}, opening = { phase = "undo_pending" } } })
count = creates
equal(PluginLoader:createPluginInstance(unknown, { ui = ui }), false)
equal(creates, count, "a pending undo in another account is also protected before provisioning")
G_reader_settings:saveSetting("bookorbit_openings", "corrupt")
equal(PluginLoader:createPluginInstance(unknown, { ui = ui }), false, "unreadable saved state fails closed")
equal(PluginLoader:createPluginInstance(cls, { ui = ui }), false, "known plugin also stops on corrupt saved state")
local unrelated = { name = "other", new = function(self, attrs) return attrs end }
local attrs = { sentinel = true }
local unrelated_ok, unrelated_instance = PluginLoader:createPluginInstance(unrelated, attrs)
assert(unrelated_ok and unrelated_instance == attrs, "other plugins are never gated")
equal(#errors, 0, "no job errors swallowed by stock runner")
print("bookorbit_undo_patch_test.lua: ok (stock source, callable events, queues, transport, compatibility)")
