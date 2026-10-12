local config = require "config.config"
TEST [[
---@param x number
local function f(x) end

f(<!true!>)
]]

TEST [[
---@class A

---@param n A
local function f(n)
end

---@class B
local a = {}

---@type A?
a.x = XX

f(<!a.x!>)
]]
TEST [[
---@alias A string|boolean

---@param x string|boolean
local function f(x) end

---@type A
local x

f(x)
]]

TEST [[
---@alias A string|boolean

---@param x A
local function f(x) end

---@type string|boolean
local x

f(x)
]]

TEST [[
---@param b boolean
local function f(b)
end

---@type boolean
local t

if t then
    f(t)
end
]]

TEST [[
---@enum A
local t = {
    x = 1,
    y = 2,
}

---@param x A
local function f(x)
end

f(<!t!>)
f(t.x)
f(1)
f(<!3!>)
]]

TEST [[
---@enum A
local t = {
    x = { h = 1 },
    y = { h = 2 },
}

---@param x A
local function f(x)
end

f(t.x)
f(t.y)
f(<!{ h = 1 }!>)
]]

TEST [[
---@enum(key) A
local t = {
    x = 1,
    ['y'] = 2,
}

---@param x A
local function f(x)
end

f('x')
f('y')
f(<!'z'!>)
]]

-- `keyof self` (wowlua-ls interop): inside a method, `self` resolves to the receiver's own class
TEST [[
---@class KeyofSelfPTM.Widget
local Widget = {}

function Widget:Show() end
function Widget:Hide() end

---@generic K: keyof self
---@param method K
function Widget:Dispatch(method)
end

---@type KeyofSelfPTM.Widget
local w = {}

w:Dispatch('Show')
w:Dispatch('Hide')
w:Dispatch(<!'Nope'!>)
]]

TEST [[
---@generic T: string | boolean | table
---@param x T
---@return T
local function f(x)
    return x
end

f(<!1!>)
]]

TEST [[
---@param opts {a:number, b:number}
local function foo(opts)

end

---@param opts {a:number, b:number}
local function bar(opts)
    foo(opts)
end
]]

TEST [[
---@param opts {a:number, b:number}
local function foo(opts)

end

---@param opts {c:number, d:number}
local function bar(opts)
    foo(<!opts!>)  -- this should raise linting error
end
]]

TEST [[
---@param opts {[number]: boolean}
local function foo(opts)

end

---@param opts {[1]: boolean}
local function bar(opts)
    foo(opts)
end
]]

TEST [[
---@generic T
---@param v1 T
---@param v2 T|table
local function func(v1, v2)
end

func('hello', 'world')
]]

TEST [[
---@generic T1, T2, T3, T4, T5
---@param f fun(): T1?, T2?, T3?, T4?, T5?
---@return T1?, T2?, T3?, T4?, T5?
local function foo(f)
    return f()
end

local a, b = foo(function()
    return 1
end)
]]

TEST [[
---@generic T1, T2, T3, T4, T5
---@param f fun(): T1|nil, T2|nil, T3|nil, T4|nil, T5|nil
---@return T1?, T2?, T3?, T4?, T5?
local function foo(f)
    return f()
end

local a, b = foo(function()
    return 1
end)
]]

TEST [[
---@param v integer
---@return boolean
local function is_string(v)
    return type(v) == 'string'
end

print(is_string(3))
]]

TEST [[
---@param p integer|string
local function get_val(p)
    local is_number = type(p) == 'number'
    return is_number and p or p
end

get_val('hi')
]]

TEST [[
---@class Class
local Class = {}

---@param source string
function Class.staticCreator(source)

end

Class.staticCreator(<!true!>)
Class<!:!>staticCreator() -- Expecting a waring
]]

TEST [[
---@class A

---@class B : A

---@class C : B

---@class D : B

---@param x A
local function func(x) end

---@type C|D
local var
func(var)
]]

TEST [[
---@class MyClass
---@overload fun(x : string) : MyClass
local MyClass = {}

local w = MyClass(<!1!>)
]]

TEST [[
---@enum(key) A
local t1 = {
    x = 1,
}

---@enum(key) A
local t2 = {
    y = 1,
}

---@param v A
local function f(v) end

f 'x'
f 'y'
]]

TEST [[
---@class A
---@field x string
---@field y number

local a = {x = "", y = 0}

---@param a A
function f(a) end

f(a)
]]

config.set(nil, 'Lua.type.checkTableShape', true)

TEST [[
---@class A
---@field x string
---@field y number

local a = {x = ""}

---@param a A
function f(a) end

f(<!a!>)
]]

TEST [[
---@class A
---@field x string
---@field y number

local a = {x = "", y = ""}

---@param a A
function f(a) end

f(<!a!>)
]]

TEST [[
---@class A
---@field x string
---@field y? B

---@class B
---@field x string

local a = {x = "b", y = {x = "c"}}

---@param a A
function f(a) end

f(a)
]]

TEST [[
---@class A
---@field x string
---@field y B

---@class B
---@field x string

local a = {x = "b", y = {}}

---@param a A
function f(a) end

f(<!a!>)
]]

TEST [[
---@class A
---@field x string

---@type A
local a = {}

---@param a A
function f(a) end

f(a)
]]

TEST [[
---@class A: integer

---@param a A
local function f(a) end

---@type integer
local i

f(i)
]]

TEST [[
---@class A: integer

---@param a A
local function f(a) end

local t = {
    { int = 123 },
    { int = 456 },
    { int = 789 },
}

---@type integer
local i

local k = t[i].int

f(k)
]]

TEST [[
---@type [1, 2, 3]
local x

---@param y { [1]?: 1, [2]?: 2, [3]?: 3, [4]?: 4}
local function f(y) end

f(x)
]]

-- A class inheriting a generic one is still a child of that generic's own parent: the
-- parent given with arguments is parsed one level down and used to be skipped.
TEST [[
---@class Base

---@class Middle<T> : Base
---@field Value T

---@class Child : Middle<boolean>

---@param value Base
local function f(value) end

---@type Child
local child

f(child)
]]

-- `---@generic T: string` (a constraint): an argument that does not fit it is reported. `expandGenerics`
-- expands `T` to its constraint (`generic.generic.extends`, the generic NAME use's back-reference to its
-- declaration, set by `bindGeneric` in parser/luadoc.lua); no test exercised this path before.
TEST [[
---@generic T: string
---@param x T
---@return T
local function f(x) return x end

f(<!123!>)
f('ok')
]]

-- an unconstrained generic still takes anything, as before
TEST [[
---@generic T
---@param x T
---@return T
local function f(x) return x end

f(123)
f('ok')
f(true)
]]

-- a generic constraint on a method
TEST [[
---@class Widget
local Widget = {}

---@generic T: string
---@param x T
function Widget:set(x) end

---@type Widget
local w

w:set(<!123!>)
w:set('ok')
]]

config.set(nil, 'Lua.type.checkTableShape', false)

-- TypeScript-parity types as parameter types: what they accept and what they reject
-- (a table literal's wrong field is reported by assign-type-mismatch, so these pass typed values)
TEST [[
---@class TSParamPTM.Point
---@field x number
---@field y string

---@param k keyof TSParamPTM.Point
local function byKey(k) end

byKey('x')
byKey('y')
byKey(<!'z'!>)
byKey(<!1!>)

---@param v TSParamPTM.Point['x']
local function byField(v) end

byField(1)
byField(<!'s'!>)
]]

TEST [[
---@class TSParamPTM.Point2
---@field x number
---@field y string

---@param v Pick<TSParamPTM.Point2, "x">
local function picked(v) end

---@type { x: number }
local good
---@type { x: string }
local bad

picked(good)
picked(<!bad!>)
picked(<!1!>)
]]

TEST [[
---@class TSParamPTM.Point3
---@field x number
---@field y string

---@param v Omit<TSParamPTM.Point3, "x">
local function omitted(v) end

---@type { y: string }
local good
---@type { y: number }
local bad

omitted(good)
omitted(<!bad!>)
]]

TEST [[
---@class TSParamPTM.Point4
---@field x number

---@param v Partial<TSParamPTM.Point4>
local function partial(v) end

---@type { x: number }
local full
---@type { x: number? }
local optional
---@type { x: string }
local bad

partial(full)
partial(optional)
partial(<!bad!>)
]]

TEST [[
---@class TSParamPTM.Point5
---@field x number

---@param v Required<TSParamPTM.Point5>
local function required(v) end

---@type { x: number }
local full

required(full)
required(<!nil!>)
]]

TEST [[
---@param v Record<"a"|"b", number>
local function rec(v) end

---@type { a: number, b: number }
local good
---@type { a: string, b: number }
local bad

rec(good)
rec(<!bad!>)
]]

TEST [[
---@class TSParamPTM.A
---@field x number

---@class TSParamPTM.B
---@field y string

---@param v TSParamPTM.A & TSParamPTM.B
local function both(v) end

---@type { x: number, y: string }
local good
---@type { x: string, y: string }
local bad

both(good)
both(<!bad!>)
]]

-- a method of a generic class: the class's type parameter is replaced by the receiver's own type
-- argument before the argument is checked
TEST [[
---@class GenBoxPTM<T>
local Box = {}

---@param v T
function Box:set(v) end

---@type GenBoxPTM<string>
local b

b:set('ok')
b:set(<!1!>)
]]

TEST [[
---@class GenPairPTM<K, V>
local Pair = {}

---@param k K
---@param v V
function Pair:put(k, v) end

---@type GenPairPTM<string, number>
local p

p:put('a', 1)
p:put(<!1!>, 1)
p:put('a', <!'x'!>)
]]

-- `---@generic T extends Base` (TypeScript's spelling) is the same constraint as `T: Base`
TEST [[
---@class ExtendsAnimal
---@class ExtendsDog: ExtendsAnimal
---@class ExtendsRock

---@generic T extends ExtendsAnimal
---@param x T
---@return T
local function feed(x) return x end

---@type ExtendsDog
local dog
---@type ExtendsRock
local rock

feed(dog)
feed(<!rock!>)
]]

-- ... and so is passing it on, also through `...`
TEST [[
---@generic T: table
---@param tbl T
---@param ... keyof T
local function f(tbl, ...)
    for _, key in ipairs({...}) do
        local text = tostring(key)
        local raw = rawget(tbl, key)
        print(type(key), key)
    end
    local first = ...
    return rawget(tbl, first)
end
]]

-- the type parameters of a class are read through the classes that inherit from it: a parent written with arguments, with a renamed
-- parameter forwarded, two levels down
TEST [[
---@class InhBox<T>
local InhBox = {}

---@param value T
function InhBox:set(value) end

---@class InhRenamed<U>: InhBox<U>
---@class InhNumbers: InhBox<number>
---@class InhDeep: InhNumbers

---@type InhRenamed<string>
local renamed
---@type InhNumbers
local numbers
---@type InhDeep
local deep

renamed:set('x')
renamed:set(<!1!>)
numbers:set(1)
numbers:set(<!'x'!>)
deep:set(1)
deep:set(<!'x'!>)
]]

-- a parameter of the child with the same name as the parent's is not the parent's: the method of the parent is read with ITS argument
TEST [[
---@class InhBase<T>
local InhBase = {}

---@param value T
function InhBase:take(value) end

---@class InhMixed<T>: InhBase<string>

---@type InhMixed<number>
local mixed
mixed:take('x')
mixed:take(<!1!>)
]]

-- `---@param ... params<F>` (wowlua-ls, TypeScript's `Parameters<F>`): the extra arguments are the parameters of the function F was bound to
TEST [[
---@generic F: fun(...)
---@param fn F
---@param ... params<F>
---@return returns<F>
local function call(fn, ...) return fn(...) end

---@param name string
---@param count integer
---@return boolean
local function spawn(name, count) return true end

call(spawn, 'orc', 3)
call(spawn, 'orc', <!'three'!>)
call(spawn, <!5!>, 3)
]]

-- a function literal, a method, a callee with an optional parameter and one with a `...` of its own, and F not known
TEST [[
---@generic F: fun(...)
---@param fn F
---@param ... params<F>
local function call(fn, ...) end

call(function (a, b) end, 1, 'x')

---@param a number
---@param b string
local function typed(a, b) end
call(typed, 1, 'x')
call(typed, <!'x'!>, 'x')

local obj = {}
---@generic F: fun(...)
---@param fn F
---@param ... params<F>
function obj:run(fn, ...) end

---@param name string
---@param count integer
local function spawn(name, count) end
obj:run(spawn, 'orc', <!'three'!>)

---@param a string
---@param ... number
local function rest(a, ...) end
call(rest, 'a', 1, 2, 3)

---@param fn fun(...)
---@param ... any
local function unknownF(fn, ...)
    call(fn, 1, 'anything')
end
]]

-- F stands for several functions, or has a type parameter of its own: nothing is claimed about the arguments
TEST [[
---@generic F: fun(...)
---@param fn F
---@param ... params<F>
local function call(fn, ...) end

---@param name string
local function one(name) end
---@param count integer
local function two(count) end
local either = math.random() > 0.5 and one or two
call(either, {})

---@generic T
---@param value T
local function identity(value) return value end
call(identity, {})

---@generic T: string
---@param value T
local function constrained(value) return value end
call(constrained, {})

---@param label string
---@param ... number
local function rest(label, ...) end
call(rest, 'a', 1, 'not a number')
]]

-- an array argument: the element type has to fit the parameter's
TEST [[
---@type number[]
local nums = {}
---@type string[]
local strs = {}

---@param xs string[]
local function takes(xs) end

takes(strs)
takes(<!nums!>)
]]

-- a typed `...` is the type of EVERY extra argument (a rest parameter, as in TypeScript), not of the first one only
TEST [[
---@param ... number
local function sum(...) end

sum()
sum(1, 2, 3)
sum(1, <!'x'!>, 3, <!{}!>)
sum(nil, 1)

---@param label string
---@param ... number
local function labeled(label, ...) end

labeled('a', 1, 2)
labeled('a', 1, <!'bad'!>)
labeled('a', <!'bad'!>)

---@param ... any
local function anything(...) end
anything(1, 'x', {})

---@param ... string|number
local function either(...) end
either(1, 'x', <!{}!>)

---@param ... number
local function forwards(...)
    sum(...)
    sum(1, ...)
end

local numbers = { 1, 2 }
sum(1, table.unpack(numbers))
]]

-- the same for a method and for a function type
TEST [[
local obj = {}
---@param ... number
function obj:add(...) end

obj:add(1, 2)
obj:add(1, <!'x'!>)

---@type fun(...: number)
local callback
callback(1, 2)
callback(1, <!'x'!>)
]]

-- opaque aliases are nominal (wowlua-ls): another opaque alias of the same inner type is not accepted; plain values and literals are, and
-- the alias flows out to its inner type
TEST [[
---@alias (opaque) PlayerID number
---@alias (opaque) ItemID number

---@param id PlayerID
local function lookup(id) return id end

---@param n number
local function takesNumber(n) end

---@return ItemID
local function getItemID() return 1 end

---@type ItemID
local item
---@type PlayerID
local player
---@type number
local plain

lookup(42)
lookup(plain)
lookup(player)
lookup(<!item!>)
lookup(<!getItemID()!>)
takesNumber(player)
takesNumber(item)
local sum = player + 1
lookup(sum)
local copy = item
lookup(<!copy!>)
]]

-- string literal unions as well; a plain alias (not opaque) stays interchangeable
TEST [[
---@alias (opaque) Answer "YES"|"NO"
---@alias (opaque) Toggle "YES"|"NO"
---@alias Plain1 "YES"|"NO"
---@alias Plain2 "YES"|"NO"

---@param a Answer
local function process(a) end
---@param a Plain1
local function plainProcess(a) end

---@return Toggle
local function getToggle() return "YES" end
---@return Plain2
local function getPlain() return "YES" end

process("YES")
process(<!getToggle()!>)
plainProcess(getPlain())
]]

-- Lua.type.checkFieldNilArguments: false (the original LuaLS) takes the nil out of a field read before the check, true (the default) checks it like a variable
config.set(nil, 'Lua.type.checkFieldNilArguments', false)
TEST [[
---@class Opt
---@field f? table
---@field name string?

---@type Opt
local o

---@param t table
local function plain(t) end
---@param s string
local function str(s) end

plain(o.f)
str(o.name)
plain(o['f'])
local v = o.f
plain(<!v!>)
]]

config.set(nil, 'Lua.type.checkFieldNilArguments', true)
TEST [[
---@class Opt
---@field f? table
---@field name string?

---@type Opt
local o

---@param t table
local function plain(t) end
---@param s string
local function str(s) end

plain(<!o.f!>)
str(<!o.name!>)
plain(<!o['f']!>)
local v = o.f
plain(<!v!>)

-- narrowed like a variable
if o.f then
    plain(o.f)
end
if not o.name then
    return
end
str(o.name)
plain(o.f or {})
o.f = {}
plain(o.f)

-- a field that is never nil is no business of the setting
---@class Req
---@field f table
---@type Req
local r
plain(r.f)
]]
config.set(nil, 'Lua.type.checkFieldNilArguments', false)

-- under Lua.type.weakUnionCheck a union fits as soon as one member does (nil included): the field setting still asks for the nil of a field
config.set(nil, 'Lua.type.weakUnionCheck', true)
TEST [[
---@class Opt
---@field f? table
---@type Opt
local o

---@param t table
local function plain(t) end

plain(o.f)
local v = o.f
plain(v)
]]

config.set(nil, 'Lua.type.checkFieldNilArguments', true)
TEST [[
---@class Opt
---@field f? table
---@type Opt
local o

---@param t table
local function plain(t) end

---@param t table?
local function maybe(t) end

plain(<!o.f!>)
maybe(o.f) -- (a parameter that takes nil)
local v = o.f
plain(v) -- (a variable: the weak union check still takes it)
if o.f then
    plain(o.f)
end
plain(o.f or {})
]]

config.set(nil, 'Lua.type.weakNilCheck', true)
TEST [[
---@class Opt
---@field f? table
---@type Opt
local o

---@param t table
local function plain(t) end

plain(o.f)
]]
config.set(nil, 'Lua.type.weakNilCheck', false)
config.set(nil, 'Lua.type.checkFieldNilArguments', true)
config.set(nil, 'Lua.type.weakUnionCheck', false)

-- `params<F>` where F is a type parameter of the CLASS (the registry pattern): the receiver says what it stands for, a child class passes it on, an unbound receiver checks nothing
TEST [[
---@class Registry<F>
local Registry = {}

---@param key string
---@param ... params<F>
function Registry:Call(key, ...) end

---@class Plain
local Plain = {}

---@param key string
---@param ... number
function Plain:Call(key, ...) end

---@class Child : Registry<fun(name: string)>

---@type Registry<fun(name: string, count: number)>
local reg

---@type Registry<fun(name: string, count?: number)>
local optional

---@type Child
local child

---@type Registry
local unbound

---@class Sub<T> : Registry<fun(x: T)>

---@type Sub<string>
local sub

reg:Call('k', 'orc', 3)
reg:Call('k', <!5!>, 3)
reg:Call('k', 'orc', <!'three'!>)
reg.Call(reg, 'k', <!5!>, 3)
optional:Call('k', 'orc')
optional:Call('k', 'orc', 3)
child:Call('k', 'orc')
child:Call('k', <!5!>)
unbound:Call('k', 5, 'anything')
sub:Call('k', 'text')
sub:Call('k', <!5!>)
]]

-- a table called through the `__call` of its metatable: the arguments are checked against the parameters after the first (the table)
TEST [[
---@diagnostic disable: unused-local
local counter = setmetatable({}, {
    ---@param self table
    ---@param step integer
    ---@param label string
    __call = function (self, step, label) end,
})

counter(1, 'a')
counter(<!'x'!>, 'a')
counter(1, <!2!>)
]]

-- no declared parameter type: nothing to compare with
TEST [[
local counter = setmetatable({}, {
    __call = function (self, step) end,
})
counter('anything')
]]

-- ... a `...` parameter after the first: nil is accepted there, not for a plain parameter
TEST [[
---@diagnostic disable: unused-local
local counter = setmetatable({}, {
    ---@param self table
    ---@param step integer
    ---@param ... string
    __call = function (self, step, ...) end,
})
counter(1, nil)
counter(<!nil!>, 'a')
]]

-- an index with a key that is a local nobody assigns again narrows like a literal key (TypeScript 5.5: constant indexed accesses)
TEST [[
---@class Profile
local Profile = {}

---@type table<string, Profile?>
local db = {}

---@param p Profile
local function take(p) end

---@param bid string
local function param(bid)
    if db[bid] then
        take(db[bid])
    end
end

local key = "x"
if db[key] then
    take(db[key])
end

for _, k in ipairs({ "a", "b" }) do
    if db[k] then
        take(db[k])
    end
end

---@param bid? string
---@param create? boolean
local function guarded(bid, create)
    if not bid or bid == "" then
        return false
    end
    if db[bid] then
        take(db[bid])
        if not create then
            db[bid] = nil
            return true
        end
        return true, db[bid]
    end
end
param("a") guarded()
]]

-- ... a key that is assigned again, another key, a key a nested function may change: not narrowed
TEST [[
---@class Profile
local Profile = {}

---@type table<string, Profile?>
local db = {}

---@param p Profile
local function take(p) end

---@param bid string
local function reassigned(bid)
    if db[bid] then
        bid = "other"
        take(<!db[bid]!>)
    end
end

---@param bid string
---@param other string
local function otherKey(bid, other)
    if db[bid] then
        take(<!db[other]!>)
    end
end

---@param bid string
local function changed(bid)
    local function change() bid = "x" end
    if db[bid] then
        change()
        take(<!db[bid]!>)
    end
end
reassigned("a") otherKey("a", "b") changed("a")
]]
