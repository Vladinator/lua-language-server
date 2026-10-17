-- excess-field hands the quick fix what it needs as the `data` of its diagnostic: the class, the key and a short type of the value
-- (test/code_action/quickfix.lua tests the fix itself).
local files = require 'files'
local core  = require 'core.diagnostics'

---@diagnostic disable: await-in-sync

---@param text string
---@return table[]
local function excess(text)
    files.setText(TESTURI, text)
    ---@type table[]
    local found = {}
    core(TESTURI, false, function (result)
        if result.code == 'excess-field' then
            found[#found+1] = result
        end
    end, nil, true, { ['excess-field'] = true })
    files.remove(TESTURI)
    return found
end

local NL = string.char(10)
local found = excess(table.concat({
    '---@class ExcessData',
    '---@field a number',
    '---@type ExcessData',
    'local v = { a = 1, n = 2, s = "x", t = { 1 }, f = function() end, z = nil, u = SOMETHING_UNKNOWN }',
    '',
}, NL))
---@type table<string, string>
local types = {}
for _, result in ipairs(found) do
    assert(type(result.data) == 'table' and result.data.class == 'ExcessData', 'the class travels with the diagnostic')
    types[result.data.key] = result.data.type
end
assert(types.n == 'integer', 'a number: ' .. tostring(types.n))
assert(types.s == 'string', 'a string: ' .. tostring(types.s))
assert(types.t == 'table', 'a table: ' .. tostring(types.t))
assert(types.f == 'function', 'a function: ' .. tostring(types.f))
assert(types.z == 'any', 'nil: ' .. tostring(types.z))
assert(types.u == 'any', 'unknown: ' .. tostring(types.u))
assert(types.a == nil, 'a declared field is not reported')

-- two classes at once (`A|B`): no single place for the field, no data
found = excess(table.concat({
    '---@class ExcessOne',
    '---@field a number',
    '---@class ExcessTwo',
    '---@field b number',
    '---@type ExcessOne|ExcessTwo',
    'local v = { c = 1 }',
    '',
}, NL))
assert(#found == 1 and found[1].data == nil, 'a union has no data')
