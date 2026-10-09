-- Run from the repository root: luajit tests/header_thumbnail_test.lua
-- ReaderThumbnail renders to a separate buffer with render_mode still nil.
local function object(methods)
    local cls = methods or {}
    cls.__index = cls
    function cls:new(attrs) return setmetatable(attrs or {}, self) end
    return cls
end

local function loadHeaders(paths)
    local state = { pages = {}, text = {}, rects = {}, timers = {}, power_calls = 0, offscreen_calls = 0 }
    local function preload(name, value)
        package.loaded[name] = nil
        package.preload[name] = function() return value end
    end
    local function headerOnly()
        if state.offscreen then state.offscreen_calls = state.offscreen_calls + 1 end
        assert(not state.offscreen, "header code must not run during thumbnail rendering")
    end
    local function buffer()
        return {
            paintRect = function(_, ...)
                headerOnly()
                state.rects[#state.rects + 1] = { ... }
            end,
            getWidth = function() return 1264 end,
            getHeight = function() return 1680 end,
        }
    end
    local screen = { bb = buffer(), getWidth = function() return 1264 end }
    local power = {
        getCapacity = function()
            headerOnly()
            state.power_calls = state.power_calls + 1
            return 84
        end,
        isCharging = function()
            headerOnly()
            state.power_calls = state.power_calls + 1
            return false
        end,
    }
    preload("device", {
        screen = screen,
        hasBattery = function() headerOnly(); return true end,
        getPowerDevice = function() headerOnly(); return power end,
    })
    preload("ui/widget/textwidget", object({
        getSize = function(self)
            return { w = math.min(#self.text * 7, self.max_width or math.huge), h = 20 }
        end,
        paintTo = function(self)
            headerOnly()
            state.text[#state.text + 1] = self.text
        end,
        free = function() end,
    }))
    preload("ui/font", { getFace = function() headerOnly(); return {} end })
    preload("ui/geometry", object())
    preload("ui/bidi", { auto = function(text) return text end })
    preload("datetime", { secondsToHour = function() headerOnly(); return "19:37" end })
    preload("util", {
        splitToArray = function(text)
            local parts = {}
            for part in text:gmatch("[^\n]+") do parts[#parts + 1] = part end
            return parts
        end,
    })
    preload("ffi/util", { template = function(text, value) return text:gsub("%%1", value) end })
    preload("ffi/blitbuffer", { COLOR_WHITE = "white", COLOR_BLACK = "black" })
    preload("ui/widget/linewidget", object({ paintTo = headerOnly }))
    preload("ui/event", {})
    preload("ui/uimanager", {
        scheduleIn = function(_, _, callback)
            headerOnly()
            state.timers[callback] = true
        end,
        unschedule = function(_, callback) state.timers[callback] = nil end,
        setDirty = headerOnly,
    })
    preload("apps/reader/modules/readerdogear", {
        getRefreshRegion = function() return { x = 1224, y = 0, w = 40, h = 40 } end,
    })
    local ReaderView = {
        paintTo = function(_, bb, x, y)
            state.pages[#state.pages + 1] = { bb = bb, x = x, y = y }
        end,
        onCloseWidget = function() state.closed = true end,
    }
    preload("apps/reader/modules/readerview", ReaderView)
    G_reader_settings = {
        readSetting = function() return {} end,
        isTrue = function() return false end,
    }
    for _, path in ipairs(paths) do dofile(path) end

    local function view(file)
        local document = {
            file = file,
            getPageInnerRect = function() headerOnly(); return { x = 0, w = 1264 } end,
            getPageCount = function() return 222 end,
        }
        local reader_view = setmetatable({ document = document, state = { page = 117 } }, { __index = ReaderView })
        reader_view.ui = {
            document = document,
            doc_props = { display_title = "Test Book", authors = "Test Author" },
            view = reader_view,
        }
        return reader_view
    end
    return state, screen, buffer, view
end

local function count(values)
    local n = 0
    for _ in pairs(values) do n = n + 1 end
    return n
end

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS: " .. name)
    else
        failed = failed + 1
        print("FAIL: " .. name .. ": " .. tostring(err))
    end
end

local custom, manga = "2-custom-reader-header.lua", "2-header-manga.lua"
local novel, comic = "/books/EPUBs/Fiktion/Novel.epub", "/books/EPUBs/Manga/Volume.epub"
for _, configuration in ipairs({
    { name = "prose only", paths = { custom }, files = { novel } },
    { name = "manga only", paths = { manga }, files = { comic } },
    { name = "both headers", paths = { custom, manga }, files = { novel, comic } },
    { name = "reversed load order", paths = { manga, custom }, files = { novel, comic } },
}) do
    for _, file in ipairs(configuration.files) do
        local label = configuration.name .. " / " .. file
        test(label .. ": first paint can be a thumbnail", function()
            local state, screen, buffer, view = loadHeaders(configuration.paths)
            local reader = view(file)
            local thumbnail = buffer()
            assert(thumbnail ~= screen.bb and thumbnail:getWidth() == screen.bb:getWidth())
            assert(reader.render_mode == nil, "match real ReaderThumbnail, not a fictitious render mode")
            state.offscreen = true
            reader:paintTo(thumbnail, 11, 23)
            assert(#state.pages == 1 and state.pages[1].bb == thumbnail)
            assert(state.pages[1].x == 11 and state.pages[1].y == 23)
            assert(#state.text == 0 and #state.rects == 0 and state.power_calls == 0)
            assert(state.offscreen_calls == 0, "even swallowed errors must not reach header APIs")
            assert(count(state.timers) == 0)
            assert(reader._header_charge_event_handler == nil and reader._manga_header_charge_event_handler == nil)
            state.offscreen = false
            reader:paintTo(screen.bb, 0, 0)
            assert(#state.text == 2 and state.power_calls > 0 and count(state.timers) == 1)
        end)
        test(label .. ": thumbnail after reading preserves the live header and timer", function()
            local state, screen, buffer, view = loadHeaders(configuration.paths)
            local reader = view(file)
            reader:paintTo(screen.bb, 0, 0)
            assert(#state.text == 2 and count(state.timers) == 1)
            local power_calls, rects = state.power_calls, #state.rects
            local timer = next(state.timers)
            state.offscreen = true
            reader:paintTo(buffer(), 0, 0)
            assert(state.offscreen_calls == 0, "even swallowed errors must not reach header APIs")
            assert(#state.pages == 2 and #state.text == 2 and #state.rects == rects)
            assert(state.power_calls == power_calls and count(state.timers) == 1 and state.timers[timer])
            state.offscreen = false
            reader:paintTo(screen.bb, 0, 0)
            assert(#state.pages == 3 and #state.text == 4 and count(state.timers) == 1)
            reader:onCloseWidget()
            assert(state.closed and count(state.timers) == 0)
        end)
        test(label .. ": replacing the screen buffer does not disable the header", function()
            local state, screen, buffer, view = loadHeaders(configuration.paths)
            local reader = view(file)
            local old_buffer = screen.bb
            reader:paintTo(old_buffer, 0, 0)
            screen.bb = buffer()
            reader:paintTo(screen.bb, 0, 0)
            assert(#state.text == 4)
            state.offscreen = true
            reader:paintTo(old_buffer, 0, 0)
            assert(state.offscreen_calls == 0, "even swallowed errors must not reach header APIs")
            assert(#state.pages == 3 and #state.text == 4)
        end)
    end
end

test("folder filters and existing render modes are unchanged", function()
    local state, screen, _, view = loadHeaders({ custom, manga })
    for _, file in ipairs({ "/books/elsewhere/Novel.epub", novel, comic }) do
        local reader = view(file)
        if file ~= "/books/elsewhere/Novel.epub" then reader.render_mode = 0 end
        reader:paintTo(screen.bb, 0, 0)
    end
    assert(#state.pages == 3 and #state.text == 0 and count(state.timers) == 0)
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
