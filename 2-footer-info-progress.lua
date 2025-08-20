local TextWidget = require("ui/widget/textwidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local BD = require("ui/bidi")
local Device = require("device")
local Font = require("ui/font")
local util = require("util")
local datetime = require("datetime")
local T = require("ffi/util").template
local ReaderView = require("apps/reader/modules/readerview")
local ReaderView_paintTo_orig = ReaderView.paintTo
local header_settings = G_reader_settings:readSetting("footer") or {}

-- Footer config
local footer_font_face = "ffont"
local footer_font_size = header_settings.text_font_size or 14
local footer_font_bold = header_settings.text_font_bold or false
local footer_margin = 20
local footer_bottom_margin = 10
local separator = "│"

-- Progress bar config
local progress_bar_height = 8   -- Höjd på progress bar (ökad från 6)
local progress_bar_margin = 8   -- Marginal ovanför/under progress bar

-- Function to check if book should show footer (all ePubs except Manga and Serier)
local function shouldShowFooter(file_path)
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

-- Function to get reading progress (0.0 to 1.0)
local function getReadingProgress(ui)
    if not ui then return 0 end
    
    local success, result = pcall(function()
        local current_page = getCurrentPage(ui)
        local total_pages = getTotalPages(ui)
        
        if not current_page or not total_pages or total_pages == 0 then 
            return 0 
        end
        
        return current_page / total_pages
    end)
    
    if success and result then
        return math.min(math.max(result, 0), 1) -- Clamp between 0 and 1
    else
        return 0
    end
end

-- Function to get chapter positions for progress bar ticks (adapted from sebastien's patch)
local function getChapterTicks(ui)
    if not ui then return nil end
    
    local success, result = pcall(function()
        local total_pages = getTotalPages(ui)
        if not total_pages or total_pages == 0 then return nil end
        
        if ui.document and ui.document.getToc then
            local toc_table = ui.document:getToc()
            if toc_table and type(toc_table) == "table" and #toc_table > 1 then
                local ticks = {}
                
                -- Beräkna absoluta sidnummer för varje kapitel (inte relativa positioner)
                for i = 1, #toc_table do
                    local item = toc_table[i]
                    if item and item.page and type(item.page) == "number" then
                        table.insert(ticks, item.page)
                    end
                end
                
                -- Returnera bara om vi har fler än 1 kapitel
                return #ticks > 1 and ticks or nil
            end
        end
        
        return nil
    end)
    
    if success then
        return result
    else
        return nil
    end
end

-- Function to get chapter name (using document TOC)
local function getChapterName(ui)
    if not ui then return "Okänt kapitel" end
    
    local success, result = pcall(function()
        local current_page = getCurrentPage(ui)
        if not current_page then return "Okänt kapitel" end
        
        -- Use document TOC since ui.toc:getToc() fails
        if ui.document and ui.document.getToc then
            local toc_table = ui.document:getToc()
            if toc_table and type(toc_table) == "table" and #toc_table > 0 then
                
                local current_chapter = "Okänt kapitel"
                
                -- Find the last chapter that starts before or at current page
                for i = 1, #toc_table do
                    local item = toc_table[i]
                    if item and item.page and type(item.page) == "number" and item.page <= current_page then
                        if item.title and type(item.title) == "string" and item.title ~= "" then
                            current_chapter = item.title
                        else
                            current_chapter = "Kapitel " .. tostring(i)
                        end
                    end
                end
                
                return current_chapter
            end
        end
        
        return "Okänt kapitel"
    end)
    
    if success and result then
        return result
    else
        return "Okänt kapitel"
    end
end

-- Function to get pages left in current chapter (using document TOC)
local function getPagesLeftInChapter(ui)
    if not ui then return "?" end
    
    local success, result = pcall(function()
        local current_page = getCurrentPage(ui)
        local total_pages = getTotalPages(ui)
        
        if not current_page or not total_pages then return "?" end
        
        -- Use document TOC
        if ui.document and ui.document.getToc then
            local toc_table = ui.document:getToc()
            if toc_table and type(toc_table) == "table" and #toc_table > 0 then
                
                -- Find current chapter and next chapter
                local current_chapter_index = nil
                for i = 1, #toc_table do
                    local item = toc_table[i]
                    if item and item.page and type(item.page) == "number" and item.page <= current_page then
                        current_chapter_index = i
                    end
                end
                
                if current_chapter_index then
                    local next_chapter_page = total_pages + 1
                    if current_chapter_index < #toc_table then
                        local next_item = toc_table[current_chapter_index + 1]
                        if next_item and next_item.page and type(next_item.page) == "number" then
                            next_chapter_page = next_item.page
                        end
                    end
                    
                    local pages_left = next_chapter_page - current_page - 1
                    return pages_left > 0 and tostring(pages_left) or "0"
                end
            end
        end
        
        return "?"
    end)
    
    if success and result then
        return result
    else
        return "?"
    end
end

-- Function to get pages left in book (simplified)
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

ReaderView.paintTo = function(self, bb, x, y)
    ReaderView_paintTo_orig(self, bb, x, y)
    
    if self.render_mode ~= nil then return end
    
    -- Wrap everything in pcall for safety
    local success, error_msg = pcall(function()
        -- Check if current book should show footer
        local book_path = self.ui and self.ui.document and self.ui.document.file
        if not shouldShowFooter(book_path) then
            return -- Don't show footer for excluded folders
        end
        
        -- Try to get basic info
        local current_page = getCurrentPage(self.ui)
        local total_pages = getTotalPages(self.ui)
        
        -- Chapter and page info
        local chapter_name = getChapterName(self.ui)
        local pages_left_chapter = getPagesLeftInChapter(self.ui)
        local pages_left_book = getPagesLeftInBook(self.ui)
        local reading_progress = getReadingProgress(self.ui)
        local chapter_ticks = getChapterTicks(self.ui)
        local current_page = getCurrentPage(self.ui)
        local total_pages = getTotalPages(self.ui)
        
        -- Page geometry with safer defaults
        local page_geom = self.document and self.document.getPageInnerRect and self.document:getPageInnerRect()
        local page_x = page_geom and page_geom.x or 0
        local page_w = page_geom and page_geom.w or (Device.screen and Device.screen:getWidth()) or 1072
        local page_h = page_geom and page_geom.h or (Device.screen and Device.screen:getHeight()) or 1448
        
        -- Create text content with current page/total pages added
        local left_text = BD.auto(chapter_name or "Okänt kapitel")
        local progress_percent = math.floor((reading_progress or 0) * 100)
        local right_text = string.format("%s/%s %s %s kvar i kap %s %s kvar i bok %s %d %%", 
                                       current_page or "?",
                                       total_pages or "?",
                                       separator,
                                       pages_left_chapter or "?", 
                                       separator, 
                                       pages_left_book or "?",
                                       separator,
                                       progress_percent)
        
        -- Create widgets
        local right_widget = TextWidget:new {
            text = right_text,
            face = Font:getFace(footer_font_face, footer_font_size),
            bold = footer_font_bold,
            padding = 0,
        }
        
        local max_left_width = page_w - right_widget:getSize().w - footer_margin*2
        if max_left_width < 100 then max_left_width = 100 end -- Minimum width
        
        local left_widget = TextWidget:new {
            text = left_text,
            face = Font:getFace(footer_font_face, footer_font_size),
            bold = footer_font_bold,
            padding = 0,
            max_width = max_left_width,
        }
        
        -- Create progress bar widget (full width with margins)
        local progress_bar_width = page_w - footer_margin * 2
        local progress_widget = ProgressWidget:new {
            width = progress_bar_width,
            height = progress_bar_height,
            percentage = reading_progress,
            ticks = chapter_ticks, -- Sidnummer för kapitel
            last = total_pages,    -- Total antal sidor (behövs för tick-beräkning)
            tick_width = 2,
            margin_h = 0,
            margin_v = 0,
        }
        
        -- Calculate footer dimensions and position
        local text_height = left_widget:getSize().h
        local total_footer_height = text_height + progress_bar_height + progress_bar_margin
        local footer_y = y + page_h - total_footer_height - footer_bottom_margin
        
        -- Text positions (top row)
        local left_x = page_x + footer_margin
        local right_x = page_x + page_w - footer_margin - right_widget:getSize().w
        
        -- Progress bar position (bottom row, full width with margins)
        local progress_x = page_x + footer_margin
        local progress_y = footer_y + text_height + progress_bar_margin
        
        -- Paint all widgets
        left_widget:paintTo(bb, x + left_x, footer_y)
        right_widget:paintTo(bb, x + right_x, footer_y)
        progress_widget:paintTo(bb, x + progress_x, progress_y)
        
    end)
    
    -- If there's an error, silently fail (don't crash KOReader)
    if not success then
        -- Debug information
        print("Footer error: " .. tostring(error_msg))
    end
end