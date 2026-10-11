
TEST [[
local function x(a, b)
    return a, b
end
x(1)
]]

TEST [[
---@param a integer
---@param b integer
local function x(a, b)
    return a, b
end
<!x(1)!>
]]

TEST [[
---@param a integer
---@param b integer
local function x(a, b)
    return a, b
end
<!x()!>
]]

TEST [[
---@param a integer
---@param b integer
---@param ... integer
local function x(a, b, ...)
    return a, b, ...
end
x(1, 2)
]]

TEST [[
---@param a integer
---@param b integer
local function f(a, b)
end

f(...)
]]

TEST [[
---@param a integer
---@param b integer
local function f(a, b)
end

local function return2Numbers()
    return 1, 2
end

f(return2Numbers())
]]

TEST [[
---@param a integer
---@param b? integer
local function x(a, b)
    return a, b
end
x(1)
]]

TEST [[
---@param b integer?
local function x(a, b)
    return a, b
end
x(1)
]]

TEST [[
---@param b integer|nil
local function x(a, b)
    return a, b
end
x(1)
]]

TEST [[
local t = {}

function t:init() end

<!t.init()!>
]]

-- `---@param ... params<F>`: the parameters of F that are not optional are required
TEST [[
---@generic F: fun(...)
---@param fn F
---@param ... params<F>
---@return returns<F>
local function call(fn, ...) return fn(...) end

---@param name string
---@param count integer
---@return boolean
local function spawn(name, count) return true end

---@param name string
---@param count? integer
local function optional(name, count) end

call(spawn, 'orc', 3)
<!call(spawn, 'orc')!>
<!call(spawn)!>
call(optional, 'orc')
<!call(optional)!>
]]

-- `params<F>` where F is a type parameter of the class: the parameters of F that are not optional are required
TEST [[
---@class Registry<F>
local Registry = {}

---@param key string
---@param ... params<F>
function Registry:Call(key, ...) end

---@class Plain
local Plain = {}

---@param key string
---@param ... number
function Plain:Call(key, ...) end

---@class Child : Registry<fun(name: string)>

---@type Registry<fun(name: string, count: number)>
local reg

---@type Registry<fun(name: string, count?: number)>
local optional

---@type Child
local child

---@type Registry
local unbound

reg:Call('k', 'orc', 3)
<!reg:Call('k', 'orc')!>
<!reg:Call('k')!>
optional:Call('k', 'orc')
<!optional:Call('k')!>
child:Call('k', 'orc')
<!child:Call('k')!>
unbound:Call('k')
]]
