-- Run against an unpacked Hardcover plugin. All storage, UI and API access is mocked.
local plugin_dir = assert(arg[1], "usage: luajit tests/hardcover_bookorbit_sync_test.lua PLUGIN_DIR")
package.path = plugin_dir .. "/?.lua;" .. package.path
table.unpack = table.unpack or unpack
table.pack = table.pack or function(...) return { n = select("#", ...), ... } end

local function preload(name, value)
    package.preload[name] = function() return value end
end
local function noop() end
local function object(methods)
    local cls = methods or {}
    cls.__index = cls
    function cls:new(attrs) return setmetatable(attrs or {}, self) end
    return cls
end

local now, tasks, messages = 0, {}, {}
local UIManager = {}
function UIManager:scheduleIn(delay, fn, ...)
    tasks[#tasks + 1] = { at = now + delay, fn = fn, args = table.pack(...) }
end
function UIManager:unschedule(fn)
    for i = #tasks, 1, -1 do
        if tasks[i].fn == fn then table.remove(tasks, i) end
    end
end
function UIManager:nextTick(fn) self:scheduleIn(0, fn) end
function UIManager:show(widget) messages[#messages + 1] = widget end
local function advance(seconds)
    local deadline, iterations = now + seconds, 0
    while true do
        table.sort(tasks, function(a, b) return a.at < b.at end)
        if not tasks[1] or tasks[1].at > deadline then break end
        local task = table.remove(tasks, 1)
        now = task.at
        task.fn(table.unpack(task.args, 1, task.args.n))
        iterations = iterations + 1
        assert(iterations < 100, "unexpected repeating task")
    end
    now = deadline
end

local file = "/books/example.epub"
local saved = {
    always_sync = true,
    auto_status_reading = true,
    link_by_hardcover = true,
    track_method = "frequency",
    track_frequency = 1,
    books = {
        [file] = { book_id = 10, edition_id = 20, pages = 100, sync = true },
        ["/books/explicit-off.epub"] = { book_id = 11, sync = false },
        ["/books/default.epub"] = { book_id = 12 },
    },
}
local flushes = 0
local storage = {}
function storage:readSetting(key, default)
    if saved[key] == nil then return default end
    return saved[key]
end
function storage:saveSetting(key, value) saved[key] = value end
function storage:flush() flushes = flushes + 1 end
preload("luasettings", { open = function() return storage end })
preload("version", { getNormalizedCurrentVersion = function() return 202600000000 end })
preload("gettext", function(s) return s end)
preload("datastorage", { getSettingsDir = function() return "/mock/settings" end })
preload("dispatcher", { registerAction = noop })
preload("logger", { warn = noop, err = noop, dbg = noop, info = noop })
preload("util", {})
preload("device", { hasWifiRestore = function() return true end })
preload("ffi/util", { template = function(s) return s end })
preload("ui/font", {})
preload("ui/time", { now = function() return now end })
preload("ui/uimanager", UIManager)
preload("ui/trapper", { wrap = function(self, fn) return fn() end })
preload("ui/network/manager", { isConnected = function() return true end })
preload("ui/widget/infomessage", object())
preload("ui/widget/notification", object())
preload("ui/widget/spinwidget", object())
preload("hardcover/lib/ui/update_double_spin_widget", object())
preload("hardcover/lib/ui/dialog_manager", object())
preload("hardcover/lib/github", object())
preload("hardcover/lib/auto_wifi", object({
    withWifi = function(self, fn) fn(); return true end,
}))
preload("hardcover/lib/page_mapper", object({
    cachePageMap = noop,
    getMappedPage = function(self, page) return page end,
    getRemotePagePercent = function(self, page) return page / 100, page end,
}))
preload("hardcover/lib/scheduler", {
    clear = noop,
    withRetries = function(self, attempts, interval, work, done)
        work(done, function() error("unexpected retry") end)
        return noop
    end,
})
preload("hardcover/lib/user", { getId = function() return 7 end })

local WidgetContainer = object()
function WidgetContainer:extend(attrs)
    attrs.__index = attrs
    setmetatable(attrs, { __index = self })
    function attrs:new(o)
        setmetatable(o, self)
        o:init()
        return o
    end
    return attrs
end
preload("ui/widget/container/widgetcontainer", WidgetContainer)

local remote = {
    id = 30, book_id = 10, edition_id = 20, status_id = 2, privacy_setting_id = 1,
    user_book_reads = { { id = 40, edition_id = 20, started_at = "2026-09-10" } },
}
local writes, reads = {}, 0
local Api = {}
function Api:findUserBook() reads = reads + 1; return remote end
function Api:updateUserBook(...)
    writes[#writes + 1] = { kind = "status", args = { ... } }
    return remote
end
function Api:updatePage(...)
    writes[#writes + 1] = { kind = "progress", args = { ... } }
    return remote
end
function Api:query() reads = reads + 1; return { data = "metadata" } end
function Api:findBookByIdentifiers()
    reads = reads + 1
    return { book_id = 10, edition_id = 21, pages = 150, title = "Linked edition", reading_format_id = 4 }
end
preload("hardcover/lib/hardcover_api", Api)
local summary = { status = "complete" }
preload("docsettings", {
    hasSidecarFile = function() return true end,
    open = function() return { readSetting = function() return summary end } end,
})
G_reader_settings = {
    isTrue = function() return false end,
    readSetting = function(self, key) if key == "end_document_action" then return "pop-up" end end,
}

local callbacks = {}
preload("userpatch", {
    registerPatchPluginFunc = function(name, callback) callbacks[name] = callback end,
})
dofile("2-hardcover-bookorbit-sync.lua")
assert(callbacks.hardcoverapp, "must use the directory name used by PluginLoader")
assert(not package.loaded["hardcover/lib/hardcover_settings"], "disabled plugin must not be loaded")
assert(not package.loaded["hardcover/lib/hardcover_api"], "patch registration must not load API/token")
print("PASS: lazy registration, safe with Hardcover absent/disabled")

local function newApp(patched, file_manager)
    local cls = assert(loadfile(plugin_dir .. "/main.lua"))()
    local ui = {
        document = {
            file = file,
            getPageCount = function() return 100 end,
            getProps = function() return { identifiers = "hardcover-edition:21" } end,
        },
        getCurrentPage = function() return 100 end,
        menu = { registerToMainMenu = noop },
        highlight = { removeFromHighlightDialog = noop, addToHighlightDialog = noop },
    }
    if file_manager then ui.document = nil end
    local app = cls:new{ ui = ui }
    app.state.book_status = remote
    app.state.page = 100
    -- Match userpatch: callback receives the CLASS, after creating its instance.
    if patched then callbacks.hardcoverapp(cls) end
    return app
end

local baseline = newApp(false)
baseline:onEndOfBook()
if baseline.onDocSettingsItemsChanged then
    baseline:onDocSettingsItemsChanged(file, { summary = summary })
end
baseline:onDocumentClose()
advance(31)
assert(#writes > 0, "baseline must exercise real plugin completion writes")
print("PASS: unpatched completion flow sends " .. #writes .. " status update(s)")

writes, tasks = {}, {}
local app = newApp(true)
local Settings = require("hardcover/lib/hardcover_settings")
local saved_flushes = flushes
assert(not app.settings:syncEnabled())
for path in pairs(saved.books) do assert(not app.settings:fileSyncEnabled(path)) end
assert(not Settings:fileSyncEnabled(nil))
app.settings:setSync(true)
app.settings:setSync(false)
assert(saved.always_sync and saved.books[file].sync, "saved preferences must remain untouched")
assert(flushes == saved_flushes, "patch must not rewrite tracking settings")
print("PASS: global guard overrides existing/default tracking without changing preferences")

app:onReaderReady()
app:onPageUpdate(100)
app:pageUpdateEvent(100)
app:_handlePageUpdate(file, 100, true)
app:_throttledHandlePageUpdate(file, 100) -- captured before the patch callback
app:updatePageNow()
assert(app:onEndOfBook() == nil, "must not consume other plugins' end-of-book events")
if app.onDocSettingsItemsChanged then
    app:onDocSettingsItemsChanged(file, { summary = summary })
    app:onDocSettingsItemsChanged(file, { summary = { status = "reading" } })
end
app:onDocumentClose()
advance(120)
assert(#writes == 0, "end/mark-read/close/delayed tasks must not send reading updates")
print("PASS: page updates, final-page dialog, mark-read, close and deferred callbacks send no writes")

-- Progress-percentage tracking and auto-marking must be blocked too.
saved.track_method = "progress"
app.state.book_status, app.state.page, app.state.process_page_turns = remote, 90, true
app:onPosUpdate(nil, 100)
G_reader_settings.isTrue = function() return true end
app:onEndOfBook()
G_reader_settings.isTrue = function() return false end
app:onHardcoverTrack()
app:onHardcoverUpdateProgress()
app:onSuspend()
app:onResume()
app:onNetworkConnected()
advance(120)
assert(#writes == 0)
print("PASS: percentage tracking, auto-mark, track gesture and resume cannot bypass the guard")

local menu = app.menu:getSubMenuItems(true)
assert(menu[1].text == "Automatic reading sync: BookOrbit")
for _, items in ipairs({ menu, app.menu:getSettingsSubMenuItems() }) do
    for _, item in ipairs(items) do
        if item.text == "Automatically track progress"
                or item.text == "Always track progress by default"
                or item.text == "Automatically set status to Currently Reading" then
            assert(item.checked_func() == false and item.enabled_func() == false)
            assert(item.callback == nil)
        end
    end
end
print("PASS: menu explains sync ownership and disables automatic tracking controls")

local prev_reads = reads
assert(Api:query().data == "metadata")
assert(reads > prev_reads, "metadata API must remain usable by Bookshelf")
local new_book = { book_id = 10, edition_id = 21, title = "New edition", pages = 150, reading_format_id = 4 }
assert(app.hardcover:linkBook(new_book))
assert(saved.books[file].edition_id == 21 and saved.books[file].pages == 150)
assert(saved.books[file].edition_format == "E-Book", "format must survive when only reading_format_id is provided")
assert(saved.books[file].sync == true, "linking must preserve saved tracking preference")
assert(#writes == 0, "edition selection must not re-send remote reading status")
assert(app.hardcover:linkBook({ book_id = 10 }))
assert(saved.books[file].edition_id == nil and saved.books[file].pages == nil)
assert(saved.books[file].edition_format == nil and saved.books[file].title == nil)
print("PASS: metadata reads and local edition linking work without remote writes or stale fields")

file = "/books/new.epub"
app.ui.document.file = file
app.state.book_status = {}
assert(not app.settings:bookLinked())
app:onReaderReady()
advance(10)
assert(saved.books[file].book_id == 10 and saved.books[file].edition_id == 21)
assert(#writes == 0, "automatic identifier linking must stay local")
print("PASS: reader auto-linking still works for new books")

local second = newApp(true)
callbacks.hardcoverapp(getmetatable(second))
local entries = second.menu:getSubMenuItems(true)
local notices = 0
for _, item in ipairs(entries) do
    if item.text == "Automatic reading sync: BookOrbit" then notices = notices + 1 end
end
assert(notices == 1 and not second.settings:syncEnabled())
assert(second:onEndOfBook() == nil)
advance(35)
assert(#writes == 0)
print("PASS: repeated Reader instances stay protected without duplicated menus")

second.hardcover:updateCurrentBookStatus(3)
assert(#writes == 1, "explicit manual Hardcover status actions should remain available")
print("PASS: explicit manual status action is unchanged")

local fm = newApp(true, true)
assert(not fm.settings:syncEnabled())
assert(fm.menu:getSubMenuItems(false)[1].text == "Automatic reading sync: BookOrbit")
assert(fm.hardcover:linkBook(new_book) == false, "reader-only link action must tolerate no open document")
fm:onNetworkConnected()
fm:onResume()
advance(35)
assert(#writes == 1, "FileManager startup must not send any updates")
print("PASS: FileManager without an open document is safe")
print("All tests passed (mocked network/storage; no real account accessed).")
