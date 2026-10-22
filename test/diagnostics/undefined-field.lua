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
    local _ = cb[<!"yyy"!>]
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

-- a module-private table whose fields are all spelled in the code that can reach it is closed: a field it never has is a typo
TEST [[
local rec = { x = 1 }
rec.alpha = 1
function rec.beta() return rec.alpha end
function rec:gamma() end

print(rec.x, rec.alpha, rec.beta, rec.gamma)
print(rec.<!alfa!>, rec.<!Beta!>)
rec:<!gama!>()
local _ = rec.<!zz!> ~= nil
]]

-- a string-literal index is the same field
TEST [[
local rec = { first = 1 }
rec["second"] = 2
print(rec.second, rec.<!thrid!>)
]]

-- anything that lets the table be used through a name the code does not spell keeps it open
TEST [[
local function use(t) return t end

local passed = { a = 1 }
use(passed)
print(passed.zzz)

local dynamic = { a = 1 }
dynamic[tostring(1)] = 2
print(dynamic.zzz)

local computed = { [tostring(1)] = 1 }
print(computed.zzz)

local reassigned = { a = 1 }
reassigned = { b = 2 }
print(reassigned.zzz)

local returned = { a = 1 }
local function give() return returned end
print(returned.zzz)

local looped = { a = 1 }
for _ in pairs(looped) do end
print(looped.zzz)

local meta = { a = 1 }
setmetatable(meta, { __index = function () end })
print(meta.zzz)
]]

-- a declared class or a table with a type is checked the way it always was
TEST [[
---@type { alfa: number }
local typed = { alfa = 1 }
print(typed.alfa, typed.<!beta!>)
]]

-- a table declared empty and never given a field says nothing about what it will hold
TEST [[
local cache = {}
print(cache.anything)
]]

-- a type the author wrote is not second-guessed
TEST [[
---@type table
local declared = { a = 1 }
print(declared.zzz)
]]

-- a plain comment above the declaration changes nothing
TEST [[
-- the record of this module
local rec = { x = 1 }
print(rec.x, rec.<!y!>)
]]

-- a table declared empty becomes a record by the fields the code gives it
TEST [[
local rec = {}
rec.alpha = 1
print(rec.alpha, rec.<!alfa!>)
]]

-- `---@return self` is the receiver: a method of the subclass is found down a chain
TEST [[
---@class UfSelfBase
local UfSelfBase = {}
---@return self
function UfSelfBase:Set() return self end

---@class UfSelfChild : UfSelfBase
local UfSelfChild = {}
function UfSelfChild:Extra() end

---@type UfSelfChild
local child
child:Set():Extra()
child:Set():<!Missing!>()
]]

-- a class declared on a `return { ... }`: the fields of the table are the fields of the class (LibPixelStrip: `---@class Stats` before `return { ... }`)
TEST [[
local function stats()
    local pending = 0
    ---@class RetStats
    return {
        enabled = true,
        pending = pending,
    }
end
local st = stats()
print(st.enabled, st.pending, st.<!nope!>)
]]

-- ... and the same table kept in a local first
TEST [[
local function stats()
    ---@class RetStats2
    local t = {
        enabled = true,
    }
    return t
end
local st = stats()
print(st.enabled, st.<!nope!>)
]]

-- `p['nothing']` is the same read as `p.nothing` for a value declared as a class
TEST [[
---@class StrIdx1
---@field name string
---@type StrIdx1
local p = { name = 'x' }
print(p['name'], p[<!'nothing'!>], p.name, p.<!nothing!>)
]]

-- ... not for a plain table, `any`, a class that answers any string key, or a key that is not a literal
TEST [[
---@class StrIdx2
---@field name string
---@class StrIdx3
---@field [string] number
---@type StrIdx2
local declared = { name = 'x' }
---@type StrIdx3
local open = {}
---@type table<string, number>
local dict = {}
---@type any
local any
local plain = {}
local key = 'nothing'
print(declared[key], open['anything'], dict['anything'], any['anything'], plain['anything'], string['len'])
]]

-- ... a field of a parent class, and one added with a doc field further down
TEST [[
---@class StrIdx4
---@field base number
---@class StrIdx5: StrIdx4
---@field own number
---@type StrIdx5
local c = { base = 1, own = 2 }
print(c['base'], c['own'], c[<!'zzz'!>])
]]
