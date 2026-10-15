local core  = require 'core.completion'
local files = require 'files'
local catch = require 'catch'

---@diagnostic disable: await-in-sync

--- The completion items of a script with `<??>` at the cursor, by label.
---@param script string
---@return table<string, vm.completion.result>
local function itemsOf(script)
    local newScript, catched = catch(script, '?')
    files.setText(TESTURI, newScript)
    local result = core.completion(TESTURI, catched['?'][1][1], nil)
    assert(result, 'no completion')
    ---@type table<string, vm.completion.result>
    local byLabel = {}
    for _, item in ipairs(result) do
        byLabel[item.label] = item
    end
    files.remove(TESTURI)
    return byLabel
end

-- the built-in type operators carry their signature and what they do
local items = itemsOf [[
---@param x Part<??>
]]
assert(items['Partial'], 'Partial is offered')
assert(items['Partial'].detail == 'Partial<T>', 'its signature: ' .. tostring(items['Partial'].detail))
assert(tostring(items['Partial'].description):find('optional', 1, true), 'what it does')

items = itemsOf [[
---@type Rec<??>
]]
assert(items['Record'] and items['Record'].detail == 'Record<K, V>', 'Record: ' .. tostring(items['Record'] and items['Record'].detail))

items = itemsOf [[
---@type key<??>
]]
assert(items['keyof'] and items['keyof'].detail == 'keyof T', 'keyof')

-- a project type of the same name is not described as the operator
items = itemsOf [[
---@class Partial
local P = {}

---@type Part<??>
]]
assert(items['Partial'], 'the project class is offered')
assert(items['Partial'].detail ~= 'Partial<T>', 'not the operator signature')
