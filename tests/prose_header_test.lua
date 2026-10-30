-- Run from the repository root: luajit tests/prose_header_test.lua
-- Exercise the real patches with mocked KOReader widgets and screen buffers.
local function object(methods)
    local cls = methods or {}
    cls.__index = cls
    function cls:new(attrs) return setmetatable(attrs or {}, self) end
    return cls
end

local prose, manga = "2-custom-reader-header.lua", "2-header-manga.lua"
local novel, comic = "/books/EPUBs/Fiktion/Novel.epub", "/books/EPUBs/Manga/Volume.cbz"
local function render(options)
    local state = options or {}
    state.width = state.width or 1264
    state.text, state.rects, state.order = {}, {}, {}
    state.native_paints, state.power_calls, state.samples = 0, 0, 0
    state.timers = {}
    local function preload(name, value)
        package.loaded[name] = nil
        package.preload[name] = function() return value end
    end
    local function buffer()
        return {
            paintRect = function(_, x, y, w, h, color)
                assert(w > 0 and h > 0, "only positive rectangles")
                state.rects[#state.rects + 1] = { x = x, y = y, w = w, h = h, color = color }
                state.order[#state.order + 1] = "rect"
            end,
            getPixel = not state.no_get_pixel and function()
                state.samples = state.samples + 1
                if state.bad_get_pixel then error("cannot sample pixel") end
                return { getColor8 = function() return { a = state.dark and 0 or 255 } end }
            end or nil,
        }
    end
    local screen = { bb = buffer(), getWidth = function() return state.width end }
    local power = {
        getCapacity = function() state.power_calls = state.power_calls + 1; return 84 end,
        isCharging = function() state.power_calls = state.power_calls + 1; return false end,
    }
    preload("device", {
        screen = screen,
        hasBattery = function() state.power_calls = state.power_calls + 1; return true end,
        getPowerDevice = function() return power end,
    })
    preload("ui/widget/textwidget", object({
        getSize = function(self)
            local width = #self.text * self.face.size * 0.6
            if self.max_width then
                assert(self.max_width > 0, "no nonpositive width passed to text shaping")
                width = math.min(width, self.max_width)
            end
            return { w = math.ceil(width), h = math.ceil(self.face.size * 1.2) }
        end,
        paintTo = function(self, _, x, y)
            local size = self:getSize()
            state.text[#state.text + 1] = { widget = self, x = x, y = y, w = size.w, h = size.h }
            state.order[#state.order + 1] = "text"
        end,
        free = function(self) self.freed = true end,
    }))
    preload("ui/font", { getFace = function(_, _, size) return { size = size * (state.font_scale or 2) } end })
    preload("ui/geometry", object())
    preload("ui/bidi", { auto = function(text) return text end })
    preload("datetime", { secondsToHour = function() return "19:37" end })
    preload("util", { splitToArray = function(text)
        local parts = {}
        for part in text:gmatch("[^\n]+") do parts[#parts + 1] = part end
        return parts
    end })
    preload("ffi/util", { template = function(text, value) return text:gsub("%%1", value) end })
    preload("ffi/blitbuffer", { COLOR_WHITE = "white", COLOR_BLACK = "black" })
    preload("ui/widget/linewidget", object({ paintTo = function() state.line = true end }))
    preload("ui/event", {})
    preload("ui/uimanager", {
        scheduleIn = function(_, _, callback) state.timers[callback] = true end,
        unschedule = function(_, callback) state.timers[callback] = nil end,
        setDirty = function() end,
    })
    local ReaderDogear = object({
        -- Like KOReader, the native icon has no painted dimen on its first frame.
        getRefreshRegion = function(self) return self.native_region end,
        paintTo = function(self, _, x, y)
            state.native_paints = state.native_paints + 1
            self.native_region = { x = x + state.width - 40, y = y, w = 40, h = 40 }
        end,
    })
    preload("apps/reader/modules/readerdogear", ReaderDogear)
    local ReaderView = {
        paintTo = function(self, bb, x, y)
            state.order[#state.order + 1] = "page"
            if self.dogear_visible then self.dogear:paintTo(bb, x, y) end
        end,
    }
    preload("apps/reader/modules/readerview", ReaderView)
    G_reader_settings = {
        readSetting = function() return { text_font_size = state.font_size or 14 } end,
        isTrue = function() return false end,
    }
    for _, path in ipairs(state.paths or { prose }) do dofile(path) end
    local file = state.file
    if file == nil then file = novel end
    if file == false then file = nil end
    local document = {
        file = file,
        getPageCount = function() return 222 end,
    }
    if not state.fallback_geometry then
        document.getPageInnerRect = function() return { x = state.page_x or 0, w = state.width } end
    end
    local view = setmetatable({ document = document, render_mode = state.render_mode,
        dogear_visible = state.bookmarked, state = { page = 117 } }, { __index = ReaderView })
    view.ui = { document = document, view = view,
        doc_props = { display_title = state.title or "Test Book", authors = state.author or "Test Author" } }
    view.dogear = ReaderDogear:new { view = view }
    state.screen, state.view = screen, view
    state.buffer = state.offscreen and buffer() or screen.bb
    view:paintTo(state.buffer, state.x or 0, state.y or 0)
    return state, view
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

test("ribbon hangs directly from the top without a header band or line", function()
    local result, view = render({ bookmarked = true })
    local ribbon = assert(view._header_bookmark_ribbon_region)
    assert(ribbon.y == 0 and ribbon.h >= 12)
    assert(result.order[1] == "page" and result.order[2] == "text")
    assert(not result.line and result.native_paints == 0 and view.dogear_visible)
    assert(#result.rects > 2 and result.rects[1].y == 0)
    for _, rect in ipairs(result.rects) do
        assert(rect.x >= ribbon.x and rect.x + rect.w <= ribbon.x + ribbon.w)
        assert(rect.y >= 0 and rect.y + rect.h <= ribbon.h, "no page-wide white rectangle")
    end
end)

test("prose extends manga's ribbon body, preserving its width, tip and colors", function()
    for _, dark in ipairs({ false, true }) do
        local regular, view = render({ bookmarked = true, dark = dark })
        -- Manga subtracts two points; compensate to compare identical text sizes.
        local illustrated, manga_view = render({ paths = { manga }, file = comic,
            bookmarked = true, dark = dark, font_size = 16 })
        local ribbon, source = view._header_bookmark_ribbon_region, manga_view._manga_bookmark_ribbon_region
        assert(ribbon.w == source.w and ribbon.h > source.h and ribbon.notch_depth == source.notch_depth)
        local extension = ribbon.h - source.h
        assert(#regular.rects == #illustrated.rects - 1, "exclude manga's opaque band")
        for i, rect in ipairs(regular.rects) do
            local original = illustrated.rects[i + 1]
            assert(rect.x == original.x and rect.w == original.w and rect.color == original.color)
            if rect.y == 0 then
                assert(original.y == source.y and rect.h == original.h + extension)
            else
                assert(rect.y == original.y - source.y + extension and rect.h == original.h)
            end
        end
    end
end)

test("ribbon reaches the header text bottom across fonts, scales and offsets", function()
    for _, size in ipairs({ 10, 14, 24 }) do
        for _, scale in ipairs({ 1, 2, 3, 4 }) do
            local result, view = render({ bookmarked = true, font_size = size,
                font_scale = scale, width = 1680, x = 11, y = 23 })
            local status = result.text[#result.text]
            local ribbon = assert(view._header_bookmark_ribbon_region)
            assert(ribbon.y == 23)
            assert(ribbon.y + ribbon.h == status.y + status.h)
            assert(ribbon.notch_depth < ribbon.h / 2, "elongate body, not notch")
            local region = assert(view.dogear:getRefreshRegion())
            assert(region.y + region.h >= status.y + status.h)
        end
    end
end)

test("black fill on light pages and white fill on dark pages, with contrast outline", function()
    for _, dark in ipairs({ false, true }) do
        local result = render({ bookmarked = true, dark = dark })
        assert(result.samples == 9)
        assert(result.rects[1].color == (dark and "black" or "white"))
        assert(result.rects[#result.rects].color == (dark and "white" or "black"))
    end
end)

test("unavailable or failing pixel sampling uses manga's safe fallback", function()
    for _, options in ipairs({ { no_get_pixel = true }, { bad_get_pixel = true } }) do
        options.bookmarked = true
        local result = render(options)
        assert(result.rects[1].color == "white" and result.rects[#result.rects].color == "black")
    end
end)

test("unbookmarked pages keep their header but no icon or pixel sampling", function()
    local result, view = render()
    assert(#result.text == 2 and #result.rects == 0 and result.samples == 0)
    assert(view._header_bookmark_ribbon_region, "remember area for later bookmark toggle")
end)

test("first bookmark frame refreshes even though the native icon has no dimen", function()
    local result, view = render({ bookmarked = true })
    assert(view.dogear.native_region == nil and result.native_paints == 0)
    local region = assert(view.dogear:getRefreshRegion())
    local ribbon = view._header_bookmark_ribbon_region
    assert(region.x == ribbon.x and region.y == ribbon.y and region.w == ribbon.w and region.h == ribbon.h)
end)

test("removing a bookmark retains its complete refresh region and draws no ribbon", function()
    local result, view = render({ bookmarked = true })
    local ribbon = view._header_bookmark_ribbon_region
    view.dogear_visible = false
    local region = assert(view.dogear:getRefreshRegion())
    assert(region.y <= ribbon.y and region.y + region.h >= ribbon.y + ribbon.h)
    result.rects, result.text = {}, {}
    view:paintTo(result.buffer, 0, 0)
    assert(#result.rects == 0 and #result.text == 2 and not view.dogear_visible)
end)

test("existing native refresh region is included rather than overwritten", function()
    local _, view = render({ bookmarked = true })
    view.dogear.native_region = { x = 1200, y = 0, w = 64, h = 70 }
    local region = view.dogear:getRefreshRegion()
    assert(region.x <= 1200 and region.x + region.w >= 1264 and region.y + region.h >= 70)
end)

test("metadata and status do not overlap the ribbon, including larger fonts", function()
    for _, scale in ipairs({ 1, 2, 3, 4 }) do
        local result, view = render({ title = string.rep("Long title ", 60), font_scale = scale,
            bookmarked = true, width = 1680 })
        local left, right = result.text[1], result.text[2]
        assert(left and right and left.x + left.w < right.x)
        assert(left.widget.max_width and not left.widget.maxWidth)
        assert(right.x + right.w < view._header_bookmark_ribbon_region.x)
        assert(left.widget.freed and right.widget.freed)
    end
end)

test("a very narrow screen omits the title rather than passing invalid text width", function()
    local result = render({ width = 300, bookmarked = true })
    assert(#result.text == 1 and not result.text[1].widget.max_width)
    assert(result.view._header_bookmark_ribbon_region and #result.rects > 0)
end)

test("offset and fallback geometry preserve top anchor and right alignment", function()
    local normal, view = render({ bookmarked = true })
    local shifted, moved = render({ x = 11, y = 23, page_x = 17, bookmarked = true })
    assert(moved._header_bookmark_ribbon_region.x == view._header_bookmark_ribbon_region.x + 28)
    assert(moved._header_bookmark_ribbon_region.y == 23)
    for i, text in ipairs(normal.text) do
        assert(shifted.text[i].x == text.x + 28 and shifted.text[i].y == text.y + 23)
    end
    local _, fallback = render({ fallback_geometry = true, bookmarked = true })
    assert(fallback._header_bookmark_ribbon_region.x == view._header_bookmark_ribbon_region.x)
end)

test("folder rules remain case-insensitive and accept Windows separators", function()
    local result = render({ file = "C:\\Books\\EPUBS\\Fiktion\\Novel.epub", bookmarked = true })
    assert(#result.text == 2 and #result.rects > 0 and result.native_paints == 0)
end)

test("excluded folders and special render modes preserve the native icon", function()
    for _, options in ipairs({ { file = false }, { file = comic }, { file = "/books/epubs/Serier/Comic.cbz" },
        { file = "/other/Novel.epub" }, { render_mode = 0 }, { render_mode = "thumbnail" } }) do
        options.bookmarked = true
        local result, view = render(options)
        assert(#result.text == 0 and #result.rects == 0 and result.power_calls == 0)
        assert(result.native_paints == 1 and not view._header_bookmark_ribbon_region)
        assert(view.dogear:getRefreshRegion() == view.dogear.native_region)
    end
end)

test("offscreen thumbnails preserve native drawing and do not run header code", function()
    local result, view = render({ offscreen = true, bookmarked = true })
    assert(result.native_paints == 1 and #result.text == 0 and #result.rects == 0)
    assert(result.power_calls == 0 and result.samples == 0 and next(result.timers) == nil)
    assert(view._header_bookmark_ribbon_region == nil)
end)

test("prose and manga remain independent in both patch load orders", function()
    for _, paths in ipairs({ { prose, manga }, { manga, prose } }) do
        local regular, view = render({ paths = paths, bookmarked = true })
        assert(#regular.text == 2 and regular.native_paints == 0)
        assert(view._header_bookmark_ribbon_region.y == 0 and not view._manga_bookmark_ribbon_region)
        assert(view.dogear:getRefreshRegion())
        local illustrated, manga_view = render({ paths = paths, file = comic, bookmarked = true })
        assert(#illustrated.text == 2 and illustrated.native_paints == 1)
        assert(manga_view._manga_bookmark_ribbon_region.y > 0 and not manga_view._header_bookmark_ribbon_region)
        local region = manga_view.dogear:getRefreshRegion()
        local ribbon = manga_view._manga_bookmark_ribbon_region
        assert(region.y + region.h >= ribbon.y + ribbon.h)
    end
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
