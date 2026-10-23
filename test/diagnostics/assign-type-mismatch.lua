local config = require 'config'

TEST [[
local m = {}

---@type integer[]
m.ints = {}
]]

TEST [[
---@class A
---@field x A

---@type A
local t

t.x = {}
]]

TEST [[
---@class A
---@field x integer

---@type A
local t

<!t.x!> = true
]]

TEST [[
---@class A
---@field x integer

---@type A
local t

---@type boolean
local y

<!t.x!> = y
]]

TEST [[
---@class A
local m

m.x = 1

---@type A
local t

<!t.x!> = true
]]

TEST [[
---@class A
local m

---@type integer
m.x = 1

<!m.x!> = true
]]

TEST [[
---@class A
local mt

---@type integer
mt.x = 1

function mt:init()
    <!self.x!> = true
end
]]

TEST [[
---@class A
---@field x integer

---@type A
local t = {
    <!x!> = true
}
]]

TEST [[
---@type boolean[]
local t = {}

t[5] = nil
]]

TEST [[
---@type table<string, true>
local t = {}

t['x'] = nil
]]

TEST [[
---@type [boolean]
local t = { <![1]!> = nil }

t = nil
]]

TEST [[
local t = { true }

t[1] = nil
]]

TEST [[
---@class A
local t = {
    x = 1
}

<!t.x!> = true
]]

TEST [[
---@type number
local t

t = 1
]]

TEST [[
---@type number
local t

---@type integer
local y

t = y
]]

TEST [[
---@class A
local m

---@type number
m.x = 1

<!m.x!> = {}
]]

TEST [[
local n

if G then
    n = {}
else
    n = nil
end

local t = {
    x = n,
}
]]

TEST [[
---@type boolean[]
local t = {}

---@type boolean?
local x

t[#t+1] = x
]]

TEST [[
---@type number
local n
---@type integer
local i

<?i?> = n
]]

config.set(nil, 'Lua.type.castNumberToInteger', true)
TEST [[
---@type number
local n
---@type integer
local i

i = n
]]

config.set(nil, 'Lua.type.castNumberToInteger', false)
TEST [[
---@type number|boolean
local nb

---@type number
local n

<?n?> = nb
]]

config.set(nil, 'Lua.type.weakUnionCheck', true)
TEST [[
---@type number|boolean
local nb

---@type number
local n

n = nb
]]

config.set(nil, 'Lua.type.weakUnionCheck', false)
TEST [[
---@class Option: string

---@param x Option
local function f(x) end

---@type Option
local x = 'aaa'

f(x)
]]
config.set(nil, 'Lua.type.weakUnionCheck', true)

TEST [[
---@type number
local <!x!> = 'aaa'
]]
TEST [[
---@class X

---@class A
local mt = G

---@type X
mt._x = nil
]]
config.set(nil, 'Lua.type.weakUnionCheck', false)

config.set(nil, 'Lua.type.weakNilCheck', true)
TEST [[
---@type number?
local nb

---@type number
local n

n = nb
]]

TEST [[
---@type number|nil
local nb

---@type number
local n

n = nb
]]
config.set(nil, 'Lua.type.weakNilCheck', false)

TEST [[
---@class A
local a = {}

---@class B
local <!b!> = a
]]

TEST [[
---@class A
local a = {}

---@class B: A
local b = a
]]

TEST [[
---@class A
local a = {}
a.__index = a

---@class B: A
local b = setmetatable({}, a)
]]

TEST [[
---@class A
local a = {}

---@class B: A
local b = setmetatable({}, {__index = a})
]]

TEST [[
---@class A
local a = {}

---@class B
local <!b!> = setmetatable({}, {__index = a})
]]

TEST [[
---@class A
---@field x number?
local a

---@class B
---@field x number
local b

b.x = a.x
]]

TEST [[

---@class A
---@field x number?
local a

---@type number
local t

t = a.x
]]

TEST [[
local mt = {}
mt.x = 1
mt.x = nil
]]

config.set(nil, 'Lua.type.weakUnionCheck', true)
TEST [[
---@type number
local x = G
]]

TEST [[
---@generic T
---@param x T
---@return T
local function f(x)
    return x
end
]]
config.set(nil, 'Lua.type.weakUnionCheck', false)


TEST [[
---@alias test boolean

---@type test
local <!test!> = 4
]]

TEST [[
---@class MyClass
local MyClass = {}

function MyClass:new()
    ---@class MyClass
    local myObject = setmetatable({
        initialField = true
    }, self)

    print(myObject.initialField)
end
]]

TEST [[
---@class T
local t = {
    x = nil
}

t.x = 1
]]

TEST [[
---@type {[1]: string, [10]: number, xx: boolean}
local t = {
    <!true!>,
    <![10]!> = 's',
    <!xx!> = 1,
}
]]

TEST [[
---@type boolean[]
local t = { <!1!>, <!2!>, <!3!> }
]]

TEST [[
---@type boolean[]
local t = { true, false, nil }
]]

TEST [[
---@type boolean|nil
local x

---@type boolean[]
local t = { true, false, x }
]]

TEST [[
---@enum Enum
local t = {
    x = 1,
    y = 2,
}

---@type Enum
local y

---@type integer
local x = y
]]

TEST [[
---@type string|string[]|string[][]
local t = {{'a'}}
]]

TEST [[
local A = "Hello"
local B = "World"

---@alias myLiteralAliases `A` | `B`

---@type myLiteralAliases
local x = A
]]

TEST [[
local enum = { a = 1, b = 2 }

---@type { [integer] : boolean }
local t = {
    <![enum.a]!> = 1,
    <![enum.b]!> = 2,
    <![3]!> = 3,
}
]]

TEST [[
---@class SomeClass
---@field [1] string
-- ...

---@param some_param SomeClass|SomeClass[]
local function some_fn(some_param) return end

some_fn { { "test" } } -- <- diagnostic: "Cannot assign `table` to `string`."
]]

TEST [[
---@type string[]
local arr = {
    <!3!>,
}
]]

TEST [[
---@type (string|boolean)[]
local arr2 = {
    <!3!>, -- no warnings
}
]]

TEST [[
local t = {}
t.a = 1
t.a = 2
return t
]]

-- `never` is the type of a value that cannot exist: assigning to it after a chain that handled every
-- variant is the exhaustiveness check, and it reports the variant that is still possible
TEST [[
---@param x string|number|boolean
local function f(x)
    if type(x) == 'string' then
        return 1
    elseif type(x) == 'number' then
        return 2
    else
        ---@type never
        local <!_bad!> = x
    end
end
]]

TEST [[
---@param x string|number
local function f(x)
    if type(x) == 'string' then
        return 1
    elseif type(x) == 'number' then
        return 2
    else
        ---@type never
        local _ok = x
    end
end
]]

TEST [[
---@class Circle
---@field kind 'circle'
---@class Square
---@field kind 'square'
---@class Tri
---@field kind 'tri'

---@param s Circle|Square|Tri
local function area(s)
    if s.kind == 'circle' then
        return 1
    elseif s.kind == 'square' then
        return 2
    else
        ---@type never
        local <!_missing!> = s
    end
end
]]

TEST [[
---@class Circle
---@field kind 'circle'
---@class Square
---@field kind 'square'

---@param s Circle|Square
local function area(s)
    if s.kind == 'circle' then
        return 1
    elseif s.kind == 'square' then
        return 2
    else
        ---@type never
        local _all = s
    end
end
]]

-- the exhaustiveness check for a union of table types written inline
TEST [[
---@alias Shape { kind: 'circle', r: number } | { kind: 'square', side: number } | { kind: 'tri', base: number }

---@param s Shape
local function area(s)
    if s.kind == 'circle' then
        return 1
    elseif s.kind == 'square' then
        return 2
    else
        ---@type never
        local <!_missing!> = s
    end
end
]]

TEST [[
---@alias Shape { kind: 'circle', r: number } | { kind: 'square', side: number }

---@param s Shape
local function area(s)
    if s.kind == 'circle' then
        return 1
    elseif s.kind == 'square' then
        return 2
    else
        ---@type never
        local _all = s
    end
end
]]

-- inside the body of a generic function a `keyof T` stays symbolic and is a string-like key: assigning, concatenating and using it as a key are fine
TEST [[
---@generic T: table
---@param tbl T
---@param key keyof T
local function f(tbl, key)
    ---@type string|number
    local asKey = key
    ---@type string
    local joined = "k:" .. key
    tbl[key] = nil
    local t = { [key] = true }
end
]]

-- an array assigned from another array: the element types have to fit (TypeScript: `string[]` does not take a `number[]`)
TEST [[
---@class ArrAnimal
---@class ArrDog: ArrAnimal

---@type number[]
local nums = {}
---@type string[]
local strs = {}
---@type ArrDog[]
local dogs = {}
---@type ArrAnimal[]
local animals = {}
---@type integer[]
local ints = {}
---@type any[]
local anys = {}

---@type string[]
local <!a1!> = nums
---@type string[]
local a2 = strs
---@type (string|number)[]
local a3 = nums
---@type ArrAnimal[]
local a4 = dogs
---@type ArrDog[]
local <!a5!> = animals
---@type number[]
local a6 = ints
---@type string[]
local a7 = anys
---@type any[]
local a8 = strs
---@type string[]?
local <!a9!> = nums
]]

-- the type arguments of a generic class are compared here too
TEST [[
---@class TArgAssign<T>
local TArgAssign = {}

---@type TArgAssign<number>
local numBox

---@type TArgAssign<boolean>
local <!boolBox!> = numBox

---@type TArgAssign<number | string>
local wideBox = numBox
]]

-- the values of a table written in a `return` are checked against the fields of the declared type, array and shape included
TEST [[
---@class RetValues
---@field name string

---@return RetValues
local function wrongField()
    return { <!name!> = 5 }
end

---@return string[]
local function wrongElements()
    return { "a", <!2!> }
end

---@return {[1]: string, [2]: number}
local function wrongPair()
    return { "hello", <!"world"!> }
end

---@return string[]
local function fine()
    return { "a", "b" }
end

---@return RetValues
local function alsoFine()
    return { name = "x" }
end
]]

-- the value of a `Record<string, V>`
TEST [[
---@type Record<string, number>
local rec = {}
rec.a = 1
<!rec['b']!> = 'x'
]]

-- a table written for a generic class with its arguments (`Box<integer>`): the fields are the class's with the arguments bound
TEST [[
---@class GBox<T>
---@field value T
---@field label string

---@type GBox<integer>
local a = { value = 1, label = 'x' }
---@type GBox<integer>
local b = { <!value!> = 'x', label = 'x' }
---@type GBox<string>
local c = { value = 'x', <!label!> = 1 }
local holder = {}
---@type GBox<string>
holder.d = { <!value!> = 1, label = 'x' }
]]

-- the same for a table given as an ARGUMENT for a parameter of a generic class with its arguments
TEST [[
---@class GArg<T>
---@field value T
---@field label string

---@param b GArg<integer>
local function take(b) end

take({ value = 1, label = 'x' })
take({ <!value!> = 'x', label = 'x' })
take({ value = 1, <!label!> = 2 })
---@param s GArg<string>
local function takeString(s) end
takeString({ value = 'x', label = 'y' })
takeString({ <!value!> = 1, label = 'y' })
]]

-- the elements of a `T[]` field of a generic class with its arguments (nested table literal), and of a `table<string, T>` field
TEST [[
---@class GList<T>
---@field list T[]
---@field map table<string, T>

---@type GList<integer>
local a = { list = { 1, 2 }, map = { k = 1 } }
---@type GList<integer>
local b = { list = { 1, <!'s'!> }, map = { <!k!> = 's' } }
---@param p GList<string>
local function take(p) end
take({ list = { 'a' }, map = { k = 'b' } })
take({ list = { <!1!> }, map = { <!k!> = 2 } })
]]

-- the hooking idiom: a plain function written for a method slot takes the object first
TEST [[
---@class HookFrame
local HookFrame = {}
function HookFrame:Show() end
---@param n number
function HookFrame:SetN(n) end
---@return boolean
function HookFrame:Is() return true end

---@type HookFrame
local f = HookFrame
f.Show = function(self) end
f.Show = function(self, ...) end
f.Show = function() end
f.SetN = function(self, n) end
f.SetN = function(self, ...) end
f.Is = function(self) return false end
]]

-- ... one that needs more than the object and what the method provides is still a mismatch
TEST [[
---@class HookFrame2
local HookFrame2 = {}
function HookFrame2:Show() end

---@type HookFrame2
local f = HookFrame2
<!f.Show!> = function(self, extra) end
<!f.Show!> = function(self, a, b) end
]]

-- a write through a proxy takes the value type its `__newindex` function declares
TEST [[
---@param t table
---@param k string
---@param v number
local function setIt(t, k, v) rawset(t, k, v) end
local proxy = setmetatable({}, { __newindex = setIt })
proxy.name = 1
<!proxy.name!> = 'x'
<!proxy['other']!> = true
]]

-- ... a function that declares no value type, an inline function and a plain table take anything
TEST [[
local function untyped(t, k, v) rawset(t, k, v) end
local a = setmetatable({}, { __newindex = untyped })
a.name = 'x'
local b = setmetatable({}, { __newindex = function (t, k, v) rawset(t, k, v) end })
b.name = 'x'
local c = {}
c.name = 'x'
]]

-- ... two possible __newindex functions say nothing about the value
TEST [[
---@param t table
---@param k string
---@param v number
local function setNumber(t, k, v) rawset(t, k, v) end
---@param t table
---@param k string
---@param v string
local function setString(t, k, v) rawset(t, k, v) end
local flag = math.random() > 0.5
local proxy = setmetatable({}, { __newindex = flag and setNumber or setString })
proxy.a = 1
proxy.b = 'x'
]]
