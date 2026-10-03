-- The `Lua.semantic.*` settings: which semantic tokens are produced for code and for annotations, with each
-- setting off and on (`enable` off means no tokens at all).
local files    = require 'files'
local config   = require 'config'
local define   = require 'proto.define'
local semantic = require 'core.semantic-tokens'

---@diagnostic disable: await-in-sync

---@type table<integer, string>
local typeNames = {}
for name, id in pairs(define.TokenTypes) do
    typeNames[id] = name
end

--- How many tokens of each type `script` gets.
---@param script string
---@return table<string, integer>
local function tokenCounts(script)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    local data = semantic(TESTURI, 0, math.huge) --[[@as integer[] ]]
    files.remove(TESTURI)
    ---@type table<string, integer>
    local counts = {}
    for i = 1, #data, 5 do
        local name = typeNames[data[i + 3]] or tostring(data[i + 3])
        counts[name] = (counts[name] or 0) + 1
    end
    return counts
end

---@param key   string
---@param value any
---@param fn    fun()
local function with(key, value, fn)
    local full = 'Lua.' .. key
    local saved = config.get(nil, full)
    config.set(nil, full, value)
    fn()
    config.set(nil, full, saved)
end

local code = 'local x = 1\nprint(x)\nfor i = 1, 2 do end\n'
local doc  = '---@class Foo\n---@field a number\nlocal t = {}\n'

-- enable: off, nothing at all
with('semantic.enable', true, function ()
    assert(next(tokenCounts(code)) ~= nil and next(tokenCounts(doc)) ~= nil)
end)
with('semantic.enable', false, function ()
    assert(next(tokenCounts(code)) == nil and next(tokenCounts(doc)) == nil)
end)

-- variable: the variables of the code (not the ones of an annotation, which are `annotation`'s)
with('semantic.variable', true, function ()
    assert((tokenCounts(code).variable or 0) > 0)
end)
with('semantic.variable', false, function ()
    -- (with the keywords off, the variables and the functions called through them are all the tokens code has)
    assert(next(tokenCounts(code)) == nil, 'no token for the variables or the calls')
    assert((tokenCounts(doc).type or 0) > 0, 'the annotation tokens are not the variables')
end)

-- keyword (off by default): `local`, `for`, `do`, ... and the literals around them
with('semantic.keyword', true, function ()
    assert((tokenCounts(code).keyword or 0) > 0 and (tokenCounts(code).number or 0) > 0)
end)
with('semantic.keyword', false, function ()
    assert((tokenCounts(code).keyword or 0) == 0 and (tokenCounts(code).number or 0) == 0)
end)

-- annotation: the type names and field names inside `---@` comments
with('semantic.annotation', true, function ()
    local counts = tokenCounts(doc)
    assert((counts.type or 0) > 0 and (counts.property or 0) > 0, 'type and field names')
end)
with('semantic.annotation', false, function ()
    local counts = tokenCounts(doc)
    assert((counts.type or 0) == 0 and (counts.property or 0) == 0)
    assert((counts.keyword or 0) > 0, 'the tag words (`class`, `field`) stay')
end)
