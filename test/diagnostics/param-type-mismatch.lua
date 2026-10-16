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

-- an optional parameter of a method stays optional (a method call builds the parameter type again from the receiver)
TEST [[
---@class OptionalMethodPTM
local M = {}

---@param count integer?
function M:Run(count) end

---@type OptionalMethodPTM
local m = {}
---@type integer?
local maybe

m:Run(maybe)
m:Run(nil)
m:Run(<!'x'!>)
]]

-- `keyof self` follows the receiver of the call: a subclass's own member is a valid key, the base class's receiver does not know it
TEST [[
---@class KeyofSelfPoly.Animal
local Animal = {}

function Animal:Eat() end

---@generic K: keyof self
---@param method K
function Animal:Do(method)
end

---@class KeyofSelfPoly.Dog : KeyofSelfPoly.Animal
local Dog = {}

function Dog:Bark() end

---@type KeyofSelfPoly.Dog
local dog = {}
---@type KeyofSelfPoly.Animal
local animal = {}

dog:Do('Eat')
dog:Do('Bark')
dog:Do(<!'Fly'!>)
animal:Do('Eat')
animal:Do(<!'Bark'!>)
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

-- the type arguments of a generic class are compared (covariantly, as the argument of the parameter must be assignable to the one
-- the parameter names): `Container<number>` is not a `Container<boolean>`
TEST [[
---@class TArgBox<T>
local TArgBox = {}

---@param c TArgBox<boolean>
local function takeBool(c) end

---@type TArgBox<number>
local numBox
---@type TArgBox<boolean>
local boolBox
---@type TArgBox<boolean | number>
local unionBox

takeBool(<!numBox!>)
takeBool(boolBox)
takeBool(<!unionBox!>)
]]

-- ... a narrower argument is fine where a wider one is asked for, a wider one with a member that does not fit is not
TEST [[
---@class TArgBox2<T>
local TArgBox2 = {}

---@param c TArgBox2<string | number>
local function takeBoth(c) end

---@type TArgBox2<number>
local numBox
---@type TArgBox2<number | false>
local falseBox

takeBoth(numBox)
takeBoth(<!falseBox!>)
]]

-- ... a class with no argument given, `any`, and an argument that is a type parameter say nothing
TEST [[
---@class TArgBox3<T>
local TArgBox3 = {}

---@param c TArgBox3<boolean>
local function takeBool(c) end

---@type TArgBox3
local bare
---@type TArgBox3<any>
local anyBox

takeBool(bare)
takeBool(anyBox)

---@generic T
---@param box TArgBox3<T>
local function forward(box)
    takeBool(box)
end
]]

-- ... the arguments of a class that inherits are read through its parent: a forwarded parameter and a fixed parent
TEST [[
---@class TArgBox4<T>
local TArgBox4 = {}

---@class TArgSub<T> : TArgBox4<T>

---@class TArgFixed<T> : TArgBox4<string>

---@param c TArgBox4<boolean>
local function takeBool(c) end

---@type TArgSub<number>
local subNum
---@type TArgSub<boolean>
local subBool
---@type TArgFixed<number>
local fixedNum

takeBool(<!subNum!>)
takeBool(subBool)
takeBool(<!fixedNum!>)
]]

-- ... a parent that also allows another class is not judged by the arguments, an optional parent still is
TEST [[
---@class TArgBox5<T>
local TArgBox5 = {}

---@class TArgOther

---@param c TArgBox5<boolean> | TArgOther
local function takeEither(c) end

---@param c TArgBox5<boolean>?
local function takeOptional(c) end

---@type TArgBox5<number>
local numBox
---@type TArgBox5<boolean>
local boolBox

takeEither(numBox)
takeOptional(<!numBox!>)
takeOptional(boolBox)
takeOptional(nil)
]]

-- ... a class with two type parameters: either argument can be the one that does not fit
TEST [[
---@class TArgPair<K, V>
local TArgPair = {}

---@param p TArgPair<string, number>
local function takePair(p) end

---@type TArgPair<string, number>
local good
---@type TArgPair<string, boolean>
local badValue
---@type TArgPair<integer, number>
local badKey

takePair(good)
takePair(<!badValue!>)
takePair(<!badKey!>)
]]

-- ... a parent named without arguments takes any argument, and a child that is a union of two instances needs both to fit
TEST [[
---@class TArgBox6<T>
local TArgBox6 = {}

---@param c TArgBox6
local function takeBare(c) end

---@param c TArgBox6<boolean>
local function takeBool(c) end

---@param c TArgBox6<boolean | number>
local function takeWide(c) end

---@param t table
local function takeTable(t) end

---@type TArgBox6<number>
local numBox
---@type TArgBox6<boolean> | TArgBox6<number>
local mixedBox

takeBare(numBox)
takeTable(numBox)
takeBool(<!mixedBox!>)
takeWide(mixedBox)
]]

-- a function given where a `fun(...)` is asked for: it must not need more arguments than the type provides
TEST [[
---@param cb fun(x: number)
local function on(cb) end

local function none() end
local function one(a) end
local function two(a, b) end
---@param a number
---@param b? number
local function optional(a, b) end
local function rest(...) end

on(none)
on(one)
on(<!two!>)
on(optional)
on(rest)
on(function (a) end)
on(<!function (a, b) end!>)
]]

-- ... a `...` in the type provides any number of them
TEST [[
---@param cb fun(...: number)
local function on(cb) end

local function three(a, b, c) end
on(three)
]]

-- ... the parameter types: what the type provides has to fit what the function takes
TEST [[
---@param cb fun(name: string)
local function on(cb) end

---@param n number
local function takesNumber(n) end
---@param s string
local function takesString(s) end
---@param s string|number
local function takesEither(s) end
local function untyped(s) end

on(<!takesNumber!>)
on(takesString)
on(takesEither)
on(untyped)
]]

-- ... and the return types the other way: what the function gives (written, or inferred when known) has to fit what the type promises
TEST [[
---@param cb fun(): number
local function on(cb) end

---@return string
local function gives() return '' end
---@return integer
local function giveInteger() return 1 end
local function inferred() return '' end
local function nothing() end

on(<!gives!>)
on(giveInteger)
on(<!inferred!>)
on(nothing)
]]

-- ... a plain `function` takes any; a generic callback type is judged by what does not depend on its type parameters (how many arguments it gives)
TEST [[
---@generic T
---@param cb fun(x: T)
local function on(cb) end

---@param cb function
local function plain(cb) end

local function one(a) end
local function two(a, b) end
on(one)
on(<!two!>)
plain(two)
]]

-- ... a callback may take a narrower or a wider type than it is called with (bivariant, as TypeScript's methods)
TEST [[
---@class FnBase
---@class FnDerived : FnBase

---@param cb fun(x: FnBase)
local function onBase(cb) end
---@param cb fun(x: FnDerived)
local function onDerived(cb) end

---@param x FnDerived
local function narrower(x) end
---@param x FnBase
local function wider(x) end

onBase(narrower)
onBase(wider)
onDerived(narrower)
onDerived(wider)
]]

-- ... a `nil` among the returns is not what makes it unfit, another type is
TEST [[
---@param cb fun(): string
local function on(cb) end

---@return string?
local function maybe() return nil end
---@return number?
local function maybeNumber() return nil end

on(maybe)
on(<!maybeNumber!>)
]]

-- ... a value typed `fun(...)` is compared like a function
TEST [[
---@param cb fun(a: number)
local function on(cb) end

---@type fun(a: number, b: number)
local two
---@type fun(a: number)
local one
---@type fun(a: string)
local other

on(<!two!>)
on(one)
on(<!other!>)
]]

-- ... a function with a `...` of its own needs no argument for it, a generic function is not judged, and a `...` of the type is not
-- compared with the parameters of the function
TEST [[
---@param cb fun()
local function onNone(cb) end
---@param cb fun(x: number)
local function onOne(cb) end
---@param cb fun(...: number)
local function onNumbers(cb) end

local function rest(...) end
local function firstAndRest(a, ...) end
---@generic T
---@param a T
---@param b T
local function generic(a, b) end
---@param a string
local function takesString(a) end

onNone(rest)
onNone(<!firstAndRest!>)
onOne(generic)
onNumbers(takesString)
]]

-- ... a basic type next to the generic class in the parent does not hide the arguments
TEST [[
---@class TArgBox7<T>
local TArgBox7 = {}

---@param c TArgBox7<boolean> | string
local function take(c) end

---@type TArgBox7<number>
local numBox
---@type TArgBox7<boolean>
local boolBox

take(<!numBox!>)
take(boolBox)
take('text')
]]

-- `params<F>` inside an inline `fun()`: the wrapper takes the parameters of the function it wraps
TEST [[
---@generic F
---@param func F
---@return fun(...: params<F>): string
local function wrapToString(func) end

---@param a number
---@param b string
---@return boolean
local function original(a, b) return true end

local wrapped = wrapToString(original)
wrapped(1, 'x')
wrapped(<!'x'!>, 'y')
wrapped(1, <!2!>)
]]

-- ... a function with no parameter typed, one with an optional one, and a `...` that stays one
TEST [[
---@generic F
---@param func F
---@return fun(...: params<F>): string
local function wrap(func) end

local function untyped(a, b) end
---@param a number
---@param b? string
local function optional(a, b) end
local function rest(...) end

local w1 = wrap(untyped)
w1(1, 2)
local w2 = wrap(optional)
w2(1)
w2(1, 'x')
w2(<!'x'!>)
local w3 = wrap(rest)
w3(1, 2, 3)
]]

-- `K` bound to a literal key keeps the literal (`local r = key(o, "age")` is a `string` like `local r = "age"` is, the call itself is "age")
TEST [[
---@generic T, K: keyof T
---@param t T
---@param k K
---@return K
local function key(t, k) return k end

---@param name "age"
local function takeAge(name) end
---@param name "name"
local function takeName(name) end

---@type {name: string, age: number}
local o

takeAge(key(o, "age"))
takeName(key(o, "name"))
takeAge(<!key(o, "name")!>)
]]

-- ... an inferred return counts when it is known: a string given where a number is promised, not an unknown one, not a `nil` among them
TEST [[
---@param cb fun(): number
local function on(cb) end

local function text() return '' end
local function mixed(...) if ... then return 1 end return '' end
local function unknownResult(...) return (...) end
local function maybeNumber(...) if ... then return 1 end end
local function numbers() return 1 end
local function nothing() end

on(<!text!>)
on(<!mixed!>)
on(unknownResult)
on(maybeNumber)
on(numbers)
on(nothing)
]]

-- a dictionary `table<K, V>` is not an array: a hash with string keys, or one with number keys (they overlap the indices), does not fit `E[]`
TEST [[
---@class SubEntry
---@field name string

---@param list SubEntry[]
local function useArray(list) end

---@type table<string, number>
local hashOnly
---@type table<number, string>
local numKeyed
---@type SubEntry[]
local real
---@type table<integer, SubEntry>
local integerKeyed
---@type table
local plain

useArray(<!hashOnly!>)
useArray(<!numKeyed!>)
useArray(real)
useArray(integerKeyed)
useArray(plain)
]]

-- ... a string-keyed hash next to an array member of the union is tolerated (it does not interfere with reading the array), a number-keyed one is
-- not, and the array member still has to fit
TEST [[
---@class SubEntry2
---@field name string
---@class SubOther2
---@field id integer

---@param list SubEntry2[]
local function useArray(list) end

---@type table<string, number> | SubEntry2[]
local mixed
---@type table<string, boolean> | SubEntry2[]
local unrelatedHash
---@type table<number, string> | SubEntry2[]
local numberHash
---@type table<string, number> | SubOther2[]
local wrongArray

useArray(mixed)
useArray(unrelatedHash)
useArray(<!numberHash!>)
useArray(<!wrongArray!>)
]]

-- a dictionary whose keys are string literals is a class when it has every required field with a fitting value; a dictionary with open keys
-- is not (nothing says which fields it has)
TEST [[
---@class SPoint3
---@field x number
---@field y number

---@param pt SPoint3
local function usePoint(pt) end

---@type table<"x"|"y", number>
local complete
---@type table<"x", number>
local missingY
---@type table<"x"|"y", string>
local wrongValue
---@type table<string, number>
local openKeys
---@type table<"x"|"y"|"z", number>
local extraKey

usePoint(complete)
usePoint(<!missingY!>)
usePoint(<!wrongValue!>)
usePoint(<!openKeys!>)
usePoint(extraKey)
]]

-- ... an optional field may be absent, an inherited required one may not, a class with no fields takes any dictionary
TEST [[
---@class SColorBase
---@field r number
---@class SColorChild : SColorBase
---@field g number
---@field b number
---@field a? number
---@class SEmpty

---@param c SColorChild
local function useChild(c) end
---@param e SEmpty
local function useEmpty(e) end

---@type table<"r"|"g"|"b", number>
local noAlpha
---@type table<"g"|"b", number>
local missingInherited
---@type table<string, number>
local openKeys

useChild(noAlpha)
useChild(<!missingInherited!>)
useEmpty(openKeys)
]]

-- ... an integer-keyed dictionary has to hold what the array holds, a key that is not known says nothing, a nullable field may be absent
TEST [[
---@class SBox4
---@field label string
---@field note string?

---@param list SBox4[]
local function useList(list) end
---@param box SBox4
local function useBox(box) end

---@type table<integer, string>
local strings
---@type table<integer, SBox4>
local boxes
---@type table<any, number>
local anyKeys
---@type table<"label", string>
local onlyLabel

useList(<!strings!>)
useList(boxes)
useList(anyKeys)
useBox(anyKeys)
useBox(onlyLabel)
]]

-- a table can be an array and a dictionary at once (`{ [1] = "a", a = 1, [2] = "b" }`): a union of key types, or number keys, is not judged as a hash
TEST [[
---@class MixBox
---@field name string

---@param list string[]
local function useStrings(list) end
---@param list MixBox[]
local function useBoxes(list) end
---@param box MixBox
local function useBox(box) end
---@param list number[]
local function useNumbers(list) end

---@type table<string|integer, string>
local mixed = { [1] = "a", a = "x", [2] = "b", b = "y" }
---@type table<number, string>
local numbers = { "a", "b" }
---@type table<string|integer, MixBox>
local mixedBoxes
---@type table<number|string, string|number>
local wide

useStrings(mixed)
useStrings(numbers)
useBoxes(mixedBoxes)
useBox(mixedBoxes)
useNumbers(wide)
]]

-- ... but what the number-keyed table holds still has to be what the array holds
TEST [[
---@param list string[]
local function useStrings(list) end

---@type table<number, boolean>
local flags

useStrings(<!flags!>)
]]

-- ... string literals next to `string` are still a string-keyed hash
TEST [[
---@param list string[]
local function useStrings(list) end

---@type table<"a"|string, string>
local hash

useStrings(<!hash!>)
]]

-- a class made of positions (`---@field [1] string`) is an array and a record at once: the dictionary rule does not make it required keys
TEST [[
---@class PositionalTest
---@field public [1] string
---@field public [2] number
---@field public [3] string
---@field public [4] number

---@param t PositionalTest
local function useTest(t) end
---@param list (string|number)[]
local function useList(list) end

---@type PositionalTest
local t = { "a", 1, "b", 2 }
---@type table<integer, string|number>
local arr
---@type table<"x", number>
local named
---@type table<string|integer, string|number>
local mixed

useTest(t)
useList(t)
useTest(arr)
useTest(named)
useTest(mixed)
useList(mixed)
for i = 1, #t do
    local v = t[i]
end
]]

-- a class given where an inline shape (or an intersection, which is one) is asked for has to have its fields
TEST [[
---@class FacetA
---@field a number
---@class FacetB
---@field b number
---@class FacetAB : FacetA
---@field b number
---@class FacetWrong
---@field a string
---@field b number
---@class FacetOpen
---@field a number
---@field [string] any

---@param p FacetA & FacetB
local function needsBoth(p) end
---@param p {a: number, b: number}
local function needsShape(p) end
---@param p {a: number, b?: number}
local function optionalShape(p) end

---@type FacetA
local onlyA
---@type FacetAB
local inherited
---@type FacetWrong
local wrong
---@type FacetOpen
local open
---@type FacetA & FacetB
local both

needsBoth(<!onlyA!>)
needsBoth(inherited)
needsBoth(<!wrong!>)
needsBoth(both)
needsShape(<!onlyA!>)
needsShape(inherited)
needsShape(<!wrong!>)
needsShape(open)
optionalShape(onlyA)
optionalShape(<!wrong!>)
]]

-- ... methods are fields too, a shape asking for one is met by the class that has it
TEST [[
---@class HasMethod
local HasMethod = {}
function HasMethod:run() end

---@class LacksMethod
local LacksMethod = {}

---@param p { run: fun(self: any) }
local function needsRun(p) end

---@type HasMethod
local has
---@type LacksMethod
local lacks

needsRun(has)
needsRun(<!lacks!>)
]]

-- ... an index in the shape (`{[string]: number}`) is not a field the class has to have
TEST [[
---@class IndexedShapeClass
---@field a number

---@param p {[string]: number, a: number}
local function needsIndexed(p) end

---@type IndexedShapeClass
local c

needsIndexed(c)
]]

-- a callback for a generic function is compared with its type parameters bound by the call (backtick names bind to what the string names)
TEST [[
---@class BoundMap<K, V>
local BoundMap = {}

---@generic K, V
---@param keyType `K`
---@param valType `V`
---@param lookup fun(key: K): V
---@return BoundMap<K, V>
local function newMap(keyType, valType, lookup) return {} end

---@param n number
---@return number
local function numberLookup(n) return n end
---@param s string
---@return number
local function stringLookup(s) return 1 end
---@param s string
---@return string
local function wrongResult(s) return s end

newMap("string", "number", <!numberLookup!>)
newMap("string", "number", stringLookup)
newMap("string", "number", <!wrongResult!>)
]]

-- ... an optional callback parameter stays optional
TEST [[
---@generic K, V
---@param keyType `K`
---@param valType `V`
---@param lookup? fun(key: K): V
local function newMap(keyType, valType, lookup) end

---@param n number
---@return number
local function numberLookup(n) return n end

newMap("string", "number")
newMap("string", "number", nil)
newMap("string", "number", <!numberLookup!>)
]]

-- ... a callback parameter that is not optional does not take `nil`
TEST [[
---@generic K, V
---@param keyType `K`
---@param valType `V`
---@param lookup fun(key: K): V
local function newRequired(keyType, valType, lookup) end

newRequired("string", "number", <!nil!>)
]]
