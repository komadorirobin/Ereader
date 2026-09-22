-- Run from the repository root: luajit tests/manga_header_test.lua
-- Exercise the actual patch with KOReader's widget and device APIs stubbed.
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

local state
local function textWidth(text, size)
    local width = 0
    for glyph in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local ratio = (glyph == "W" and 0.9) or (glyph == "i" and 0.25) or 0.6
        width = width + size * ratio
    end
    return math.ceil(width)
end

local TextWidget = object()
function TextWidget:getSize()
    self.full_width = textWidth(self.text, self.face.size)
    -- Match KOReader's public contract: max_width is supported, maxWidth is not.
    local width = self.full_width
    if self.max_width then
        assert(self.max_width > 0, "do not pass a nonpositive width to text shaping")
        width = math.min(width, self.max_width)
    end
    return { w = width, h = math.ceil(self.face.size * 1.2) }
end
function TextWidget:paintTo(bb, x, y)
    local size = self:getSize()
    state.text[#state.text + 1] = { widget = self, x = x, y = y, w = size.w, h = size.h }
    state.order[#state.order + 1] = "text"
end
preload("ui/widget/textwidget", TextWidget)
preload("ui/geometry", object())
preload("ui/bidi", { auto = function(text) return text end })
preload("ui/font", {
    getFace = function(_, _, size) return { size = size * (state.font_scale or 2) } end,
})
preload("util", {
    splitToArray = function(text, separator)
        local result = {}
        for part in text:gmatch("[^" .. separator .. "]+") do
            result[#result + 1] = part
        end
        return result
    end,
})
preload("datetime", { secondsToHour = function() return state.clock or "19:37" end })
preload("ffi/util", { template = function(text, value) return text:gsub("%%1", value) end })
local power = {
    getCapacity = function() return state.battery or 84 end,
    isCharging = function() return state.charging or false end,
}
preload("device", {
    hasBattery = function() return true end,
    getPowerDevice = function() return power end,
    screen = { getWidth = function() return state.width end },
})
preload("ui/uimanager", { scheduleIn = noop, unschedule = noop, setDirty = noop })
preload("ui/event", {})
preload("ffi/blitbuffer", { COLOR_WHITE = "white", COLOR_BLACK = "black" })
local ReaderDogear = {
    getRefreshRegion = function()
        return { x = state.width - 40, y = 0, w = 40, h = 40 }
    end,
}
preload("apps/reader/modules/readerdogear", ReaderDogear)
local ReaderView = { paintTo = function() state.order[#state.order + 1] = "page" end }
preload("apps/reader/modules/readerview", ReaderView)
preload("ui/widget/linewidget", object({
    paintTo = function(self, bb, x, y)
        state.line = { x = x, y = y, w = self.dimen.w, h = self.dimen.h }
        state.order[#state.order + 1] = "line"
    end,
}))
G_reader_settings = { readSetting = function() return {} end, isTrue = function() return false end }
dofile(arg[1] or "2-header-manga.lua")

local function render(options)
    state = options or {}
    state.width = state.width or 1264
    state.text, state.rects, state.order = {}, {}, {}
    local document = {
        file = state.file or "/storage/EPUBs/Manga/Series/Volume.cbz",
        getPageCount = function() return state.total or 222 end,
    }
    if not state.fallback_geometry then
        document.getPageInnerRect = function()
            return { x = state.page_x or 0, w = state.width }
        end
    end
    local view = setmetatable({
        document = document,
        render_mode = state.render_mode,
        dogear_visible = state.bookmarked,
        ui = {
            document = document,
            doc_props = { display_title = state.title or "Billy Bat, Vol. 2", authors = state.author or "Naoki Urasawa" },
            view = { state = { page = state.page or 117 } },
        },
    }, { __index = ReaderView })
    local bb = {
        paintRect = function(_, x, y, w, h, color)
            state.rects[#state.rects + 1] = { x = x, y = y, w = w, h = h, color = color }
            state.order[#state.order + 1] = "rect"
        end,
        getPixel = function()
            return { getColor8 = function() return { a = state.dark and 0 or 255 } end }
        end,
    }
    view:paintTo(bb, state.x or 0, state.y or 0)
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
local function assertLayout(result, truncated)
    assert(result.line, "header must finish painting, not silently fail inside pcall")
    assert(#result.text == 2, "both text blocks must be painted")
    local left, right = result.text[1], result.text[2]
    assert(left.widget.max_width, "title must use KOReader's max_width field")
    assert(left.widget.maxWidth == nil, "unsupported maxWidth field")
    assert(left.x + left.w < right.x, "title must leave a gap before status")
    assert(right.widget.max_width == nil, "status must remain untruncated")
    assert(right.x + right.w == (result.x or 0) + (result.page_x or 0) + result.width - 40)
    assert((left.w < left.widget.full_width) == truncated, "unexpected title truncation")
    assert(left.widget.truncate_with_ellipsis ~= false, "keep native ellipsis behavior")
end

test("long title is bounded on the Bigme's 1264px portrait screen", function()
    assertLayout(render({ title = string.rep("A very long manga title ", 12) }), true)
end)
test("short titles keep their full width", function()
    assertLayout(render({ title = "Akira", author = "Otomo" }), false)
end)
test("long author and title use measured width, including landscape and large fonts", function()
    for _, width in ipairs({ 1264, 1680 }) do
        assertLayout(render({ width = width, font_scale = 2.5,
            author = string.rep("Wide WWW name ", 10), title = string.rep("iii ", 30) }), true)
    end
end)
test("larger page counts, charging and 12-hour time shrink the title budget", function()
    local normal = render({ title = string.rep("Title ", 30) })
    assertLayout(normal, true)
    local expanded = render({ title = string.rep("Title ", 30), page = 1234, total = 5678,
        battery = 100, charging = true, clock = "11:59 PM" })
    assertLayout(expanded, true)
    assert(expanded.text[1].widget.max_width < normal.text[1].widget.max_width)
end)
test("UTF-8 metadata reaches the native widget without byte slicing", function()
    local title = string.rep("\228\184\150\231\149\140 \195\165\195\164\195\182 ", 20)
    local result = render({ title = title, author = "First author\nSecond author" })
    assertLayout(result, true)
    assert(result.text[1].widget.text:find(title, 1, true), "metadata must not be cut by bytes")
    assert(result.text[1].widget.text:find("First author, et al.", 1, true))
end)
test("offset and fallback page geometry preserve alignment", function()
    assertLayout(render({ page_x = 17, x = 11, y = 23, title = string.rep("Title ", 40) }), true)
    assertLayout(render({ fallback_geometry = true, title = string.rep("Title ", 40) }), true)
end)
test("no space for a title still paints the status and header", function()
    local normal = render()
    local status_width = normal.text[2].w
    local result = render({ width = status_width + 80 })
    assert(result.line, "header must not abort when title space runs out")
    assert(#result.text == 1, "omit title when no positive space remains")
    assert(result.text[1].widget.text == normal.text[2].widget.text)
end)
test("opaque background, rule and contrast ribbon remain intact", function()
    for _, dark in ipairs({ false, true }) do
        local result, view = render({ bookmarked = true, dark = dark })
        local background = result.rects[1]
        assert(result.order[1] == "page" and result.order[2] == "rect")
        assert(background.color == "white" and background.w == 1264 and background.y == 0)
        assert(background.h == result.line.y + result.line.h)
        local ribbon = assert(view._manga_bookmark_ribbon_region)
        assert(ribbon.y == background.h, "ribbon must start below the header")
        assert(result.rects[2].y == ribbon.y)
        assert(result.rects[2].color == (dark and "black" or "white"), "contrast outline")
        local region = ReaderDogear.getRefreshRegion({ view = view })
        assert(region.y + region.h >= ribbon.y + ribbon.h, "refresh must cover ribbon tip")
    end
end)
test("only manga/comics in normal render mode get the header", function()
    assert(render({ file = "/books/epubs/serier/Comic.cbz" }).line)
    for _, opts in ipairs({ { file = "/books/epubs/fiction/Novel.epub" }, { render_mode = "thumbnail" } }) do
        local result = render(opts)
        assert(#result.text == 0 and #result.rects == 0)
        assert(result.order[1] == "page")
    end
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
