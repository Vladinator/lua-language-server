-- Robustness: truncated / malformed doc comments must never make a language
-- feature throw. Every prefix (cut at token boundaries) of a set of doc tags is
-- bound to some code, then each feature is asked about many positions.
local files = require 'files'
local guide = require 'parser.guide'

---@async
---@param uri uri
---@param pos integer
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
    completion  = require 'core.completion'.completion,
    rename      = require 'core.rename'.prepareRename,
}
local semantic = require 'core.semantic-tokens'
local symbols  = require 'core.document-symbol'
local folding  = require 'core.folding'
local hint     = require 'core.hint'
local diagnostics = require 'core.diagnostics'
local codeAction = require 'core.code-action'
local wsSymbol = require 'core.workspace-symbol'
local formatting = require 'core.formatting'

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
    '---@secret a, b, c',
    '---@secret a b c',
    '---@secret-unwrap x, y',
    '---@secret-check',
    '---@version >5.1, JIT',
    '---@source file:///x.lua#1:2',
    '---@vararg string',
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

for _, text in ipairs(cases) do
    do
        files.setText(TESTURI, text)
        local state = files.getState(TESTURI)
        try('semantic-tokens', text, semantic, TESTURI, 0, #text)
        try('document-symbol', text, symbols, TESTURI)
        try('folding', text, folding, TESTURI)
        try('inlay-hint', text, hint, TESTURI, 0, #text)
        try('workspace-symbol', text, wsSymbol, '', TESTURI)
        try('diagnostics', text, diagnostics, TESTURI, false, function () end)
        try('formatting', text, formatting, TESTURI, {})
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
