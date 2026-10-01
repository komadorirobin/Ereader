-- Undo accidental openings without modifying bookorbit.koplugin on disk.
-- Server support is required. See README.md before enabling/disabling this patch.
-- A persistent hold protects new openings from sweeps and delayed uploads.
local Opening = {}
local KEYS = { "percent_finished", "last_xpointer", "last_page", "last_page_position" }
local MAX_AGE = 24 * 60 * 60

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end

-- Only the files involved in lifecycle, queues, and upload acknowledgement are
-- pinned. MD5 is a compatibility fingerprint, not a download security check.
-- Tested against BookOrbit 2855dbb8a39d20bf711f01772e2678ef0625dd63 (plugin 1.5.5).
-- Ignore only the release literal; unrelated updates need no new fingerprint.
local TESTED_FILES = {
    ["main.lua"] = "0fb0dcfe30ce494812c8d692498649a2",
    ["bookorbit_api.lua"] = "bdeaeb095543878e2902e3ea8e7f9522",
    ["bookorbit_book_sync.lua"] = "a796ae57941a69c80a9b2d7578e3c858",
    ["bookorbit_sweep.lua"] = "c3bd9f40996b4aa1b4beaeb439b9da19",
    ["bookorbit_main_menu.lua"] = "40392af3dab84f329cdd8065b2fa765e",
    ["bookorbit_sync_coordinator.lua"] = "2494dc3c629a693957597c98ca3457cd",
    ["bookorbit_sync_job_runner.lua"] = "c6b54c96b1c1514f85ae74cb42bcb7b9",
    ["bookorbit_lifecycle_outbox.lua"] = "8ed7c3d6910e05d0d6533441d1a7c353",
    ["bookorbit_progress_sync.lua"] = "7609f401e37b2aabb7d42aa424595b8f",
}

function Opening.account(client, create)
    if not G_reader_settings then return nil end
    local all = G_reader_settings:readSetting("bookorbit_openings", {})
    local url = tostring(client.server_url):gsub("^http://localhost([:/])", "http://127.0.0.1%1"):gsub("/+$", "")
    local key = url .. "\n" .. tostring(client.username)
    if create and not all[key] then all[key] = { ignored_stats = {} } end
    if create then G_reader_settings:saveSetting("bookorbit_openings", all) end
    return all[key]
end

local function persist() G_reader_settings:flush() end

local function liveReader(plugin, row)
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local ui = ReaderUI and ReaderUI.instance or plugin.ui
    return ui and ui.document and ui.document.file == row.file and ui or nil
end

function Opening.record(plugin)
    local account = Opening.account(plugin.settings)
    return account and account.opening
end

function Opening.held(client, digest)
    local account = Opening.account(client)
    local row = account and account.opening
    return row and row.digest == digest and not row.local_restored and row.phase ~= "done" and row.phase ~= "undone"
end

function Opening.available(plugin)
    local row = Opening.record(plugin)
    return row and (row.phase == "undo_pending" or
        ((row.phase == "candidate" or row.phase == "active") and os.time() - row.opened_at < MAX_AGE))
end

function Opening.blockedRequest(client, method, path, body)
    if method == "GET" or not body or path:find("/openings", 1, true) then return false end
    if path == "/koreader/syncs/progress" then return Opening.held(client, body.document) end
    if not path:match("^/koreader/plugin/") or path:find("match-check", 1, true) then return false end
    for _, entry in ipairs(body.books or body.items or {}) do
        if Opening.held(client, entry.hash) then return true end
    end
    return false
end

function Opening.filterStats(client, books)
    local account = Opening.account(client)
    local filtered, skipped = {}, {}
    for _, book in ipairs(books) do
        local events = {}
        local intervals = account and account.ignored_stats[book.hash] or {}
        for _, event in ipairs(book.events or {}) do
            local ignore = false
            for _, interval in ipairs(intervals or {}) do
                if event.startTime >= interval[1] and event.startTime <= interval[2] then ignore = true; break end
            end
            if ignore then skipped[book.hash] = math.max(skipped[book.hash] or 0, event.startTime)
            else table.insert(events, event) end
        end
        if #events > 0 then
            local item = copy(book)
            item.events = events
            table.insert(filtered, item)
        end
    end
    return filtered, skipped
end

local function uuid()
    return ("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
        return string.format("%x", c == "x" and math.random(0, 15) or math.random(8, 11))
    end)
end

function Opening.beforeLoad(plugin, ds)
    plugin.opening_before = nil
    if not plugin:isLoggedIn() or not plugin.settings.auto_sync then return end
    if not ds or not plugin.ui or not plugin.ui.document then return end
    local summary = ds:readSetting("summary") or {}
    if (summary.status and summary.status ~= "new") or (ds:readSetting("percent_finished") or 0) > 0 then return end
    local before = {}
    for _, key in ipairs(KEYS) do before[key] = copy(ds:readSetting(key)) end
    before.status = summary.status
    before.modified = summary.modified
    local history = require("readhistory")
    local index = history:getIndexByFile(plugin.ui.document.file)
    before.history_time = index and history.hist[index].time
    plugin.opening_before = before
end

function Opening.capture(plugin)
    plugin.opening_session_id = nil
    if not plugin:isLoggedIn() or not plugin.settings.auto_sync then return end
    local ui = plugin.ui
    if not ui or not ui.document or not ui.doc_settings then return end
    local previous = Opening.record(plugin)
    if previous and previous.phase ~= "done" and previous.phase ~= "undone" then
        if previous.phase ~= "undo_pending" then previous.phase = "committing"; persist() end
        return
    end
    local before = plugin.opening_before
    plugin.opening_before = nil
    if not before then return end
    local digest = plugin:getDocumentDigest()
    if not digest then return end
    local account = Opening.account(plugin.settings, true)
    account.opening = {
        id = uuid(), digest = digest, file = ui.document.file,
        title = (ui.doc_props and ui.doc_props.title) or ui.document.file:match("([^/]+)$"),
        before = before, opened_at = os.time(), phase = "candidate", initial_page = ui:getCurrentPage(),
        annotations = copy(ui.annotation and ui.annotation.annotations or {}),
    }
    plugin.opening_session_id = account.opening.id
    persist()
end

local function payload(plugin, row)
    return { id = row.id, document = row.digest, deviceId = plugin.device_id }
end

function Opening.ensure(plugin)
    local row = Opening.record(plugin)
    if not row or row.phase == "done" or row.phase == "undone" or row.phase == "undo_pending" then return true end
    if os.time() - row.opened_at >= MAX_AGE then row.phase = "committing" end
    if (row.phase == "candidate" or row.phase == "active") and not Opening.localUnchanged(plugin, row) then
        row.phase = "committing"
        persist()
    end
    local client = plugin:newClient()
    if not row.registered then
        row.sent = true
        persist()
        local body, err = client:request("POST", "/koreader/plugin/openings", payload(plugin, row))
        if not body then
            if err == 404 or err == 409 then row.phase = "done"; persist(); return true end
            return false
        end
        row.registered = true
        row.remote_pending = body.hardcoverPending
        if body.phase == "committed" or body.phase == "undone" then row.phase = "done" end
        persist()
    end
    if row.phase == "committing" then
        local body, err = client:request("POST", "/koreader/plugin/openings/commit", payload(plugin, row))
        if not body and err ~= 409 and err ~= 404 then return false end
        row.phase = "done"
        persist()
    elseif row.phase == "candidate" then row.phase = "active"; persist() end
    return true
end

function Opening.pageTurn(plugin, page)
    local row = Opening.record(plugin)
    if not row or not plugin.ui or not plugin.ui.document or row.file ~= plugin.ui.document.file then return end
    if (row.phase == "active" or row.phase == "candidate" or (row.phase == "undo_pending" and not row.local_restored))
            and page ~= nil and page ~= row.initial_page then
        row.phase = "committing"
        persist()
        plugin:requestOpeningSync()
    end
end

function Opening.keep(plugin)
    local row = Opening.record(plugin)
    if row and (row.phase == "candidate" or row.phase == "active") then
        row.phase = "committing"
        persist()
    end
end

function Opening.close(plugin)
    local row = Opening.record(plugin)
    if not row or plugin.opening_session_id ~= row.id or not plugin.ui.document or row.file ~= plugin.ui.document.file then return end
    if (row.phase == "candidate" or row.phase == "active") and not Opening.localUnchanged(plugin, row) then Opening.keep(plugin) end
    row.closed_at = os.time()
    local ds = plugin.ui.doc_settings
    row.after_close = {}
    for _, key in ipairs(KEYS) do row.after_close[key] = copy(ds:readSetting(key)) end
    row.after_close.summary = copy(ds:readSetting("summary"))
    row.after_close.annotations = copy(ds:readSetting("annotations"))
    persist()
end

function Opening.localUnchanged(plugin, row)
    if row.local_restored then return true end
    local dump = require("dump")
    local ui = liveReader(plugin, row)
    if ui then
        if row.closed_at or ui:getCurrentPage() ~= row.initial_page then return false end
        local summary = ui.doc_settings:readSetting("summary") or {}
        return (summary.status == nil or summary.status == "new" or summary.status == "reading")
            and dump(ui.annotation and ui.annotation.annotations or {}) == dump(row.annotations)
    end
    if not row.after_close then return false end
    local ds = require("docsettings"):open(row.file)
    for _, key in ipairs(KEYS) do
        if dump(ds:readSetting(key)) ~= dump(row.after_close[key]) then return false end
    end
    return dump(ds:readSetting("summary")) == dump(row.after_close.summary)
        and dump(ds:readSetting("annotations")) == dump(row.after_close.annotations)
end

function Opening.finishLocal(plugin, row)
    if row.local_restored then return end
    local UIManager = require("ui/uimanager")
    local reader = liveReader(plugin, row)
    -- Reader close flushes its in-memory sidecar; restore only after that flush.
    if reader then reader:onClose() end
    local ds = require("docsettings"):open(row.file)
    for _, key in ipairs(KEYS) do
        if row.before[key] == nil then ds:delSetting(key) else ds:saveSetting(key, copy(row.before[key])) end
    end
    local summary = ds:readSetting("summary") or {}
    summary.status = row.before.status or "new"
    summary.modified = row.before.modified
    ds:saveSetting("summary", summary)
    ds:flush()
    local history = require("readhistory")
    history:removeItemByPath(row.file)
    if row.before.history_time then history:addItem(row.file, row.before.history_time) end
    local BookList = require("ui/widget/booklist")
    BookList.setBookInfoCacheProperty(row.file, "status", summary.status)
    BookList.setBookInfoCacheProperty(row.file, "percent_finished", row.before.percent_finished or 0)
    local account = Opening.account(plugin.settings, true)
    account.ignored_stats[row.digest] = account.ignored_stats[row.digest] or {}
    table.insert(account.ignored_stats[row.digest], { row.opened_at, row.closed_at or os.time() })
    row.local_restored = true
    persist()
    if reader then reader:showFileManager(row.file) end
    UIManager:broadcastEvent(require("ui/event"):new("BookMetadataChanged", { file = row.file, key = "summary" }))
    UIManager:setDirty("all", "ui")
end

function Opening.undo(plugin, expected_id)
    local row = Opening.record(plugin)
    if expected_id and (not row or row.id ~= expected_id) then return false, "The book changed; nothing was reset." end
    if not Opening.available(plugin) then return false, "This opening can no longer be undone." end
    if not Opening.localUnchanged(plugin, row) then
        row.phase = "committing"
        persist()
        plugin:requestOpeningSync()
        return false, "Reading or annotations changed; nothing was reset."
    end
    row.phase = "undo_pending"
    persist()
    local pending = false
    if row.sent then
        local client = plugin:newClient()
        if not row.registered then
            local body, err = client:request("POST", "/koreader/plugin/openings", payload(plugin, row))
            if not body then
                if err == 404 or err == 409 then row.phase = "done"; persist() end
                return false, "Could not confirm the opening. No reading data was reset."
            end
            row.registered = true
            persist()
        end
        local body, err = client:request("POST", "/koreader/plugin/openings/undo", payload(plugin, row))
        if not body then
            if err == 409 or err == 404 then
                row.phase = "done"; persist()
                return false, "Reading changed on the server. Undo cannot continue; no further data was reset."
            end
            return false, "Undo is pending. Reconnect and retry Undo; reading data is held until then."
        end
        pending = body.hardcoverPending == true
    end
    -- Network requests yield to the UI. Never reset a page turned while waiting.
    if not Opening.localUnchanged(plugin, row) then
        row.phase = "done"; persist()
        return false, "Reading changed while waiting. The local book was not reset; sync it again to keep the new reading."
    end
    Opening.finishLocal(plugin, row)
    row.phase = pending and "undo_pending" or "undone"
    persist()
    return true, pending and "Opening undone locally and in BookOrbit. Hardcover still needs attention; retry Undo to finish." or "Opening undone, including its Hardcover reading if one was created."
end

function Opening.install(BookOrbit)
    function BookOrbit:onDocSettingsLoad(ds)
        Opening.beforeLoad(self, ds)
    end
    function BookOrbit:requestOpeningSync()
        if not self:isLoggedIn() or not require("ui/network/manager"):isConnected() then return end
        self:submitSyncJob{
            family = "reading_opening", label = "Reading opening", source = "opening", interactive = false,
            priority = 300,
            run = function()
                Opening.ensure(self)
                self:requestLifecycleOutboxDrain("opening")
            end,
        }
    end
    function BookOrbit:onBookOrbitUndoOpening()
        local row = Opening.record(self)
        if not Opening.available(self) then return end
        local UIManager = require("ui/uimanager")
        local _ = require("gettext")
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = _("Undo this accidental opening?") .. "\n\n" .. tostring(row.title), ok_text = _("Undo opening"),
            ok_callback = function()
                if Opening.record(self) ~= row or not Opening.available(self) then return end
                -- Prevent an automatic commit from superseding an explicit queued undo.
                if not Opening.localUnchanged(self, row) then
                    row.phase = "committing"
                    persist()
                    self:requestOpeningSync()
                    UIManager:show(require("ui/widget/infomessage"):new{ text = _("Reading or annotations changed; nothing was reset.") })
                    return
                end
                row.phase = "undo_pending"
                persist()
                self:submitSyncJob{
                    family = "reading_opening", label = _("Undo opening"), source = "manual", priority = 400, interactive = true,
                    run = function()
                        local _success, message = Opening.undo(self, row.id)
                        UIManager:show(require("ui/widget/infomessage"):new{ text = _(message) })
                    end,
                }
            end,
        })
    end
end

local function callable(value)
    local mt = type(value) == "table" and getmetatable(value)
    return type(value) == "function" or (type(mt) == "table" and type(mt.__call) == "function")
end

function Opening.checkCompatibility(plugin)
    if type(plugin.path) ~= "string" then return false, "missing plugin path" end
    local md5 = require("ffi/sha2").md5
    for filename, expected in pairs(TESTED_FILES) do
        local file = io.open(plugin.path .. "/" .. filename, "rb")
        if not file then return false, "missing " .. filename end
        local source = file:read("*a")
        file:close()
        if source and filename == "main.lua" then
            source = source:gsub('(local PLUGIN_VERSION = )"[^"\n]+"', '%1"<release>"', 1)
        end
        if not source or md5(source) ~= expected then return false, "untested " .. filename end
    end
    for _, name in ipairs({
        "onReaderReady", "onBookOrbitSyncBook", "onBookOrbitPushProgress", "onDispatcherRegisterActions",
        "_onCloseDocument", "_onPageUpdate", "_onResume", "_onNetworkConnected", "submitSyncJob",
        "matchOpenBookForAutoSync", "addToMainMenu", "requestLifecycleOutboxDrain", "registerEvents",
    }) do
        if not callable(plugin[name]) then return false, "missing method " .. name end
    end
    if plugin.onDocSettingsLoad or plugin.onBookOrbitUndoOpening then return false, "another undo implementation is installed" end
    for module, methods in pairs({
        bookorbit_api = { "request", "uploadPageStats" },
        bookorbit_book_sync = { "capture" },
        bookorbit_sweep = { "run" },
    }) do
        local value = package.loaded[module]
        for _, method in ipairs(methods) do
            if type(value) ~= "table" or type(value[method]) ~= "function" then return false, "missing " .. module .. "." .. method end
        end
    end
    return true
end

function Opening.hasProtectedData()
    local accounts = G_reader_settings and G_reader_settings:readSetting("bookorbit_openings", {}) or {}
    assert(type(accounts) == "table", "invalid opening accounts")
    local protected = false
    for _, account in pairs(accounts) do
        assert(type(account) == "table" and type(account.ignored_stats) == "table", "invalid opening account")
        local row = account.opening
        if row and row.phase ~= "done" and row.phase ~= "undone" then protected = true end
        for _, intervals in pairs(account.ignored_stats) do
            assert(type(intervals) == "table", "invalid excluded statistics")
            if next(intervals) then protected = true end
        end
    end
    return protected
end

local notices = {}
local function notice(text)
    if notices[text] then return end
    notices[text] = true
    require("logger").warn("Ereader undo patch:", text)
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        UIManager:show(require("ui/widget/infomessage"):new{ text = text })
    end)
end

local shared_installed = false
local function installSharedHooks()
    if shared_installed then return end
    local Api = require("bookorbit_api")
    local request = Api.request
    function Api:request(method, path, body, ...)
        if Opening.blockedRequest(self, method, path, body) then return nil, "opening_held" end
        return request(self, method, path, body, ...)
    end
    local upload = Api.uploadPageStats
    function Api:uploadPageStats(books)
        for _, book in ipairs(books) do
            if Opening.held(self, book.hash) then return nil, "opening_held" end
        end
        local filtered, skipped = Opening.filterStats(self, books)
        local response, err, errbody
        if #filtered > 0 then
            response, err, errbody = upload(self, filtered)
            if not response then return nil, err, errbody end
        else
            response = { results = {} }
        end
        response.results = response.results or {}
        for hash, watermark in pairs(skipped) do
            local found = false
            for _, result in ipairs(response.results) do
                if result.hash == hash then
                    result.watermark = math.max(result.watermark or 0, watermark)
                    found = true
                    break
                end
            end
            if not found then
                local submitted = false
                for _, book in ipairs(filtered) do
                    if book.hash == hash then submitted = true; break end
                end
                -- Only locally excluded events may be acknowledged without a server result.
                if not submitted then table.insert(response.results, { hash = hash, watermark = watermark }) end
            end
        end
        return response
    end

    local BookSync = require("bookorbit_book_sync")
    local capture = BookSync.capture
    function BookSync.capture(plugin, ...)
        local row = Opening.record(plugin)
        if row and plugin.opening_session_id == row.id and plugin:getDocumentDigest() == row.digest
                and row.phase ~= "done" and row.phase ~= "committing" then return nil end
        return capture(plugin, ...)
    end

    local Sweep = require("bookorbit_sweep")
    local run = Sweep.run
    function Sweep.run(opts)
        local account = Opening.account(opts.api)
        if account and account.opening and Opening.held(opts.api, account.opening.digest) then
            -- Do not reach into private sweep steps or falsely acknowledge skipped books.
            -- Per-book sync for other books remains available while this manual sweep waits.
            if opts.interactive then
                require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                    text = "Undo the accidental opening, or continue reading it, before syncing the whole library.",
                })
            end
            return false
        end
        return run(opts)
    end
    shared_installed = true
end

local function before(plugin, name, hook)
    local original = plugin[name]
    plugin[name] = function(self, ...)
        hook(self, ...)
        return original(self, ...)
    end
end

local WRITE_JOBS = { lifecycle_outbox = true, progress_push = true, sweep = true, book_snapshot = true, annotation_exchange = true }
local function apply(plugin)
    Opening.install(plugin)
    installSharedHooks()
    before(plugin, "onReaderReady", Opening.capture)
    before(plugin, "_onCloseDocument", Opening.close)
    before(plugin, "_onPageUpdate", Opening.pageTurn)
    before(plugin, "onBookOrbitSyncBook", Opening.keep)
    before(plugin, "onBookOrbitPushProgress", Opening.keep)
    before(plugin, "_onResume", function(self) self:requestOpeningSync() end)
    before(plugin, "_onNetworkConnected", function(self) self:requestOpeningSync() end)
    before(plugin, "onDispatcherRegisterActions", function()
        require("dispatcher"):registerAction("bookorbit_undo_opening", {
            category = "none", event = "BookOrbitUndoOpening",
            title = require("gettext")("BookOrbit: undo accidental opening"), general = true,
        })
    end)

    local match = plugin.matchOpenBookForAutoSync
    function plugin:matchOpenBookForAutoSync(callback, ...)
        return match(self, function(matched, ...)
            if matched then Opening.ensure(self) end
            if callback then return callback(matched, ...) end
        end, ...)
    end
    local submit = plugin.submitSyncJob
    function plugin:submitSyncJob(job)
        if WRITE_JOBS[job.family] then
            local wrapped = {}
            for key, value in pairs(job) do wrapped[key] = value end
            wrapped.run = function(...)
                Opening.ensure(self)
                return job.run(...)
            end
            return submit(self, wrapped)
        end
        return submit(self, job)
    end
    local menu = plugin.addToMainMenu
    function plugin:addToMainMenu(items)
        menu(self, items)
        if self:isLoggedIn() and Opening.available(self) and items.bookorbit then
            table.insert(items.bookorbit.sub_item_table, 1, {
                id = "undo_opening", text = require("gettext")("Undo accidental opening"),
                enabled_func = function() return Opening.available(self) end,
                callback = function() self:onBookOrbitUndoOpening() end,
            })
        end
    end
    plugin._ereader_undo_installed = true
end

-- registerPatchPluginFunc runs AFTER plugin:init(). The preflight must run
-- BEFORE init so an incompatible sync client cannot drain protected data first.
-- Only BookOrbit is intercepted; other plugins use the original factory unchanged.
local PluginLoader = require("pluginloader")
local create = PluginLoader.createPluginInstance
function PluginLoader:createPluginInstance(plugin, attr)
    if plugin.name ~= "bookorbit" then return create(self, plugin, attr) end
    local readable, protected = pcall(Opening.hasProtectedData)
    if not readable then
        notice("BookOrbit undo patch: saved opening data is unreadable. BookOrbit sync is paused to protect reading history. Keep the saved state and repair it before syncing.")
        return false, "BookOrbit undo state hold"
    end
    if not plugin._ereader_undo_installed then
        local ok, compatible, reason = pcall(Opening.checkCompatibility, plugin)
        if not ok then compatible, reason = false, "compatibility check failed" end
        if not compatible then
            notice("BookOrbit undo patch: " .. tostring(reason) .. ".\n\n" .. (protected
                and "BookOrbit sync is paused to protect a pending undo or excluded reading statistics. Update the patch in Patch Manager and restart KOReader. Do not delete its saved state."
                or "Undo is unavailable. Ordinary BookOrbit sync is unchanged. Update the patch in Patch Manager and restart KOReader."))
            if protected then return false, "BookOrbit undo compatibility hold" end
            return create(self, plugin, attr)
        end
        apply(plugin)
    end
    local ok, instance = create(self, plugin, attr)
    if ok then
        require("ui/uimanager"):scheduleIn(5, function() instance:requestOpeningSync() end)
    end
    return ok, instance
end

return Opening
