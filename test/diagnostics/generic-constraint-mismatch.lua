-- A type bound to a type parameter has to satisfy a constraint that names another type parameter (`---@generic K: keyof T`).
-- The argument that binds the type parameter is reported. A constraint on its own (`T: Base`) is already reported by
-- `param-type-mismatch` (as `<T:Base>`): this diagnostic leaves it alone, so the same call is not marked twice.

-- `keyof`: the key has to be a field of the other argument
TEST [[
---@generic T, K: keyof T
---@param obj T
---@param key K
---@return T[K]
local function get(obj, key) return obj[key] end

---@class Point
---@field x number
---@field y number

---@type Point
local p
get(p, 'x')
get(p, 'y')
get(p, <!'z'!>)
]]

-- the key can be an inline table's field too
TEST [[
---@generic T, K: keyof T
---@param obj T
---@param key K
---@return T[K]
local function get(obj, key) return obj[key] end

get({ a = 1 }, 'a')
get({ a = 1 }, <!'b'!>)
]]

-- a constraint that stands alone is not this diagnostic's: class, primitive and union constraints are reported by param-type-mismatch
TEST [[
---@class Animal
---@class Rock

---@generic T: Animal
---@param x T
---@return T
local function feed(x) return x end

---@generic T: number
---@param x T
---@return T
local function double(x) return x end

---@type Rock
local rock
feed(rock)
feed(5)
double('a')
]]

-- unknown / any keys and nothing given say nothing
TEST [[
---@generic T, K: keyof T
---@param obj T
---@param key? K
---@return T
local function f(obj, key) return obj end

---@class Point
---@field x number
---@type Point
local p
---@type any
local anything
f(p, anything)
f(p)
f(p, nil)
]]

-- a generic without a constraint is never reported
TEST [[
---@generic T
---@param x T
---@return T
local function id(x) return x end

id(1)
id('a')
id(nil)
]]

-- inside another generic function the argument is still a type parameter: nothing is decided yet
TEST [[
---@generic T, K: keyof T
---@param obj T
---@param key K
---@return T[K]
local function get(obj, key) return obj[key] end

---@generic U
---@param u U
local function outer(u)
    get(u, 'anything')
end
]]

-- the message of a union key names the member that does not fit; a plain key does not
TEST [[
---@generic T, K: keyof T
---@param obj T
---@param key K
---@return T[K]
local function get(obj, key) return obj[key] end

---@class Point
---@field x number
---@type Point
local p
---@type 'x'|'z'
local mixed

get(p, <!mixed!>)
]]
(function (diags)
    local reported = diags --[[@as { message: string }[] ]]
    local message = reported[1].message
    assert(message:find("`\"z\"` does not fit", 1, true) or message:find("`'z'` does not fit", 1, true), message)
end)

TEST [[
---@generic T, K: keyof T
---@param obj T
---@param key K
---@return T[K]
local function get(obj, key) return obj[key] end

---@class Point
---@field x number
---@type Point
local p

get(p, <!'z'!>)
]]
(function (diags)
    local reported = diags --[[@as { message: string }[] ]]
    local message = reported[1].message
    assert(not message:find('does not fit', 1, true), message)
end)

-- `K extends keyof T` is the same constraint as `K: keyof T`
TEST [[
---@generic T, K extends keyof T
---@param obj T
---@param key K
---@return T[K]
local function get(obj, key) return obj[key] end

---@class Point
---@field x number
---@type Point
local p

get(p, 'x')
get(p, <!'z'!>)
]]

-- a parameter typed `keyof T` takes only keys of the type `T` was bound to by another argument
TEST [[
---@class Point
---@field x number
---@field y number
---@type Point
local p

---@generic T: table
---@param tbl T
---@param key keyof T
local function one(tbl, key) end

one(p, 'x')
one(p, 'y')
one(p, <!'zz'!>)
one(p, <!5!>)
]]

-- `---@param ... keyof T`: every extra argument is checked
TEST [[
---@class Point
---@field x number
---@field y number
---@type Point
local p

---@generic T: table
---@param tbl T
---@param ... keyof T
local function many(tbl, ...) end

many(p)
many(p, 'x')
many(p, 'x', 'y')
many(p, 'x', <!'zz'!>)
many(p, <!'aa'!>, 'x', <!'bb'!>)
many(p, 'x', <!5!>)
]]

-- a method called with a colon: its first argument is the receiver (`self`)
TEST [[
---@class Point
---@field x number
---@type Point
local p

---@class Holder
local Holder = {}

---@generic T: table
---@param tbl T
---@param ... keyof T
function Holder:check(tbl, ...) end

Holder:check(p, 'x')
Holder:check(p, <!'zz'!>)
Holder.check(Holder, p, <!'zz'!>)
]]

-- unknown arguments and a parameter with no `keyof` are left alone
TEST [[
---@class Point
---@field x number
---@type Point
local p
---@type any
local anything
local unknown = nil

---@generic T: table
---@param tbl T
---@param ... keyof T
local function many(tbl, ...) end

---@generic T: table
---@param tbl T
---@param ... number
local function numbers(tbl, ...) end

many(p, anything)
many(p, unknown)
-- (a wrong type for a parameter with no `keyof` is `param-type-mismatch`'s business, not this diagnostic's)
numbers(p, 'zz', 'anything goes')
]]

-- the type arguments of a class (or an alias) with a constrained type parameter: `---@class Widget<T: Frame>`
TEST [[
---@class Frame
---@class Button: Frame
---@class Widget<T: Frame>

---@type Widget<Frame>
local a
---@type Widget<Button>
local b
---@type Widget<<!number!>>
local c
---@type Widget<Frame?>
local d
---@type Widget<<!Frame|number!>>
local e
]]

-- the `extends` spelling, an alias, the argument that is checked is the one of its own parameter
TEST [[
---@alias Pair<K: string, V extends number> { [K]: V }

---@type Pair<string, number>
local ok
---@type Pair<<!integer!>, number>
local badKey
---@type Pair<string, <!string!>>
local badValue
]]

-- left alone: no constraint, an argument that is unknown or `any`, a constraint or an argument that names another type parameter
TEST [[
---@class Frame
---@class Plain<T>
---@class Widget<T: Frame>
---@class Keyed<K: keyof T, T>

---@type Plain<number>
local plain
---@type Widget<any>
local anything
---@type Widget<Missing>
local unknown

---@generic U
---@param w Widget<U>
local function f(w) end
]]

-- an argument that is a type parameter of the function around it is not checked (what it stands for is known at a call); nor is a
-- constraint that names another type parameter of the class
TEST [[
---@class Frame
---@class Widget<T: Frame>

---@generic U: Frame
---@param w Widget<U>
local function ok(w) end

---@generic V
---@param w Widget<V>
local function free(w) end

---@generic N: number
---@param w Widget<N>
local function bad(w) end

---@class Keyed<K: keyof T, T>
---@type Keyed<string, Frame>
local keyed
]]
