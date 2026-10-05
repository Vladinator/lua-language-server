-- The type bound to a type parameter has to satisfy its constraint (`---@generic T: Base`, `---@generic K: keyof T`).
-- The argument that binds the type parameter is reported.

-- a class constraint: the class itself and its subclasses fit, an unrelated type does not
TEST [[
---@class Animal
---@class Dog: Animal
---@class Rock

---@generic T: Animal
---@param x T
---@return T
local function feed(x) return x end

---@type Animal
local animal
---@type Dog
local dog
---@type Rock
local rock

feed(animal)
feed(dog)
feed(<!rock!>)
feed(<!5!>)
]]

-- a primitive constraint
TEST [[
---@generic T: number
---@param x T
---@return T
local function double(x) return x end

double(1)
double(1.5)
double(<!'a'!>)
double(<!true!>)
]]

-- a union constraint
TEST [[
---@generic T: string|number
---@param x T
---@return T
local function show(x) return x end

show('a')
show(1)
show(<!true!>)
]]

-- unknown / any arguments, and nothing given, say nothing
TEST [[
---@generic T: number
---@param x? T
---@return T?
local function f(x) return x end

---@type any
local anything
f(anything)
f()
f(nil)
]]

-- `keyof` constraint: the key has to be a field of the other argument
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
---@generic T: number
---@param x T
---@return T
local function double(x) return x end

---@generic U
---@param u U
---@return U
local function outer(u)
    double(u)
    return u
end

---@generic T, K: keyof T
---@param obj T
---@param key K
---@return T[K]
local function get(obj, key) return obj[key] end

---@generic U
---@param u U
local function outer2(u)
    get(u, 'anything')
end
]]
