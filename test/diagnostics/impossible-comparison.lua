-- a string literal the declared literals do not have (a typo), either side, `==` and `~=`
TEST [[
---@alias CMode "queue"|"latest"
---@class CD
---@field mode CMode
---@type CD
local d = { mode = 'queue' }

if <!d.mode == "latestt"!> then end
if <!d.mode ~= "queu"!> then end
if <!"latestt" == d.mode!> then end
local x = <!d.mode == "nope"!> and 1 or 2
]]

-- fine: a literal the type has, an optional value compared with a member, nil comparisons
TEST [[
---@alias CMode2 "queue"|"latest"
---@param m CMode2
---@param o? CMode2
local function f(m, o)
    if m == "queue" then end
    if m == "latest" then end
    if m ~= "queue" then end
    if "queue" == m then end
    if o == "queue" then end
    if o == nil then end
    if o ~= nil then end
    if m == nil then end
end
]]

-- numbers: a number the union does not have, floats equal their integer
TEST [[
---@type 1|2|3
local n
---@type 1|2|3|nil
local o

if n == 1 then end
if n == 2.0 then end
if <!n == 4!> then end
if <!n ~= 0!> then end
if o == 3 then end
if <!o == 9!> then end
]]

-- fine: values that are not a union of declared literals say nothing (primitives, `any`, unknown, classes, booleans, inferred values)
TEST [[
---@param s string
---@param i integer
---@param a any
---@param u unknown
---@param b boolean
---@param t table
local function f(s, i, a, u, b, t)
    if s == "anything" then end
    if i == 5 then end
    if a == "x" then end
    if u == "x" then end
    if b == true then end
    if t == "x" then end
    if s == 5 then end
    if b == 1 then end
end
local function untyped(p, ...)
    if p == "x" then end
    local q
    if q == "y" then end
end
local inferred = "queue"
if inferred == "other" then end
local count = 3
if count == 4 then end
local flag = true
if flag == false then end
]]

-- fine: an enum is its values (nothing is judged), two literals, two values
TEST [[
---@enum CColor
local Color = { red = 1, green = 2 }
---@param c CColor
---@param a CColor
---@param b CColor
local function f(c, a, b)
    if c == 1 then end
    if c == 5 then end
    if c == Color.red then end
    if a == b then end
    if 1 == 2 then end
    if 'a' == 'b' then end
end
]]

-- a union of types: nothing but literals is judged
TEST [[
---@param v string|"x"
---@param w "a"|"b"|number
---@param z "a"|"b"
local function f(v, w, z)
    if v == "y" then end
    if w == "c" then end
    if w == 7 then end
    if <!z == "c"!> then end
end
]]

-- fields, calls and indexes are judged by their declared type like variables
TEST [[
---@alias CMode3 "queue"|"latest"
---@class CBag
---@field mode CMode3
---@field list CMode3[]
---@return CMode3
local function get() return 'queue' end
---@type CBag
local bag = { mode = 'queue', list = {} }

if <!bag.mode == "oops"!> then end
if <!get() == "oops"!> then end
if <!bag.list[1] == "oops"!> then end
if get() == "queue" then end
if bag.list[1] == "latest" then end
]]

-- the type names a LuaJIT `type()` answers with are not judged against the standard ones
TEST [[
local tv = type(1)
if tv == 'cdata' or tv == 'ctype' then end
if <!tv == 'strng'!> then end
]]
