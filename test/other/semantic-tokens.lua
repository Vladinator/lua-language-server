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

-- the parts of a tag the registry lets a plugin add are tokens too, not comment text: the names of a list are variables, the
-- parameter names of the other shapes are parameters, a kind word is an enum member
local parameter  = define.TokenTypes.parameter
local variable   = define.TokenTypes.variable
local enumMember = define.TokenTypes.enumMember

tokens = tokensOf('---@fixture-names a, b\nlocal a, b\n')
assert(has(tokens, 0, 18, 1, variable, 0), 'a name of a list')
assert(has(tokens, 0, 21, 1, variable, 0), 'the second name of a list')

tokens = tokensOf('---@fixture-param-kind value alpha\nlocal function f(value) end\n')
assert(has(tokens, 0, 23, 5, parameter, 0), 'the parameter of a param-kind tag')
assert(has(tokens, 0, 29, 5, enumMember, 0), 'the kind word of a param-kind tag')

tokens = tokensOf('---@fixture-kind-params alpha value other\nlocal function f(value, other) end\n')
assert(has(tokens, 0, 24, 5, enumMember, 0), 'the kind word of a kind-params tag')
assert(has(tokens, 0, 30, 5, parameter, 0), 'the first name of a kind-params tag')
assert(has(tokens, 0, 36, 5, parameter, 0), 'the second name of a kind-params tag')

tokens = tokensOf('---@fixture-kind-params kind-with-hyphen value\nlocal function f(value) end\n')
assert(has(tokens, 0, 24, 16, enumMember, 0), 'a hyphenated kind word is one token')

-- a tag that did not read cleanly (unknown kind) stays bare: no part is a token
tokens = tokensOf('---@fixture-param-kind value nokind\nlocal function f(value) end\n')
assert(not has(tokens, 0, 23, 5, parameter, 0), 'an unclean param-kind tag has no parameter token')
assert(not has(tokens, 0, 29, 6, enumMember, 0), 'an unclean param-kind tag has no kind token')
tokens = tokensOf('---@fixture-kind-params nokind value\nlocal function f(value) end\n')
assert(not has(tokens, 0, 24, 6, enumMember, 0), 'an unclean kind-params tag has no kind token')

-- no kind, no names: only the tag itself
tokens = tokensOf('---@fixture-kind-params alpha\nlocal function f() end\n')
assert(has(tokens, 0, 24, 5, enumMember, 0), 'a kind with no names')

-- `Lua.semantic.annotation` off: no annotation tokens at all
local config = require 'config'
config.set(nil, 'Lua.semantic.annotation', false)
tokens = tokensOf('---@fixture-param-kind value alpha\nlocal function f(value) end\n')
assert(not has(tokens, 0, 23, 5, parameter, 0), 'annotation tokens switched off: the parameter')
assert(not has(tokens, 0, 29, 5, enumMember, 0), 'annotation tokens switched off: the kind')
config.set(nil, 'Lua.semantic.annotation', true)

-- the words of the type syntax are keywords too, not comment text: `keyof`, `extends` (a generic's constraint and a conditional type), and a type
-- keyword a plugin registers, in front of a type or as a one-argument generic
tokens = tokensOf('---@param k keyof T\nlocal function f(k) end\n')
assert(has(tokens, 0, 12, 5, keyword, 0), '`keyof`')

tokens = tokensOf('---@generic T extends table\nlocal function f() end\n')
assert(has(tokens, 0, 14, 7, keyword, 0), '`extends` of a generic')
tokens = tokensOf('---@generic T: table\nlocal function f() end\n')
assert(not has(tokens, 0, 13, 5, keyword, 0), 'the colon form has no keyword')
for _, t in ipairs(tokens) do
    assert(not (t[1] == 0 and t[4] == keyword and t[2] > 11), 'the colon form: no keyword token after the tag word')
end

tokens = tokensOf('---@type (T extends string ? number : boolean)\nlocal x\n')
assert(has(tokens, 0, 12, 7, keyword, 0), '`extends` of a conditional type')

tokens = tokensOf('---@param v fixturetype number\nlocal function f(v) end\n')
assert(has(tokens, 0, 12, 11, keyword, 0), 'a type keyword in front of a type')
tokens = tokensOf('---@param v fixturetype<number>\nlocal function f(v) end\n')
assert(has(tokens, 0, 12, 11, keyword, 0), 'a type keyword as a one-argument generic')
tokens = tokensOf('---@param v fixturetype<number>[]\nlocal function f(v) end\n')
assert(has(tokens, 0, 12, 11, keyword, 0), 'a type keyword as a generic on an array element')
tokens = tokensOf('---@param v number\nlocal function f(v) end\n')
for _, t in ipairs(tokens) do
    assert(not (t[1] == 0 and t[4] == keyword and t[2] > 8), 'a plain type has no keyword token')
end

-- annotation tokens off: no keyword tokens either
config.set(nil, 'Lua.semantic.annotation', false)
tokens = tokensOf('---@param k keyof T\nlocal function f(k) end\n')
assert(not has(tokens, 0, 12, 5, keyword, 0), '`keyof` with annotation tokens off')
config.set(nil, 'Lua.semantic.annotation', true)
