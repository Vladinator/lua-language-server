local core  = require 'core.completion'
local files = require 'files'
local catch = require 'catch'

---@diagnostic disable: await-in-sync

-- Ctrl+Space right after the `(` (or after a `,`) of a call, with no word typed yet: the values that fit the parameter come first, like with
-- a word typed (`boostExpectedType`). The editor sends no trigger character for a manual invocation, which the shared harness of this group
-- cannot express (it takes the next character of the text for one), so this asks `core.completion` itself.

--- The labels offered at the `<??>` with no trigger character, in order.
---@param script string
---@return string[]
local function labelsOf(script)
    local newScript, catched = catch(script, '?')
    files.setText(TESTURI, newScript)
    local result = core.completion(TESTURI, catched['?'][1][1], nil)
    files.remove(TESTURI)
    ---@type string[]
    local labels = {}
    for _, item in ipairs(result or {}) do
        labels[#labels+1] = item.label
    end
    return labels
end

---@param labels string[]
---@param label  string
---@return number
local function indexOf(labels, label)
    for i, name in ipairs(labels) do
        if name == label then
            return i
        end
    end
    return math.huge
end

do
    local labels = labelsOf [[
---@param s string
local function takes(s) end
local vara = 1
local varb = "x"
takes(<??>)
]]
    assert(indexOf(labels, 'varb') < indexOf(labels, 'vara'), 'right after the bracket: the string variable first')
    assert(indexOf(labels, 'vara') ~= math.huge, 'the number variable is still offered')
end

do
    local labels = labelsOf [[
---@param n number
---@param s string
local function takes(n, s) end
local vara = 1
local varb = "x"
takes(1, <??>)
]]
    assert(indexOf(labels, 'varb') < indexOf(labels, 'vara'), 'after the comma: the string variable first (the second parameter counts)')
end

-- negative: a parameter that takes anything keeps the order of the declarations
do
    local labels = labelsOf [[
---@param s any
local function takes(s) end
local vara = 1
local varb = "x"
takes(<??>)
]]
    assert(indexOf(labels, 'vara') < indexOf(labels, 'varb'), 'any: the order is unchanged')
end

-- negative: outside a call nothing is ranked by a parameter
do
    local labels = labelsOf [[
---@param s string
local function takes(s) end
local vara = 1
local varb = "x"
local other = <??>
]]
    assert(indexOf(labels, 'vara') < indexOf(labels, 'varb'), 'not in a call: the order is unchanged')
end
