local util       = require 'utility'
local await      = require 'await'
local pub        = require 'pub'
local jsonrpc    = require 'jsonrpc'
local define     = require 'proto.define'
local json       = require 'json'
local inspect    = require 'inspect'
local platform   = require 'bee.platform'
local fs         = require 'bee.filesystem'
local net        = require 'service.net'
local timer      = require 'timer'

local reqCounter = util.counter()

local function logSend(buf)
    if not RPCLOG then
        return
    end
    log.info('rpc send:', buf)
end

---@param proto any
local function logRecieve(proto)
    if not RPCLOG then
        return
    end
    log.info('rpc recieve:', json.encode(proto))
end

---@class proto.message
---@field id?                    integer|string
---@field method                 string
---@field params?                any
---@field package _closeReason?  integer
---@field package _closeMessage? string

---@class proto
---@field client any
local m = {}

---@type table<string, async fun()>
m.ability = {}
---@type table<any, any>
m.waiting = {}
---@type table<integer|string, proto.message>
m.holdon  = {}
m.mode    = 'stdio'
m.client  = nil

---@param proto proto.message
---@return string method
---@return boolean isOptional
function m.getMethodName(proto)
    if proto.method:sub(1, 2) == '$/' then
        return proto.method, true
    else
        return proto.method, false
    end
end

---@param method string
---@param callback async fun()
function m.on(method, callback)
    m.ability[method] = callback
end

---@param data any
function m.send(data)
    local buf = jsonrpc.encode(data)
    logSend(buf)
    if m.mode == 'stdio' then
        io.write(buf)
    elseif m.mode == 'socket' then
        m.client:write(buf)
    end
end

---@param id integer|string?
---@param res any
function m.response(id, res)
    if id == nil then
        log.error('Response id is nil!', inspect(res))
        return
    end
    if not m.holdon[id] then
        log.error('Unknown response id!', id)
        return
    end
    m.holdon[id] = nil
    local data  = {}
    data.id     = id
    data.result = res == nil and json.null or res
    m.send(data)
end

---@param id integer|string?
---@param code integer
---@param message any
function m.responseErr(id, code, message)
    if id == nil then
        log.error('Response id is nil!', inspect(message))
        return
    end
    if not m.holdon[id] then
        log.error('Unknown response id!', id)
        return
    end
    m.holdon[id] = nil
    m.send {
        id    = id,
        error = {
            code    = code,
            message = message,
        }
    }
end

---@param name string
---@param params any
function m.notify(name, params)
    m.send {
        method = name,
        params = params,
    }
end

---@async
---@param name string
---@param params? table
---@return any
function m.awaitRequest(name, params)
    local id  = reqCounter()
    m.send {
        id     = id,
        method = name,
        params = params,
    }
    local result, error = await.wait(function (resume)
        m.waiting[id] = {
            id     = id,
            method = name,
            params = params,
            resume = resume,
        }
    end)
    if error then
        log.warn(('Response of [%s] error [%d]: %s'):format(name, error.code, error.message))
    end
    return result
end

---@param name string
---@param params any
---@param callback? fun(result: any)
function m.request(name, params, callback)
    local id  = reqCounter()
    m.send {
        id     = id,
        method = name,
        params = params,
    }
    m.waiting[id] = {
        id     = id,
        method = name,
        params = params,
        resume = function (result, error)
            if error then
                log.warn(('Response of [%s] error [%d]: %s'):format(name, error.code, error.message))
            end
            if callback then
                callback(result)
            end
        end
    }
end

local secretOption = {
    process = function (item, path)
        if  path[1] == 'params'
        and path[2] == 'textDocument'
        and path[3] == 'text'
        and path[4] == nil then
            return '"***"'
        end
        return item
    end
}

---@type proto.message[]
m.methodQueue = {}

---@param proto proto.message
function m.applyMethod(proto)
    logRecieve(proto)
    local method, optional = m.getMethodName(proto)
    local abil = m.ability[method]
    if proto.id then
        m.holdon[proto.id] = proto
    end
    if not abil then
        if not optional then
            log.warn('Recieved unknown proto: ' .. method)
        end
        if proto.id then
            m.responseErr(proto.id, define.ErrorCodes.MethodNotFound, method)
        end
        return
    end
    await.call(function () ---@async
        --log.debug('Start method:', method)
        if proto.id then
            await.setID('proto:' .. proto.id)
        end
        local clock = os.clock()
        local ok = false
        local res
        -- 任务可能在执行过程中被中断，通过close来捕获
        local response <close> = function ()
            local passed = os.clock() - clock
            if passed > 0.5 then
                log.warn(('Method [%s] takes [%.3f]sec. %s'):format(method, passed, inspect(proto, secretOption)))
            end
            --log.debug('Finish method:', method)
            if not proto.id then
                return
            end
            await.close('proto:' .. proto.id)
            if ok then
                m.response(proto.id, res)
            else
                m.responseErr(proto.id, proto._closeReason or define.ErrorCodes.InternalError, proto._closeMessage or res)
            end
        end
        ok, res = xpcall(abil, log.error, proto.params, proto.id)
        await.delay()
    end)
end

function m.applyMethodQueue()
    local queue = m.methodQueue
    m.methodQueue = {}
    ---@type table<any, boolean>
    local canceled = {}
    for _, proto in ipairs(queue) do
        if proto.method == '$/cancelRequest' then
            canceled[proto.params.id] = true
        end
    end
    for _, proto in ipairs(queue) do
        if not canceled[proto.id] then
            m.applyMethod(proto)
        end
    end
end

---@param proto proto.message
function m.doMethod(proto)
    m.methodQueue[#m.methodQueue+1] = proto
    if #m.methodQueue > 1 then
        return
    end
    timer.wait(0, m.applyMethodQueue)
end

---@param id      integer|string
---@param reason  integer?
---@param message string?
function m.close(id, reason, message)
    local proto = m.holdon[id]
    if not proto then
        return
    end
    proto._closeReason = reason
    proto._closeMessage = message
    await.close('proto:' .. id)
end

---@class proto.response
---@field id     integer|string
---@field error? { code: integer, message: string }
---@field result? any

---@param proto proto.response
function m.doResponse(proto)
    logRecieve(proto)
    local id = proto.id
    local waiting = m.waiting[id]
    if not waiting then
        log.warn('Response id not found: ' .. inspect(proto))
        return
    end
    m.waiting[id] = nil
    if proto.error then
        waiting.resume(nil, proto.error)
        return
    end
    waiting.resume(proto.result)
end

---@param mode 'stdio'|'socket'
---@param socketPort? integer
function m.listen(mode, socketPort)
    m.mode = mode
    if mode == 'stdio' then
        log.info('Listen Mode: stdio')
        if platform.os == 'windows' then
            local windows = require 'bee.windows'
            windows.filemode(io.stdin,  'b')
            windows.filemode(io.stdout, 'b')
        end
        io.stdin:setvbuf  'no'
        io.stdout:setvbuf 'no'
        pub.task('loadProtoByStdio')
    elseif mode == 'socket' then
        local unixFolder = LOGPATH .. '/unix'
        fs.create_directories(fs.path(unixFolder))
        local unixPath = unixFolder .. '/' .. tostring(socketPort)

        local server = net.listen('unix', unixPath)

        log.info('Listen Mode: socket')
        log.info('Listen Port:', socketPort)
        log.info('Listen Path:', unixPath)

        assert(server)

        ---@class proto.dummyClient
        ---@field buf string
        local dummyClient = {
            buf = '',
            ---@param self proto.dummyClient
            ---@param data string
            write = function (self, data)
                self.buf = self.buf.. data
            end,
            update = function () end,
        }
        m.client = dummyClient

        local anyServer = server --[[@as any]]

        function anyServer:on_accepted(client)
            m.client = client
            client:write(dummyClient.buf)
            return true
        end

        function anyServer:on_error(...)
            log.error(...)
        end

        pub.task('loadProtoBySocket', {
            port = socketPort,
            unixPath = unixPath,
        })
    end
end

return m
