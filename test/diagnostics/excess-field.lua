-- a field the class does not declare, in a typed local and as an argument
TEST [[
---@diagnostic disable: unused-local
---@class Line
---@field label string
---@field content string

---@type Line
local a = { label = "a", content = "b", <!extra!> = true }

---@param l Line
local function useLine(l) end

useLine({ label = "a", content = "b", <!extra!> = true })
useLine({ label = "a", content = "b" })
]]

-- declared fields, inherited ones, optional ones and fields assigned in code are fine
TEST [[
---@diagnostic disable: unused-local
---@class Base
---@field id number

---@class Child : Base
---@field name? string
local Child = {}
Child.assigned = 1

---@type Child
local c = { id = 1, name = "x", assigned = 2 }
]]

-- a class that takes any string key, a plain table and an array take anything
TEST [[
---@diagnostic disable: unused-local
---@class Bag : table<string, number>
---@field known number

---@type Bag
local b = { known = 1, other = 2 }

---@type table<string, number>
local t = { anything = 1 }

---@type Bag[]
local list = { { known = 1, other = 2 } }
]]

-- a union of classes: a field of any member is fine, one of none is reported
TEST [[
---@diagnostic disable: unused-local
---@class One
---@field a number

---@class Two
---@field b number

---@type One|Two
local u = { a = 1, b = 2, <!c!> = 3 }

---@type One|table<string, number>
local v = { a = 1, c = 3 }
]]

-- non-string keys and computed keys are left alone
TEST [[
---@diagnostic disable: unused-local
---@class Line
---@field label string

local key = "dynamic"
---@type Line
local l = { label = "a", [key] = 1, [1] = 2 }
]]

-- a table returned from a function with `---@return Class` is checked against that class
TEST [[
---@class Line
---@field label string

---@return Line
local function make()
    return { label = "a", <!extra!> = true }
end

---@class Other
---@field size number

---@return Line, Other
local function pair()
    return { label = "a" }, { size = 1, <!label!> = "b" }
end

---@return Line|nil
local function maybe()
    return { label = "a", <!extra!> = 1 }
end

---@return table
local function anything()
    return { label = "a", extra = 1 }
end

local function undeclared()
    return { label = "a", extra = 1 }
end
]]
