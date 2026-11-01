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
local digests, source_by_file, tampered = {}, {}, false
for _, filename in ipairs({ "main", "bookorbit_api", "bookorbit_book_sync", "bookorbit_sweep",
        "bookorbit_main_menu", "bookorbit_sync_coordinator", "bookorbit_sync_job_runner",
        "bookorbit_lifecycle_outbox", "bookorbit_progress_sync", "bookorbit_menu_sheet" }) do
    local path = plugin_dir .. "/" .. filename .. ".lua"
    local f = io.open(path, "rb")
    if f then
        local source = f:read("*a"); f:close()
        local quoted_path = "'" .. path:gsub("'", "'\\''") .. "'"
        local command = "openssl dgst -md5 " .. quoted_path
        if filename == "main" then
            source = source:gsub('(local PLUGIN_VERSION = )"[^"\n]+"', '%1"<release>"', 1)
            command = [[sed -E 's/(local PLUGIN_VERSION = )"[^"]+"/\1"<release>"/' ]] .. quoted_path .. " | openssl dgst -md5"
        end
        local pipe = assert(io.popen(command))
        digests[source] = assert(pipe:read("*a"):match("= (%x+)"))
        source_by_file[filename] = source
        assert(pipe:close())
    else
        assert(filename == "bookorbit_menu_sheet", "missing " .. path)
    end
end
preload("ffi/sha2", { md5 = function(source) return not tampered and digests[source] or "changed" end })
local now, tasks, messages, errors, actions = 1800000000, {}, {}, {}, {}
os.time = function() return now end
local UIManager = {
    getElapsedTimeSinceBoot = function() return now end,
    scheduleIn = function(self, delay, fn) tasks[#tasks + 1] = { delay = delay, fn = fn } end,
    nextTick = function(self, fn) self:scheduleIn(0, fn) end,
    unschedule = noop, setDirty = noop, broadcastEvent = noop,
    show = function(self, widget) messages[#messages + 1] = widget end,
}
local connected = true
preload("ui/uimanager", UIManager)
preload("bookorbit_toast", {
    show = function(text) UIManager:show({ text = text }) end,
    error = function(text) UIManager:show({ text = text }) end,
})
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
local outbox = { nextEntry = noop, nextRetryAt = noop, diagnostics = function() return { count = 0 } end,
    enqueue = function() outbox_enqueues = outbox_enqueues + 1; return {} end }
preload("bookorbit_lifecycle_outbox", { open = function() return outbox end })
preload("bookorbit_stats_reader", { cachedIdentity = function() return {}, true end, primeIdentity = noop })
preload("bookorbit_state", { isMatchFresh = function() return true end })
preload("bookorbit_state_manager", { setAccount = noop, session = function() return { getBook = function() return {} end } end })
preload("bookorbit_board_metrics", { setUserScale = function(scale) return scale or 1.05 end })
local menuActions
if source_by_file.bookorbit_menu_sheet then menuActions = dofile("tests/bookorbit_undo_menu_mocks.lua") end
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
-- Every pinned file is checked, not only the version string or main module.
for filename, source in pairs(source_by_file) do
    local hash = digests[source]
    digests[source] = "changed"
    local compatible, reason = Opening.checkCompatibility(cls)
    assert(not compatible, "must reject changes to " .. filename)
    equal(reason, "untested " .. filename .. ".lua")
    digests[source] = hash
end
local api_source = source_by_file.bookorbit_api
local api_hash = digests[api_source]
digests[api_source] = source_by_file.bookorbit_menu_sheet and "bdeaeb095543878e2902e3ea8e7f9522" or "f6177967c71277b6467148cf567c0694"
assert(not Opening.checkCompatibility(cls), "must reject mixed files from otherwise tested releases")
digests[api_source] = api_hash
local io_open = io.open
io.open = function(path, mode)
    if path == plugin_dir .. "/main.lua" then
        return { read = function() return source_by_file.main:gsub('<release>', '99.0.0') end, close = noop }
    end
    return io_open(path, mode)
end
local version_only_ok = Opening.checkCompatibility(cls)
io.open = io_open
assert(version_only_ok, "version literal alone must not affect source fingerprints")
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
if app.dashboardMenuItems then
    local undo_items = 0
    for _, item in ipairs(app:dashboardMenuItems()) do if item.id == "undo_opening" then undo_items = undo_items + 1 end end
    equal(undo_items, 1, "dashboard exposes the same undo action")
end
if menuActions then
    assert(not package.loaded.bookorbit_menu_sheet, "new menu remains lazy until opened")
    local catalog = { current_context = {} }
    local sheet = app:openMenuSheet(catalog)
    local Sheet = require("bookorbit_menu_sheet")
    equal(sheet.sheet_data.ereader_undo.id, row.id)
    equal(sheet.sheet_data.ereader_undo.title, row.title)
    local function undoAction(d)
        local found, count = nil, 0
        for _, action in ipairs(menuActions(Sheet.body(d, 600))) do
            if action.kind == "ereader-undo-opening" then found, count = action, count + 1 end
        end
        equal(count, d.ereader_undo and 1 or 0, "only one eligible undo row")
        return found
    end
    local action = assert(undoAction(sheet.sheet_data))
    local popover_undo = 0
    for _, item in ipairs(menuActions(Sheet.body(sheet.sheet_data, 600, { popover = true, cols = 3 }))) do
        if item.kind == "ereader-undo-opening" then popover_undo = popover_undo + 1 end
    end
    equal(popover_undo, 1, "tablet and landscape popover also exposes undo")
    local short_screen_undo = 0
    for _, item in ipairs(menuActions(Sheet.body(sheet.sheet_data, 900, { popover = true, cols = 3, side_rows = true }))) do
        if item.kind == "ereader-undo-opening" then short_screen_undo = short_screen_undo + 1 end
    end
    equal(short_screen_undo, 1, "short landscape side-row layout also exposes undo")
    local data_hook = Sheet.data
    local fresh = newInstance(loadPlugin(), app.ui)
    fresh:openMenuSheet(catalog)
    equal(Sheet.data, data_hook, "new instances do not stack menu wrappers")
    undoAction(Sheet.data(app, catalog))
    local phase = row.phase
    row.phase = "done"
    equal(undoAction(Sheet.data(app, catalog)), nil, "committed opening has no undo row")
    local nmessages = #messages
    sheet.on_action(sheet, action)
    equal(#messages, nmessages, "stale eligibility cannot launch undo")
    assert(not sheet.closed)
    row.phase = phase
    local original_id = row.id
    row.id = "another-opening"
    sheet.on_action(sheet, action)
    equal(#messages, nmessages, "stale sheet never targets another opening")
    row.id = original_id
    local username = app.settings.username
    app.settings.username = "other-account"
    equal(Sheet.data(app, catalog).ereader_undo, nil, "menu is account scoped")
    sheet.on_action(sheet, action)
    equal(#messages, nmessages, "stale sheet never targets another account")
    app.settings.username = username
    sheet.on_action(sheet, action)
    assert(sheet.closed and messages[#messages].ok_callback, "sheet closes into ordinary undo confirmation")
    equal(row.phase, phase, "tapping row alone cannot reset data")
    -- Normal menu actions still run through the real upstream dispatcher.
    local searched = false
    catalog.onSearchButtonTap = function() searched = true end
    local ordinary = app:openMenuSheet(catalog)
    ordinary.on_action(ordinary, { kind = "search" })
    assert(ordinary.closed)
    tasks[#tasks].fn()
    assert(searched, "stock search action preserved")
end
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
if source_by_file.bookorbit_menu_sheet then
    assert(client:annotationPendingBooks({ row.digest }), "2.0 pending-annotation query is read-only and remains available")
end
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
equal(messages[#messages].text, source_by_file.bookorbit_menu_sheet and "A sync is already running" or "BookOrbit sync is already running.", "unheld sweeps reach stock code")
Sweep.running = false

-- Real stock lifecycle handlers must retain the opening through duplicate
-- readiness and a fresh reader/plugin after KOReader reloads the same cover.
app, row = open()
app:matchOpenBookForAutoSync()
local opening_id, opened_at, before_reload = row.id, row.opened_at, dump(row.before)
now = now + 10
app:onReaderReady()
equal(row.phase, "active", "duplicate stock ReaderReady does not commit")
equal(app.opening_session_id, opening_id)
equal(BookSync.capture(app), nil, "duplicate readiness retains the outbox hold")
ds:saveSetting("percent_finished", 0.01)
ds:saveSetting("last_page", 1)
app:onCloseDocument()
assert(row.closed_at and row.after_close)
local old_ui, reloaded_ui = app.ui, {}
for key, value in pairs(old_ui) do reloaded_ui[key] = value end
reloaded_ui.document = {file = row.file, info = {has_pages = true, number_of_pages = 269}}
old_ui.document = nil
now = now + 10
app = newInstance(loadPlugin(), reloaded_ui)
app:onDocSettingsLoad(ds)
ds:readSetting("summary").modified = "2026-11-02"
app:onReaderReady()
equal(Opening.record(app), row)
equal(row.phase, "active", "same cover reloaded in a new stock instance is still undoable")
equal(row.id, opening_id); equal(row.opened_at, opened_at)
equal(dump(row.before), before_reload)
equal(row.closed_at, nil); equal(row.after_close, nil)
equal(app.opening_session_id, opening_id)
app:matchOpenBookForAutoSync()
equal(#requests, 1, "reload never sends another opening or a commit")
equal(BookSync.capture(app), nil)
app:onSuspend()
equal(outbox_enqueues, 0, "reload cannot enqueue provisional progress")
assert(Opening.available(app) and Opening.held(app.settings, row.digest))
local reload_menu = {}
app:addToMainMenu(reload_menu)
equal(reload_menu.bookorbit.sub_item_table[1].id, "undo_opening")
if menuActions then
    local sheet = app:openMenuSheet({current_context = {}})
    equal(sheet.sheet_data.ereader_undo.id, opening_id, "stock sheet retains the undo row after reload")
end
app.ui.page = 2
app:onPageUpdate(2)
equal(row.phase, "done", "real page turn after reload still commits exactly once")
equal(#requests, 2); equal(requests[2].path, "/koreader/plugin/openings/commit")
equal(requests[2].body.id, opening_id)
equal(#errors, 0, dump(errors))

app, row = open()
local protected = row
app.ui.document = {file = "/books/other.epub", info = {has_pages = true}}
app:onDocSettingsLoad(ds)
app:onReaderReady()
equal(row.phase, "committing", "switching books still commits the previous opening")
equal(Opening.record(app), protected, "book switch cannot discard the previous operation")
equal(app.opening_session_id, nil)
app:requestOpeningSync()
equal(row.phase, "done")
equal(requests[1].path, "/koreader/plugin/openings")
equal(requests[2].path, "/koreader/plugin/openings/commit")
equal(#errors, 0, dump(errors))

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

if source_by_file.bookorbit_menu_sheet then
    -- 2.0 file-manager instances register their network handler during init.
    -- An offline opening closed in the reader must still recover there.
    row.phase = "committing"
    local old_ui = app.ui
    old_ui.document = nil
    local manager = newInstance(loadPlugin(), { menu = { registerToMainMenu = noop } })
    assert(not manager.in_reader and manager.onNetworkConnected, "file manager reconnect hook installed before init")
    manager:onNetworkConnected()
    equal(row.phase, "done", "file manager reconnect commits a persisted opening")
    assert(not manager:getSyncCoordinator():isBusy())

    -- The redesigned This book sheet asks for a quiet manual sync. It must
    -- commit the opening before book data runs, then reconcile progress AFTER
    -- book sync. Only the book-sync completion is stubbed in this scenario.
    app, row = open()
    local run = BookSync.run
    local synced, finished = 0, 0
    BookSync.run = function(opts)
        equal(row.phase, "done", "explicit manual sync commits first")
        equal(opts.skip_progress, true, "2.0 synchronizes book data before progress")
        equal(opts.quiet, true, "sheet quiet option preserved")
        equal(opts.snap.digest, row.digest)
        synced = synced + 1
        opts.on_finish()
        return true
    end
    app:onBookOrbitSyncBook({ quiet = true, on_done = function(err)
        equal(err, nil); finished = finished + 1
    end })
    BookSync.run = run
    equal(synced, 1); equal(finished, 1)
    equal(#errors, 0, dump(errors))
    equal(requests[1].path, "/koreader/plugin/openings")
    equal(requests[2].path, "/koreader/plugin/openings/commit")
    reply = function(method, path)
        if method == "GET" then return { percentage = 0.01, progress = "1" } end
        return {}
    end
    tasks[#tasks].fn()
    equal(requests[#requests].path, "/koreader/syncs/progress", "progress upload follows manual book sync")
    equal(app.progress_compared_digest, row.digest)
    assert(not app:getSyncCoordinator():isBusy())
    assert(not Opening.available(app))
end

if type(app.isSamePlace) == "function" then
    -- 2.1 carries copy-position compatibility through identity matching.
    -- That flag must survive the opening wrapper without releasing its hold.
    app, row = open()
    local State, Manager = require("bookorbit_state"), require("bookorbit_state_manager")
    local fresh, version, session, get_book = State.isMatchFresh, State.applyLibraryVersion, Manager.session, Manager.getBook
    local matched_copy
    State.isMatchFresh = function() return false end
    State.applyLibraryVersion = noop
    Manager.session = function() return {
        getBook = function() return matched_copy end, flush = noop,
        setMatched = function(_self, hash, file_id, book_id, file, library_version, position_compatible)
            equal(hash, row.digest)
            equal(position_compatible, false, "copy-position flag survives the matching wrapper")
            matched_copy = { positionIncompatible = not position_compatible }
        end,
    } end
    Manager.getBook = function() return matched_copy end
    reply = function(_method, path)
        if path == "/koreader/plugin/match-check" then
            return { matches = {{ hash = row.digest, bookFileId = 2, bookId = 1, positionCompatible = false }} }
        end
        return { phase = "active" }
    end
    local matched = false
    app:matchOpenBookForAutoSync(function(value) matched = value end)
    assert(matched and app:isOpenBookPositionIncompatible(row.digest))
    equal(row.phase, "active")
    assert(Opening.held(app.settings, row.digest))
    State.isMatchFresh, State.applyLibraryVersion, Manager.session, Manager.getBook = fresh, version, session, get_book

    -- 2.1's percentage fallback rounds to a page. If that moves the reader,
    -- the normal PageUpdate event must commit rather than leave undo enabled.
    app, row = open()
    app.ui.document.getPageCount = function() return 100 end
    app.ui.document.info.number_of_pages = 100
    app.ui.rolling = { view = { view_mode = "page" } }
    assert(app:isSamePlace({ percentage = 0.50 }, 0.505, "different-copy"))
    assert(not app:isSamePlace({ percentage = 0.50 }, 0.52, "different-copy"))
    equal(row.phase, "candidate", "comparing places alone does not commit")
    local event
    app.ui.handleEvent = function(self, value)
        event = value
        self.page = value.payload
        app:onPageUpdate(self.page)
    end
    app:syncToProgress(nil, 0.4249)
    equal(event.name, "GotoPage"); equal(event.payload, 42)
    equal(row.phase, "done", "moving to the remote page commits the opening")
    assert(not Opening.available(app))
    equal(requests[#requests].path, "/koreader/plugin/openings/commit")

    -- The new unmatched-outbox cleanup may remove that queue entry only.
    -- A different provisional opening must stay protected and undoable.
    app, row = open()
    app:matchOpenBookForAutoSync()
    local entry = { id = "unmatched-entry", generation = 1,
        snapshot = { digest = string.rep("b", 32), file = "/books/unknown.epub", title = "Unknown book" } }
    local removed = 0
    app.lifecycle_outbox = {
        nextEntry = function() return entry end, readLatest = function() return entry end,
        markStarted = function() return entry end, isComplete = function() return false end,
        nextRetryAt = noop,
        removeEntry = function(_self, id)
            equal(id, "unmatched-entry"); removed = removed + 1; entry = nil
        end,
    }
    app.settings.last_error = { event = "lifecycle_outbox", code = "outbox_blocked" }
    local run = BookSync.run
    Manager.getBook = noop
    BookSync.run = function(opts)
        equal(opts.snap.digest, string.rep("b", 32))
        equal(row.phase, "active")
        opts.on_finish("unmatched")
        return true
    end
    tasks = {}
    app:requestLifecycleOutboxDrain("recovery")
    table.remove(tasks, 1).fn()
    BookSync.run, Manager.getBook = run, get_book
    equal(removed, 1)
    equal(app.settings.last_error, nil)
    equal(row.phase, "active", "unmatched cleanup cannot commit another opening")
    assert(Opening.available(app) and Opening.held(app.settings, row.digest))
    assert(not app:getSyncCoordinator():isBusy())
    equal(#errors, 0, dump(errors))
end

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
