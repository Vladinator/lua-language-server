---@meta bee.windows

---@class bee.windows
local windows = {}

--- ANSI code page -> UTF-8.
---@param text string
---@return string
function windows.a2u(text) end

--- UTF-8 -> ANSI code page.
---@param text string
---@return string
function windows.u2a(text) end

---@param f file*
---@param mode string
function windows.filemode(f, mode) end

return windows
