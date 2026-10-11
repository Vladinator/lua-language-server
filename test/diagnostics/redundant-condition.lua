-- constant by type: a table, a non-optional string, a function
TEST [[
---@type table
local t
---@type string
local s

if <!t!> then end
if <!s!> then end
while <!t!> do break end
if <!t == nil!> then
elseif <!s!> then
end
]]

-- literals are deliberate, real conditions are fine
TEST [[
---@type string?
local a
---@type boolean
local b
---@type any
local c

if true then end
if false then end
while true do break end
if a then end
if b then end
if c then end
if unknownGlobal then end
local function f(p) if p then end end
if not a then end
]]

-- a value compared with itself
TEST [[
---@type string
local s
local t = {}
t.x = 'a'

if <!s == s!> then end
if <!s ~= s!> then end
if <!t.x == t.x!> then end
]]

-- ... but not numbers (the NaN test), different values, calls
TEST [[
---@type number
local n
---@type string
local s
---@type string
local o

if n ~= n then end
if n == n then end
if s == o then end
local function g() return 'a' end
if g() == g() then end
]]

-- a narrowing makes a later check redundant
TEST [[
---@type string?
local a

if a then
    if <!a!> then end
end
]]

-- a comparison with a literal that the type rules out (type mismatch, literal union, nil of a non-optional)
TEST [[
---@type string
local s
if <!s == 1!> then end
]]
TEST [[
---@type number
local n
if <!n == 'x'!> then end
]]
TEST [[
---@type 'a' | 'b'
local u
if <!u == 'c'!> then end
]]
TEST [[
---@type string
local s
if <!s == nil!> then end
]]
TEST [[
---@type string
local s
if <!s ~= nil!> then end
]]
TEST [[
---@type 'a' | 'b'
local u
if <!u ~= 'c'!> then end
]]
TEST [[
---@type string
local s
if <!1 == s!> then end
]]

-- ... and the comparisons that can be true or false
TEST [[
---@type string
local s
---@type 'a' | 'b'
local u
---@type number?
local n
---@type string?
local o
---@type any
local c

if s == 'x' then end
if u == 'a' then end
if u ~= 'b' then end
if n == 1 then end
if n == nil then end
if o == 'x' then end
if c == 1 then end
if unknownGlobal == 1 then end
if 1 == 2 then end
]]

-- a value that is always the one literal
TEST [[
---@type 'a'
local one

if <!one == 'a'!> then end
if <!one ~= 'a'!> then end
if <!one == 'b'!> then end
]]

-- a comparison among the operands of `and` / `or` / `not` is judged too (a callback where an event name was meant); one per
-- function, because a comparison that cannot hold widens the value for the code after it
TEST [[
---@param event fun(name: string)
local function f(event)
    if <!event == "OnTooltipSetUnit"!> or <!event == "OnTooltipUpdate"!> then end
end
---@param n number
local function g(n)
    if not (<!n == "x"!>) then end
end
---@param n number
local function h(n)
    if n > 0 and <!n ~= "x"!> then end
end
---@param n number
local function i(n)
    if n < 3 and (<!n == "x"!> or n == 2) then end
end
]]

-- ... but only "can never be equal": the operands before narrow the type, so a correct chain must stay quiet
TEST [[
---@param kind "a"|"b"
---@param s string
---@param n number
local function f(kind, s, n)
    if kind == "a" or kind == "b" then end
    if kind ~= "a" and kind ~= "b" then end
    if s == "a" or s == "b" then end
    if n == 1 or n == 2 then end
    if s == "a" and n == 2 then end
end
]]

-- an operand that is always equal is left alone (only a whole condition is reported as always true)
TEST [[
---@type 'a'
local one
---@type number
local n

if n > 0 and one == 'a' then end
if n > 0 or one ~= 'a' then end
]]

-- a comparison that is not a condition is judged too (TypeScript: TS2367 anywhere): only "can never be equal"
TEST [[
---@param n number
---@param m number?
local function f(n, m)
    local flag = <!n == "x"!>
    print(<!n ~= "y"!>, <!m == "z"!>)
    return <!n == "x"!>
end
f(1)
]]

-- ... what can hold, what must hold and a test against nil are left alone outside a condition
TEST [[
---@param n number
---@param s string|number
---@param k 1
local function f(n, s, k)
    local a = n == 1
    local b = s == "x"
    local c = n == nil
    local d = 1 == 2
    local e = k == 1
    return a, b, c, d, e
end
f(1, 2, 1)
]]

-- a comparison in a condition is reported once, by the condition's own judgement
TEST [[
---@param n number
local function f(n)
    if <!n == "x"!> then
    end
    while <!n == "x"!> do
    end
end
f(1)
]] (function (diags)
    assert(#diags == 2, 'one report per comparison: ' .. #diags)
end)
