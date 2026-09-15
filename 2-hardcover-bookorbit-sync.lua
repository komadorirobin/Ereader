-- Let BookOrbit own automatic reading sync; keep the Hardcover API and links.
local userpatch = require("userpatch")
local _ = require("gettext")

local function disabled()
    return false
end

local function showNotice()
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = _("Automatic Hardcover reading sync is handled by BookOrbit.\n\n"
            .. "Linking, edition selection and metadata still work. Keep KOReader-to-BookOrbit sync enabled.\n\n"
            .. "Manual Hardcover status/rating actions are still available.\n\n"
            .. "To restore the plugin's automatic sync, disable 2-hardcover-bookorbit-sync.lua and restart KOReader."),
    })
end

local function disableSyncControls(items)
    for _index, item in ipairs(items) do
        if item.text == _("Automatically track progress")
                or item.text == "Always track progress by default"
                or item.text == _("Always track progress by default")
                or item.text == "Automatically set status to Currently Reading"
                or item.text == _("Automatically set status to Currently Reading") then
            item.checked_func = disabled
            item.enabled_func = disabled
            item.callback = nil
        end
    end
    return items
end

local function patchHardcover(plugin)
    local Settings = require("hardcover/lib/hardcover_settings")
    local Hardcover = require("hardcover/lib/hardcover")
    local Book = require("hardcover/lib/book")
    local Menu = require("hardcover/lib/ui/hardcover_menu")

    -- This shared gate also covers existing books with an explicit sync=true.
    -- Do not rewrite saved preferences: removing the patch is reversible.
    Settings.fileSyncEnabled = disabled
    Settings.syncEnabled = disabled
    Settings.setSync = function(self, value)
        if value then showNotice() end
    end

    -- The class is patched after instantiation. Already-created throttled
    -- callbacks still consult this gate before sending anything.
    plugin.syncFileUpdates = disabled
    plugin.onHardcoverTrack = showNotice
    plugin.onHardcoverUpdateProgress = showNotice

    -- Upstream linkBook also writes the remote edition with the current status.
    -- Keep linking local so even automatic edition matching cannot re-send it.
    function Hardcover:linkBook(book)
        local filename = self.ui and self.ui.document and self.ui.document.file
        if not filename or not book or not book.book_id then return false end
        local config = {
            book_id = book.book_id,
            edition_id = book.edition_id,
            edition_format = Book:editionFormatName(book.edition_format, book.reading_format_id),
            pages = book.pages,
            title = book.title,
            _delete = {},
        }
        for _index, key in ipairs({ "book_id", "edition_id", "edition_format", "pages", "title" }) do
            if config[key] == nil then
                config._delete[#config._delete + 1] = key
            end
        end
        self.settings:updateBookSetting(filename, config)
        self.cache:cacheUserBook()
        return true
    end

    -- Settings/menu modules are shared by successive Reader/FileManager instances.
    if not Menu._ereader_bookorbit_sync then
        local getSubMenuItems = Menu.getSubMenuItems
        function Menu:getSubMenuItems(...)
            local items = disableSyncControls(getSubMenuItems(self, ...))
            table.insert(items, 1, {
                text = _("Automatic reading sync: BookOrbit"),
                callback = showNotice,
                separator = true,
            })
            return items
        end
        local getSettingsSubMenuItems = Menu.getSettingsSubMenuItems
        function Menu:getSettingsSubMenuItems(...)
            return disableSyncControls(getSettingsSubMenuItems(self, ...))
        end
        Menu._ereader_bookorbit_sync = true
    end
end

-- The loader uses the plugin directory name, not its internal class name.
-- No Hardcover modules are loaded when the plugin is absent or disabled.
userpatch.registerPatchPluginFunc("hardcoverapp", patchHardcover)
