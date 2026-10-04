-- Two arguments bound to the same type parameter have to fit together. The first argument binds `T` (TypeScript's
-- first candidate), a later one has to be assignable to it, or be wider (which widens `T`).

-- the later argument does not fit what the first one bound
TEST [[
---@generic T
---@param value T
---@param fallback T
---@return T
local function f(value, fallback) return value end

---@type number
local n
f(n, <!'asd'!>)
f(1, <!'asd'!>)
f('a', <!true!>)
]]

-- an optional parameter of `T` binds and checks the same way
TEST [[
---@generic T
---@param value T
---@param fallback? T
---@return T
local function f(value, fallback) return value end

---@type string
local s
f(s, <!5!>)
f(s)
f(s, nil)
]]

-- fine: the same type, a literal of it, a narrower and a wider later argument, integer and number
TEST [[
---@generic T
---@param a T
---@param b T
---@return T
local function f(a, b) return a end

---@type number
local n
---@type integer
local i
---@type number?
local maybe
---@type string|number
local mixed
f(n, n)
f(n, 1)
f(1, 2.5)
f(2.5, 1)
f(i, n)
f('a', 'b')
f(true, false)
f(n, mixed)
f(mixed, n)
f(n, maybe)
]]

-- nothing to bind from: `any`, an unknown value, a nil argument
TEST [[
---@generic T
---@param a T
---@param b T
---@return T
local function f(a, b) return a end

---@type any
local anything
local unknownValue = unknownGlobal
f(1, anything)
f(anything, 'x')
f(1, unknownValue)
f(1, nil)
f(nil, 'x')
]]

-- different type parameters are independent, and a parameter that mentions a type parameter only inside a container
-- is bound through its elements, not here
TEST [[
---@generic A, B
---@param a A
---@param b B
---@return A, B
local function pair(a, b) return a, b end

---@generic T
---@param list T[]
---@param value T
---@return T
local function add(list, value) return value end

pair(1, 'x')
pair('x', 1)
add({ 1, 2 }, 3)
]]

-- overloads: the signature the call can be is the one that is checked (here only the two-parameter one takes two
-- arguments); when several signatures fit the call, nothing is said
TEST [[
---@generic T
---@param a T
---@param b T
---@return T
---@overload fun<T>(a: T): T
local function f(a, b) return a end

---@generic T
---@param a T
---@param b T
---@return T
---@overload fun<T>(a: T, b: string): T
local function g(a, b) return a end

---@param a number
---@param b number
local function plain(a, b) end

f(1, <!'x'!>)
f(1)
g(1, 'x')
plain(1, 'x')
]]

-- the optional-fallback shape of a helper that returns a value or a fallback: an overload for "no fallback" and one
-- for an explicit nil do not take part in a call with a real fallback
TEST [[
---@generic T
---@param value T
---@param fallback T
---@return T
---@overload fun<T>(value: T): T?
---@overload fun<T>(value: T, fallback: nil): T?
local function orFallback(value, fallback) return value end

---@type number
local n
orFallback(n, 2)
orFallback(n, <!'asd'!>)
orFallback(n)
orFallback(n, nil)
]]

-- a method call: `self` is the first argument of the call
TEST [[
---@class Box
local Box = {}

---@generic T
---@param a T
---@param b T
---@return T
function Box:pick(a, b) return a end

---@type Box
local box
box:pick(1, <!'x'!>)
box:pick(1, 2)
]]

-- a method of a plain table (its `self` is not among the parameters)
TEST [[
local obj = {}

---@generic T
---@param a T
---@param b T
---@return T
function obj:pick(a, b) return a end

obj:pick(1, <!'x'!>)
obj:pick(1, 2)
obj.pick(obj, 1, <!'x'!>)
]]

-- the second type parameter use: both later arguments are checked against the first
TEST [[
---@generic T
---@param a T
---@param b T
---@param c T
---@return T
local function f(a, b, c) return a end

f(1, 2, <!'x'!>)
f(1, <!'x'!>, <!'y'!>)
]]
