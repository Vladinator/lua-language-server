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
