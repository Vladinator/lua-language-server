local fs             = require 'bee.filesystem'

---@class log.bee_time
---@field time      fun(): integer
---@field monotonic fun(): integer

---@type log.bee_time
local time           = require 'bee.time'

local monotonic      = time.monotonic
local osDate         = os.date
local ioOpen         = io.open
local tablePack      = table.pack
local tableConcat    = table.concat
local tostring       = tostring
local debugTraceBack = debug.traceback
local mathModf       = math.modf
local debugGetInfo   = debug.getinfo
local ioStdErr       = io.stderr

---@class log
---@field file?       file*
---@field startTime   integer
---@field size        integer
---@field maxSize     integer
---@field level       string
---@field levelMap    table<string, integer>
---@field path?       string
---@field prefixLen?  integer
---@field print?      boolean
---@field firstError? string
local m = {}

m.file = nil
m.startTime = time.time() - monotonic()
m.size = 0
m.maxSize = 100 * 1024 * 1024
m.level = 'info'
m.levelMap = {
    ['trace'] = 1,
    ['debug'] = 2,
    ['info']  = 3,
    ['warn']  = 4,
    ['error'] = 5,
}

---@param src string
---@return string
local function trimSrc(src)
    if src:sub(1, 1) == '@' then
        src = src:sub(2)
    end
    return src
end

local function init_log_file()
    if not m.file then
        m.file = ioOpen(m.path, 'w')
        if not m.file then
            return
        end
        m.file:write('')
        m.file:close()
        m.file = ioOpen(m.path, 'ab')
        if not m.file then
            return
        end
        m.file:setvbuf 'no'
    end
end

---@param level string
---@param ... any
---@return string?
local function pushLog(level, ...)
    if not m.path then
        return
    end
    ---@type { n: integer, [integer]: any }
    local t = tablePack(...)
    for i = 1, t.n do
        t[i] = tostring(t[i])
    end
    local joined = tableConcat(t, '\t', 1, t.n)
    ---@type string
    local str
    if level == 'error' then
        str = joined .. '\n' .. debugTraceBack(nil, 3)
    else
        str = joined
    end
    local info = debugGetInfo(3, 'Sl')
    local text = m.raw(0, level, str, info.source, info.currentline, monotonic())

    return text
end

---@param ... any
function m.trace(...)
    pushLog('trace', ...)
end

---@param ... any
function m.debug(...)
    pushLog('debug', ...)
end

---@param ... any
function m.info(...)
    pushLog('info', ...)
end

---@param ... any
function m.warn(...)
    pushLog('warn', ...)
end

---@param ... any
---@return string?
function m.error(...)
    -- Don't use tail calls,
    -- Otherwise, the count of `debug.getinfo` will be wrong
    local msg = pushLog('error', ...)
    return msg
end

---@param thd         integer
---@param level       string
---@param msg         string
---@param source      string
---@param currentline integer
---@param clock       integer
---@return string
function m.raw(thd, level, msg, source, currentline, clock)
    if m.levelMap[level] < (m.levelMap[m.level] or m.levelMap['info']) then
        return msg
    end
    if level == 'error' then
        ioStdErr:write(msg .. '\n')
        if not m.firstError then
            m.firstError = msg
        end
    end
    if m.size > m.maxSize then
        return msg
    end
    init_log_file()
    local sec, ms = mathModf((m.startTime + clock) / 1000)
    local timestr = osDate('%H:%M:%S', sec)
    local agl = ''
    if #level < 5 then
        agl = (' '):rep(5 - #level)
    end
    local buf ---@type string
    if currentline == -1 then
        buf = ('[%s.%03.f][%s]%s[#%d]: %s\n'):format(timestr, ms * 1000, level, agl, thd, msg)
    else
        buf = ('[%s.%03.f][%s]%s[#%d:%s:%s]: %s\n'):format(timestr, ms * 1000, level, agl, thd, trimSrc(source), currentline, msg)
    end
    m.size = m.size + #buf
    if m.file then
        if m.size > m.maxSize then
            m.file:write(buf:sub(1, m.size - m.maxSize))
            m.file:write('[REACH MAX SIZE]')
        else
            m.file:write(buf)
        end
    end

    if m.print then
        print(buf)
    end

    return buf
end

---@param root fs.path
---@param path fs.path
function m.init(root, path)
    ---@type string?
    local lastBuf
    if m.file then
        m.file:close()
        m.file = nil
        local file = ioOpen(m.path, 'rb')
        if file then
            lastBuf = file:read(m.maxSize)
            file:close()
        end
    end
    m.path = path:string()
    m.prefixLen = #root:string()
    m.size = 0
    pcall(function ()
        if not fs.exists(path:parent_path()) then
            fs.create_directories(path:parent_path())
        end
    end)
    if lastBuf then
        init_log_file()
        if m.file then
            m.file:write(lastBuf)
            m.size = m.size + #lastBuf
        end
    end
end

return m
