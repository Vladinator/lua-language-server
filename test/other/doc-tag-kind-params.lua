-- A tag with a kind word and an optional list of parameter names (`---@mytag <kind> [a b ...]`), produced as
-- `{ kind = <word>, names = { <name nodes> } }`: what a plugin registers with `docTags.registerKindParamsTag` (wowlua-ls's
-- `---@secret-args none a b`). The fixture tag is registered in test/docfixture.lua, so the test passes with the whole extra/ folder removed.
local files   = require 'files'
local guide   = require 'parser.guide'
require 'docfixture'

---@param line string the text after `---@fixture-kind-params `
---@return parser.object? doc the parsed tag, or nil when the tag was not produced
local function parse(line)
    files.setText(TESTURI, '---@fixture-kind-params ' .. line .. string.char(10) .. 'local function f(a, b, ...) end' .. string.char(10))
    local state = assert(files.getState(TESTURI))
    ---@type parser.object?
    local found
    guide.eachSourceType(state.ast, 'doc.fixture-kind-params', function (doc)
        found = doc
    end)
    files.remove(TESTURI)
    return found
end

---@param doc parser.object?
---@return string[]
local function namesOf(doc)
    ---@type string[]
    local out = {}
    for _, name in ipairs(doc and doc.names or {}) do
        out[#out+1] = name[1] --[[@as string]]
    end
    return out
end

--- a kind with no names: the policy applies to everything
local doc = parse('alpha')
assert(doc and doc.kind == 'alpha', 'kind alone')
assert(#namesOf(doc) == 0 and doc.names == nil, 'no names given: names stay unset')

--- a kind and names, separated by spaces
doc = parse('beta a b')
assert(doc and doc.kind == 'beta')
assert(table.concat(namesOf(doc), ',') == 'a,b', 'names a b')

--- `...` is a name
doc = parse('alpha ...')
assert(doc and doc.kind == 'alpha')
assert(table.concat(namesOf(doc), ',') == '...', 'vararg')
doc = parse('alpha a ...')
assert(table.concat(namesOf(doc), ',') == 'a,...', 'name and vararg')

--- the kind may contain hyphens
doc = parse('kind-with-hyphen a')
assert(doc and doc.kind == 'kind-with-hyphen', 'hyphenated kind')

--- anything else leaves the tag bare, so a plugin can report it: a kind that is not in the list, no kind, a comma list
doc = parse('gamma a')
assert(doc and doc.kind == nil and doc.names == nil, 'unknown kind is bare')
doc = parse('')
assert(doc and doc.kind == nil, 'no kind is bare')
doc = parse('alpha a, b')
assert(doc and doc.kind == nil and doc.names == nil, 'comma separated names are bare')
doc = parse('"alpha"')
assert(doc and doc.kind == nil, 'a string is not a kind')
doc = parse('alpha "text"')
assert(doc and doc.kind == nil, 'a string is not a name')

--- the name nodes are children of the tag (hover, references, undefined names reach them) and know their parent
doc = parse('alpha a b')
local count = 0
guide.eachChild(doc --[[@as parser.object]], function () count = count + 1 end)
assert(count == 2, 'names are walked as children, got ' .. count)
local firstName = doc and doc.names and doc.names[1]
assert(firstName and firstName.parent == doc, 'the name knows its tag')
