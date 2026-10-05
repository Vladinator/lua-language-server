-- Calling a value whose every known type is a primitive (number, integer, string, boolean) is reported on the callee. Anything that
-- could be callable stays silent: functions, tables (`__call`), classes, `any`, unknown values, unions with one of those, and
-- values that may be nil (need-check-nil).

TEST [[
local n = 5
<!n!>()
local s = 'text'
<!s!>()
local b = true
<!b!>()
local f = 1.5
<!f!>()
]]

-- through an annotation, and as a call argument or method call target
TEST [[
---@type number
local n
local _ = <!n!>(1, 2)

---@type string
local s
print(<!s!>())
]]

-- annotated literal types, alone or in a union of literals
TEST [[
---@type 'a'|'b'
local words
<!words!>()
---@type 1
local one
<!one!>()
---@type true
local yes
<!yes!>()
---@type 'a'|1
local mixed
<!mixed!>()
]]

-- a literal called directly
TEST [[
local _ = <!(5)!>()
]]

-- callable things
TEST [[
local function fn() end
fn()

local t = setmetatable({}, { __call = function() end })
t()

---@class Callable
---@field run fun()
---@type Callable
local c
c.run()

---@type any
local a
a()

local unknownValue = unknownGlobal
unknownValue()

---@type fun()|number
local u
u()

---@type number|table
local m
m()
]]

-- may be nil: need-check-nil, not this
TEST [[
---@type number?
local o
o()
]]

-- a variable that holds a number first and a function later could be either
TEST [[
local x = 5
x = function() end
x()
]]

-- method calls on strings are not calls of the string
TEST [[
local s = 'text'
s:upper()
print(('x'):rep(3))
]]

-- only a value whose type is certain is judged: a field or a method access is not (its type can be wrong when a table is built
-- across files, as with LibStub), nor is the iterator of a generic `for`
TEST [[
local libs = {}
local Stub = { libs = libs, minor = 2 }
function Stub:Iterate() return pairs(self.libs) end
for major, library in Stub:Iterate() do
    print(major, library)
end
for k, v in pairs({}) do end
for i, v in ipairs({}) do end

---@class Holder
---@field count number
---@type Holder
local holder
holder.count()
Stub.minor()
]]
