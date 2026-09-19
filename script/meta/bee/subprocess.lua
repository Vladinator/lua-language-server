---@meta bee.subprocess

---@class bee.subprocess.process
local process = {}

---@return integer? exitCode
---@return string? err
function process:wait() end

---@class bee.subprocess
local subprocess = {}

---@param args table
---@return bee.subprocess.process?
---@return string? err
function subprocess.spawn(args) end

---@return integer
function subprocess.get_id() end

return subprocess
