local TextWidget = require("ui/widget/textwidget")
local Geom = require("ui/geometry")
local BD = require("ui/bidi")
local Device = require("device")
local Font = require("ui/font")
local util = require("util")
local datetime = require("datetime")
local T = require("ffi/util").template
local ReaderView = require("apps/reader/modules/readerview")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")

local ReaderView_paintTo_orig = ReaderView.paintTo
local header_settings = G_reader_settings:readSetting("footer") or {}

-- Header config
local header_font_face = "ffont"
local header_font_size = header_settings.text_font_size or 14
local header_font_bold = header_settings.text_font_bold or false
local header_margin = 20
local header_top_margin = 10
local separator = "│"

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
    
    local side_margin_extra = header_margin * 2  -- Extra margin for symmetry and bookmark icon
    local max_left_width = page_w - right_widget:getSize().w - side_margin_extra - side_margin_extra
    local left_widget = TextWidget:new {
        text = left_text,
        face = Font:getFace(header_font_face, header_font_size),
        bold = header_font_bold,
        padding = 0,
        maxWidth = max_left_width,
    }
    
    -- Positions
    local left_x = page_x + side_margin_extra
    local right_x = page_x + page_w - side_margin_extra - right_widget:getSize().w
    local header_y = y + header_top_margin
    
    left_widget:paintTo(bb, x + left_x, header_y)
    right_widget:paintTo(bb, x + right_x, header_y)
end