-- every comparison after a bare `not x`
TEST [[
local x, y = 1, 2
if <!not x == nil!> then end
if <!not x ~= y!> then end
if <!not x < y!> then end
if <!not x <= y!> then end
if <!not x > y!> then end
if <!not x >= y!> then end
]]

-- in every place an expression can be
TEST [[
local x, y, count = 1, 2, 0
while <!not x == y!> do break end
local function f() return <!not count > 0!> end
local r = <!not count > 0!>
print(<!not x == y!>, f(), r)
repeat until <!not x == y!>
local t = { <!not x == y!> }
]]

-- brackets say which one is meant
TEST [[
local x, y, count = 1, 2, 0
if not (x == nil) then end
if not (x ~= y) then end
local ok = not (count > 0)
if (not x) == nil then end
print(ok)
]]

-- no comparison, or the comparison does not start with the `not`
TEST [[
local x, y, a = 1, 2, 3
if not x then end
local nn = not x
if not x and y == a then end
if y == a and not x then end
if x ~= nil then end
if y == not x then end
print(nn)
]]

-- `not a == not b` asks whether both are nil-ish or both are not: deliberate for equality, never for an ordering
TEST [[
local a, b = 1, 2
if not a == not b then end
if not a ~= not b then end
if <!not a == b!> then end
if <!not a < not b!> then end
if <!not a <= not b!> then end
]]

-- a longer `not` chain, and the suppression comment
TEST [[
local x = 1
if <!not not x == nil!> then end
---@diagnostic disable-next-line: not-precedence
if not x == nil then end
]]
