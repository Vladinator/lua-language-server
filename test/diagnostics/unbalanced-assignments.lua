TEST [[
local x, <!y!>, <!z!> = 1
]]

TEST [[
local x, y, <!z!> = 1, 2
]]

TEST [[
local x, y, z = print()
]]

TEST [[
local x, y, z
]]

TEST [[
local x, y, z
x, <!y!>, <!z!> = 1
]]

TEST [[
X, <!Y!>, <!Z!> = 1
]]

TEST [[
T = {}
T.x, <!T.y!>, <!T.z!> = 1
]]

TEST [[
T = {}
T['x'], <!T['y']!>, <!T['z']!> = 1
]]

-- the values of a call: a function that returns fewer than there are variables
TEST [[
---@return number
local function one() return 1 end

---@return number, string
local function two() return 1, 'a' end

local a, <!b!> = one()
local c, d, <!e!> = two()
local f, g = two()
local h = one()
]]

-- ... read from the body when nothing is annotated, also for an assignment to existing variables and to fields
TEST [[
local function single() return 42 end
local function double() return 1, 2 end

local x, <!y!> = single()
local p, q, <!r!>, <!s!> = double()

local m, n
m, <!n!> = single()

local t = {}
t.a, <!t.b!> = single()
]]

-- no maximum: a `...` return, a pass-through, an unknown callee, a function that returns nothing, an overload that has enough
TEST [[
local function vararg(...) return ... end
local function tail() return vararg(1, 2) end
local function triple() return 1, 2, 3 end
local function forward() return triple() end

---@return ...
local function rest() end

---@overload fun(): number, number
---@return number
local function overloaded() return 1 end

local function nothing() end

local a, b, c = vararg(1, 2)
local d, e, f = tail()
local g, h, i = forward()
local j, k, l = rest()
local m, n = overloaded()
local o, p = nothing()
local q, r = unknownFunction()
local s, t = print()
]]

-- one variable too many on a call that returns three
TEST [[
local function triple() return 1, 2, 3 end
local a, b, c = triple()
local d, e, f, <!g!> = triple()
]]

-- the standard library and the annotations of an API are not trusted: their return lists are often incomplete
TEST [[
local a, b, c = select(2, 'x', 'y', 'z')
local d, e = string.find('abc', 'b')
local f, g, h = string.gsub('abc', 'b', 'c')
]]

-- a placeholder `_` is wanted to be nil; a last value of unknown type may stand for several
TEST [[
local function two() return 1, 2 end

---@return any
local function unknown() end

---@return number, any
local function trailingAny() return 1, nil end

---@type fun(): any
local callback

local a, b, _ = two()
local m, n, o
m, n, _ = two()
m, n, <!o!> = two()
local c, d = unknown()
local e, f, g = trailingAny()
local h, i = callback()
local j, k, <!l!> = two()
]]
