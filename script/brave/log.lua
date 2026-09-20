local brave          = require 'brave'
local time           = require 'bee.time'

local tablePack      = table.pack
local tostring       = tostring
local tableConcat    = table.concat
local debugTraceBack = debug.traceback
local debugGetInfo   = debug.getinfo
local monotonic      = time.monotonic

_ENV = nil

---@param level string
---@return string
local function pushLog(level, ...)
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
    brave.push('log', {
        level = level,
        msg   = str,
        src   = info.source,
        line  = info.currentline,
        clock = monotonic(),
    })
    return str
end

local m = {}

function m.info(...)
    pushLog('info', ...)
end

function m.debug(...)
    pushLog('debug', ...)
end

function m.trace(...)
    pushLog('trace', ...)
end

function m.warn(...)
    pushLog('warn', ...)
end

function m.error(...)
    pushLog('error', ...)
end

return m
