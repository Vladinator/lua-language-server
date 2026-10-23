TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number

---@type A
local t = <!{}!>
]]

TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number

---@type A
local t = <!{
    x = 1,
}!>
]]

TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number

---@type A
local t = <!{
    x = 1,
    y = 2,
}!>
]]

TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number

---@type A
local t = {
    x = 1,
    y = 2,
    z = 3,
}
]]

TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number
local A = {}

function A:fun()
end

---@type A
local t = {
    x = 1,
    y = 2,
    z = 3,
}
]]

TEST [[
---@diagnostic disable: unused-local

---@class Parent
---@field a number
local Parent = {}

function Parent:fun2()
end

---@class A : Parent
---@field x number
---@field y? number
---@field z number
local A = {}

function A:fun()
end

---@type A
local t = <!{
    x = 1,
    y = 2,
}!>
]]

TEST [[
---@diagnostic disable: unused-local

---@class Parent
---@field a number
local Parent = {}

function Parent:fun2()
end

---@class A : Parent
---@field x number
---@field y? number
---@field z number
local A = {}

function A:fun()
end

---@type A
local t = {
    x = 1,
    y = 2,
    z = 3,
    a = 1,
}
]]

TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number
local A = {}

function A:fun()
end

---@type A
local t = <!{
    x = 1,
    y = 2,
}!>
]]

TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number

---@type A
local t = {
    x = 1,
    z = 3,
}
]]

TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number

---@param a A
local function f(a) end

f <!{}!>
]]

TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number

---@param a A
local function f(a) end

f <!{
    x = 1,
}!>
]]

TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number

---@param a A
local function f(a) end

f <!{
    x = 1,
    y = 2,
}!>
]]

TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number

---@param a A
local function f(a) end

f {
    x = 1,
    y = 2,
    z = 3,
}
]]

TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number

---@param a A
local function f(a) end

f {
    x = 1,
    z = 3,
}
]]

TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
local t = {}
]]

TEST [[
---@diagnostic disable: unused-local

---@class A
---@field x number

---@class A
local t = {}
]]

TEST [[
---@diagnostic disable: unused-local

---@class Foo
---@field a number
---@field b number
---@field c number

---@type Foo|Foo[]
local a = {
    {
        a = 1,
        b = 2,
        c = 3,
    }
}
]]

TEST [[
---@diagnostic disable: unused-local

---@class Foo
---@field a number
---@field b number
---@field c number

---@class Bar
---@field ba number
---@field bb number
---@field bc number

---@type Foo|Bar
local b = {
    a = 1,
    b = 2,
    c = 3,
}
]]

TEST [[
---@class A
---@field x integer

---@type A
return <!{}!>
]]

TEST [[
---@class A
---@field x number

---@class B
---@field y number

---@type A|B
local t = <!{
    z = 1,
}!>
]]

TEST [[
---@class A
---@field x number

---@class B
---@field y number

---@type A|B
local t = {
    y = 1,
}
]]

TEST [[
---@diagnostic disable: unused-local

---@class Foo
---@field a number
---@field b number
---@field c number

---@class Foo

---@class Bar
---@field ba number
---@field bb number
---@field bc number

---@class Bar
---@field bd number

---@type Foo|Bar
local x = {
	ba = 1,
	bb = 2,
	bc = 3,
	bd = 4,
}
]]

TEST [[
---@diagnostic disable: unused-local

---@class Foo
---@field a number
---@field b number
---@field c number

---@class Foo

---@class Bar
---@field ba number
---@field bb number
---@field bc number

---@class Bar
---@field bd number

---@type Foo|Bar
local x = {
	a = 1,
	b = 2,
	c = 3,
}
]]

TEST [[
---@diagnostic disable: unused-local

---@class Foo
---@field a number
---@field b number
---@field c number

---@class Foo

---@class Bar
---@field ba number
---@field bb number
---@field bc number

---@class Bar
---@field bd number

---@type Foo|Bar
local x = <!{
	a = 1,
	b = 2,
}!>
]]

TEST [[
---@diagnostic disable: unused-local

---@class Foo
---@field a number
---@field b number
---@field c number

---@class Foo

---@class Bar
---@field ba number
---@field bb number
---@field bc number

---@class Bar
---@field bd number

---@type Foo|Bar
local x = <!{
	ba = 1,
	bb = 2,
	bd = 4,
}!>
]]

TEST [[
---@class A
---@field [1] string
---@field x number

---@type A
local t = {x = 1, ""}
]]

TEST [[
---@class A
---@field [1] string
---@field x number

---@type A
local t = <!{x = 1}!>
]]

-- Inheritance

TEST [[
---@class A
---@field x number

---@class B: A

---@type B
local t = <!{}!>
]]

TEST [[
---@class A
---@field x number
---@field y number

---@class B: A

---@type B
local t = <!{y = 1}!>
]]

TEST [[
---@class A
---@field x number

---@class B: A
---@field y number

---@type B
local t = <!{y = 1}!>
]]

-- Inheritance + optional

TEST [[
---@class A
---@field x? number

---@class B: A

---@type B
local t = {}
]]

TEST [[
---@class A
---@field x? number
---@field y number

---@class B: A

---@type B
local t = {y = 1}
]]

TEST [[
---@class A
---@field x? number

---@class B: A
---@field y number

---@type B
local t = {y = 1}
]]

-- Inheritance + function call

TEST [[
---@class A
---@field x number

---@class B: A

---@param b B
local function f(b) end

f <!{}!>
]]

TEST [[
---@class A
---@field x number
---@field y number

---@class B: A

---@param b B
local function f(b) end

f <!{y = 1}!>
]]

TEST [[
---@class A
---@field x number

---@class B: A
---@field y number

---@param b B
local function f(b) end

f <!{y = 1}!>
]]

-- partial class

TEST [[
---@class A
---@field x number

---@class (partial) B: A

---@type B
local t = {}
]]

TEST [[
---@class A
---@field x number

---@class (partial) B: A
---@field y number

---@type B
local t = <!{}!>
]]

TEST [[
---@class A
---@field x number

---@class (partial) B: A
---@field y number

---@type B
local t = {y = 1}
]]

--

-- (incremental)：对象是逐字段构建的，构造表不要求完整
TEST [[
---@class (incremental) A
---@field x number
---@field y number

---@type A
local t = {}

---@type A
local u = {x = 1}
]]

TEST [[
---@class (incremental) A
---@field x number

---@class B: A
---@field y number

---@type B
local t = <!{}!>
]]

-- many tables of one class in a file: each is checked against what the class requires, whatever
-- the ones before it were (the required keys of a class are worked out once)
TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field y? number
---@field z number

---@type A
local a = <!{ x = 1 }!>
---@type A
local b = { x = 1, z = 3 }
---@type A
local c = <!{ z = 3 }!>
---@type A
local d = { x = 1, y = 2, z = 3 }
---@type A
local e = <!{}!>
]]

-- inherited fields count too, and a class is not mixed up with its parent
TEST [[
---@diagnostic disable: unused-local
---@class Base
---@field id integer

---@class Child: Base
---@field name string

---@type Child
local a = <!{ name = 'a' }!>
---@type Child
local b = { id = 1, name = 'b' }
---@type Base
local c = { id = 2 }
---@type Base
local d = <!{}!>
]]

-- the class changes: the answer follows (each TEST is a new text)
TEST [[
---@diagnostic disable: unused-local
---@class A
---@field x number
---@field w number

---@type A
local a = <!{ x = 1 }!>
]]

-- a table written in a `return` is checked against the class the function declares
TEST [[
---@class RetFields
---@field name string
---@field count integer

---@return RetFields
local function complete()
    return { name = "x", count = 1 }
end

---@return RetFields
local function partial()
    return <!{ name = "x" }!>
end

---@return RetFields, RetFields
local function second()
    return { name = "x", count = 1 }, <!{ name = "y" }!>
end

---@return string, RetFields
local function otherSlot()
    return "a", <!{ name = "x" }!>
end

---@return RetFields?
local function maybe()
    return nil
end

---@generic T
---@param v T
---@return T
local function id(v)
    return {}
end
]]

-- an inline shape has required fields like a class: the table declared as nothing else is checked against it
TEST [[
---@param p { x: number, y: number }
local function f(p) end
f(<!{ x = 1 }!>)
f({ x = 1, y = 2 })
f({ x = 1, y = 2, z = 3 })

---@type { a: number, b: string }
local shaped = <!{ a = 1 }!>
]]

-- ... an optional or nullable field may be left out, an index signature and a table<K, V> have no required key
TEST [[
---@param p { x: number, y?: number, z: string|nil }
local function f(p) end
f({ x = 1 })

---@param d table<string, number>
local function g(d) end
g({})

---@param s { [string]: number }
local function h(s) end
h({})
]]

-- ... a union of shapes is not judged against each of them
TEST [[
---@param p { a: number }|{ b: number }
local function f(p) end
f({ a = 1 })
f({ b = 1 })
]]

-- ... nested shapes, and a returned table
TEST [[
---@param p { inner: { z: number } }
local function f(p) end
f({ inner = { z = 1 } })
f({ inner = <!{}!> })
f(<!{}!>)

---@return { a: number, b: string }
local function g() return <!{ a = 1 }!> end
]]
