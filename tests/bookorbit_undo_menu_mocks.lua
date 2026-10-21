-- Drawing-only stand-ins. The adapter test still loads the real upstream
-- menu sheet, controller dispatch and patch; no reader or graphics needed.
local function node(kind, children, attrs)
    local n = { kind = kind, children = children, attrs = attrs or {} }
    function n:getSize() return { w = self.attrs.w or 20, h = self.attrs.h or 20 } end
    return n
end
local function preload(name, value) package.preload[name] = function() return value end end
preload("datetime", { secondsToHour = function() return "12:00" end })
preload("bookorbit_board_metrics", {
    setUserScale = function(scale) return scale or 1.05 end,
    px = function(n) return n end, INK = {},
})
local Board = {}
for _, name in ipairs({ "text", "runs", "icon", "space", "rect", "flex", "statusCluster" }) do
    Board[name] = function(value, opts) return node(name, nil, type(opts) == "table" and opts or { value = value }) end
end
for _, name in ipairs({ "hstack", "vstack" }) do
    Board[name] = function(opts, children) return node(name, children, opts) end
end
function Board.overlay(w, h, layers) return node("overlay", layers, { w = w, h = h }) end
function Board.hit(widget, action) return node("hit", { widget }, { action = action }) end
preload("bookorbit_board_ui", Board)
local MenuUI = {
    serverHost = function() return "example.test" end,
    ago = function(value) return value and "recently" or nil end,
    rowsIn = function(w) return w - 32 end,
    tapInset = function() return 4 end, hair = function() return 1 end,
    iconButton = function(icon, action) return node("button", nil, { action = action, icon = icon }) end,
    row = function(w, attrs) return node("row", nil, attrs) end,
    group = function(w, children) return node("group", children, { w = w }) end,
    card = function(w, children) return node("card", children, { w = w }) end,
    section = function(w, title, widget) return node("section", { widget }, { w = w, title = title }) end,
    chip = function(label) return node("chip", nil, { label = label }) end,
}
preload("bookorbit_menu_ui", MenuUI)
preload("bookorbit_menu_page", {
    new = function(self, attrs)
        function attrs:close() self.closed = true end
        return attrs
    end,
})

-- Extract actions from the real sheet's composed widget tree.
return function(widgets)
    local actions = {}
    local function visit(n)
        if type(n) ~= "table" then return end
        if n.attrs and n.attrs.action then actions[#actions + 1] = n.attrs.action end
        for _, child in ipairs(n.children or {}) do visit(child.widget or child) end
    end
    for _, widget in ipairs(widgets) do visit(widget) end
    return actions
end
