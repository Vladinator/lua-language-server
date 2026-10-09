-- A tag with up to N integers or one name (`---@mytag 1 2` / `---@mytag ClassName`), produced as `{ integers = { <nodes> } }` or `{ name = <node> }`:
-- what `docTags.registerIntegersOrNameTag` registers (wowlua-ls's `---@type-narrows`). The fixture tag (two integers at most) is registered in
-- test/docfixture.lua, so the test passes with the whole extra/ folder removed.
local files    = require 'files'
local guide    = require 'parser.guide'
require 'docfixture'

---@diagnostic disable: await-in-sync

---@param line string the text after `---@fixture-slots`
---@return parser.object? doc the parsed tag, or nil when the tag was not produced
local function parse(line)
    files.setText(TESTURI, '---@fixture-slots' .. line .. string.char(10) .. 'local function f() end' .. string.char(10))
    local state = assert(files.getState(TESTURI))
    ---@type parser.object?
    local found
    guide.eachSourceType(state.ast, 'doc.fixture-slots', function (doc)
        found = doc
    end)
    files.remove(TESTURI)
    return found
end

-- the integers
local doc = parse(' 1 2')
assert(doc and doc.integers and #doc.integers == 2 and doc.name == nil, 'two integers')
assert(doc.integers[1][1] == 1 and doc.integers[2][1] == 2, 'their values')
assert(doc.integers[1].type == 'doc.fixture-slots.integer', 'the integer node type')
doc = parse(' 0')
assert(doc and doc.integers and #doc.integers == 1 and doc.integers[1][1] == 0, 'one integer, zero')

-- no more integers than the tag takes: the third is description
doc = parse(' 1 2 3')
assert(doc and doc.integers and #doc.integers == 2, 'at most two integers')

-- the name
doc = parse(' Frame')
assert(doc and doc.name and doc.name[1] == 'Frame' and doc.integers == nil, 'a name')
assert(doc.name.type == 'doc.fixture-slots.name', 'the name node type')
-- (only one: the rest is description)
doc = parse(' Frame Button')
assert(doc and doc.name and doc.name[1] == 'Frame', 'the first name only')

-- anything else leaves the tag bare, so a plugin can report it
for _, bad in ipairs { '', ' :', ' "text"' } do
    doc = parse(bad)
    assert(doc and doc.name == nil and doc.integers == nil, ('a bare tag for %q'):format(bad))
end
