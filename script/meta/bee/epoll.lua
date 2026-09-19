---@meta bee.epoll

---@class bee.epoll.fd
local epfd = {}

---@param fd userdata
---@param events integer
---@return boolean?
---@return string? err
function epfd:event_add(fd, events) end

---@param timeout? integer
---@return fun(): any?, integer?
function epfd:wait(timeout) end

---@return boolean?
---@return string? err
function epfd:close() end

---@class bee.epoll
---@field EPOLLIN integer
local epoll = {}

---@param max_events integer
---@return bee.epoll.fd?
function epoll.create(max_events) end

return epoll
