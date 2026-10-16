-- A tag that says something about a parameter and a type (`---@mytag x is T` / `---@mytag x is not T`): what `docTags.registerGuardTag`
-- registers. The words `is` and `not` have their own ranges and are drawn as keywords; the fixture tag is registered in
-- test/docfixture.lua, so the test passes with the whole extra/ folder removed.
local files    = require 'files'
local guide    = require 'parser.guide'
local define   = require 'proto.define'
local semantic = require 'core.semantic-tokens'
require 'docfixture'

---@diagnostic disable: await-in-sync

---@param line string the text after `---@fixture-isguard `
---@return parser.object? doc the parsed tag
local function parse(line)
    files.setText(TESTURI, '---@fixture-isguard ' .. line .. string.char(10) .. 'local function f(x) end' .. string.char(10))
    local state = assert(files.getState(TESTURI))
    ---@type parser.object?
    local found
    guide.eachSourceType(state.ast, 'doc.fixture-isguard', function (doc)
        found = doc
    end)
    files.remove(TESTURI)
    return found
end

-- `is`
local doc = parse('x is string')
assert(doc and doc.param and doc.param[1] == 'x' and doc.extends, 'the parts')
assert(not doc.negated, 'not negated')
assert(doc.kwStart ~= nil and doc.kwFinish ~= nil, '`is` has its range')
assert(doc.notStart == nil and doc.notFinish == nil, 'no `not` range')

-- `is not`
doc = parse('x is not string')
assert(doc and doc.negated == true, 'negated')
local isFinish, notStart = doc.kwFinish, doc.notStart
assert(doc.kwStart ~= nil and isFinish and notStart and notStart >= isFinish, '`is` and `not` have ranges, `not` after `is`')

-- anything else leaves the tag bare: no ranges either
for _, bad in ipairs { '', 'x', 'x is', 'x is not', 'x was string' } do
    doc = parse(bad)
    assert(doc and doc.param == nil and doc.kwStart == nil and doc.notStart == nil, ('a bare tag for %q'):format(bad))
end

-- the words are keyword tokens
local keyword = define.TokenTypes.keyword
---@param text string
---@return integer[][]
local function tokensOf(text)
    files.setText(TESTURI, text)
    local data = semantic(TESTURI, 0, math.huge) --[[@as integer[] ]]
    ---@type integer[][]
    local found = {}
    local char = 0
    for i = 1, #data, 5 do
        char = (data[i] == 0) and (char + data[i + 1]) or data[i + 1]
        found[#found+1] = { char, data[i + 2], data[i + 3] }
    end
    files.remove(TESTURI)
    return found
end
---@param found integer[][]
---@param start integer
---@param length integer
---@param tp integer
---@return boolean
local function has(found, start, length, tp)
    for _, t in ipairs(found) do
        if t[1] == start and t[2] == length and t[3] == tp then
            return true
        end
    end
    return false
end
-- (`---@fixture-isguard ` is 20 characters: `x` at 20, `is` at 22, `not` at 25)
local found = tokensOf('---@fixture-isguard x is not string' .. string.char(10) .. 'local function f(x) end' .. string.char(10))
assert(has(found, 22, 2, keyword), '`is` is a keyword token')
assert(has(found, 25, 3, keyword), '`not` is a keyword token')
found = tokensOf('---@fixture-isguard x is string' .. string.char(10) .. 'local function f(x) end' .. string.char(10))
assert(has(found, 22, 2, keyword), '`is` is a keyword token without `not`')
assert(not has(found, 25, 3, keyword), 'no `not` token')
-- a bare tag draws no keyword over its words
found = tokensOf('---@fixture-isguard x was string' .. string.char(10) .. 'local function f(x) end' .. string.char(10))
assert(not has(found, 22, 3, keyword), 'a bare tag has no keyword token')
