-- Robustness: truncated / malformed doc comments must never make a language
-- feature throw. Every prefix (cut at token boundaries) of a set of doc tags is
-- bound to some code, then each feature is asked about many positions.
local files = require 'files'
local guide = require 'parser.guide'

---@async
---@param uri uri
---@param pos integer
---@return markdown?
local function hover(uri, pos)
    return require 'core.hover'.byUri(uri, pos, 1)
end

local features = {
    hover       = hover,
    definition  = require 'core.definition',
    reference   = require 'core.reference',
    signature   = require 'core.signature',
    highlight   = require 'core.highlight',
    typedef     = require 'core.type-definition',
    implement   = require 'core.implementation',
    -- the request, then the second step the editor does for the items it shows: the first two
    -- and two spread over the rest (every item would multiply the time of the whole run by six;
    -- the ones the editor resolves are the ones the user moves to, anywhere in the list)
    ---@async
    completion  = (function ()
        local state = 12345
        ---@async
        return function (uri, pos)
            local completion = require 'core.completion'
            local items = completion.completion(uri, pos) or {}
            ---@async
            ---@param item any
            local function resolve(item)
                if item.id then
                    completion.resolve(item.id)
                end
            end
            for i = 1, math.min(#items, 2) do
                resolve(items[i])
            end
            for _ = 1, math.min(#items - 2, 2) do
                state = (state * 1103515245 + 12345) % 2147483648
                local index = 3 + state % (#items - 2)
                resolve(items[index])
            end
        end
    end)(),
    rename      = require 'core.rename'.prepareRename,
    -- the rename itself, with a new name, not only its preparation
    ---@async
    renameTo    = function (uri, pos)
        return require 'core.rename'.rename(uri, pos, 'renamed')
    end,
    -- what the editor asks on typing a newline
    ---@async
    typeFormat  = function (uri, pos)
        return require 'core.type-formatting'(uri, pos, '\n', {})
    end,
}
local semantic = require 'core.semantic-tokens'
local symbols  = require 'core.document-symbol'
local folding  = require 'core.folding'
local hint     = require 'core.hint'
local diagnostics = require 'core.diagnostics'
local codeAction = require 'core.code-action'
local wsSymbol = require 'core.workspace-symbol'
local formatting = require 'core.formatting'
local color      = require 'core.color'
local codeLens   = require 'core.code-lens'
local psiView    = require 'core.view.psi-view'
local rangeFormatting = require 'core.rangeformatting'
local vm         = require 'vm'
local export     = require 'cli.doc.export'

-- `--doc` export reads the global `DOC` (the project directory), and turns a file uri into a path
-- with `fs.canonical`, which needs the file to exist; the unit test file does not
DOC = ROOT:string()
export.getLocalPath = function (uri)
    return uri
end

--- What `--doc` does for the classes, aliases and enums a file declares.
---@async
---@param uri uri
local function docExport(uri)
    local state = files.getState(uri)
    if not state or not state.ast or not state.ast.docs then
        return
    end
    for _, doc in ipairs(state.ast.docs) do
        local name = (doc.class and doc.class[1]) or (doc.alias and doc.alias[1]) or (doc.enum and doc.enum[1])
        if type(name) == 'string' then
            local global = vm.getGlobal('type', name)
            if global then
                export.documentObject(global)
            end
        end
    end
end

local samples = {
    '---@class Foo: Bar<T>, Baz',
    '---@class (exact) Foo<T: string, U>',
    '---@alias Name string|integer',
    "---@alias Name\n---| 'a' # first\n---| 'b'",
    '---@param a string? desc',
    '---@param ... integer',
    '---@param cb fun(x: integer, y?: string): boolean, string',
    '---@return string name, integer? count desc',
    '---@return (fun(): integer)[]',
    '---@field x integer desc',
    '---@field private y? {a: integer, b: string[]}',
    '---@field [string] table<string, integer>',
    '---@type table<string, fun(a: integer): string[]>',
    '---@type (string|integer)[]',
    '---@type `T`',
    '---@type Foo<Bar<Baz>>',
    '---@generic T: string, U',
    '---@overload fun(a: integer): string',
    '---@cast x string?',
    '---@cast x +string, -nil',
    '---@operator add(integer): Foo',
    '---@operator unm: Foo',
    '---@enum Color',
    '---@enum (key) Color',
    '---@see Foo.bar',
    '---@meta my.mod',
    "---@module 'x'",
    '---@async',
    '---@deprecated use other',
    '---@diagnostic disable-next-line: undefined-global, unused-local',
    '---@diagnostic expect-next-line: undefined-global, no-such-diagnostic',
    '---@diagnostic expect-line: need-check-nil',
    '---@diagnostic expect-next-line',
    -- the tags of the secret plugin (core/diagnostics/extra/): text only, without the plugin they are
    -- plain comments and still must not make anything throw
    '---@secret a, b, c',
    '---@secret a b c',
    '---@secret-unwrap x, y',
    '---@secret-check',
    '---@nosecret a, b',
    '---@field readonly name string',
    '---@field readonly',
    '---@field readonly private name string',
    '---@guard v is string',
    '---@guard v is not nil',
    '---@guard v is',
    '---@guard v is not',
    '---@guard',
    '---@asserts v is string|number',
    '---@asserts v string',
    '---@nosecret',
    '---@type nosecret string, secret integer',
    '---@return nosecret string, nosecret',
    '---@param a nosecret string, b nosecret',
    '---@field name nosecret string',
    '---@type number, secret string?, boolean',
    '---@param a secret string, b secret',
    '---@return secret string, secret integer',
    '---@type secret',
    '---@type secret |',
    '---@version >5.1, JIT',
    '---@source file:///x.lua#1:2',
    '---@vararg string',
    '---@class (incremental) Foo',
    '---@class (partial, exact) Foo: Bar',
    '---@field x [string, integer?]',
    '---@field y { [1]: string, n: integer, f: fun(...: any) }',
    '---@field [integer] string',
    '---@field public z fun(self: Foo, a: `T`): T',
    "---@type 'a'|'b'|1|true",
    '---@type fun(a: integer, ...: string): (string, integer)',
    '---@type async fun(): table<string, [integer, string]>',
    '---@type string[][]?',
    '---@type Foo.Bar<T>[]',
    '---@type table<string, table<string, table<string, integer>>>',
    '---@type {}',
    '---@type [ ]',
    '---@type fun()',
    '---@type (fun())?',
    '---@type ...',
    '---@param self Foo\n---@param ... integer\n---@return ...',
    '---@return integer|string ...',
    '---@return T, U',
    '---@generic T: table, U: {x: integer}',
    '---@generic T\n---@param a T\n---@return T',
    '---@overload fun(...: string): boolean',
    '---@overload fun(self: Foo): self',
    '---@cast x -?',
    '---@cast x +nil',
    '---@cast x string|integer, -nil',
    '---@cast a, b string',
    '---@as string',
    '---@enum (key) Color\n---@enum Other',
    '---@operator call(...): Foo',
    '---@operator concat(string): Foo',
    '---@operator len: integer',
    '---@nodiscard',
    '---@package',
    '---@private',
    '---@protected',
    '---@meta _',
    '---@meta',
    '---@see Foo#bar',
    "---@module 'a.b'",
    '---@source c:\\x.lua:3',
    '---@version 5.4',
    '---@version <5.4, JIT',
    '---@diagnostic disable',
    '---@diagnostic enable: unused-local',
    '---@diagnostic disable-line: undefined-global',
    '---@diagnostic expect-next-line: need-check-nil, undefined-field',
    '---@secret-access-check',
    '---@field secret token string',
    '---@class A\n---@field x integer',
    '---@param a integer\n---@param b',
    '--[[@as string]]',
}
local codes = {
    'local function f(a, b) end',
    'local x = 1',
    'function M.g(...) end',
    'local t = {a = 1}\nt.b = 2',
    'for i = 1, 2 do end',
    'return M',
}

---@param s string
---@return string[]
local function cuts(s)
    ---@type table<string, boolean>
    local seen = {}
    ---@type string[]
    local list = {}
    local function add(c)
        if not seen[c] then
            seen[c] = true
            list[#list+1] = c
        end
    end
    add('')
    for i = 1, #s do
        if s:sub(i, i):find '[%s,:|<>()%[%]{}?=#%.]' then
            add(s:sub(1, i - 1))
        end
    end
    local e = 0
    while true do
        local _, last = s:find('%w+', e + 1)
        if not last then
            break
        end
        add(s:sub(1, last))
        e = last
    end
    add(s)
    return list
end

---@type table<string, {count: integer, example: string}>
local failures = {}
local total = 0

---@param name string
---@param text string
---@param fn function
---@param ... any
local function try(name, text, fn, ...)
    total = total + 1
    local ok, err = xpcall(fn, function (e)
        local tb = debug.traceback(tostring(e), 2)
        local frame = tb:match('(script[^\n]-:%d+:[^\n]*)') or tb:match('([^\n]*)')
        return tostring(e):match('^[^\n]*') .. ' @ ' .. (frame or '?')
    end, ...)
    if not ok then
        local key = name .. ': ' .. tostring(err):gsub('%s+', ' '):sub(1, 260)
        local f = failures[key]
        if f then
            f.count = f.count + 1
        else
            failures[key] = { count = 1, example = text }
        end
    end
end

-- truncated Lua code, bound to a doc comment or bare
local luaSamples = {
    'local function f(a, b, ...) return a + b, ... end',
    'local t = { x = 1, [2] = 3, f = function (self) return self end, 4 }',
    'function M.a.b:c(x) if x then return x.y[1]:z() else goto done end ::done:: end',
    'for k, v in pairs(t) do if k == "a" then break end end',
    'while true do local x <const> = 1; repeat x = x + 1 until x > 2 end',
    'local s = "abc\\u{41}" .. [[long]] .. #t .. -x .. not y',
    'local a, b <close>, c = f(), (g()), ...',
    'x = y and z or w; M.k, t[1] = 1, 2',
    'local ok = pcall(function () return M:method "s" end)',
    'local i = 0x1p4 + 1e3 + 0b101',
    'return function () end',
    -- Lua 5.4 / 5.5 attributes, integer division, bit operators, goto
    'local x <const>, y <close> = 1, nil; local z = x // 2 | y ~ 3 << 1 >> 2 & 4',
    'goto a; ::a:: ::b:: local n = 7 // 2 % 3',
    -- Lua 5.5 `global` declarations and named varargs
    'global x, y = 1, 2; global function f(...args) return #args end',
    'global <const> *; global z <const> = 1',
    'local function g(...rest) return rest, select("#", ...rest) end',
    -- LuaJIT / integer suffixes / odd literals
    'local a = 1LL + 2ULL + 0xFFi + 3e-2 + .5 + 5. + 0x.1p-1',
    'local s = "\\z   \\x41\\65\\u{1F600}" .. \'q\' .. [==[a]]b]==]',
    -- comments, long comments, shebang-ish and unfinished strings
    '--[==[ long\ncomment ]==] local x = 1 -- trailing',
    'local s = "unterminated',
    'local t = { [ =',
    'function ( end',
    'if then elseif else end until',
    'x = = = 1',
    '::',
    '@ # $ ` ~ ^',
}

---@type string[]
local cases = {}
for si, sample in ipairs(samples) do
    for ci, cut in ipairs(cuts(sample)) do
        local code = codes[(si + ci) % #codes + 1]
        cases[#cases+1] = ('local M = {}\n%s\n%s\nprint(M)\n'):format(cut, code)
    end
end
for _, sample in ipairs(luaSamples) do
    for _, cut in ipairs(cuts(sample)) do
        cases[#cases+1] = ('---@class Foo\nlocal M = {}\n---@param a integer\n%s\n'):format(cut)
        cases[#cases+1] = cut
    end
end

-- Deterministic mutations of realistic snippets: delete / insert / swap / truncate.
local snippets = {
    [=[
---@class Animal
---@field name string
---@field age? integer
local Animal = {}
Animal.__index = Animal

---@param name string
---@return Animal
function Animal.new(name)
    return setmetatable({ name = name }, Animal)
end

---@generic T: Animal
---@param self T
---@return T
function Animal:clone() return Animal.new(self.name) end
]=],
    [=[
---@alias Handler fun(ev: string, ...: any): boolean?
---@type table<string, Handler[]>
local handlers = {}

---@param name string
---@param h Handler
local function on(name, h)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], h)
end

for k, list in pairs(handlers) do
    for i = #list, 1, -1 do
        if not list[i]('x') then goto continue end
        ::continue::
    end
end
]=],
    [=[
local M = {}
---@enum Color
local Color = { red = 1, green = 2 }
---@overload fun(a: integer): string
---@param a integer|string
---@param b? Color
---@return string?, integer
function M.f(a, b)
    local t <const> = { [1] = a, x = b, f = function (self, ...) return ... end }
    while a do repeat a = a - 1 until a < 0 end
    return t.x and tostring(t.x) or nil, #t
end
return M
]=],
}

local rngState = 12345
---@param n integer
---@return integer
local function rand(n)
    rngState = (rngState * 1103515245 + 12345) % 2147483648
    return rngState % n + 1
end

local punct = { '[', ']', '(', ')', '{', '}', ',', '.', ':', '=', '<', '>', '|', '?', '"', "'", '-', '@', '#', ' ', '\n' }
for _, snippet in ipairs(snippets) do
    for _ = 1, 120 do
        local text = snippet
        for _ = 1, rand(3) do
            local at = rand(#text)
            local kind = rand(4)
            if kind == 1 then
                text = text:sub(1, at - 1) .. text:sub(at + 1)
            elseif kind == 2 then
                text = text:sub(1, at) .. punct[rand(#punct)] .. text:sub(at + 1)
            elseif kind == 3 then
                local other = rand(#text)
                text = text:sub(1, at - 1) .. text:sub(other, other) .. text:sub(at + 1)
            else
                text = text:sub(1, at)
            end
        end
        cases[#cases+1] = text
    end
end

-- token soup: keywords, doc tags, punctuation and names in random order
local vocab = {
    'local', 'function', 'end', 'if', 'then', 'else', 'for', 'in', 'do', 'while', 'repeat', 'until', 'return',
    'goto', 'global', 'nil', 'true', 'false', 'and', 'or', 'not', 'x', 'y', 'M', 'self', '...', '1', '"s"',
    '{', '}', '(', ')', '[', ']', ',', ';', ':', '.', '=', '==', '..', '<const>', '<close>', '::',
    '---@class', '---@param', '---@return', '---@type', '---@field', '---@alias', '---@generic',
    '---@overload', '---@cast', '---@diagnostic', '---@secret', 'fun(', '|', '?', 'integer', 'string',
    '\n', '\n', ' ',
}
for _ = 1, 150 do
    ---@type string[]
    local parts = {}
    for _ = 1, 20 + rand(60) do
        parts[#parts+1] = vocab[rand(#vocab)]
    end
    cases[#cases+1] = table.concat(parts, ' ')
end
-- byte-level damage: random bytes, including invalid UTF-8 and NUL, inside a realistic snippet
for _, snippet in ipairs(snippets) do
    for _ = 1, 30 do
        local text = snippet
        for _ = 1, 1 + rand(4) do
            local at = rand(#text)
            text = text:sub(1, at - 1) .. string.char(rand(256) - 1) .. text:sub(at + 1)
        end
        cases[#cases+1] = text
    end
end

for _, text in ipairs(cases) do
    do
        files.setText(TESTURI, text)
        local state = files.getState(TESTURI)
        -- (positions, as the requests give them: `#text` would only cover the first line)
        try('semantic-tokens', text, semantic, TESTURI, 0, math.huge)
        try('semantic-tokens/range', text, semantic, TESTURI, 10000, 30000)
        try('document-symbol', text, symbols, TESTURI)
        try('folding', text, folding, TESTURI)
        try('inlay-hint', text, hint, TESTURI, 0, math.huge)
        try('workspace-symbol', text, wsSymbol, '', TESTURI)
        try('diagnostics', text, diagnostics, TESTURI, false, function () end)
        try('formatting', text, formatting, TESTURI, {})
        try('color', text, color.colors, TESTURI)
        try('code-lens', text, codeLens.codeLens, TESTURI)
        try('psi-view', text, psiView, TESTURI)
        try('doc-export', text, docExport, TESTURI)
        try('range-formatting', text, rangeFormatting, TESTURI,
            { start = { line = 0, character = 0 }, ['end'] = { line = 2, character = 0 } }, {})
        for off = 1, #text + 1, 7 do
            try('code-action', text, codeAction, TESTURI, off, off + 3, {})
        end
        for off = 1, #text + 1, 2 do
            local pos = state and guide.offsetToPosition(state, off) or off
            for name, fn in pairs(features) do
                try(name, text, fn, TESTURI, pos)
            end
        end
        files.remove(TESTURI)
    end
end

-- What a user plugin (`Lua.runtime.plugin`) can hand back is arbitrary: the server must survive it.
-- Every hook gets a rotating set of odd results (wrong types, broken diffs, errors) while the
-- same cases are read by the features again.
local scope = require 'workspace.scope'

---@type (fun(text: string): any)[]
local oddTexts = {
    function () return nil end,
    function () return '' end,
    function (text) return text:sub(1, #text // 2) end,
    function (text) return text .. '\n---@class' end,
    function () return 42 end,
    function () return true end,
    function () return {} end,
    function () return { { start = 1, finish = 0, text = '' } } end,
    function (text) return { { start = 0, finish = #text + 50, text = 'x' } } end,
    function () return { { start = 3, finish = 1, text = 'x' } } end,
    function () return { { start = 1, finish = 2, text = 5 } } end,
    function () return { 'not a diff', 7 } end,
    function () return { { start = 1, finish = 2, text = 'a' }, { start = 2, finish = 3, text = 'b' } } end,
    function () error('plugin failure') end,
    function () return string.char(0, 255, 254) end,
}
---@type (fun(uri: uri, ast: any): any)[]
local oddTrees = {
    function () return nil end,
    function () return 'not a tree' end,
    function () return 42 end,
    function (_, ast) return ast end,
    function () error('plugin failure') end,
}
---@type (fun(): any)[]
local oddRequires = {
    function () return nil end,
    function () return 'a string' end,
    function () return {} end,
    function () return { 'file:///nowhere.lua' } end,
    function () return { TESTURI } end,
    function () error('plugin failure') end,
}
---@type (fun(next: function, func: any, source: any): any)[]
local oddParams = {
    function () return nil end,
    function () return true end,
    function () return false end,
    function () return 'x' end,
    function (next, func, source) return next(func, source) end,
    function () error('plugin failure') end,
}

local client   = require 'client'
local oldShow  = client.showMessage
local oldError = log.error
client.showMessage = function () end
log.error = function () end
local pluginCases = 0
for i, text in ipairs(cases) do
    if i % 10 == 0 then
        pluginCases = pluginCases + 1
        local n = pluginCases
        text = text .. '\nlocal m = require "a.b"\nlocal function f(p, q) return p.x + q end\nm.y()\n'
        local interface = {
            OnSetText      = oddTexts[n % #oddTexts + 1],
            OnTransformAst = oddTrees[n % #oddTrees + 1],
            ResolveRequire = oddRequires[n % #oddRequires + 1],
            VM             = { OnCompileFunctionParam = oddParams[n % #oddParams + 1] },
        }
        local scp = scope.getScope(TESTURI)
        scp:set('pluginInterfaces', { interface })
        files.setText(TESTURI, text)
        local state = files.getState(TESTURI)
        local shown = state and state.lua or text
        try('plugin/semantic-tokens', text, semantic, TESTURI, 0, math.huge)
        try('plugin/document-symbol', text, symbols, TESTURI)
        try('plugin/diagnostics', text, diagnostics, TESTURI, false, function () end)
        try('plugin/formatting', text, formatting, TESTURI, {})
        for off = 1, #shown + 1, 17 do
            local pos = state and guide.offsetToPosition(state, off) or off
            for name, fn in pairs(features) do
                try('plugin/' .. name, text, fn, TESTURI, pos)
            end
        end
        files.remove(TESTURI)
        scp:set('pluginInterfaces', nil)
    end
end
client.showMessage = oldShow
log.error = oldError

---@type string[]
local keys = {}
for k in pairs(failures) do keys[#keys+1] = k end
table.sort(keys)
print(('fuzz_doc: %d calls, %d distinct failures'):format(total, #keys))
for _, k in ipairs(keys) do
    local f = failures[k]
    print(('  x%d  %s\n      e.g. %q'):format(f.count, k, f.example))
end
assert(#keys == 0, 'a feature threw on malformed input')
