local core    = require 'core.completion'
local files   = require 'files'
local catch   = require 'catch'
local docTags = require 'parser.docTags'

---@diagnostic disable: await-in-sync

-- Every position where a type is written offers the same names: the type keywords, the built-in type operators, and the classes, aliases and
-- enums of the project, with a word typed and without one (right after `---@type `, `---@param x `, ...). They come from one function
-- (`addTypeNames` in core/completion/completion.lua); this is the matrix that keeps it so. The client keeps filtering the first list it got while
-- the word is typed, so a name missing from the list of the empty word would never show up.

local PRELUDE = [[
---@class TnClass
---@alias TnAlias string
---@enum TnEnum
local TnEnum = { A = 1 }

]]

--- The labels offered at the `<??>` of a script.
---@param script string
---@return table<string, vm.completion.result>
local function itemsOf(script)
    local newScript, catched = catch(PRELUDE .. script, '?')
    files.setText(TESTURI, newScript)
    local result = core.completion(TESTURI, catched['?'][1][1], nil)
    files.remove(TESTURI)
    ---@type table<string, vm.completion.result>
    local byLabel = {}
    for _, item in ipairs(result or {}) do
        byLabel[item.label] = item
    end
    return byLabel
end

--- The type keywords the registry knows (a plugin may register more: they are asked, not named).
---@type string[]
local keywords = {}
for name in docTags.eachTypeKeyword() do
    keywords[#keywords+1] = name
end

--- Each position a type is written at; `%s` is where the word goes.
local positions = {
    { name = 'type',             text = '---@type %s' },
    { name = 'param',            text = '---@param x %s' },
    { name = 'return',           text = '---@return %s', self = true },
    { name = 'field',            text = '---@class TnHost\n---@field name %s' },
    { name = 'alias',            text = '---@alias TnNew %s' },
    { name = 'cast',             text = 'local v\n---@cast v %s' },
    { name = 'union',            text = '---@type string | %s' },
    { name = 'array',            text = '---@type %s[]' },
    { name = 'optional prefix',  text = '---@type ?%s' },
    { name = 'generic argument', text = '---@type table<string, %s>' },
    { name = 'function param',   text = '---@type fun(a: %s)' },
    { name = 'function return',  text = '---@type fun(): %s' },
    { name = 'overload',         text = '---@class TnOver\n---@overload fun(a: %s)' },
}

---@type string[]
local failures = {}
---@param position table
---@param what string
---@param ok boolean
local function check(position, what, ok)
    if not ok then
        failures[#failures+1] = ('%s: %s'):format(position.name, what)
    end
end

for _, position in ipairs(positions) do
    -- no word typed yet
    local items = itemsOf(position.text:format('<??>'))
    check(position, 'class (empty word)', items['TnClass'] ~= nil)
    check(position, 'alias (empty word)', items['TnAlias'] ~= nil)
    check(position, 'enum (empty word)', items['TnEnum'] ~= nil)
    check(position, 'Partial (empty word)', items['Partial'] ~= nil)
    check(position, 'keyof (empty word)', items['keyof'] ~= nil)
    for _, keyword in ipairs(keywords) do
        check(position, 'keyword ' .. keyword .. ' (empty word)', items[keyword] ~= nil)
    end
    check(position, 'self (empty word)', (items['self'] ~= nil) == (position.self == true))

    -- a word typed
    items = itemsOf(position.text:format('Tn<??>'))
    check(position, 'class (word)', items['TnClass'] ~= nil)
    check(position, 'alias (word)', items['TnAlias'] ~= nil)
    check(position, 'enum (word)', items['TnEnum'] ~= nil)
    check(position, 'no operator that does not match (word)', items['Partial'] == nil)

    items = itemsOf(position.text:format('Par<??>'))
    check(position, 'Partial (word)', items['Partial'] ~= nil)
    check(position, 'no class that does not match (word)', items['TnClass'] == nil)

    items = itemsOf(position.text:format('Zzz<??>'))
    check(position, 'nothing for a word that matches nothing', next(items) == nil)
end

assert(#failures == 0, 'type names missing or wrong:\n  ' .. table.concat(failures, '\n  '))

-- the kinds: a class is a class, an enum an enum, a keyword a keyword
do
    local items = itemsOf('---@type <??>')
    local define = require 'proto.define'
    assert(items['TnClass'].kind == define.CompletionItemKind.Class, 'class kind')
    assert(items['TnEnum'].kind == define.CompletionItemKind.Enum, 'enum kind')
    if keywords[1] then
        assert(items[keywords[1]].kind == define.CompletionItemKind.Keyword, 'keyword kind')
    end
end

-- the parent of a class: classes only, not the class itself, no keywords / operators / aliases / enums, with a word and without
for _, word in ipairs { '', 'Tn' } do
    local items = itemsOf('---@class TnChild : ' .. word .. '<??>')
    assert(items['TnClass'], 'a class is a parent (' .. word .. ')')
    assert(not items['TnChild'], 'the class itself is not (' .. word .. ')')
    assert(not items['TnAlias'] and not items['TnEnum'], 'no alias or enum (' .. word .. ')')
    assert(not items['Partial'] and not items['keyof'], 'no type operator (' .. word .. ')')
    for _, keyword in ipairs(keywords) do
        assert(not items[keyword], 'no keyword ' .. keyword .. ' (' .. word .. ')')
    end
end
