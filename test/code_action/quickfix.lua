-- The quick fixes offered for a diagnostic (`core.code-action` called with the client's diagnostics):
-- the "disable this diagnostic" family, marking a global, the semicolon / brackets / async /
-- trailing-space fixes. Each case marks the diagnostic's range with `<!` `!>` and states what must be
-- offered; a diagnostic with no dedicated fix still gets the disable actions.
local core      = require 'core.code-action'
local files     = require 'files'
local lang      = require 'language'
local catch     = require 'catch'
local converter = require 'proto.converter'

---@param script string with one `<!` `!>` pair: the range of the diagnostic
---@param code   string
---@param extra? table<string, any> fields merged into the diagnostic (`data`, `source`, ...)
---@return core.code-action.results
---@return parser.state
local function actions(script, code, extra)
    local text, catched = catch(script, '!')
    files.setText(TESTURI, text)
    local state = assert(files.getState(TESTURI))
    local range = converter.packRange(state, catched['!'][1][1], catched['!'][1][2])
    local diag = { code = code, range = range }
    for k, v in pairs(extra or {}) do
        diag[k] = v
    end
    local results = core(TESTURI, catched['!'][1][1], catched['!'][1][2], { diag })
    files.remove(TESTURI)
    return assert(results), state
end

---@param results core.code-action.results
---@param title   string
---@return core.code-action.result?
local function find(results, title)
    for _, result in ipairs(results) do
        if result.title == title then
            return result
        end
    end
    return nil
end

---@param result core.code-action.result
---@return table
local function onlyEdit(result)
    local edits = result.edit and result.edit.changes[TESTURI]
    assert(edits and #edits == 1, 'one edit expected')
    return edits[1]
end

---@param result core.code-action.result
---@return any
local function commandArg(result)
    return assert(result.command).arguments[1]
end

---@param result core.code-action.result
---@return string
local function commandName(result)
    return assert(result.command).command
end

---@param result core.code-action.result
---@return table[]
local function editsOf(result)
    return assert(result.edit).changes[TESTURI]
end

-- every diagnostic can be disabled: through the config, for the next line, for the whole file
do
    local results = actions('local x = <!1!>\n', 'some-code')
    assert(find(results, lang.script('ACTION_DISABLE_DIAG', 'some-code')), 'disable in config')
    local line = assert(find(results, lang.script('ACTION_DISABLE_DIAG_LINE', 'some-code')))
    local edit = onlyEdit(line)
    assert(edit.newText == '---@diagnostic disable-next-line: some-code\n', edit.newText)
    assert(edit.start == edit.finish, 'an insertion')
    local file = assert(find(results, lang.script('ACTION_DISABLE_DIAG_FILE', 'some-code')))
    assert(onlyEdit(file).newText == '---@diagnostic disable: some-code\n')
    assert(#results == 3, 'nothing else for a code without a dedicated fix: ' .. #results)
end

-- an existing `disable-next-line` comment on the line above is extended, not duplicated
do
    local results = actions('---@diagnostic disable-next-line: first\nlocal x = <!1!>\n', 'second')
    local edit = onlyEdit(assert(find(results, lang.script('ACTION_DISABLE_DIAG_LINE', 'second'))))
    assert(edit.newText == ', second', edit.newText)
end

-- ... and a bare one (no code list yet) gets `: code`
do
    local results = actions('---@diagnostic disable-next-line\nlocal x = <!1!>\n', 'second')
    local edit = onlyEdit(assert(find(results, lang.script('ACTION_DISABLE_DIAG_LINE', 'second'))))
    assert(edit.newText == ': second', edit.newText)
end

-- on the first line there is no line above: a comment is inserted before it
do
    local results = actions('local x = <!1!>\n', 'second')
    local edit = onlyEdit(assert(find(results, lang.script('ACTION_DISABLE_DIAG_LINE', 'second'))))
    assert(edit.newText:find('disable%-next%-line: second'))
end

-- undefined-global: mark it as a known global (and offer the versions that define it)
do
    local results = actions('<!foo!>()\n', 'undefined-global', { data = { versions = { 'Lua 5.1', 'Lua 5.4' } } })
    local mark = assert(find(results, lang.script('ACTION_MARK_GLOBAL', 'foo')))
    local arg = commandArg(mark)
    assert(arg.key == 'Lua.diagnostics.globals' and arg.value == 'foo' and arg.action == 'add')
    local version = assert(find(results, lang.script('ACTION_RUNTIME_VERSION', 'Lua 5.4')))
    assert(commandArg(version).key == 'Lua.runtime.version')
    assert(find(results, lang.script('ACTION_RUNTIME_VERSION', 'Lua 5.1')))
end

-- lowercase-global: the same "mark as global" fix
do
    local results = actions('<!foo!> = 1\n', 'lowercase-global')
    assert(find(results, lang.script('ACTION_MARK_GLOBAL', 'foo')))
end

-- newline-call: a semicolon goes in front of the ambiguous line
do
    local results = actions('local a = f\n<!(g)!>()\n', 'newline-call')
    local edit = onlyEdit(assert(find(results, lang.script.ACTION_ADD_SEMICOLON)))
    assert(edit.newText == ';' and edit.start == edit.finish)
end

-- ambiguity-1 (`a or b == c`): offered as a command that adds the brackets
do
    local results = actions('local x = <!a or b == c!>\n', 'ambiguity-1')
    local fix = assert(find(results, lang.script.ACTION_ADD_BRACKETS))
    assert(commandName(fix) == 'lua.solve' and commandArg(fix).name == 'ambiguity-1')
end

-- trailing-space: a command that strips it
do
    local results = actions('local x = 1<!   !>\n', 'trailing-space')
    local fix = assert(find(results, lang.script.ACTION_REMOVE_SPACE))
    assert(commandName(fix) == 'lua.removeSpace')
end

-- await-in-sync: `---@async` is added above the enclosing function, keeping its indentation
do
    local results = actions('local function f()\n    <!coroutine.yield()!>\nend\n', 'await-in-sync')
    local edit = onlyEdit(assert(find(results, lang.script.ACTION_MARK_ASYNC)))
    assert(edit.newText == '---@async\n', edit.newText)
end

do
    local results = actions('do\n    local function f()\n        <!coroutine.yield()!>\n    end\nend\n', 'await-in-sync')
    local edit = onlyEdit(assert(find(results, lang.script.ACTION_MARK_ASYNC)))
    assert(edit.newText == '    ---@async\n', edit.newText)
end

-- no diagnostics at all: only the range-based actions (none for this range)
do
    local text, catched = catch('local x = <!1!>\n', '!')
    files.setText(TESTURI, text)
    local results = core(TESTURI, catched['!'][1][1], catched['!'][1][2], nil)
    files.remove(TESTURI)
    assert(results and #results == 0, 'no quick fix without a diagnostic')
end

-- the fixes of syntax errors: the client reports them as diagnostics of the syntax checker, the
-- fix is looked up through the parser's own error with the same range
local config = require 'config'

---@param script  string
---@param errType string the parser error to ask the quick fixes of
---@param version? string runtime version to parse with
---@return core.code-action.results
local function syntaxActions(script, errType, version)
    if version then
        config.set(nil, 'Lua.runtime.version', version)
    end
    files.setText(TESTURI, script)
    local state = assert(files.getState(TESTURI))
    ---@type core.code-action.results?
    local results
    for _, err in ipairs(state.errs) do
        if err.type == errType then
            local diag = {
                source = lang.script.DIAG_SYNTAX_CHECK,
                code   = errType:lower():gsub('_', '-'),
                range  = converter.packRange(state, err.start, err.finish),
            }
            results = core(TESTURI, err.start, err.finish, { diag })
            break
        end
    end
    files.remove(TESTURI)
    if version then
        config.set(nil, 'Lua.runtime.version', nil)
    end
    return assert(results, 'the parser did not report ' .. errType)
end

-- statements after a `return`: wrap them in `do ... end`
do
    local results = syntaxActions('return 1\nprint(2)\n', 'ACTION_AFTER_RETURN')
    local fix = assert(find(results, lang.script.ACTION_ADD_DO_END))
    local edits = editsOf(fix)
    assert(#edits == 2 and edits[1].newText == 'do ' and edits[2].newText == ' end')
end

-- a symbol the configured version does not have: offer the versions that do
do
    local results = syntaxActions('local x = 1 // 2\n', 'UNSUPPORT_SYMBOL', 'Lua 5.1')
    assert(find(results, lang.script('ACTION_RUNTIME_VERSION', 'Lua 5.3')))
    assert(not find(results, lang.script('ACTION_RUNTIME_VERSION', 'Lua 5.1')), 'not the version in use')
end

-- a non-ASCII name: offer to allow it
do
    local results = syntaxActions('local \xe5\x8f\x98\xe9\x87\x8f = 1\n', 'UNICODE_NAME')
    local fix = assert(find(results, lang.script('ACTION_RUNTIME_UNICODE_NAME')))
    assert(commandArg(fix).key == 'Lua.runtime.unicodeName')
end

-- fixes the parser itself proposes (`!=` -> `~=`, `==` where `=` was meant) become text edits
do
    local results = syntaxActions('x = 1 ~= 2 != 3\n', 'ERR_NONSTANDARD_SYMBOL')
    local edit = onlyEdit(results[1])
    assert(edit.newText == '~=', edit.newText)
end

do
    local results = syntaxActions('local x == 1\n', 'ERR_ASSIGN_AS_EQ')
    local edit = onlyEdit(results[1])
    assert(edit.newText == '=', edit.newText)
end

-- a syntax error nothing can fix still offers nothing (and does not fail)
do
    local results = syntaxActions('print(1))\n', 'UNKNOWN_SYMBOL')
    assert(#results == 0, #results)
end

-- need-check-nil: a guard around the statement, an assert before it, safe navigation where the syntax is on
do
    local results = actions('---@type table?\nlocal t\nlocal x = <!t!>.a\n', 'need-check-nil')
    local wrap = assert(find(results, lang.script('ACTION_NIL_WRAP', 't')))
    local edits = assert(wrap.edit).changes[TESTURI]
    assert(#edits == 2, 'one line: the opening and the closing edit, got ' .. #edits)
    assert(edits[1].newText == 'if t then\n    ', edits[1].newText)
    assert(edits[2].newText == '\nend', edits[2].newText)
    local assertFix = assert(find(results, lang.script('ACTION_NIL_ASSERT', 't')))
    assert(onlyEdit(assertFix).newText == 'assert(t)\n')
    assert(not find(results, lang.script.ACTION_NIL_SAFE_NAV), 'no safe navigation in plain Lua')
end

-- a statement on several lines is indented line by line, keeping the indentation of the statement
do
    local results = actions('---@type table?\nlocal t\nif true then\n    print(\n        <!t!>.a\n    )\nend\n', 'need-check-nil')
    local wrap = assert(find(results, lang.script('ACTION_NIL_WRAP', 't')))
    local edits = assert(wrap.edit).changes[TESTURI]
    assert(edits[1].newText == '    if t then\n    ', edits[1].newText)
    assert(#edits == 4, 'opening, 2 continuation lines, the closing one: ' .. #edits)
    assert(edits[#edits].newText == '\n    end')
end

-- a field path is guarded as text; a call result or an expression is not (no plain text to repeat)
do
    local results = actions('---@type {a: table?}\nlocal t\nlocal x = <!t.a!>.b\n', 'need-check-nil')
    assert(find(results, lang.script('ACTION_NIL_WRAP', 't.a')), 'a field path')
    local results2 = actions('local function f() ---@type table?\n    return nil end\nlocal x = <!f()!>.b\n', 'need-check-nil')
    assert(not find(results2, lang.script('ACTION_NIL_ASSERT', 'f()')), 'nothing for a call')
end

-- safe navigation: offered only when the syntax is enabled
do
    config.set(nil, 'Lua.runtime.nonstandardSymbol', { '?.', '?.[', '?.(' })
    local results = actions('---@type table?\nlocal t\nlocal x = <!t!>.a\nlocal y = <!t!>[1]\nlocal z = <!t!>()\n', 'need-check-nil')
    config.set(nil, 'Lua.runtime.nonstandardSymbol', {})
    assert(find(results, lang.script.ACTION_NIL_SAFE_NAV), 'with the symbols on')
end

-- the edits of the need-check-nil fixes give valid code when applied
do
    local guide = require 'parser.guide'
    ---@param script string
    ---@param title  string
    ---@return string
    local function applied(script, title)
        local results, state = actions(script, 'need-check-nil')
        local fix = assert(find(results, title))
        local text = assert(state.lua)
        ---@type {s: integer, f: integer, t: string, i: integer}[]
        local list = {}
        for i, edit in ipairs(assert(fix.edit).changes[TESTURI]) do
            list[i] = {
                s = guide.positionToOffset(state, edit.start + 1) or 1,
                f = guide.positionToOffset(state, edit.finish),
                t = edit.newText,
                i = i,
            }
        end
        -- from the end of the text to its start, so the offsets stay valid (same position: later edit first)
        table.sort(list, function (a, b)
            if a.s ~= b.s then
                return a.s > b.s
            end
            return a.i > b.i
        end)
        for _, e in ipairs(list) do
            text = text:sub(1, e.s - 1) .. e.t .. text:sub(e.f + 1)
        end
        return text
    end
    local NL = string.char(10)
    assert(applied('---@type table?' .. NL .. 'local t' .. NL .. 'local x = <!t!>.a' .. NL,
        lang.script('ACTION_NIL_WRAP', 't'))
        == '---@type table?' .. NL .. 'local t' .. NL .. 'if t then' .. NL .. '    local x = t.a' .. NL .. 'end' .. NL)
    assert(applied('---@type table?' .. NL .. 'local t' .. NL .. 'do' .. NL .. '    print(' .. NL .. '        <!t!>.a' .. NL .. '    )' .. NL .. 'end' .. NL,
        lang.script('ACTION_NIL_WRAP', 't'))
        == '---@type table?' .. NL .. 'local t' .. NL .. 'do' .. NL .. '    if t then' .. NL .. '        print(' .. NL
        .. '            t.a' .. NL .. '        )' .. NL .. '    end' .. NL .. 'end' .. NL)
    assert(applied('---@type table?' .. NL .. 'local t' .. NL .. 'local x = <!t!>.a' .. NL,
        lang.script('ACTION_NIL_ASSERT', 't'))
        == '---@type table?' .. NL .. 'local t' .. NL .. 'assert(t)' .. NL .. 'local x = t.a' .. NL)
end
