-- non-portable-annotation: a `---@tag` that none of the dialects of `Lua.annotations.dialects` knows.
-- Each dialect list with the tags it accepts and the ones it flags; the default (`mixed`) flags nothing.
local config = require 'config'

---@diagnostic disable: await-in-sync

---@param dialects string[]
---@param fn       fun()
local function with(dialects, fn)
    local saved = config.get(nil, 'Lua.annotations.dialects')
    config.set(nil, 'Lua.annotations.dialects', dialects)
    fn()
    config.set(nil, 'Lua.annotations.dialects', saved)
end

-- default: nothing is reported, whatever the tags
TEST [[
---@secret-when x
---@frobnicate
---@secret
---@async
local x
]]
with({ 'mixed' }, function ()
    TEST [[
---@secret-when x
---@frobnicate
local x
]]
end)
-- `mixed` next to others still means every dialect
with({ 'legacyluals', 'mixed' }, function ()
    TEST [[
---@secret-when x
local x
]]
end)
with({}, function ()
    TEST [[
---@secret-when x
local x
]]
end)

-- legacyluals: the original's tags only
with({ 'legacyluals' }, function ()
    TEST [[
---@class A
---@field x number
---@param a number
---@return number
---@async
---@version >5.1
---@diagnostic disable-next-line: unused-local
---@deprecated
local function f(a) return a end

--- @param b number
local function g(b) end

---@<!secret!>
---@<!secret-guard!> a is-secret
---@<!correlated!> a
---@<!guard!> v is string
---@<!secret-when!> a
---@<!frobnicate!>
local x
]]
end)

-- wowluals: its own and the shared tags; the original's `async` and this fork's `secret` are not known to it
with({ 'wowluals' }, function ()
    TEST [[
---@class A
---@param a number
---@secret-guard a is-secret
---@secret-when a
---@correlated a
---@defclass
---@<!async!>
---@<!secret!>
---@<!guard!> v is string
---@<!version!> 5.1
local function f(a) end
]]
end)

-- a list is a union: `luals` + `wowluals` flags only what neither knows
with({ 'luals', 'wowluals' }, function ()
    TEST [[
---@secret
---@guard v is string
---@async
---@secret-when a
---@<!frobnicate!>
local x
]]
end)
with({ 'legacyluals', 'wowluals' }, function ()
    TEST [[
---@async
---@secret-when a
---@<!secret!>
---@<!guard!> v is string
local x
]]
end)

-- only a tag at the start of a comment: prose, a long comment, a string and a plain comment are not tags
with({ 'legacyluals' }, function ()
    TEST [[
-- see @secret-when for the details
--[=[ ---@secret ]=]
local s = "---@secret"
---@param a number a description that mentions @secret
local function f(a) end
]]
end)

-- keywords of the annotations: in front of a type and in front of a field's type
with({ 'legacyluals' }, function ()
    TEST [[
---@param a <!secret!> string
---@param b <!nosecret!> string
---@param c <!readonly!> table
---@field x <!readonly!> number
---@return string
local function f(a, b, c) end
]]
end)
with({ 'wowluals' }, function ()
    TEST [[
---@param a secret string
---@param b <!nosecret!> string
---@param c <!readonly!> table
---@param d secret<string>
local function f(a, b, c, d) end
]]
end)
with({ 'luals' }, function ()
    TEST [[
---@param a secret string
---@param b nosecret string
---@param c readonly table
---@field x readonly number
local function f(a, b, c) end
]]
end)
-- the default flags no keyword either
TEST [[
---@param a nosecret string
---@param c readonly table
local function f(a, c) end
]]
-- a class that is called like a keyword is a plain type name, not a keyword use
with({ 'legacyluals' }, function ()
    TEST [[
---@class readonly
---@param a readonly
local function f(a) end
]]
end)

-- type syntax: what each dialect knows (legacyluals has none of it)
with({ 'legacyluals' }, function ()
    TEST [[
---@generic T
---@param a <!keyof T!>
local function f(a) end
]]
    TEST [[
---@param a <!A & B!>
local function f(a) end
]]
    TEST [[
---@param a <!T[K]!>
local function f(a) end
]]
    TEST [[
---@param a (<!string extends number ? 1 : 2)!>
local function f(a) end
]]
    TEST [[
---@param a ?<!string!>
local function f(a) end
]]
    -- the optional marker itself is portable, also with spaces around it
    TEST [[
---@param a? string
---@param b ? string
---@param c?  string
local function f(a, b, c) end
]]
    TEST [[
---@type ?<!string!>
local a
]]
    TEST [[
---@param a <!string!!>
local function f(a) end
]]
    TEST [[
---@param a <!never!>
local function f(a) end
]]
    TEST [[
---@param a <!Partial<table>!>
local function f(a) end
]]
    TEST [[
---@param a <!returns<f>!>
local function f(a) end
]]
    TEST [[
---@param a <!params<f>!>
local function f(a) end
]]
    -- the plain forms are fine
    TEST [[
---@param a string?
---@param b table<string, number>
---@param c string[]
local function f(a, b, c) end
]]
end)
-- luals knows all of it but the wowlua-ls only generics
with({ 'luals' }, function ()
    TEST [[
---@generic T
---@param a keyof T
---@param b A & B
---@param c T[K]
---@param d (string extends number ? 1 : 2)
---@param e string
---@param f string!
---@param g never
---@param h Partial<table>
---@param i returns<f>
---@param j <!params<f>!>
local function f(a, b, c, d, e, f, g, h, i, j) end
]]
end)
-- wowluals: no conditional types, no never, no utility types
with({ 'wowluals' }, function ()
    TEST [[
---@generic T
---@param a keyof T
---@param b A & B
---@param c T[K]
---@param d (<!string extends number ? 1 : 2)!>
---@param e string
---@param f string!
---@param g <!never!>
---@param h <!Partial<table>!>
---@param i returns<f>
---@param j params<f>
local function f(a, b, c, d, e, f, g, h, i, j) end
]]
end)
-- the default flags no syntax either
TEST [[
---@param a keyof T
---@param b ?string
---@param c never
local function f(a, b, c) end
]]
