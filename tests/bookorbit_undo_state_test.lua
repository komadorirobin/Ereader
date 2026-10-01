-- All storage, UI and network access is mocked.
package.loaded.pluginloader = { createPluginInstance = function() error("unexpected plugin creation") end }
local Opening = dofile("2-bookorbit-undo-opening.lua")
local now = 1800000000
os.time = function() return now end
local function equal(actual, expected, message)
    assert(actual == expected, (message or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function dump(value)
    if type(value) ~= "table" then return tostring(value) end
    local keys, values = {}, {}
    for key in pairs(value) do keys[#keys+1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do values[#values+1] = key .. "=" .. dump(value[key]) end
    return table.concat(values, ";")
end
package.loaded.dump = dump
local function settings(data)
    return {
        data = data or {},
        readSetting = function(self, key, default) local value = self.data[key]; if value == nil then return default end; return value end,
        saveSetting = function(self, key, value) self.data[key] = value end,
        delSetting = function(self, key) self.data[key] = nil end,
        flush = function() end,
    }
end
local calls, response, plugin, ds, history, closed, shown, events, cached
local function setup(initial)
    G_reader_settings = settings()
    calls, closed, shown, events, cached = {}, 0, 0, {}, {}
    response = function(path)
        return { phase = path:match("/undo$") and "undone" or path:match("/commit$") and "committed" or "active" }
    end
    history = {
        hist = {}, getIndexByFile = function(self) return self.hist[1] and 1 end,
        removeItemByPath = function(self) self.hist = {} end,
        addItem = function(self, file, time) self.hist = {{ file = file, time = time }} end,
    }
    package.loaded.readhistory = history
    ds = settings(initial or { summary = { rating = 4, note = "keep me" }, doc_props = { title = "Book" } })
    package.loaded.docsettings = { open = function() return ds end }
    package.loaded["ui/widget/booklist"] = { setBookInfoCacheProperty = function(file, key, value) cached[key] = value end }
    package.loaded["ui/event"] = { new = function(self, name) return name end }
    package.loaded["ui/uimanager"] = { broadcastEvent = function(self, event) events[#events+1] = event end, setDirty = function() end }
    plugin = {
        settings = { server_url = "https://example.test/api/v1", username = "a", auto_sync = true }, device_id = "ereader",
        isLoggedIn = function() return true end, getDocumentDigest = function() return string.rep("a", 32) end,
        requestOpeningSync = function() end,
        ui = { document = { file = "/books/book.epub" }, doc_settings = ds, annotation = { annotations = {} }, page = 1 },
    }
    function plugin:newClient()
        return { request = function(self, method, path, body)
            calls[#calls+1] = { method = method, path = path, body = body }
            return response(path, body)
        end }
    end
    function plugin.ui:getCurrentPage() return self.page end
    function plugin.ui:onClose()
        closed = closed + 1
        ds:saveSetting("last_page", self.page)
        ds:saveSetting("percent_finished", 0.005)
        Opening.close(plugin)
        self.document = nil
    end
    function plugin.ui:showFileManager() shown = shown + 1 end
end
local function open()
    Opening.beforeLoad(plugin, ds)
    local summary = ds:readSetting("summary") or {}
    summary.status = "reading"
    summary.modified = "2026-10-01"
    ds:saveSetting("summary", summary)
    history:addItem(plugin.ui.document.file, now)
    Opening.capture(plugin)
end

setup()
open()
local row = Opening.record(plugin)
assert(row and Opening.available(plugin), "pre-load state survives KOReader marking the book reading")
equal(row.before.status, nil, "actual original status")
equal(row.before.modified, nil)
equal(Opening.held(plugin.settings, row.digest), true)
equal(Opening.blockedRequest(plugin.settings, "POST", "/koreader/plugin/match-check", {books={{hash=row.digest}}}), false)
equal(Opening.blockedRequest(plugin.settings, "PUT", "/koreader/syncs/progress", {document=row.digest}), true)
equal(Opening.blockedRequest(plugin.settings, "POST", "/koreader/plugin/book-states", {books={{hash="other"}}}), false)
assert(Opening.ensure(plugin))
equal(#calls, 1)
local id = row.id
now = now + 20
local success = Opening.undo(plugin)
assert(success)
equal(calls[2].body.id, id, "undo uses original operation id")
equal(calls[2].path, "/koreader/plugin/openings/undo")
equal(closed, 1, "reader closed before sidecar restore")
equal(shown, 1, "returns to file manager")
equal(ds:readSetting("summary").status, "new")
equal(ds:readSetting("summary").modified, nil)
equal(ds:readSetting("summary").rating, 4, "rating untouched")
equal(ds:readSetting("summary").note, "keep me", "review untouched")
equal(ds:readSetting("last_page"), nil)
equal(ds:readSetting("percent_finished"), nil)
equal(ds:readSetting("doc_props").title, "Book", "metadata untouched")
equal(#history.hist, 0)
equal(cached.status, "new")
equal(events[1], "BookMetadataChanged", "SimpleUI/Bookshelf caches invalidated")
local filtered, skipped = Opening.filterStats(plugin.settings, {
    {hash=row.digest,events={{startTime=row.opened_at-1},{startTime=row.opened_at},{startTime=now},{startTime=now+1}}},
    {hash="other",events={{startTime=now}}},
})
equal(#filtered[1].events, 2, "only accidental interval removed")
equal(#filtered[2].events, 1, "other books untouched")
equal(skipped[row.digest], now)
equal(Opening.undo(plugin), false, "completed undo cannot run twice locally")

setup({summary={status="reading"},percent_finished=0.25})
open()
equal(Opening.record(plugin), nil, "existing reading cannot be undone")

setup()
history:addItem("/books/book.epub", now-100)
open()
assert(Opening.undo(plugin), "offline unsent opening can be restored locally")
equal(#calls, 0, "no remote reading was created")
equal(history.hist[1].time, now-100, "pre-existing history timestamp preserved")

setup()
open()
row = Opening.record(plugin)
plugin.ui.page = 2
Opening.pageTurn(plugin, 2)
equal(row.phase, "committing")
assert(not Opening.available(plugin), "first page turn closes undo window")
assert(Opening.ensure(plugin))
equal(calls[2].path, "/koreader/plugin/openings/commit")
equal(row.phase, "done")
equal(Opening.held(plugin.settings, row.digest), false)

setup()
open()
row = Opening.record(plugin)
response = function() return nil, "timeout" end
equal(Opening.ensure(plugin), false)
assert(row.sent and not row.registered)
response = function(path) return {phase=path:match("/undo$") and "undone" or "active"} end
assert(Opening.undo(plugin), "ambiguous start reconciled before undo")
equal(calls[1].body.id, calls[2].body.id, "no second start ID on retry")
equal(calls[3].body.id, row.id)

setup()
open()
row = Opening.record(plugin)
response = function() return nil, 404 end
assert(Opening.ensure(plugin))
equal(row.phase, "done", "old servers release hold without fake undo")

setup()
open()
assert(Opening.ensure(plugin))
response = function() return nil, 409 end
equal(Opening.undo(plugin), false, "server conflict stops local reset")
equal(closed, 0)
equal(ds:readSetting("summary").status, "reading")

setup()
open()
assert(Opening.ensure(plugin))
row = Opening.record(plugin)
response = function() return {phase="undone",hardcoverPending=true} end
assert(Opening.undo(plugin))
equal(row.phase, "undo_pending")
equal(closed, 1)
response = function() return {phase="undone",hardcoverPending=false} end
assert(Opening.undo(plugin))
equal(closed, 1, "Hardcover retry never restores local state twice")
equal(#Opening.account(plugin.settings).ignored_stats[row.digest], 1)

setup()
open()
plugin.ui.annotation.annotations = {{text="do not delete"}}
equal(Opening.undo(plugin), false)
equal(#calls, 0, "annotation change refuses before any network mutation")
equal(Opening.record(plugin).phase, "committing", "changed data releases the provisional opening")

setup()
open()
row = Opening.record(plugin)
equal(Opening.undo(plugin, "a-different-opening"), false, "a delayed confirmation cannot undo another book")
equal(row.phase, "candidate")
equal(#calls, 0)

setup()
open()
row = Opening.record(plugin)
row.phase = "undo_pending"
plugin.ui.page = 2
Opening.pageTurn(plugin, 2)
equal(row.phase, "committing", "continuing to read cancels a pending undo")
assert(Opening.ensure(plugin))
equal(Opening.held(plugin.settings, row.digest), false)

setup()
open()
plugin.ui:onClose()
ds:readSetting("summary").status = "complete"
equal(Opening.undo(plugin), false, "closed book manually finished cannot be reset")

setup()
open()
plugin.ui:onClose()
assert(Opening.undo(plugin), "undo also works after closing the initial page")

setup()
open()
row = Opening.record(plugin)
now = now + 86401
assert(not Opening.available(plugin), "expired openings are not offered")
assert(Opening.ensure(plugin))
equal(row.phase, "done", "expiry releases ordinary sync")

print("bookorbit_undo_state_test.lua: ok")
