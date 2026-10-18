local core  = require 'core.hover'
local files = require 'files'
local catch = require 'catch'
local guide = require 'parser.guide'
local vm    = require 'vm'

---@diagnostic disable: await-in-sync

-- A utility type (`Partial<Cfg>`, `Pick<Cfg, 'host'>`, ...) is written by its name where a type is shown to the user, with the fields it
-- resolves to in the block under it. Only the display: the plain view (the messages of the diagnostics) stays the resolved shape.

--- The hover at the `<??>` of a script, as text.
---@param script string
---@return string
local function hoverOf(script)
    local text, catched = catch(script, '?')
    files.setText(TESTURI, text)
    local shown = core.byUri(TESTURI, catched['?'][1][1], 1)
    files.remove(TESTURI)
    return shown and shown:string() or ''
end

---@param script string
---@param first  string the first line of the hover (after the code fence)
local function assertFirstLine(script, first)
    local shown = hoverOf(script)
    local line = shown:match('```lua%s*[\r\n]+([^\r\n]*)') or ''
    assert(line == first, ('expected `%s`, got `%s`'):format(first, line))
end

local PRELUDE = [[
---@class UN.A
---@field x number
---@field y string

]]

-- the name as written, in a parameter, a variable, optional, in a union, an array, nested and in a function type
assertFirstLine(PRELUDE .. '---@type Partial<UN.A>\nlocal <?v?>\n', 'local v: Partial<UN.A> {')
assertFirstLine(PRELUDE .. '---@param p Partial<UN.A>?\nlocal function f(<?p?>) end\n', '(parameter) p: Partial<UN.A>? {')
assertFirstLine(PRELUDE .. '---@param p Required<Partial<UN.A>>\nlocal function f(<?p?>) end\n', '(parameter) p: Required<Partial<UN.A>> {')
assertFirstLine(PRELUDE .. '---@param p Omit<UN.A, "x">\nlocal function f(<?p?>) end\n', '(parameter) p: Omit<UN.A, "x"> {')
assertFirstLine(PRELUDE .. '---@param p Record<"k", number>\nlocal function f(<?p?>) end\n', '(parameter) p: Record<"k", number> {')
assertFirstLine(PRELUDE .. '---@param p Partial<UN.A>[]\nlocal function f(<?p?>) end\n', '(parameter) p: Partial<UN.A>[]')
assertFirstLine(PRELUDE .. '---@param p string | Partial<UN.A>\nlocal function f(<?p?>) end\n', '(parameter) p: string|Partial<UN.A>')
assertFirstLine(PRELUDE .. '---@param p Partial<UN.A>\nlocal function <?f?>(p) end\n', 'function f(p: Partial<UN.A>)')
assertFirstLine(PRELUDE .. '---@param cb fun(a: Partial<UN.A>): Pick<UN.A, "x">\nlocal function <?f?>(cb) end\n',
    'function f(cb: fun(a: Partial<UN.A>):Pick<UN.A, "x">)')

-- the fields stay in the block under the name
do
    local shown = hoverOf(PRELUDE .. '---@param p Partial<UN.A>\nlocal function f(<?p?>) end\n')
    assert(shown:find('x?: number', 1, true) and shown:find('y?: string', 1, true), 'the fields are below the name: ' .. shown)
end

-- negative: a plain class, an inline table and an intersection are not utility types: nothing is renamed
assertFirstLine(PRELUDE .. '---@param p UN.A\nlocal function f(<?p?>) end\n', '(parameter) p: UN.A {')
assertFirstLine(PRELUDE .. '---@param p {x: number}\nlocal function f(<?p?>) end\n', '(parameter) p: { x: number } {')
assertFirstLine(PRELUDE .. '---@param p {x: number} & {y: string}\nlocal function f(<?p?>) end\n', '(parameter) p: { x: number, y: string } {')

-- the plain view (diagnostics) keeps the resolved shape
do
    local text = PRELUDE .. '---@param p Partial<UN.A>\nlocal function f(p) end\n'
    files.setText(TESTURI, text)
    local state = assert(files.getState(TESTURI))
    ---@type parser.object?
    local param
    guide.eachSourceType(state.ast, 'local', function (source)
        if source[1] == 'p' then
            param = source
        end
    end)
    assert(param, 'found the parameter')
    local infer = vm.getInfer(param)
    -- (the display view first, on a file nothing was compiled for: the plain view must not depend on it)
    assert(infer:viewFlagged(TESTURI) == 'Partial<UN.A>', 'display view: ' .. infer:viewFlagged(TESTURI))
    assert(infer:view(TESTURI) == '{ x: number?, y: string? }', 'plain view after the display view: ' .. infer:view(TESTURI))
    files.remove(TESTURI)
end

-- the same name in the detail of a completion item and in the inlay hint of a local
do
    local completion = require 'core.completion'
    local config     = require 'config'
    local hintCore   = require 'core.hint'

    local text, catched = catch(PRELUDE .. '---@type Partial<UN.A>\nlocal unpart = {}\nunp<??>\n', '?')
    files.setText(TESTURI, text)
    ---@type string?
    local detail
    for _, item in ipairs(completion.completion(TESTURI, catched['?'][1][1], nil) or {}) do
        if item.label == 'unpart' and item.id then
            detail = completion.resolve(item.id).detail
        end
    end
    files.remove(TESTURI)
    assert(detail == 'Partial<UN.A>', 'completion detail: ' .. tostring(detail))

    local oldEnable, oldSetType = config.get(nil, 'Lua.hint.enable'), config.get(nil, 'Lua.hint.setType')
    config.set(nil, 'Lua.hint.enable', true)
    config.set(nil, 'Lua.hint.setType', true)
    files.setText(TESTURI, PRELUDE .. '---@return Partial<UN.A>\nlocal function mk() end\nlocal hinted = mk()\n')
    files.compileState(TESTURI)
    ---@type string[]
    local seen = {}
    for _, hint in ipairs(hintCore(TESTURI, 0, math.huge --[[@as integer]])) do
        seen[#seen+1] = hint.text
    end
    files.remove(TESTURI)
    config.set(nil, 'Lua.hint.enable', oldEnable)
    config.set(nil, 'Lua.hint.setType', oldSetType)
    assert(seen[#seen] == ': Partial<UN.A>', 'inlay hint: ' .. table.concat(seen, ' | '))
end
