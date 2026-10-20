-- a key of the wrong type: write and read, for each way of declaring the key type
TEST [[
---@type table<number, boolean>
local t = {}
---@param s string
local function f(s)
    t[<!s!>] = true
    local _ = t[<!s!>]
    local _ = t[<!true!>]
end
]]

-- the key types a table can be declared with: `V[]`, `{ [K]: V }`, an alias, a class that inherits `table<K, V>`, `[K]` fields
TEST [[
---@type number[]
local arr = {}
---@type {[number]: boolean}
local inl = {}
---@alias Id number
---@type table<Id, string>
local ali = {}
---@param s string
local function f(s)
    arr[<!s!>] = 1
    inl[<!s!>] = true
    ali[<!s!>] = 'x'
end
]]

-- fine: the declared key, an `any` key, an integer-valued float, a union that holds the key, a table that declares nothing
TEST [[
---@type table<number, boolean>
local t = {}
---@type table<string|number, boolean>
local u = {}
---@type table<string, number> | table<number, string>
local either = {}
local plain = {}
---@type any
local any
---@param n number
---@param i integer
---@param s string
local function f(n, i, s)
    t[n] = true
    t[i] = true
    t[any] = true
    t[n / 2] = true
    u[s] = true
    u[n] = true
    either[s] = 1
    either[n] = 'x'
    plain[s] = 1
    plain[true] = 1
end
]]

-- fine: a float into an integer-keyed table (an integer-valued float is the same key); a class next to a table type says nothing
-- about the keys of the whole
TEST [[
---@type table<integer, string>
local ints = {}
---@class Bag2
local Bag2
---@type Bag2 | table<number, boolean>
local mixed = {}
---@param n number
---@param s string
local function f(n, s)
    ints[n] = 'x'
    mixed[s] = true
end
]]

-- a class does not declare its keys (`undefined-field` and `inject-field` say what is wrong), only `[K]` fields do
TEST [[
---@class Bag
---@field name string
local bag = {}
---@param s string
local function f(s)
    bag[s] = 1
end
]]

-- the key of a field of a generic class is the argument that was bound
TEST [[
---@class Reg<K, V>
---@field items table<K, V>
---@type Reg<string, number>
local reg = {}
---@param s string
---@param n number
local function f(s, n)
    reg.items[s] = 1
    reg.items[<!n!>] = 1
end
]]

-- a generic alias in a field: the key is the one the alias declares, not the `K` of the builtin `table<K, V>` behind it
TEST [[
---@alias Dict<V> table<string, V>
---@class Holder
---@field dict Dict<number>
---@type Holder
local holder = {}
---@param n number
---@param s string
local function f(n, s)
    holder.dict[s] = 1
    holder.dict[<!n!>] = 1
end
]]

-- a union with a member that is not a table type (a string indexes its methods): nothing is said about the keys
TEST [[
---@type string | table<number, boolean>
local either = {}
---@param s string
local function f(s)
    local _ = either[s]
end
]]

TEST [[
---@type fun() | table<number, boolean>
local either = {}
---@param s string
local function f(s)
    local _ = either[s]
end
]]
