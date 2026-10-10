TEST [[
---@class Foo
---@field field1 integer
local mt = {}
function mt:Constructor()
    self.field2 = 1
end
function mt:method1() return 1 end
function mt.method2() return 2 end

---@class Bar: Foo
---@field field4 integer
local mt2 = {}

---@type Foo
local v
print(v.field1 + 1)
print(v.field2 + 1)
print(v.<!field3!> + 1)
print(v:method1())
print(v.method2())
print(v:<!method3!>())

---@type Bar
local v2
print(v2.field1 + 1)
print(v2.field2 + 1)
print(v2.<!field3!> + 1)
print(v2.field4 + 1)
print(v2:method1())
print(v2.method2())
print(v2:<!method3!>())

local v3 = {}
print(v3.abc)

---@class Bar2
local mt3
function mt3:method() return 1 end
print(mt3:method())
]]

-- checkUndefinedField 通过type找到class
TEST [[
---@class Foo
local Foo
function Foo:method1() end

---@type Foo
local v
v:method1()
v:<!method2!>() -- doc.class.name
]]

-- checkUndefinedField 通过type找到class，涉及到 class 继承版
TEST [[
---@class Foo
local Foo
function Foo:method1() end
---@class Bar: Foo
local Bar
function Bar:method3() end

---@type Bar
local v
v:method1()
v:<!method2!>() -- doc.class.name
v:method3()
]]

-- checkUndefinedField 类名和类变量同名，类变量被直接使用
TEST [[
---@class Foo
local Foo
function Foo:method1() end
Foo:<!method2!>() -- doc.class
Foo:<!method2!>() -- doc.class
]]

-- checkUndefinedField 没有@class的不检测
TEST [[
local Foo
function Foo:method1()
    return Foo:method2() -- table
end
]]

-- checkUndefinedField 类名和类变量不同名，类变量被直接使用、使用self
TEST [[
---@class Foo
local mt
function mt:method1()
    mt.<!method2!>() -- doc.class
    self:method1()
    return self.<!method2!>() -- doc.class.name
end
]]

-- checkUndefinedField 当会推导成多个class类型时
TEST [[
---@class Foo
local mt
function mt:method1() end

---@class Bar
local mt2
function mt2:method2() end

---@type Foo
local v
---@type Bar
local v2
v2 = v
v2:method1()
v2:<!method2!>()
]]

TEST [[
---@type table
T1 = {}
print(T1.f1)
---@type tablelib
T2 = {}
print(T2.<!f2!>)
]]

TEST [[
---@type string|table
local n

print(n.x)
]]

TEST [[
---@type 'x'
local t

local n = t:upper()
]]

TEST [[
---@alias A 'x'

---@type A
local t

local n = t:upper()
]]

TEST [[
---@enum X
X = {
    A = 1,
    B = 2
}

print(X.<!C!>)
]]

-- an enum read by index: a missing key is reported, an existing one is not
TEST [[
---@enum IdxEnum
local IdxEnum = {
    A = 1,
    B = 2,
}

print(IdxEnum['A'])
print(IdxEnum[<!'C'!>])
]]

-- a class that inherits from table<string, V> has any string key
TEST [[
---@class Dict : table<string, number>
---@class DictChild : Dict

---@type Dict
local d = {}
print(d.anything)
print(d['other'])

---@type DictChild
local c = {}
print(c.anything)
]]

TEST [[
---@class Plain
---@field a number

---@type Plain
local p = {}
print(p.<!nothere!>)
]]

-- a table parent with another key type does not make string keys valid
TEST [[
---@class Numbered : table<integer, number>

---@type Numbered
local n = {}
print(n.<!foo!>)
]]

-- an index that is a choice between names: each literal has to be a field
TEST [[
---@class Cb
---@field Reg fun()
---@field Unreg fun()
---@type Cb
local cb
---@param flag boolean
---@param key "Reg"|"asd"
local function f(flag, key)
    local _ = cb[flag and "Reg" or <!"asd"!>]
    local _ = cb[flag and <!"xxx"!> or "Reg"]
    local _ = cb[<!key!>]
    local _ = cb[flag and "Reg" or "Unreg"]
end
]]

-- ... but a single literal (the metatable may answer), a plain string, an unknown owner and a key of a `table<K, V>` class are left alone
TEST [[
---@class Cb
---@field Reg fun()
---@type Cb
local cb
---@class Dyn : table<string, integer>
---@type Dyn
local dyn
---@generic K, V
---@param t table<K, V>
---@return table<V, K>
local function revert(t) end
local map = revert({ a = 'x' })
local plain = { c = 1 }
---@type any
local anything
---@param flag boolean
---@param s string
---@param mixed string|"nope"
---@param blank ""|"Reg"
local function f(flag, s, mixed, blank)
    local _ = cb["yyy"]
    local _ = cb[s]
    local _ = cb[mixed]
    local _ = cb[blank]
    local _ = anything[flag and "a" or "b"]
    local _ = dyn[flag and "a" or "b"]
    local _ = map[flag and "a" or "b"]
    local _ = unknownGlobal[flag and "a" or "b"]
    local _ = plain[flag and "a" or "b"]
    local _ = _G[flag and "a" or "b"]
end
]]
