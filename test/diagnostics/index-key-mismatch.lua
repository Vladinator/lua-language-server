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

-- `Record<K, V>` with a key type is the index signature `{ [K]: V }`: the key and the value are checked
TEST [[
---@type Record<string, number>
local rec = {}
---@param n number
---@param s string
local function f(n, s)
    rec[s] = 1
    rec[<!n!>] = 1
end
]]

-- the entries of a table constructor are keys too: `[k] = v`, `name = v` (the string key) and the positions (the integer keys)
TEST [[
---@type table<number, boolean>
local a = { [1] = true, [<!'x'!>] = true, <!y!> = true }
---@type table<string, number>
local b = { x = 1, [<!1!>] = 1 }
---@type number[]
local c = { 1, 2, <!k!> = 3 }
---@type table<string, number>
local d = { <!1!> }
]]

-- fine: entries that fit, a constructor with no declared type, an `any`
TEST [[
---@type table<number, boolean>
local a = { [1] = true, [2.5] = false }
---@type table<string, number>
local b = { x = 1, ['y'] = 2 }
---@type number[]
local c = { 1, 2, 3 }
local d = { x = 1, [1] = 2 }
---@type table<string|number, any>
local e = { x = 1, 2 }
]]

-- a named entry is the literal key: fine for a declared literal, reported for another one
TEST [[
---@type table<'a'|'b', number>
local ok = { a = 1, ['b'] = 2 }
---@type table<'a'|'b', number>
local bad = { a = 1, <!c!> = 2 }
]]

-- a class declares keys with `---@field [K] V` (its own, a parent's) or by inheriting `table<K, V>`
TEST [[
---@class IdxA
---@field [string] number
---@class IdxB: IdxA
---@class IdxC: table<string, number>
---@class IdxD
---@field name string
---@field [integer] string
---@type IdxA
local a = {}
---@type IdxB
local b = {}
---@type IdxC
local c = {}
---@type IdxD
local d = {}
---@param n number
---@param s string
---@param t boolean
local function f(n, s, t)
    a[s] = 1
    a[<!n!>] = 1
    b[s] = 1
    b[<!t!>] = 1
    c[s] = 1
    c[<!n!>] = 1
    d[1] = 'x'
    d.name = 'x'
    d[s] = 'x'
    d[<!t!>] = 'x'
end
]]

-- a class with an index field next to its named fields: a literal key is a field name (right or wrong, other diagnostics say), not a key type
TEST [[
---@class Node
---@field kind string
---@field [integer] Node
---@type Node
local n = { kind = 'x', other = 1, [1] = {} }
n.kind = 'y'
n.other = 2
]]

-- the `[K]` field of a generic class is the argument that was bound; a generic alias of a table is its expansion
TEST [[
---@class KMap<K, V>
---@field [K] V
---@type KMap<string, number>
local m = {}
---@alias KDict<V> table<string, V>
---@type KDict<number>
local d = {}
---@param n number
---@param s string
local function f(n, s)
    m[s] = 1
    m[<!n!>] = 1
    d[s] = 1
    d[<!n!>] = 1
end
]]

-- a class that inherits from a class nobody declared says nothing about its keys (no crash on the missing parent)
TEST [[
---@class OrphanChild: NoSuchParent
---@field [integer] string
---@type OrphanChild
local o = {}
---@param s string
local function f(s)
    o[1] = 'x'
    o[<!true!>] = 'x'
end
]]

-- a generic class with a concrete index field and a generic one: the concrete key stays as written, the generic one is what the argument says
TEST [[
---@class MixedMap<K, V>
---@field [K] V
---@field [boolean] string
---@type MixedMap<integer, number>
local m = {}
---@param s string
---@param i integer
---@param b boolean
local function f(s, i, b)
    m[i] = 1
    m[b] = 'x'
    m[<!s!>] = 1
end
]]
