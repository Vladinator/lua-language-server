-- A tag with a name and a type (`---@mytag T: Type` / `---@mytag T extends Type`), produced as `{ name = <name node>, extends = <doc.type> }`:
-- what `docTags.registerNameTypeTag` registers (wowlua-ls's `---@requires T: Frame`). The fixture tag is registered in test/docfixture.lua, so the
-- test passes with the whole extra/ folder removed.
local files    = require 'files'
local guide    = require 'parser.guide'
local define   = require 'proto.define'
local semantic = require 'core.semantic-tokens'
require 'docfixture'

---@diagnostic disable: await-in-sync

---@param line string the text after `---@fixture-nametype `
---@return parser.object? doc the parsed tag, or nil when the tag was not produced
local function parse(line)
    files.setText(TESTURI, '---@fixture-nametype ' .. line .. string.char(10) .. 'local function f() end' .. string.char(10))
    local state = assert(files.getState(TESTURI))
    ---@type parser.object?
    local found
    guide.eachSourceType(state.ast, 'doc.fixture-nametype', function (doc)
        found = doc
    end)
    files.remove(TESTURI)
    return found
end

-- the colon form
local doc = parse('T: Frame')
assert(doc and doc.name and doc.name[1] == 'T', 'the name')
assert(doc.name.type == 'doc.fixture-nametype.name', 'the name node type')
assert(doc.extends and doc.extends.type == 'doc.type', 'the type')
assert(doc.kwStart == nil, 'the colon form has no keyword')

-- the `extends` form
doc = parse('T extends Frame')
assert(doc and doc.name and doc.name[1] == 'T' and doc.extends, 'the extends form')
assert(doc.kwStart ~= nil and doc.kwFinish ~= nil, 'the extends form has its keyword range')

-- a type with a union, a generic type
doc = parse('T: Frame|Button')
assert(doc and doc.extends and #doc.extends.types == 2, 'a union')

-- anything else leaves the tag bare, so a plugin can report it
for _, bad in ipairs { '', 'T', 'T:', 'T extends', ': Frame', 'T is Frame' } do
    doc = parse(bad)
    assert(doc and doc.name == nil and doc.extends == nil, ('a bare tag for %q'):format(bad))
end

-- the name is a type parameter token, `extends` a keyword
local typeParameter = define.TokenTypes.typeParameter
local keyword = define.TokenTypes.keyword
files.setText(TESTURI, '---@fixture-nametype T extends Frame' .. string.char(10) .. 'local function f() end' .. string.char(10))
local data = semantic(TESTURI, 0, math.huge) --[[@as integer[] ]]
---@type integer[][]
local found = {}
local line, char = 0, 0
for i = 1, #data, 5 do
    line = line + data[i]
    char = (data[i] == 0) and (char + data[i + 1]) or data[i + 1]
    found[#found+1] = { char, data[i + 2], data[i + 3] }
end
files.remove(TESTURI)
local function has(start, length, tp)
    for _, t in ipairs(found) do
        if t[1] == start and t[2] == length and t[3] == tp then
            return true
        end
    end
    return false
end
-- (`---@fixture-nametype ` is 21 characters: the name at 21, `extends` at 23)
assert(has(21, 1, typeParameter), 'the name is a type parameter token')
assert(has(23, 7, keyword), '`extends` is a keyword token')
