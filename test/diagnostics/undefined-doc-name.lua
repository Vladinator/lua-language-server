TEST [[
---@type <!A!>
]]

TEST [[
---@class A
---@type A|<!B!>|<!C!>
]]

TEST [[
---@class AAA
---@alias B AAA

---@type B
]]

TEST [[
---@alias B <!AAA!>
]]

-- Generic class methods should not warn about class generic params
TEST [[
---@class Container<T>
local Container = {}

---@return T[]
function Container:getAll()
    return {}
end
]]

-- Inline class fields with generics should not warn
TEST [[
---@class Box<T>
---@field value T
]]

-- Multiple generic params should all be recognized
TEST [[
---@class Map<K, V>
local Map = {}

---@param key K
---@return V
function Map:get(key)
end
]]

-- Variable name different from class name
TEST [[
---@class Pool<T>
local M = {}

---@param item T
function M:push(item) end
]]

-- Undefined types SHOULD still warn (control case)
TEST [[
---@class Container<T>
local Container = {}

---@return <!UndefinedType!>
function Container:getBad()
    return {}
end
]]

-- a constraint or a default may name another type parameter of the same `---@generic` line, in any order
TEST [[
---@generic T, K: keyof T
---@param obj T
---@param key K
---@return T[K]
local function get(obj, key) return obj[key] end

---@generic K: keyof T, T
---@param obj T
---@param key K
local function reversed(obj, key) end

---@generic T, U = T[]
---@param a T
---@param b U
local function withDefault(a, b) end
]]

-- ...but a name no `---@generic` line declares is still undefined
TEST [[
---@generic K: keyof <!Missing!>
---@param key K
local function f(key) end
]]
