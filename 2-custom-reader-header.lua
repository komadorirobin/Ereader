local TextWidget = require("ui/widget/textwidget")
local Geom = require("ui/geometry")
local BD = require("ui/bidi")
local Device = require("device")
local Font = require("ui/font")
local util = require("util")
local datetime = require("datetime")
local T = require("ffi/util").template
local ReaderDogear = require("apps/reader/modules/readerdogear")
local ReaderView = require("apps/reader/modules/readerview")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Blitbuffer = require("ffi/blitbuffer")

local ReaderView_paintTo_orig = ReaderView.paintTo
local header_settings = G_reader_settings:readSetting("footer") or {}

-- Header config
local header_font_face = "ffont"
local header_font_size = header_settings.text_font_size or 14
local header_font_bold = header_settings.text_font_bold or false
local header_margin = 20
local header_top_margin = 10
local header_text_gap = 12
local separator = "│"

-- Same ribbon width, notched tip and contrast treatment as 2-header-manga.lua,
-- but the prose ribbon spans the complete header from the screen edge to the
-- bottom of its text. Each header remains standalone.
local function getBookmarkRibbonGeometry(right_edge, top, text_height)
    local width = math.max(20, math.floor(text_height * 0.75 + 0.5))
    local drop = math.max(12, math.floor(text_height * 0.55 + 0.5))
    local notch_depth = math.max(5, math.floor(drop * 0.5 + 0.5))
    local right_inset = math.max(8, math.floor(width * 0.4 + 0.5))
    local height = math.max(drop, header_top_margin + text_height)
    local ribbon_bottom = top + height

    return {
        x = right_edge - right_inset - width,
        y = top,
        w = width,
        h = height,
        notch_depth = notch_depth,
        notch_top = ribbon_bottom - notch_depth,
    }
end

local function getBookmarkRibbonColors(bb, geometry)
    if not bb or type(bb.getPixel) ~= "function" then
        return Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    end

    local x_samples = { 0.2, 0.5, 0.8 }
    local y_samples = { 0.15, 0.45, 0.75 }
    local luminance = 0
    local sample_count = 0
    for _, x_ratio in ipairs(x_samples) do
        for _, y_ratio in ipairs(y_samples) do
            local sample_x = geometry.x + math.floor((geometry.w - 1) * x_ratio)
            local sample_y = geometry.y + math.floor((geometry.h - 1) * y_ratio)
            local ok, pixel = pcall(bb.getPixel, bb, sample_x, sample_y)
            if ok and pixel and pixel.getColor8 then
                local color_ok, color = pcall(pixel.getColor8, pixel)
                local value = color_ok and color and tonumber(color.a) or nil
                if value then
                    luminance = luminance + value
                    sample_count = sample_count + 1
                end
            end
        end
    end

    if sample_count > 0 and luminance / sample_count < 128 then
        return Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    end
    return Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
end

local function paintBookmarkRibbonShape(bb, geometry, color)
    bb:paintRect(
        geometry.x,
        geometry.y,
        geometry.w,
        geometry.notch_top - geometry.y,
        color
    )
    local half_width = math.floor(geometry.w / 2)
    for row = 0, geometry.notch_depth - 1 do
        local tail_width = math.max(
            1,
            math.floor(
                half_width * (geometry.notch_depth - row) / geometry.notch_depth
            )
        )
        local row_y = geometry.notch_top + row
        bb:paintRect(geometry.x, row_y, tail_width, 1, color)
        bb:paintRect(
            geometry.x + geometry.w - tail_width,
            row_y,
            tail_width,
            1,
            color
        )
    end
end

local function paintBookmarkRibbon(bb, geometry, fill_color, outline_color)
    -- No top border: the ribbon emerges directly from the screen edge.
    paintBookmarkRibbonShape(bb, geometry, outline_color)

    local border = math.max(1, math.floor(geometry.w * 0.1 + 0.5))
    local inner_height = math.max(4, geometry.h - border)
    local inner_notch_depth = math.max(2, geometry.notch_depth - border)
    local inner_bottom = geometry.y + inner_height
    local inner = {
        x = geometry.x + border,
        y = geometry.y,
        w = geometry.w - border * 2,
        h = inner_height,
        notch_depth = inner_notch_depth,
        notch_top = inner_bottom - inner_notch_depth,
    }
    paintBookmarkRibbonShape(bb, inner, fill_color)
end

-- Function to check if book should show header (all ePubs except Manga and Serier)
local function shouldShowHeader(file_path)
    if not file_path then return false end
    -- Normalize path separators and convert to lowercase for comparison
    local normalized_path = string.lower(file_path:gsub("\\", "/"))
    
    -- Check if path contains "epubs/" (case-insensitive)
    if not string.find(normalized_path, "epubs/") then
        return false
    end
    
    -- Exclude specific folders
    if string.find(normalized_path, "epubs/manga") or string.find(normalized_path, "epubs/serier") then
        return false
    end
    
    return true
end

local function shouldShowRibbon(view)
    return view and view.render_mode == nil
        and shouldShowHeader(view.ui and view.ui.document and view.ui.document.file)
end

local ReaderDogear_paintTo_orig = ReaderDogear.paintTo
ReaderDogear.paintTo = function(self, bb, x, y)
    -- Unlike the manga header, prose has no opaque band to cover the native
    -- dogear. Skip only its drawing, without changing bookmark state/gestures.
    if bb == Device.screen.bb and shouldShowRibbon(self.view) then return end
    return ReaderDogear_paintTo_orig(self, bb, x, y)
end

local ReaderDogear_getRefreshRegion_orig = ReaderDogear.getRefreshRegion
ReaderDogear.getRefreshRegion = function(self)
    local region = ReaderDogear_getRefreshRegion_orig(self)
    local ribbon = shouldShowRibbon(self.view) and self.view._header_bookmark_ribbon_region
    if not ribbon then return region end

    -- Also works before the native icon has ever been painted (no icon.dimen).
    -- Keep this area when dogear_visible is false so removal refreshes the tip.
    local left = math.min(region and region.x or ribbon.x, ribbon.x)
    local top = math.min(region and region.y or ribbon.y, ribbon.y)
    local right = math.max(region and region.x + region.w or ribbon.x + ribbon.w, ribbon.x + ribbon.w)
    local bottom = math.max(region and region.y + region.h or ribbon.y + ribbon.h, ribbon.y + ribbon.h)
    return Geom:new { x = left, y = top, w = right - left, h = bottom - top }
end

-- Store original onCloseWidget if it exists
local ReaderView_onCloseWidget_orig = ReaderView.onCloseWidget

-- Setup event handlers for power events
ReaderView.onCloseWidget = function(self)
    -- Clean up event handlers
    if self._header_charge_event_handler then
        UIManager:unschedule(self._header_charge_event_handler)
        self._header_charge_event_handler = nil
    end
    
    -- Call original if it exists
    if ReaderView_onCloseWidget_orig then
        ReaderView_onCloseWidget_orig(self)
    end
end

-- Add handlers for charging events
ReaderView.onCharging = function(self)
    -- Force a partial refresh of the header area
    if self.ui and self.ui.view then
        UIManager:setDirty(self.ui, "partial")
    end
end

ReaderView.onNotCharging = function(self)
    -- Force a partial refresh of the header area
    if self.ui and self.ui.view then
        UIManager:setDirty(self.ui, "partial")
    end
end

-- Alternative: Poll for charging status changes
local function setupChargingMonitor(self)
    if not Device:hasBattery() then return end
    
    local powerd = Device:getPowerDevice()
    if not powerd or not powerd.isCharging then return end
    
    -- Store last charging state
    if self._last_charging_state == nil then
        self._last_charging_state = powerd:isCharging()
    end
    
    -- Check periodically for charging state changes
    self._header_charge_event_handler = function()
        local current_charging = powerd:isCharging()
        if current_charging ~= self._last_charging_state then
            self._last_charging_state = current_charging
            -- Trigger refresh
            UIManager:setDirty(self.ui, "partial")
        end
        -- Re-schedule check (every 2 seconds)
        UIManager:scheduleIn(2, self._header_charge_event_handler)
    end
    
    -- Start monitoring
    UIManager:scheduleIn(2, self._header_charge_event_handler)
end

ReaderView.paintTo = function(self, bb, x, y)
    ReaderView_paintTo_orig(self, bb, x, y)

    -- Thumbnails use an off-screen buffer (also in Page Scrubber). Do not
    -- draw headers or query device power APIs in their rendering subprocess.
    if bb ~= Device.screen.bb then return end
    
    if self.render_mode ~= nil then return end
    
    -- Check if current book should show header
    local book_path = self.ui and self.ui.document and self.ui.document.file
    if not shouldShowHeader(book_path) then
        return -- Don't show header for excluded folders
    end
    
    -- Setup charging monitor on first paint if not already done
    if not self._header_charge_event_handler and self.ui then
        setupChargingMonitor(self)
    end
    
    -- Book info
    local book_title = (self.ui and self.ui.doc_props and self.ui.doc_props.display_title) or ""
    local book_author = (self.ui and self.ui.doc_props and self.ui.doc_props.authors) or ""
    if book_author ~= "" and book_author:find("\n") then
        book_author = T("%1 et al.", util.splitToArray(book_author, "\n")[1] .. ",")
    end
    
    -- Time and battery
    local time = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    local battery_text = ""
    
    if Device:hasBattery() then
        local powerd = Device:getPowerDevice()
        if powerd and powerd.getCapacity then
            local lvl = powerd:getCapacity()
            if lvl then 
                -- Check if device is charging
                local charging_icon = ""
                if powerd.isCharging and powerd:isCharging() then
                    charging_icon = " ⚡"  -- Lightning bolt icon for charging
                end
                battery_text = tostring(lvl) .. " % batteri" .. charging_icon
            end
        end
    end
    
    -- Page geometry
    local page_geom = self.document and self.document.getPageInnerRect and self.document:getPageInnerRect()
    local page_x = page_geom and page_geom.x or 0
    local page_w = page_geom and page_geom.w or (Device.screen and Device.screen:getWidth()) or 1072
    
    -- Widgets
    local left_text = BD.auto(string.format("%s – %s", book_author, book_title))
    local right_text = string.format("%s %s %s", battery_text, separator, time)
    
    local right_widget = TextWidget:new {
        text = right_text,
        face = Font:getFace(header_font_face, header_font_size),
        bold = header_font_bold,
        padding = 0,
    }
    
    local right_size = right_widget:getSize()
    local bookmark_ribbon = getBookmarkRibbonGeometry(x + page_x + page_w, y, right_size.h)
    local side_margin_extra = header_margin * 2
    -- Reserve more room when large header fonts make the ribbon wider.
    local right_margin = math.max(side_margin_extra, x + page_x + page_w - bookmark_ribbon.x + 8)
    local max_left_width = page_w - right_size.w - side_margin_extra - right_margin - header_text_gap
    local left_widget
    if max_left_width > 0 then
        left_widget = TextWidget:new {
            text = left_text,
            face = Font:getFace(header_font_face, header_font_size),
            bold = header_font_bold,
            padding = 0,
            max_width = max_left_width,
        }
    end
    
    -- Positions
    local left_x = page_x + side_margin_extra
    local right_x = page_x + page_w - right_margin - right_size.w
    local header_y = y + header_top_margin
    
    if left_widget then
        left_widget:paintTo(bb, x + left_x, header_y)
        left_widget:free()
    end
    right_widget:paintTo(bb, x + right_x, header_y)
    right_widget:free()

    self._header_bookmark_ribbon_region = bookmark_ribbon
    if self.dogear_visible then
        local fill_color, outline_color = getBookmarkRibbonColors(bb, bookmark_ribbon)
        paintBookmarkRibbon(bb, bookmark_ribbon, fill_color, outline_color)
    end
end
