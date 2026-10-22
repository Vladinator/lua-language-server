-- the length of a number, a boolean, a function
TEST [[
---@param n number
---@param i integer
---@param b boolean
---@param fn fun(): number
local function f(n, i, b, fn)
    local a = #<!n!>
    local c = #<!i!>
    local d = #<!b!>
    local e = #<!fn!>
    local g = #<!5!>
end
]]

-- fine: a string, a table, a class (it may get a metatable), an unknown, a union holding a string
TEST [[
---@class IOPlain
---@field x number
---@param s string
---@param t table
---@param p IOPlain
---@param a any
---@param u number|string
---@param o? string
local function f(s, t, p, a, u, o)
    local l = { #s, #t, #p, #a, #u, #o, #'abc' }
end
]]

-- arithmetic, concatenation and bitwise operators with a boolean or a function, either side
TEST [[
---@param n number
---@param s string
---@param b boolean
---@param fn fun(): number
local function f(n, s, b, fn)
    local a1 = n + <!b!>
    local a2 = <!b!> * n
    local a3 = n - <!fn!>
    local a4 = -<!b!>
    local a5 = s .. <!b!>
    local a6 = <!fn!> .. s
    local a7 = n & <!b!>
    local a8 = ~<!b!>
    local a9 = n ^ <!true!>
    local a10 = 'x' .. <!false!>
end
]]

-- fine: numbers, numeric strings, number .. string, tables and unknowns (a metatable may take the operator)
TEST [[
---@param n number
---@param s string
---@param t table
---@param a any
---@param w number|boolean
local function f(n, s, t, a, w)
    local r = {
        n + 1, s + 1, -n, -s, n .. s, s .. n, n // 2, n % 2, n ^ 2, n & 1, ~n,
        t + 1, t .. s, a + 1, s .. a, w + 1, a - t,
    }
end
]]

-- a metamethod of EITHER operand counts: `pattern / function` is the pattern's `__div`
TEST [[
---@class IOPattern
---@operator div(function): IOPattern
---@operator concat(string): string
---@param p IOPattern
---@param fn fun(): number
---@param b boolean
local function f(p, fn, b)
    local r = { p / fn, p .. 'x', 'x' .. p, p / b, b / p, p .. b }
end
]]

-- a declared operator on the class is honoured for the operand itself
TEST [[
---@class IOVec
---@operator add(IOVec): IOVec
---@operator len: integer
---@param v IOVec
local function f(v)
    local r = { v + v, #v }
end
]]

-- ordering: a number with a string, a boolean, a function; same kinds are fine
TEST [[
---@param n number
---@param i integer
---@param s string
---@param b boolean
---@param fn fun(): number
---@param u number|string
---@param t table
---@param a any
local function f(n, i, s, b, fn, u, t, a)
    local ok = { n < i, s < s, u < n, t < t, a < n, n <= 1, s >= 'x' }
    local bad1 = n < <!s!>
    local bad2 = s >= <!i!>
    local bad3 = <!b!> < n
    local bad4 = <!fn!> <= 1
    local bad5 = n < <!'x'!>
end
]]

-- equality, logic and nil never raise this; an optional value is need-check-nil's business
TEST [[
---@param n number
---@param s string
---@param b boolean
---@param o? number
local function f(n, s, b, o)
    local r = { n == s, b == n, b and n, not n, b or s, o == n, n ~= b }
end
]]

-- the plain `function` type
TEST [[
---@param g function
---@param bo boolean
local function f(g, bo)
    local a = <!g!> + 1
    local b = #<!g!>
    local c = <!bo!> .. 'x'
end
]]

-- an optional primitive is judged by its non-nil part (the nil part is need-check-nil's)
TEST [[
---@param ob? boolean
---@param on? number
---@param ox boolean|nil
---@param oy nil|number
local function f(ob, on, ox, oy)
    local a = <!ob!> + 1
    local b = #<!on!>
    local c = <!ox!> + 1
    local d = #<!oy!>
end
]]

-- narrowing: after `type(x) == 'boolean'` the number member is gone
TEST [[
---@param x number|boolean
local function f(x)
    if type(x) == 'boolean' then
        local y = <!x!> + 1
    else
        local y = x + 1
    end
end
]]
