-- A function given where a `fun(...)` type is asked for and does not fit says why: the return, the parameter, or the number of arguments
-- (the message used to be two lines of "`function` cannot match `fun(...)`", reported by a user on a callback that returned `true`).
local files = require 'files'
local core  = require 'core.diagnostics'

---@diagnostic disable: await-in-sync

--- The `param-type-mismatch` messages of a text.
---@param text string
---@return string[]
local function messages(text)
    files.setText(TESTURI, text)
    ---@type string[]
    local found = {}
    core(TESTURI, false, function (result)
        if result.code == 'param-type-mismatch' then
            found[#found+1] = result.message
        end
    end, nil, true, { ['param-type-mismatch'] = true })
    files.remove(TESTURI)
    return found
end

local NL = string.char(10)
local HEAD = {
    '---@class FmrOpt',
    '---@alias FmrCb fun(dd: table, options: FmrOpt[]): FmrOpt[]?',
    '---@param func FmrCb',
    'local function register(func) end',
}

---@param lines string[]
---@return string[]
local function run(lines)
    ---@type string[]
    local all = {}
    for _, line in ipairs(HEAD) do all[#all+1] = line end
    for _, line in ipairs(lines) do all[#all+1] = line end
    all[#all+1] = ''
    return messages(table.concat(all, NL))
end

-- the return does not fit: a named function (shown as plain `function`) and an inline one
local found = run {
    '---@param options FmrOpt[]',
    'local function onToggle(dd, options) if options[1] then return true end end',
    'register(onToggle)',
}
assert(#found == 1, 'one report: ' .. #found)
assert(found[1]:find('The function returns `boolean`, but the type promises `FmrOpt[]?`', 1, true), 'the reason is the return: ' .. found[1])

-- a nullable promise is satisfied by a function that gives nothing, and a function that returns the promised type fits
found = run {
    '---@param options FmrOpt[]',
    'local function ok1(dd, options) return options end',
    'local function ok2(dd, options) end',
    'local function ok3(dd, options) return nil end',
    'register(ok1) register(ok2) register(ok3)',
}
assert(#found == 0, 'no report for functions that fit: ' .. table.concat(found, ' / '))

-- too many parameters: the type provides two
found = run {
    'local function many(a, b, c, d) return nil end',
    'register(many)',
}
assert(#found == 1 and found[1]:find('The function needs 4 argument(s), but the type provides only 2', 1, true), 'the reason is the count: ' .. tostring(found[1]))

-- fewer parameters than provided is fine
found = run {
    'local function few(a) return nil end',
    'register(few)',
}
assert(#found == 0, 'fewer parameters fit')

-- a parameter of another type
found = run {
    '---@param dd number',
    'local function pnum(dd, options) return nil end',
    'register(pnum)',
}
assert(#found == 1 and found[1]:find('Parameter #1 takes `number`, but the type provides `table`', 1, true), 'the reason is the parameter: ' .. tostring(found[1]))

-- a function that gives nothing where a value is promised
found = run {
    '---@alias FmrNeeds fun(): string',
    '---@param f FmrNeeds',
    'local function needs(f) end',
    'local function nothing() end',
    'needs(nothing)',
}
assert(#found == 1 and found[1]:find('The function returns nothing, but the type promises `string`', 1, true), 'the reason is the missing return: ' .. tostring(found[1]))
