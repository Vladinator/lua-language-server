
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
