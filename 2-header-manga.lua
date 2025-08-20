local TextWidget = require("ui/widget/textwidget")
local Geom = require("ui/geometry")
local BD = require("ui/bidi")
local Device = require("device")
local Font = require("ui/font")
local util = require("util")
local datetime = require("datetime")
local T = require("ffi/util").template
local ReaderView = require("apps/reader/modules/readerview")
local LineWidget = require("ui/widget/linewidget")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")

local ReaderView_paintTo_orig = ReaderView.paintTo
local header_settings = G_reader_settings:readSetting("footer") or {}

-- Header config (2 points smaller font)
local header_font_face = "ffont"
local header_font_size = (header_settings.text_font_size or 14) - 2
local header_font_bold = header_settings.text_font_bold or false
local header_margin = 20
local header_top_margin = 8
local separator = "│"

-- Function to check if book is manga or serier
local function isMangaOrSerier(file_path)
    if not file_path then return false end
    -- Normalize path separators and convert to lowercase for comparison
    local normalized_path = string.lower(file_path:gsub("\\", "/"))
    
    -- Check if path contains manga or serier folders
    return string.find(normalized_path, "epubs/manga") or string.find(normalized_path, "epubs/serier")
end

-- Function to safely get current page
local function getCurrentPage(ui)
    if not ui then return nil end
    
    -- Try different ways to get current page based on view mode
    if ui.view and ui.view.state and ui.view.state.page then
        return ui.view.state.page
    elseif ui.document and ui.document.state and ui.document.state.page then
        return ui.document.state.page
    elseif ui.paging and ui.paging.current_page then
        return ui.paging.current_page
    elseif ui.view and ui.view.document then
        local success, page = pcall(function()
            return ui.view.document:getCurrentPage()
        end)
        if success and page then return page end
    end
    
    return nil
end

-- Function to safely get total pages
local function getTotalPages(ui)
    if not ui or not ui.document then return nil end
    
    local success, total = pcall(function()
        return ui.document:getPageCount()
    end)
    
    if success and total and type(total) == "number" then
        return total
    end
    
    return nil
end

-- Function to get pages left in book
local function getPagesLeftInBook(ui)
    if not ui then return "?" end
    
    local success, result = pcall(function()
        local current_page = getCurrentPage(ui)
        local total_pages = getTotalPages(ui)
        
        if not current_page or not total_pages then return "?" end
        
        local pages_left = total_pages - current_page
        return pages_left > 0 and tostring(pages_left) or "0"
    end)
    
    if success and result then
        return result
    else
        return "?"
    end
end

-- Store original onCloseWidget if it exists
local ReaderView_onCloseWidget_orig = ReaderView.onCloseWidget

-- Setup event handlers for power events
ReaderView.onCloseWidget = function(self)
    -- Clean up event handlers
    if self._manga_header_charge_event_handler then
        UIManager:unschedule(self._manga_header_charge_event_handler)
        self._manga_header_charge_event_handler = nil
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
    if self._manga_last_charging_state == nil then
        self._manga_last_charging_state = powerd:isCharging()
    end
    
    -- Check periodically for charging state changes
    self._manga_header_charge_event_handler = function()
        local current_charging = powerd:isCharging()
        if current_charging ~= self._manga_last_charging_state then
            self._manga_last_charging_state = current_charging
            -- Trigger refresh
            UIManager:setDirty(self.ui, "partial")
        end
        -- Re-schedule check (every 2 seconds)
        UIManager:scheduleIn(2, self._manga_header_charge_event_handler)
    end
    
    -- Start monitoring
    UIManager:scheduleIn(2, self._manga_header_charge_event_handler)
end

ReaderView.paintTo = function(self, bb, x, y)
    ReaderView_paintTo_orig(self, bb, x, y)
    
    if self.render_mode ~= nil then return end
    
    -- Check if current book is manga or serier
    local book_path = self.ui and self.ui.document and self.ui.document.file
    if not isMangaOrSerier(book_path) then
        return -- Don't show header for other books
    end
    
    -- Setup charging monitor on first paint if not already done
    if not self._manga_header_charge_event_handler and self.ui then
        setupChargingMonitor(self)
    end
    
    -- Wrap everything in pcall for safety
    local success, error_msg = pcall(function()
        -- Book info (same format as original header)
        local book_title = (self.ui and self.ui.doc_props and self.ui.doc_props.display_title) or ""
        local book_author = (self.ui and self.ui.doc_props and self.ui.doc_props.authors) or ""
        if book_author ~= "" and book_author:find("\n") then
            book_author = T("%1 et al.", util.splitToArray(book_author, "\n")[1] .. ",")
        end
        
        -- Time, battery and pages left
        local time = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
        local battery_text = ""
        if Device and Device.hasBattery and Device:hasBattery() then
            local powerdev = Device:getPowerDevice()
            if powerdev and powerdev.getCapacity then
                local lvl = powerdev:getCapacity()
                if lvl then 
                    -- Check if device is charging
                    local charging_icon = ""
                    if powerdev.isCharging and powerdev:isCharging() then
                        charging_icon = " ⚡"  -- Lightning bolt icon for charging
                    end
                    battery_text = tostring(lvl) .. " % batteri" .. charging_icon
                end
            elseif Device.getBatteryStatus then
                local status = Device:getBatteryStatus()
                if status and status.level then 
                    battery_text = tostring(status.level) .. " % batteri"
                end
            end
        end
        
        -- Get current page and total pages
        local current_page = getCurrentPage(self.ui)
        local total_pages = getTotalPages(self.ui)
        
        -- Pages left info and progress percentage
        local pages_left = getPagesLeftInBook(self.ui)
        local progress_percent = ""
        
        -- Calculate reading progress percentage
        local success, result = pcall(function()
            if current_page and total_pages and total_pages > 0 then
                local progress = math.floor((current_page / total_pages) * 100)
                return tostring(progress) .. " %"
            end
            return "0 %"
        end)
        
        if success and result then
            progress_percent = result
        else
            progress_percent = "? %"
        end
        
        -- Page geometry (same as original header)
        local page_geom = self.document and self.document.getPageInnerRect and self.document:getPageInnerRect()
        local page_x = page_geom and page_geom.x or 0
        local page_w = page_geom and page_geom.w or (Device.screen and Device.screen:getWidth()) or 1072
        
        -- Widgets (add current/total pages before pages left)
        local left_text = BD.auto(string.format("%s – %s", book_author, book_title))
        local right_text = string.format("%s/%s %s %s kvar %s %s %s %s %s %s", 
                                       current_page or "?",
                                       total_pages or "?",
                                       separator,
                                       pages_left,
                                       separator,
                                       progress_percent,
                                       separator,
                                       battery_text,
                                       separator,
                                       time)
        
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
        
        -- Positions (same as original header)
        local left_x = page_x + side_margin_extra
        local right_x = page_x + page_w - side_margin_extra - right_widget:getSize().w
        local header_y = y + header_top_margin
        
        left_widget:paintTo(bb, x + left_x, header_y)
        right_widget:paintTo(bb, x + right_x, header_y)
        
        -- Add horizontal line under the header text
        local line_y = header_y + left_widget:getSize().h + 2  -- 2px spacing below text
        local line_widget = LineWidget:new{
            dimen = Geom:new{
                w = page_w,
                h = 1,  -- 1px line thickness
            }
        }
        line_widget:paintTo(bb, x + page_x, line_y)
    end)
    
    -- If there's an error, silently fail (don't crash KOReader)
    if not success then
        -- Optionally log error for debugging
        -- print("Manga header error: " .. tostring(error_msg))
    end
end
