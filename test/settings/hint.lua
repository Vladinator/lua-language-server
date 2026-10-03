-- The `Lua.hint.*` (inlay hint) settings that nothing covered: `paramType`, `await`, `awaitPropagate`, `semicolon`.
-- Each is checked with every value and with the case it must leave alone.
local files  = require 'files'
local config = require 'config'
local hint   = require 'core.hint'

---@diagnostic disable: await-in-sync

--- The texts of the inlay hints of `script`, sorted, joined with `|`.
---@param script string
---@return string
local function hintTexts(script)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    files.compileState(TESTURI)
    local results = hint(TESTURI, 0, math.huge --[[@as integer]])
    files.remove(TESTURI)
    ---@type string[]
    local texts = {}
    for _, result in ipairs(results) do
        texts[#texts+1] = result.text
    end
    table.sort(texts)
    return table.concat(texts, '|')
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

-- paramType: the type of a documented parameter is shown after its name (the `a:` hint of the argument at the
-- call is another setting and stays)
local paramScript = [[
---@param a number
local function f(a) end
f(1)
]]
with('hint.paramType', true, function ()
    assert(hintTexts(paramScript) == ': number|a:', hintTexts(paramScript))
end)
with('hint.paramType', false, function ()
    assert(hintTexts(paramScript) == 'a:', hintTexts(paramScript))
end)

-- await: a call of an `@async` function gets `await `
local awaitScript = [[
---@async
local function af() end
local function user() af() end
user()
]]
with('hint.await', true, function ()
    assert(hintTexts(awaitScript) == 'await ', hintTexts(awaitScript))
end)
with('hint.await', false, function ()
    assert(hintTexts(awaitScript) == '', hintTexts(awaitScript))
end)
-- ... and a call of something that is not async gets nothing
with('hint.await', true, function ()
    assert(hintTexts('local function plain() end\nplain()\n') == '')
end)

-- awaitPropagate: a function that awaits is async too, so the calls of it get the hint
with('hint.await', true, function ()
    with('hint.awaitPropagate', false, function ()
        assert(hintTexts(awaitScript) == 'await ', hintTexts(awaitScript))
    end)
    with('hint.awaitPropagate', true, function ()
        assert(hintTexts(awaitScript) == 'await |await ', hintTexts(awaitScript))
    end)
end)

-- semicolon: All = a `;` after every statement that has none (the last one too), SameLine = only where two
-- statements share a line, Disable = never
local separate = 'local a = 1\nlocal b = 2\nprint(a, b)\n'
local sameLine = 'local a = 1 local b = 2\nprint(a, b)\n'
with('hint.semicolon', 'All', function ()
    assert(hintTexts(separate) == ';|;|;', hintTexts(separate))
    assert(hintTexts(sameLine) == ';|;|;', hintTexts(sameLine))
end)
with('hint.semicolon', 'SameLine', function ()
    assert(hintTexts(separate) == '', hintTexts(separate))
    assert(hintTexts(sameLine) == ';', hintTexts(sameLine))
end)
with('hint.semicolon', 'Disable', function ()
    assert(hintTexts(separate) == '', hintTexts(separate))
    assert(hintTexts(sameLine) == '', hintTexts(sameLine))
end)
