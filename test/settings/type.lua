-- The `Lua.type.*` settings that change what the type checks accept: each case runs with the setting off
-- and on and states how many type-mismatch findings it must give in each (a positive case and a negative
-- case for both values, so a change to the checker that moves a boundary shows up here).
--
-- Findings counted: assign-type-mismatch, param-type-mismatch, return-type-mismatch, cast-local-type.
local files  = require 'files'
local core   = require 'core.diagnostics'
local config = require 'config'

---@diagnostic disable: await-in-sync

local COUNTED = {
    ['assign-type-mismatch'] = true,
    ['param-type-mismatch']  = true,
    ['return-type-mismatch'] = true,
    ['cast-local-type']      = true,
}

---@param script string
---@return integer
local function mismatches(script)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    files.open(TESTURI)
    local n = 0
    core(TESTURI, false, function (result)
        if COUNTED[result.code] then
            n = n + 1
        end
    end)
    files.remove(TESTURI)
    return n
end

---@class test.settings.case
---@field name   string
---@field script string
---@field off    integer findings with the setting false
---@field on     integer findings with the setting true

---@param key   string setting name after `Lua.`
---@param cases test.settings.case[]
local function run(key, cases)
    local full = 'Lua.' .. key
    local saved = config.get(nil, full)
    for _, case in ipairs(cases) do
        for _, value in ipairs { false, true } do
            config.set(nil, full, value)
            local got = mismatches(case.script)
            local want = value and case.on or case.off
            assert(got == want, ('%s = %s, case `%s`: wanted %d finding(s), got %d'):format(full, tostring(value), case.name, want, got))
        end
    end
    config.set(nil, full, saved)
end

-- `weakUnionCheck`: a union is assignable when ANY member fits (off: every member must fit)
run('type.weakUnionCheck', {
    { name = 'a union into a local', off = 1, on = 0, script = [[
---@type string|number
local u
---@type number
local n
n = u
]] },
    { name = 'a union into an optional @field', off = 1, on = 0, script = [[
---@class WeakUnion.C
---@field v number?
local c = {}
---@type string|number
local u
c.v = u
]] },
    { name = 'a union into a parameter', off = 1, on = 0, script = [[
---@param n number
local function f(n) end
---@type string|number
local u
f(u)
]] },
    { name = 'a union as a return value', off = 1, on = 0, script = [[
---@return number
local function f()
    ---@type string|number
    local u
    return u
end
]] },
    -- an optional is a union with nil: `number?` into `number` is accepted by the weak check too
    { name = 'an optional into a non-optional local', off = 1, on = 0, script = [[
---@type number?
local u
---@type number
local n
n = u
]] },
    { name = 'an optional into a non-optional parameter', off = 1, on = 0, script = [[
---@param n number
local function f(n) end
---@type number?
local u
f(u)
]] },
    -- what stays reported in both modes: nothing fits, or it is not a union at all
    { name = 'a union where no member fits', off = 1, on = 1, script = [[
---@type string|boolean
local u
---@type number
local n
n = u
]] },
    { name = 'a plain mismatch', off = 1, on = 1, script = [[
---@type string
local u
---@type number
local n
n = u
]] },
    -- what is accepted in both modes
    { name = 'every member fits', off = 0, on = 0, script = [[
---@type number
local u
---@type number|string
local n
n = u
]] },
    { name = 'a non-optional into an optional', off = 0, on = 0, script = [[
---@type number
local u
---@type number?
local n
n = u
]] },
})

-- `weakNilCheck`: the `nil` of an optional is ignored (only optionals are affected, not other unions)
run('type.weakNilCheck', {
    { name = 'an optional into a non-optional local', off = 1, on = 0, script = [[
---@type number?
local u
---@type number
local n
n = u
]] },
    { name = 'an optional into a non-optional parameter', off = 1, on = 0, script = [[
---@param n number
local function f(n) end
---@type number?
local u
f(u)
]] },
    { name = 'a union without nil is still checked', off = 1, on = 1, script = [[
---@type string|number
local u
---@type number
local n
n = u
]] },
    { name = 'a plain mismatch', off = 1, on = 1, script = [[
---@type string
local u
---@type number
local n
n = u
]] },
    { name = 'a non-optional into an optional', off = 0, on = 0, script = [[
---@type number
local u
---@type number?
local n
n = u
]] },
})

-- `castNumberToInteger`: a `number` may be assigned to an `integer` (the other way round always works)
run('type.castNumberToInteger', {
    { name = 'number into integer', off = 1, on = 0, script = [[
---@type number
local u
---@type integer
local n
n = u
]] },
    { name = 'integer into number', off = 0, on = 0, script = [[
---@type integer
local u
---@type number
local n
n = u
]] },
    { name = 'a string into an integer', off = 1, on = 1, script = [[
---@type string
local u
---@type integer
local n
n = u
]] },
    { name = 'an optional number into an integer', off = 1, on = 1, script = [[
---@type number?
local u
---@type integer
local n
n = u
]] },
})
