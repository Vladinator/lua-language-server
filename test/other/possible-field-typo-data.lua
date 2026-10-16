-- possible-field-typo hands the name it suggests to the client as the `data` of its diagnostic, which is what the quick fix writes over the typo
-- (test/code_action/quickfix.lua tests the fix; this one tests that the diagnostic carries what the fix needs).
local files = require 'files'
local core  = require 'core.diagnostics'

---@diagnostic disable: await-in-sync

---@param text string
---@return table[]
local function typos(text)
    files.setText(TESTURI, text)
    ---@type table[]
    local found = {}
    core(TESTURI, false, function (result)
        if result.code == 'possible-field-typo' then
            found[#found+1] = result
        end
    end, nil, true, { ['possible-field-typo'] = true })
    files.remove(TESTURI)
    return found
end

local NL = string.char(10)
local found = typos(table.concat({
    '---@class TypoData',
    '---@field total integer',
    'local TypoData = {}',
    'function TypoData:add()',
    '    self.totl = 1',
    '    self.history = {}',
    'end',
    '',
}, NL))
assert(#found == 1, 'one typo: ' .. #found)
assert(found[1].data == 'total', 'the suggestion travels with the diagnostic: ' .. tostring(found[1].data))
assert(found[1].message:find('total', 1, true), 'and is in the message')
