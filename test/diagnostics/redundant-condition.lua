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
