local ReaderView = require("apps/reader/modules/readerview")

-- Save original paintTo function
local ReaderView_paintTo_orig = ReaderView.paintTo

-- Function to check if book is manga or serier
local function isMangaOrSerier(file_path)
    if not file_path then return false end
    -- Normalize path separators and convert to lowercase for comparison
    local normalized_path = string.lower(file_path:gsub("\\", "/"))
    
    -- Check if path contains manga or serier folders
    return string.find(normalized_path, "epubs/manga") or string.find(normalized_path, "epubs/serier")
end

-- Override paintTo function to shift content down for manga/serier
ReaderView.paintTo = function(self, bb, x, y)
    -- Check if current book is manga or serier
    local book_path = self.ui and self.ui.document and self.ui.document.file
    
    if isMangaOrSerier(book_path) then
        -- Shift content down by 7 pixels to reduce bottom margin
        ReaderView_paintTo_orig(self, bb, x, y + 7)
    else
        -- Call original paintTo function for other books
        ReaderView_paintTo_orig(self, bb, x, y)
    end
end