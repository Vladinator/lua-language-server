local socket = require "bee.socket"
local select = require "bee.select"
local fs = require "bee.filesystem"

local selector = select.create()
local SELECT_READ <const> = select.SELECT_READ
local SELECT_WRITE <const> = select.SELECT_WRITE

---@class net.socket
---@field public _fd bee.socket.fd
---@field public _flags integer
---@field public _event table<string, fun(...): any>

---@param s net.socket
local function fd_clr_read(s)
    if s._flags & SELECT_READ == 0 then
        return
    end
    s._flags = s._flags & (~SELECT_READ)
    selector:event_mod(s._fd, s._flags)
end

---@param s net.socket
local function fd_set_write(s)
    if s._flags & SELECT_WRITE ~= 0 then
        return
    end
    s._flags = s._flags | SELECT_WRITE
    selector:event_mod(s._fd, s._flags)
end

---@param s net.socket
local function fd_clr_write(s)
    if s._flags & SELECT_WRITE == 0 then
        return
    end
    s._flags = s._flags & (~SELECT_WRITE)
    selector:event_mod(s._fd, s._flags)
end

---@param self net.socket
---@param name string
---@param ... any
---@return any ...
local function on_event(self, name, ...)
    local f = self._event[name]
    if f then
        return f(self, ...)
    end
end

---@param self net.socket
local function close(self)
    local fd = self._fd
    on_event(self, "close")
    selector:event_del(fd)
    fd:close()
end

local stream_mt = {}
---@class net.stream: net.socket
---@field public _writebuf string
---@field public shutdown_r boolean
---@field public shutdown_w boolean
local stream = {}
stream_mt.__index = stream
---@param self net.stream
---@param name string
---@param func fun(...): any
function stream_mt:__newindex(name, func)
    if name:sub(1, 3) == "on_" then
        self._event[name:sub(4)] = func
    end
end
---@param self net.stream
---@param data string
function stream:write(data)
    if self.shutdown_w then
        return
    end
    if data == "" then
        return
    end
    if self._writebuf == "" then
        fd_set_write(self)
    end
    self._writebuf = self._writebuf .. data
end
---@param self net.stream
---@return boolean
function stream:is_closed()
    return self.shutdown_w and self.shutdown_r
end
---@param self net.stream
function stream:close()
    if not self.shutdown_r then
        self.shutdown_r = true
        fd_clr_read(self)
    end
    if self.shutdown_w or self._writebuf == ""  then
        self.shutdown_w = true
        fd_clr_write(self)
        close(self)
    end
end
---@param self net.stream
local function close_write(self)
    fd_clr_write(self)
    if self.shutdown_r then
        close(self)
    end
end
---@param s net.stream
---@param event integer
local function update_stream(s, event)
    if event & SELECT_READ ~= 0 then
        local data = s._fd:recv()
        if data == nil then
            s:close()
        elseif data == false then
        else
            on_event(s, "data", data)
        end
    end
    if event & SELECT_WRITE ~= 0 then
        local n = s._fd:send(s._writebuf)
        if n == nil then
            s.shutdown_w = true
            close_write(s)
        elseif n == false then
        else
            s._writebuf = s._writebuf:sub(n + 1)
            if s._writebuf == "" then
                close_write(s)
            end
        end
    end
end

local listen_mt = {}
---@class net.listen: net.socket
---@field public shutdown_r boolean
local listen = {}
listen_mt.__index = listen
---@param self net.listen
---@param name string
---@param func fun(...): any
function listen_mt:__newindex(name, func)
    if name:sub(1, 3) == "on_" then
        self._event[name:sub(4)] = func
    end
end
---@param self net.listen
---@return boolean
function listen:is_closed()
    return self.shutdown_r
end
---@param self net.listen
function listen:close()
    self.shutdown_r = true
    close(self)
end

local connect_mt = {}
---@class net.connect: net.socket
---@field public _writebuf string
---@field public shutdown_w boolean
local connect = {}
connect_mt.__index = connect
---@param self net.connect
---@param name string
---@param func fun(...): any
function connect_mt:__newindex(name, func)
    if name:sub(1, 3) == "on_" then
        self._event[name:sub(4)] = func
    end
end
---@param self net.connect
---@param data string
function connect:write(data)
    if data == "" then
        return
    end
    self._writebuf = self._writebuf .. data
end
---@param self net.connect
---@return boolean
function connect:is_closed()
    return self.shutdown_w
end
---@param self net.connect
function connect:close()
    self.shutdown_w = true
    close(self)
end

local m = {}

---@param protocol "tcp"|"udp"|"unix"|"tcp6"|"udp6"
---@param address string
---@param port? integer
---@return net.listen?
---@return string?
function m.listen(protocol, address, port)
    ---@type bee.socket.fd?
    local fd; do
        local err
        fd, err = socket.create(protocol)
        if not fd then
            return nil, err
        end
        if protocol == "unix" then
            fs.remove(fs.path(address))
        end
    end
    do
        local ok, err = fd:bind(address, port)
        if not ok then
            fd:close()
            return nil, err
        end
    end
    do
        local ok, err = fd:listen()
        if not ok then
            fd:close()
            return nil, err
        end
    end
    ---@type net.listen
    local s = {
        _fd = fd,
        _flags = SELECT_READ,
        _event = {},
        shutdown_r = false,
        shutdown_w = true,
    }
    selector:event_add(fd, SELECT_READ, function ()
        local new_fd, err = fd:accept()
        if new_fd == nil then
            fd:close()
            on_event(s, "error", err)
            return
        elseif new_fd == false then
        else
            ---@type net.stream
            local new_s = setmetatable({
                _fd = new_fd,
                _flags = SELECT_READ,
                _event = {},
                _writebuf = "",
                shutdown_r = false,
                shutdown_w = false,
            }, stream_mt)
            if on_event(s, "accepted", new_s) then
                selector:event_add(new_fd, new_s._flags, function (event)
                    update_stream(new_s, event)
                end)
            else
                new_fd:close()
            end
        end
    end)
    return (setmetatable(s, listen_mt))
end

---@param protocol "tcp"|"udp"|"unix"|"tcp6"|"udp6"
---@param address string
---@param port? integer
---@return net.connect?
---@return string?
function m.connect(protocol, address, port)
    ---@type bee.socket.fd?
    local fd; do
        local err
        fd, err = socket.create(protocol)
        if not fd then
            return nil, err
        end
    end
    do
        local ok, err = fd:connect(address, port)
        if ok == nil then
            fd:close()
            return nil, err
        end
    end
    ---@type net.connect
    local s = {
        _fd = fd,
        _flags = SELECT_WRITE,
        _event = {},
        _writebuf = "",
        shutdown_r = false,
        shutdown_w = false,
    }
    selector:event_add(fd, SELECT_WRITE, function ()
        local ok, err = fd:status()
        if ok then
            on_event(s, "connected")
            setmetatable(s, stream_mt --[[@as metatable]])
            local stream_s = s --[[@as net.stream]]
            if stream_s._writebuf ~= "" then
                update_stream(stream_s, SELECT_WRITE)
                if stream_s._writebuf ~= "" then
                    stream_s._flags = SELECT_READ | SELECT_WRITE
                else
                    stream_s._flags = SELECT_READ
                end
            else
                stream_s._flags = SELECT_READ
            end
            selector:event_add(stream_s._fd, stream_s._flags, function (event)
                update_stream(stream_s, event)
            end)
        else
            s:close()
            on_event(s, "error", err)
        end
    end)
    return (setmetatable(s, connect_mt))
end

---@param timeout? integer
function m.update(timeout)
    for func, event in selector:wait(timeout or 0) do
        func(event)
    end
end

return m
