-- The `Lua.type.*` settings that change what the type checks accept: each case runs with the setting off
-- and on and states how many type-mismatch findings it must give in each (a positive case and a negative
-- case for both values, so a change to the checker that moves a boundary shows up here).
--
-- Findings counted: assign-type-mismatch, param-type-mismatch, return-type-mismatch, cast-local-type, generic-param-mismatch, generic-constraint-mismatch.
local files  = require 'files'
local core   = require 'core.diagnostics'
local config = require 'config'

---@diagnostic disable: await-in-sync

local COUNTED = {
    ['assign-type-mismatch'] = true,
    ['param-type-mismatch']  = true,
    ['return-type-mismatch'] = true,
    ['cast-local-type']      = true,
    ['generic-param-mismatch'] = true,
    ['generic-constraint-mismatch'] = true,
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

-- `generic-param-mismatch` (two arguments of one type parameter) judges a later argument in BOTH directions (assignable to what
-- `T` was bound to, or wider), so the weak checks must not change what it reports: the same count with each setting off and on.
local GENERIC_ROWS = {
    { name = 'a later argument of another type', off = 1, on = 1, script = [[
---@generic T
---@param a T
---@param b T
---@return T
local function f(a, b) return a end
f(1, 'x')
]] },
    { name = 'a later union argument that contains the first type', off = 0, on = 0, script = [[
---@generic T
---@param a T
---@param b T
---@return T
local function f(a, b) return a end
---@type string|number
local u
f(1, u)
]] },
    { name = 'a later optional argument', off = 0, on = 0, script = [[
---@generic T
---@param a T
---@param b T
---@return T
local function f(a, b) return a end
---@type number?
local o
f(1, o)
]] },
    { name = 'a first union argument, a later member of it', off = 0, on = 0, script = [[
---@generic T
---@param a T
---@param b T
---@return T
local function f(a, b) return a end
---@type string|number
local u
f(u, 1)
]] },
    { name = 'a union of two unrelated types as the later argument', off = 1, on = 1, script = [[
---@generic T
---@param a T
---@param b T
---@return T
local function f(a, b) return a end
---@type string|boolean
local u
f(1, u)
]] },
}
run('type.weakUnionCheck', GENERIC_ROWS)

-- a generic constraint (`---@generic T: table`) is checked by `param-type-mismatch` (as `<T:table>`) and only by it:
-- `generic-constraint-mismatch` leaves a constraint that names no other type parameter alone, so a violation counts 1. A union is
-- accepted by the weak check when one member fits (`string[]` is a table); a type that fits no way, or only a wrong member, is not.
run('type.weakUnionCheck', {
    { name = 'a union with one member that fits the constraint', off = 1, on = 0, script = [[
---@generic T: table
---@param x T
---@return T
local function f(x) return x end
---@type "all"|string[]
local u
f(u)
]] },
    { name = 'a type that does not fit the constraint', off = 1, on = 1, script = [[
---@generic T: table
---@param x T
---@return T
local function f(x) return x end
f(5)
]] },
    { name = 'a union with no member that fits the constraint', off = 1, on = 1, script = [[
---@generic T: table
---@param x T
---@return T
local function f(x) return x end
---@type "all"|number
local u
f(u)
]] },
    { name = 'a key that is no field of the other argument (keyof)', off = 1, on = 1, script = [[
---@generic T, K: keyof T
---@param obj T
---@param key K
---@return T[K]
local function get(obj, key) return obj[key] end
---@class KeyOf.A
---@field x number
---@type KeyOf.A
local a
get(a, 'z')
]] },
    { name = 'a key that is a field of the other argument (keyof)', off = 0, on = 0, script = [[
---@generic T, K: keyof T
---@param obj T
---@param key K
---@return T[K]
local function get(obj, key) return obj[key] end
---@class KeyOf.B
---@field x number
---@type KeyOf.B
local a
get(a, 'x')
]] },
    { name = 'a union where every member fits', off = 0, on = 0, script = [[
---@generic T: table
---@param x T
---@return T
local function f(x) return x end
---@type string[]|{ a: number }
local u
f(u)
]] },
})
run('type.weakNilCheck', GENERIC_ROWS)

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

-- `checkTableShape`: a table held in a variable (or returned) is checked against the class it is given to,
-- field by field; off, any table is accepted. A table literal written at the call is checked field by field
-- either way, so it is not what this setting decides.
run('type.checkTableShape', {
    { name = 'a table variable with a wrong field type', off = 0, on = 1, script = [[
---@class TableShape.A
---@field a number
---@param s TableShape.A
local function f(s) end
local t = { a = 'x' }
f(t)
]] },
    { name = 'a table variable missing a required field', off = 0, on = 1, script = [[
---@class TableShape.B
---@field a number
---@param s TableShape.B
local function f(s) end
local t = {}
f(t)
]] },
    { name = 'a returned table literal with a wrong field type', off = 0, on = 1, script = [[
---@class TableShape.C
---@field a number
---@return TableShape.C
local function f() return { a = 'x' } end
]] },
    { name = 'a table variable that fits', off = 0, on = 0, script = [[
---@class TableShape.D
---@field a number
---@param s TableShape.D
local function f(s) end
local t = { a = 1 }
f(t)
]] },
    { name = 'a missing OPTIONAL field is fine', off = 0, on = 0, script = [[
---@class TableShape.E
---@field a number
---@field b? string
---@param s TableShape.E
local function f(s) end
local t = { a = 1 }
f(t)
]] },
    { name = 'a literal at the call with a wrong field type', off = 1, on = 1, script = [[
---@class TableShape.F
---@field a number
---@param s TableShape.F
local function f(s) end
f({ a = 'x' })
]] },
})

---@param key    string setting name after `Lua.`
---@param values any[]  the values to try
---@param cases  { name: string, script: string, want: table<any, integer> }[] findings per value
local function runValues(key, values, cases)
    local full = 'Lua.' .. key
    local saved = config.get(nil, full)
    for _, case in ipairs(cases) do
        for _, value in ipairs(values) do
            config.set(nil, full, value)
            local got = mismatches(case.script)
            local want = case.want[value]
            -- (a value without an expectation is a boundary that is not pinned down on purpose)
            if want ~= nil then
                assert(got == want, ('%s = %s, case `%s`: wanted %d finding(s), got %d'):format(full, tostring(value), case.name, want, got))
            end
        end
    end
    config.set(nil, full, saved)
end

-- `maxUnionVariants`: a union with more variants than this is not checked (0: no limit)
runValues('type.maxUnionVariants', { 0, 2, 100 }, {
    { name = 'a union of 8 into a union of 2', want = { [0] = 1, [2] = 0, [100] = 1 }, script = [[
---@type 1|2|3|4|5|6|7|8
local u
---@type 1|2
local n
n = u
]] },
    { name = 'a union of 2 into a union of 2 that fits', want = { [0] = 0, [2] = 0, [100] = 0 }, script = [[
---@type 1|2
local u
---@type 1|2|3
local n
n = u
]] },
    { name = 'a small union that does not fit, well within the limit', want = { [0] = 1, [100] = 1 }, script = [[
---@type 1|2
local u
---@type 3|4
local n
n = u
]] },
})

-- the inferred type of a local of `script`, by name
local guide = require 'parser.guide'
local vm    = require 'vm'
---@param script string
---@param name   string
---@return string?
local function viewOf(script, name)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    local state = assert(files.getState(TESTURI))
    ---@type string?
    local view
    guide.eachSource(state.ast, function (src)
        if src.type == 'local' and src[1] == name and not view then
            view = vm.getInfer(src):view(TESTURI)
        end
    end)
    files.remove(TESTURI)
    return view
end

---@param key    string
---@param values any[]
---@param script string
---@param name   string
---@param want   table<any, string>
local function runViews(key, values, script, name, want)
    local full = 'Lua.' .. key
    local saved = config.get(nil, full)
    for _, value in ipairs(values) do
        config.set(nil, full, value)
        local got = viewOf(script, name)
        assert(got == want[value], ('%s = %s: `%s` is `%s`, wanted `%s`'):format(full, tostring(value), name, tostring(got), want[value]))
    end
    config.set(nil, full, saved)
end

-- `inferTableSize`: how many leading elements of a table constructor take part when it is read with a variable
-- index (0: none, so the element is unknown)
runViews('type.inferTableSize', { 0, 2, 100 }, [[
local t = {1, 2, 'a', 'b'}
---@type integer
local i
local x = t[i]
]], 'x', { [0] = 'unknown', [2] = 'integer', [100] = 'string|integer' })

-- `inferParamType`: off, a parameter without a `@param` is `any` and what the function returns of it is unknown;
-- on, it is what the callers pass
runViews('type.inferParamType', { false, true }, [[
local function f(a) return a end
local r = f(1)
]], 'r', { [false] = 'unknown', [true] = 'integer' })
runViews('type.inferParamType', { false, true }, [[
local function g(p)
    local q = p
end
g('s')
]], 'q', { [false] = 'any', [true] = 'string' })
-- ... a documented parameter is never inferred from callers
runViews('type.inferParamType', { false, true }, [[
---@param p number
local function g(p)
    local q = p
end
g('s')
]], 'q', { [false] = 'number', [true] = 'number' })
