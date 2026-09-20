-- The tags the plugins register are coloured like every other doc tag: the keyword with the
-- `documentation` modifier over the whole `@tag` word, no handler needed. (The tags of the test
-- fixture: nothing here depends on a plugin, see test/docfixture.lua.)
local files    = require 'files'
local define   = require 'proto.define'
local semantic = require 'core.semantic-tokens'
require 'docfixture'

---@diagnostic disable: await-in-sync

--- The tokens of a text as { line, char, length, type, modifiers }.
---@param text string
---@return integer[][]
local function tokensOf(text)
    files.setText(TESTURI, text)
    local data = semantic(TESTURI, 0, math.huge) --[[@as integer[] ]]
    ---@type integer[][]
    local tokens = {}
    local line, char = 0, 0
    for i = 1, #data, 5 do
        line = line + data[i]
        char = (data[i] == 0) and (char + data[i + 1]) or data[i + 1]
        tokens[#tokens+1] = { line, char, data[i + 2], data[i + 3], data[i + 4] }
    end
    files.remove(TESTURI)
    return tokens
end

--- Whether there is a token with the type, and the modifier, over the range.
---@param tokens integer[][]
---@param line   integer
---@param char   integer
---@param length integer
---@param tp     integer
---@param mods   integer
---@return boolean
local function has(tokens, line, char, length, tp, mods)
    for _, t in ipairs(tokens) do
        if t[1] == line and t[2] == char and t[3] == length and t[4] == tp and t[5] == mods then
            return true
        end
    end
    return false
end

local keyword = define.TokenTypes.keyword
local doc     = define.TokenModifiers.documentation

-- a marker tag, one with a list of names, and a built-in tag: the same
local tokens = tokensOf('---@fixture-marker\nlocal a\n---@fixture-names a\nlocal b\n---@deprecated\nlocal c\n')
assert(has(tokens, 0, 3, 15, keyword, doc), '`@fixture-marker`')
assert(has(tokens, 2, 3, 14, keyword, doc), '`@fixture-names` with names')
assert(has(tokens, 4, 3, 11, keyword, doc), '`@deprecated`')
