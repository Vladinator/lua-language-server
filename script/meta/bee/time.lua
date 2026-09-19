---@meta bee.time

---@class bee.time
local time = {}

--- Wall-clock time in milliseconds.
---@return integer
function time.time() end

--- Monotonic clock in milliseconds.
---@return integer
function time.monotonic() end

return time
