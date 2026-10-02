-- Editor features that no other test group touched: folding ranges and colour swatches.
---@diagnostic disable: await-in-sync
local files   = require 'files'
local folding = require 'core.folding'
local color   = require 'core.color'
local guide   = require 'parser.guide'

--- The folding ranges of `script` as `kind@startRow-finishRow` strings (rows are 0-based).
---@param script string
---@return string[]
local function foldsOf(script)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    local regions = assert(folding(TESTURI))
    files.remove(TESTURI)
    ---@type string[]
    local list = {}
    for _, region in ipairs(regions) do
        local startRow = guide.rowColOf(region.start)
        local finishRow = guide.rowColOf(region.finish)
        list[#list+1] = ('%s@%d-%d'):format(region.kind, startRow, finishRow)
    end
    table.sort(list)
    return list
end

---@param list string[]
---@param item string
---@return boolean
local function has(list, item)
    for _, v in ipairs(list) do
        if v == item then
            return true
        end
    end
    return false
end

do
    local folds = foldsOf([=[
local function f()
    if true then
        print(1)
    end
end

--[[ long
comment ]]

local t = {
    1,
    2,
}

for i = 1, 3 do
    print(i)
end

-- #region mark
local x = 1
-- #endregion
]=])
    assert(has(folds, 'region@0-4'), 'a function body: ' .. table.concat(folds, ' '))
    assert(has(folds, 'region@1-3'), 'an if block')
    assert(has(folds, 'comment@6-7'), 'a long comment')
    assert(has(folds, 'region@9-12'), 'a table constructor')
    assert(has(folds, 'region@14-16'), 'a for loop')
    assert(has(folds, 'region@18-20'), 'a #region / #endregion pair')
end

-- a class annotation group folds as a comment block
do
    local folds = foldsOf('---@class FoldA\n---@field a number\n---@field b string\nlocal A = {}\n')
    local found = false
    for _, fold in ipairs(folds) do
        if fold:find('^comment@0%-') then
            found = true
        end
    end
    assert(found, 'class doc group: ' .. table.concat(folds, ' '))
end

-- nothing to fold in a flat file
do
    local folds = foldsOf('local a = 1\nlocal b = 2\nprint(a, b)\n')
    assert(#folds == 0, table.concat(folds, ' '))
end

-- colours: an 8-digit `AARRGGBB` string and a 6-digit `#RRGGBB` one are swatches; anything else is not
local function colorsOf(script)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    local values = assert(color.colors(TESTURI))
    files.remove(TESTURI)
    return values
end

do
    local values = colorsOf('local a = "#ff8000"\nlocal b = "80ff0000"\nlocal c = "nocolor"\nlocal d = "#ff80"\nlocal e = 12345678\n')
    assert(#values == 2, #values)
    local hex6, hex8 = values[1], values[2]
    -- 6 digits: opaque (LSP colours are 0..1, the alpha used to be 255)
    assert(hex6.color.alpha == 1, hex6.color.alpha)
    assert(hex6.color.red == 1 and hex6.color.blue == 0)
    assert(math.abs(hex6.color.green - 128 / 255) < 1e-9)
    -- 8 digits: alpha first
    assert(math.abs(hex8.color.alpha - 128 / 255) < 1e-9)
    assert(hex8.color.red == 1 and hex8.color.green == 0 and hex8.color.blue == 0)
    -- the range excludes the quotes
    assert(hex6.finish - hex6.start == #'#ff8000', hex6.finish - hex6.start)
end

-- the text a colour picker result is written back as: `AARRGGBB`
assert(color.colorToText { alpha = 1, red = 1, green = 0.5, blue = 0 } == 'FFFF7F00')
assert(color.colorToText { alpha = 0, red = 0, green = 0, blue = 0 } == '00000000')
-- ... and a 6-digit swatch survives a round trip through the picker as an opaque colour
do
    local values = colorsOf('local a = "#336699"\n')
    assert(color.colorToText(values[1].color) == 'FF336699', color.colorToText(values[1].color))
end

-- go to type definition: from a type name, or from a value of that type, to the class declaration
local catch          = require 'catch'
local typeDefinition = require 'core.type-definition'

--- The start positions of every result of "go to type definition" at the `<?` `?>` of `script`.
---@param script string
---@return integer[]
local function typeDefsAt(script)
    local text, catched = catch(script, '?')
    files.remove(TESTURI)
    files.setText(TESTURI, text)
    files.compileState(TESTURI)
    local results = typeDefinition(TESTURI, catched['?'][1][1]) or {}
    ---@type integer[]
    local starts = {}
    for _, result in ipairs(results) do
        starts[#starts+1] = result.target.start
    end
    files.remove(TESTURI)
    return starts
end

local classDeclPos = 10 -- row 0, after `---@class `

do
    -- on the type name in an annotation
    local at = typeDefsAt('---@class TdFoo\nlocal TdFoo = {}\n---@type <?TdFoo?>\nlocal inst = {}\n')
    assert(#at == 1 and at[1] == classDeclPos, table.concat(at, ','))
    -- on a local declared with that type
    at = typeDefsAt('---@class TdFoo\nlocal TdFoo = {}\n---@type TdFoo\nlocal inst = {}\nprint(<?inst?>)\n')
    assert(#at == 1 and at[1] == classDeclPos, table.concat(at, ','))
    -- on a parameter
    at = typeDefsAt('---@class TdFoo\nlocal TdFoo = {}\n---@param p TdFoo\nlocal function f(p) return <?p?> end\n')
    assert(#at == 1 and at[1] == classDeclPos, table.concat(at, ','))
    -- on a field read whose declared type is the class
    at = typeDefsAt('---@class TdFoo\n---@field child TdFoo\nlocal TdFoo = {}\n---@type TdFoo\nlocal a\nprint(a.<?child?>)\n')
    assert(#at == 1 and at[1] == classDeclPos, table.concat(at, ','))
    -- a plain string value has no class declaration in the workspace to go to
    at = typeDefsAt("local s = 'x'\nprint(<?s?>)\n")
    assert(#at == 0, table.concat(at, ','))
end

-- workspace symbols: classes, aliases and globals are found by name (fuzzy), nothing for a miss
local workspaceSymbol = require 'core.workspace-symbol'
local define          = require 'proto.define'

do
    files.remove(TESTURI)
    files.setText(TESTURI, '---@class WsClassX\nlocal C = {}\n---@alias WsAliasX string\nWsGlobalX = 1\n')
    files.compileState(TESTURI)
    ---@param query string
    ---@return table<string, integer> name -> symbol kind
    local function kindsOf(query)
        ---@type table<string, integer>
        local kinds = {}
        for _, result in ipairs(workspaceSymbol(query, TESTURI)) do
            kinds[tostring(result.name)] = result.skind
        end
        return kinds
    end
    assert(kindsOf('WsClassX')['WsClassX'] == define.SymbolKind.Class)
    assert(kindsOf('WsAliasX')['WsAliasX'] == define.SymbolKind.Struct)
    assert(kindsOf('WsGlobalX')['WsGlobalX'] == define.SymbolKind.Variable)
    assert(kindsOf('wsclassx')['WsClassX'], 'case-insensitive')
    assert(next(kindsOf('zzqqxxnomatch')) == nil, 'no match, no result')
    files.remove(TESTURI)
end

-- prepare-rename: what the editor may offer to rename (and the text it shows in the box)
local rename = require 'core.rename'

---@param script string
---@return { start: integer, finish: integer, text: string|integer }?
local function prepareAt(script)
    local text, catched = catch(script, '?')
    files.remove(TESTURI)
    files.setText(TESTURI, text)
    files.compileState(TESTURI)
    local result = rename.prepareRename(TESTURI, catched['?'][1][1])
    files.remove(TESTURI)
    return result
end

do
    ---@type [string, string][] script, text shown
    local renameable = {
        { 'local <?abc?> = 1\nprint(abc)\n',                   'abc' },
        { 'local t = {}\nt.<?field?> = 1\n',                   'field' },
        { '<?Glob?> = 1\n',                                    'Glob' },
        { 'local function <?fn?>() end\n',                     'fn' },
        { '---@class <?Cls?>\nlocal C = {}\n',                 'Cls' },
        { '---@param <?p?> number\nlocal function f(p) end\n', 'p' },
        { 'local t = {}\nfunction t:<?meth?>() end\n',         'meth' },
        { 'goto <?lbl?>\n::lbl::\n',                           'lbl' },
        { "local t = {}\nt[<?'key'?>] = 1\n",                  'key' },
    }
    for _, case in ipairs(renameable) do
        local result = prepareAt(case[1])
        assert(result and result.text == case[2], case[1])
    end
    local result = assert(prepareAt('local <?abc?> = 1\nprint(abc)\n'))
    assert(result.finish - result.start == 3, 'the range is the name')

    ---@type string[]
    local notRenameable = {
        'local x = <?123?>\n',          -- a number
        '<?local?> x = 1\n',            -- a keyword
        'local x = 1 --[[<?note?>]]\n', -- a comment
        "local s = '<?text?>'\n",       -- a plain string value
    }
    for _, script in ipairs(notRenameable) do
        assert(prepareAt(script) == nil, script)
    end
end

-- keyword snippets: typing the start of a block keyword offers the whole block as a snippet
local completion = require 'core.completion'

---@param script string with one `<?` `?>` cursor
---@return table<string, string> label -> insertText of every snippet offered
local function snippetsAt(script)
    local text, catched = catch(script, '?')
    files.remove(TESTURI)
    files.setText(TESTURI, text)
    local items = completion.completion(TESTURI, catched['?'][1][2], nil) or {}
    files.remove(TESTURI)
    ---@type table<string, string>
    local snippets = {}
    for _, item in ipairs(items) do
        if item.kind == define.CompletionItemKind.Snippet then
            snippets[item.label] = tostring(item.insertText)
        end
    end
    return snippets
end

do
    local lf = string.char(10)
    local tab = string.char(9)
    ---@type [string, string, string?][] script, label, insertText (nil: only the label is checked)
    local expected = {
        { 'fo<??>',   'for .. ipairs', 'for ${1:index}, ${2:value} in ipairs(${3:t}) do' .. lf .. tab .. '$0' .. lf .. 'end' },
        { 'fo<??>',   'for .. pairs',  'for ${1:key}, ${2:value} in pairs(${3:t}) do' .. lf .. tab .. '$0' .. lf .. 'end' },
        { 'fo<??>',   'for i = ..' },
        { 'whi<??>',  'while .. do',   'while ${1:true} do' .. lf .. tab .. '$0' .. lf .. 'end' },
        { 'repea<??>', 'repeat .. until', 'repeat' .. lf .. tab .. '$0' .. lf .. 'until $1' },
        { 'func<??>', 'function ()',   'function $1($2)' .. lf .. tab .. '$0' .. lf .. 'end' },
        { 'if<??>',   'if .. then',    'if $1 then' .. lf .. tab .. '$0' .. lf .. 'end' },
        { 'do<??>',   'do .. end',     'do' .. lf .. tab .. '$0' .. lf .. 'end' },
        { 'elsei<??>', 'elseif .. then' },
        { 'x = 1 th<??>', 'then .. end', 'then' .. lf .. tab .. '$0' .. lf .. 'end' },
        { 'if x then ret<??>', 'do return end' },
        { 'while true do' .. lf .. '  con<??>' .. lf .. 'end', 'goto continue ..' },
    }
    for _, case in ipairs(expected) do
        local snippets = snippetsAt(case[1])
        assert(snippets[case[2]], ('%q should offer %q, got %s'):format(case[1], case[2], next(snippets) or 'nothing'))
        if case[3] then
            assert(snippets[case[2]] == case[3], ('%q: %q'):format(case[1], snippets[case[2]]))
        end
    end

    -- nothing is offered inside a word that is no keyword's start, and `continue` needs a loop
    assert(next(snippetsAt('zzz<??>')) == nil)
    assert(snippetsAt('local x = 1' .. lf .. 'con<??>')['goto continue ..'] == nil, 'no loop, no continue')
end
