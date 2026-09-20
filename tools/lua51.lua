local load = load
local loadfile = loadfile
local debug = debug
local xpcall = xpcall
local type = type
local debugGetupvalue = debug.getupvalue
local debugUpvaluejoin = debug.upvaluejoin
local error = error
local debugGetinfo = debug.getinfo
local getmetatable = getmetatable
local setmetatable = setmetatable
local debugGetlocal = debug.getlocal
local mathAtan = math.atan
local stringFormat = string.format
local stringMatch = string.match
local tonumber = tonumber
local mathLog = math.log
local osExit = os.exit
local stringRep = string.rep
local stringGmatch = string.gmatch
local tableConcat = table.concat
local pairs = pairs
local ipairs = ipairs
local loadfile = loadfile
local EXP = math.exp(1)
local PI = math.pi
local RAD = PI / 180.0

---@class lua51: _G
local lua51 = {}

---@type table<function|userdata|thread, table>
local FenvCache = setmetatable({}, { __mode = 'kv' })

---@param obj any
---@param expect string | "'nil'" | "'number'" | "'string'" | "'boolean'" | "'function'" | "'table'" | "'userdata'" | "'thread'"
---@param level? integer
local function checkType(obj, expect, level)
    local tp = type(obj)
    if tp ~= expect then
        error(stringFormat("%s expected, got %s", expect, tp), level and (level + 1) or 3)
    end
end

---@param f     function|integer
---@param level? integer
---@return function
local function getFunc(f, level)
    if type(f) == 'function' then
        return f
    end
    if not level then
        level = 3
    end
    checkType(f, 'number', level)
    if f < 0 then
        error('level must be non-negative', level)
    end
    local info = debugGetinfo(f + level - 1, 'f')
    if not info then
        error('invalid level', level)
    end
    ---@cast info -?
    if not info.func then
        error(stringFormat('no function environment for tail call at level %d', f), level)
    end
    return info.func --[[@as function]]
end

---@param name string
---@return table? tbl
---@return string? errorPath
local function findTable(name)
    ---@type string[]
    local pg = {}
    ---@type table<any, any>
    local current = lua51._G
    for idVal in stringGmatch(name, '[^%.]+') do
        local id = idVal
        id = stringMatch(id, '^%s*(.-)%s*$')
        pg[#pg+1] = id
        local field = rawget(current, id)
        if field == nil then
            field = {}
            current[id] = field
        elseif type(field) ~= 'table' then
            return nil, tableConcat(pg, '.')
        end
        current = field --[[@as table<any, any>]]
    end
    return current
end

---@param f   function|userdata|thread
---@param tbl table
local function setfenv(f, tbl)
    local tp = type(f)
    if tp ~= 'function' and tp ~= 'userdata' and tp ~= 'thread' then
        error [['setfenv' cannot change environment of given object]]
    end
    FenvCache[f] = tbl
    if debugGetupvalue(f --[[@as function]], 1) ~= '_ENV' then
        return
    end
    local function dummy()
        return tbl
    end
    debugUpvaluejoin(f --[[@as function]], 1, dummy, 1)
end

---@param f function
---@return table?
local function getfenv(f)
    if FenvCache[f] then
        return FenvCache[f]
    end
    local _, v = debugGetupvalue(f, 1)
    return v
end

---@param t table
---@return table<any, any>
local function copyTable(t)
    ---@type table<any, any>
    local nt = {}
    for k, v in pairs(t --[[@as table<any, any>]]) do
        nt[k] = v
    end
    return nt
end

---@param name string
---@return function
local function requireLoad(name)
    local msg = ''
    if type(lua51._G.package.loaders) ~= 'table' then
        error("'package.loaders' must be a table", 3)
    end
    for _, searcher in ipairs(lua51._G.package.loaders) do
        local f = (searcher --[[@as fun(name: string): function|string]])(name)
        if type(f) == 'function' then
            return f
        elseif type(f) == 'string' then
            msg = msg .. f --[[@as string]]
        end
    end
    error(("module '%s' not found:%s"):format(name, msg), 3)
end

---@param name string
---@param env  any
---@return any
local function requireWithEnv(name, env)
    ---@type table<string, any>
    local loaded = lua51._G.package.loaded
    if type(name) ~= 'string' then
        error(("bad argument #1 to 'require' (string expected, got %s)"):format(type(name)), 2)
    end
    local p = loaded[name]
    if p ~= nil then
        return p
    end
    local init = requireLoad(name) --[[@as fun(name: string): any]]
    if type(env) == 'table' then
        if debug.getupvalue(init, 1) == '_ENV' then
            debug.setupvalue(init, 1, env)
        end
    end
    local res = init(name)
    if res ~= nil then
        loaded[name] = res
    end
    if loaded[name] == nil then
        loaded[name] = true
    end
    return loaded[name]
end

lua51.arg = arg
lua51.assert = assert
lua51.collectgarbage = collectgarbage
---@param name? string
---@return function?
function lua51.dofile(name)
    ---@type function?, string?
    local f, err
    if name then
        f, err = loadfile(name)
    else
        f, err = loadfile()
    end
    if not f then
        error(err, 2)
    end
    return f()
end
lua51.error = error
lua51._G = lua51
---@param f function|integer
---@return table?
function lua51.getfenv(f)
    local func = getFunc(f)
    return getfenv(func)
end
lua51.getmetatable = getmetatable
lua51.ipairs = ipairs
---@param func function
---@param name? string
---@return function?
---@return string? err
function lua51.load(func, name)
    checkType(func, 'function')
    return load(func, name, 'bt', lua51._G)
end
---@param name? string
---@return function?
---@return string? err
function lua51.loadfile(name)
    return loadfile(name, 'bt', lua51._G)
end
---@param str  string
---@param name? string
---@return function?
---@return string? err
function lua51.loadstring(str, name)
    checkType(str, 'string')
    return load(str, name, 'bt', lua51._G)
end
---@param name string
---@param ... fun(mod: table)
function lua51.module(name, ...)
    checkType(name, 'string')
    ---@type table<string, any>
    local loaded = lua51._G.package.loaded
    local mod = loaded[name]
    if type(mod) ~= 'table' then
        local err
        mod, err = findTable(name)
        if not mod then
            error('name conflict for module ' .. tostring(err))
        end
        loaded[name] = mod
    end
    if mod._NAME == nil then
        mod._M = mod
        mod._NAME = name
        mod._PACKAGE = stringMatch(name, '(.-)[^%.]+$')
    end
    local f = getFunc(1)
    setfenv(f, mod)
    for _, func in ipairs {...} do
        func(mod)
    end
end
lua51.next = next
lua51.pairs = pairs
lua51.pcall = pcall
lua51.print = print
lua51.rawequal = rawequal
lua51.rawget = rawget
lua51.rawlen = rawlen
lua51.rawset = rawset
lua51.select = select
---@param f   function|integer
---@param tbl table
function lua51.setfenv(f, tbl)
    local func = getFunc(f)
    setfenv(func, tbl)
end
lua51.setmetatable = setmetatable
lua51.tonumber = tonumber
lua51.tostring = tostring
lua51.type = type
lua51._VERSION = 'Lua 5.1'
---@param f    function
---@param msgh function
---@return boolean
---@return any ...
function lua51.xpcall(f, msgh)
    checkType(f, 'function')
    checkType(f, 'function')
    return xpcall(f, msgh)
end
---@param name string
---@return any
function lua51.require(name)
    return requireWithEnv(name, lua51._G)
end
lua51.unpack = table.unpack

lua51.coroutine = {}
lua51.coroutine.create = coroutine.create
lua51.coroutine.isyieldable = coroutine.isyieldable
lua51.coroutine.resume = coroutine.resume
lua51.coroutine.running = coroutine.running
lua51.coroutine.status = coroutine.status
lua51.coroutine.wrap = coroutine.wrap
lua51.coroutine.yield = coroutine.yield

lua51.debug = {}
lua51.debug.debug = debug.debug
lua51.debug.getfenv = getfenv
lua51.debug.gethook = debug.gethook
lua51.debug.getinfo = debug.getinfo
---@overload fun(level: integer, loc: integer): string?, any
---@param ... thread|integer
---@return string?
---@return any
function lua51.debug.getlocal(...)
    local n = select('#', ...)
    if n == 2 then
        local level, loc = ...
        checkType(level, 'number')
        return debugGetlocal(level --[[@as integer]], loc --[[@as integer]])
    else
        local th, level, loc = ...
        return debugGetlocal(th --[[@as thread]], level --[[@as integer]], loc --[[@as integer]])
    end
end
lua51.debug.getmetatable = debug.getmetatable
lua51.debug.getregistry = debug.getregistry
lua51.debug.getupvalue = debug.getupvalue
lua51.debug.getuservalue = debug.getuservalue
lua51.debug.setfenv = setfenv
lua51.debug.sethook = debug.sethook
lua51.debug.setlocal = debug.setlocal
lua51.debug.setmetatable = debug.setmetatable
lua51.debug.setupvalue = debug.setupvalue
lua51.debug.setuservalue = debug.setuservalue
lua51.debug.traceback = debug.traceback

lua51.io = {}
lua51.io.stdin = io.stdin
lua51.io.stdout = io.stdout
lua51.io.stderr = io.stderr
lua51.io.close = io.close
lua51.io.flush = io.flush
lua51.io.input = io.input
lua51.io.lines = io.lines
lua51.io.open = io.open
lua51.io.output = io.output
lua51.io.popen = io.popen
lua51.io.read = io.read
lua51.io.tmpfile = io.tmpfile
lua51.io.type = io.type
lua51.io.write = io.write

lua51.math = {}
lua51.math.abs = math.abs
lua51.math.acos = math.acos
lua51.math.asin = math.asin
---@param y number
---@return number
function lua51.math.atan(y)
    return mathAtan(y)
end
---@param y number
---@param x number
---@return number
function lua51.math.atan2(y, x)
    checkType(x, 'number')
    return mathAtan(y, x)
end
lua51.math.ceil = math.ceil
lua51.math.cos = math.cos
---@param x number
---@return number
function lua51.math.cosh(x)
    return (EXP ^ x + EXP ^ -x) / 2.0
end
---@param x number
---@return number
function lua51.math.deg(x)
    return x / RAD
end
---@return number
function lua51.math.exp()
    return EXP
end
lua51.math.floor = math.floor
lua51.math.fmod = math.fmod
---@param x number
---@return number m
---@return number e
function lua51.math.frexp(x)
    if x == 0 then
        return 0.0, 0
    end
    if x ~= x then
        return x, 0
    end
    local dump = stringFormat('%q', x + 0.0)
    local mstr, estr = stringMatch(dump, '^(.-)[pP](.+)$')
    if not mstr then
        return x, 0
    end
    local m = tonumber(mstr)
    local e = tonumber(estr)
    assert(m)
    assert(e)
    if m == 0 then
        return m, e
    end
    m = m / 2.0
    e = e + 1
    return m, e
end
lua51.math.huge = math.huge
---@param m number
---@param e number
---@return number
function lua51.math.ldexp(m, e)
    return m * (2 ^ e)
end
---@param x number
---@return number
function lua51.math.log(x)
    return mathLog(x)
end
---@param x number
---@return number
function lua51.math.log10(x)
    return mathLog(x, 10)
end
lua51.math.max = math.max
lua51.math.min = math.min
lua51.math.modf = math.modf
lua51.math.pi = math.pi
---@param x number
---@param y number
---@return number
function lua51.math.pow(x, y)
    return x ^ y
end
---@param x number
---@return number
function lua51.math.rad(x)
    return x * RAD
end
lua51.math.random = math.random
lua51.math.randomseed = math.randomseed
lua51.math.sin = math.sin
---@param x number
---@return number
function lua51.math.sinh(x)
    return (EXP ^ x - EXP ^ -x) / 2.0
end
lua51.math.sqrt = math.sqrt
lua51.math.tan = math.tan
---@param x number
---@return number
function lua51.math.tanh(x)
    local a = EXP ^ x
    local b = EXP ^ -x
    return (a - b) / (a + b)
end

lua51.os = {}
lua51.os.close = os.clock
lua51.os.date = os.date
lua51.os.difftime = os.difftime
lua51.os.execute = os.execute
function lua51.os.exit(code)
    code = tonumber(code) or 0
    osExit(code--[[@as integer]])
end
lua51.os.getenv = os.getenv
lua51.os.remove = os.remove
lua51.os.rename = os.rename
lua51.os.setlocale = os.setlocale
lua51.os.time = os.time
lua51.os.tmpname = os.tmpname

lua51.package = {}
lua51.package.config = package.config
lua51.package.cpath = package.cpath
lua51.package.loaded = copyTable(package.loaded)
lua51.package.loaders = copyTable(package.searchers)
lua51.package.loadlib = package.loadlib
lua51.package.path = package.path
lua51.package.preload = copyTable(package.preload)
function lua51.package.seeall(mod)
    local mt = getmetatable(mod)
    if not mt then
        mt = {}
        setmetatable(mod, mt)
    end
    mt.__index = lua51._G
end

-- WTF ('').format
lua51.string = {}
lua51.string.byte = string.byte
lua51.string.char = string.char
lua51.string.dump = string.dump
lua51.string.find = string.find
lua51.string.format = string.format
lua51.string.gmatch = string.gmatch
lua51.string.gsub = string.gsub
lua51.string.len = string.len
lua51.string.lower = string.lower
lua51.string.match = string.match
function lua51.string.rep(s, n)
    return stringRep(s, n)
end
lua51.string.reverse = string.reverse
lua51.string.sub = string.sub
lua51.string.upper = string.upper

lua51.table = {}
lua51.table.concat = table.concat
lua51.table.insert = table.insert
---@param t table
---@return integer
function lua51.table.maxn(t)
    checkType(t, 'table')
    local max = 0
    for k in pairs(t --[[@as table<any, any>]]) do
        if type(k) == 'number' then
            if k > max then
                max = k
            end
        end
    end
    return max
end
lua51.table.remove = table.remove
lua51.table.sort = table.sort

return lua51
