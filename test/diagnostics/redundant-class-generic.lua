-- A method whose `---@generic` names a type parameter its class already declares: the class-level one is in scope, the method's is redundant.
-- (wowlua-ls: Warning, "Method redeclares class-level @generic".)

-- the class declares it with `<T>`
TEST [[
---@class Box<T>
local Box = {}

---@generic <!T!>
---@param x T
function Box:set(x) end

---@generic U
---@param x U
function Box:other(x) end
]]

-- a list of generics: only the redeclared name is marked; a field assigned a function counts as a method too
TEST [[
---@class Pair<K, V>
local Pair = {}

---@generic <!K!>, W
function Pair.static(k, w) end
]]

-- left alone: a plain function, a class without type parameters, a name that is not a type parameter of this class
TEST [[
---@class Box<T>
local Box = {}

---@generic T
local function free(x) end

---@class Flat
local Flat = {}

---@generic T
function Flat:get() end

---@class Other<U>
local Other = {}

---@generic T
function Other:get() end
]]

-- (not modelled: wowlua-ls's other spelling of a class type parameter, a `---@generic T` written after the `---@class` line: the fork does not
-- bind it to the class, so nothing is declared and nothing is reported)
TEST [[
---@class Container
---@generic T
local Container = {}

---@generic T
function Container:Get() end
]]
