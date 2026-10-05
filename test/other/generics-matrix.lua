-- Plain generics (no secrets anywhere in this file): what a call of a generic function is typed as, case by case, with
-- what TypeScript does beside each one. One row per case: { name, code, the local to read, the type it must have,
-- note }. A row with a 6th element is a KNOWN GAP: the 4th is what TypeScript says, the 6th is what the engine says
-- today, and the test pins the latter, so a fix shows up here (update the row, move it out of the gaps).
-- The written spec is GENERICS-SPEC.md in the dev repo.
local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'

---@param ... string
---@return string
local function L(...)
    return table.concat({ ... }, string.char(10)) .. string.char(10)
end

---@type string[]
local ID  = { '---@generic T', '---@param v T', '---@return T', 'local function f(v) return v end' }
---@param ... string
---@return string
local function id(...)
    ---@type string[]
    local lines = {}
    for _, line in ipairs(ID) do
        lines[#lines+1] = line
    end
    for _, line in ipairs { ... } do
        lines[#lines+1] = line
    end
    return L(table.unpack(lines))
end

---@type string[][]
local cases = {
    -- binding from one argument
    { 'identity integer',    id('local r = f(1)'),                                        'r', 'integer', '' },
    { 'identity string',     id('local r = f("a")'),                                      'r', 'string',  'TS infers the literal "a"; a Lua string literal is just string' },
    { 'identity boolean',    id('local r = f(true)'),                                     'r', 'boolean', 'TS infers true' },
    { 'identity table',      id('local r = f({1})'),                                      'r', 'table',   'a table literal is viewed as `table` (TS: number[])' },
    { 'nilable argument',    id('---@type number?', 'local m', 'local r = f(m)'),        'r', 'number?', 'TS: number | undefined' },
    { 'union argument',      id('---@type string|number', 'local m', 'local r = f(m)'),  'r', 'string|number', '' },
    { 'nil argument',        id('local r = f(nil)'),                                      'r', 'nil',     'TS: undefined' },
    { 'nested call',         id('local r = f(f(1))'),                                     'r', 'integer', '' },
    -- optional parameter, default, return shapes
    { 'T? return',           L('---@generic T', '---@param v T', '---@return T?', 'local function f(v) return v end', 'local r = f(1)'), 'r', 'integer?', '' },
    { 'optional param',      L('---@generic T', '---@param v? T', '---@return T?', 'local function f(v) return v end', 'local r = f()'), 'r', 'unknown?', 'TS: unknown (nothing to infer from)' },
    { 'default type param',  L('---@generic T = string', '---@param v? T', '---@return T', 'local function f(v) return v end', 'local r = f()'), 'r', 'string', 'TS: a default type parameter' },
    { 'T[] return',          L('---@generic T', '---@param v T', '---@return T[]', 'local function wrap(v) return {v} end', 'local r = wrap(1)'), 'r', 'integer[]', '' },
    { 'second return slot',  L('---@generic T', '---@param v T', '---@return T, boolean', 'local function f(v) return v, true end', 'local a, b = f(1)'), 'b', 'boolean', '' },
    -- containers
    { 'array element',       L('---@generic T', '---@param l T[]', '---@return T', 'local function first(l) return l[1] end', 'local r = first({1, 2})'), 'r', 'integer', '' },
    { 'array of string',     L('---@generic T', '---@param l T[]', '---@return T', 'local function first(l) return l[1] end', '---@type string[]', 'local s', 'local r = first(s)'), 'r', 'string', '' },
    { 'table key',           L('---@generic K, V', '---@param t table<K, V>', '---@return K', 'local function keyOf(t) return next(t) end', '---@type table<string, number>', 'local t', 'local r = keyOf(t)'), 'r', 'string', '' },
    { 'table value',         L('---@generic K, V', '---@param t table<K, V>', '---@return V', 'local function valOf(t) return select(2, next(t)) end', '---@type table<string, number>', 'local t', 'local r = valOf(t)'), 'r', 'number', '' },
    { 'string-keyed table',  L('---@generic T', '---@param t table<string, T>', '---@return T', 'local function anyOf(t) return next(t) end', '---@type table<string, boolean>', 'local t', 'local r = anyOf(t)'), 'r', 'boolean', '' },
    { 'array of the same T', L('---@generic T', '---@param a T', '---@param b T', '---@return T[]', 'local function two(a, b) return {a, b} end', 'local r = two(1, 2)'), 'r', 'integer[]', '' },
    -- callbacks
    { 'callback result',     L('---@generic T', '---@param fn fun(): T', '---@return T', 'local function call(fn) return fn() end', 'local r = call(function() return 1 end)'), 'r', 'integer', '' },
    { 'callback parameter',  L('---@generic T', '---@param l T[]', '---@param fn fun(x: T)', 'local function each(l, fn) end', 'each({"a"}, function(x) local inner = x end)'), 'inner', 'string', 'the callback parameter is typed from the list' },
    { 'map',                 L('---@generic T, U', '---@param l T[]', '---@param fn fun(x: T): U', '---@return U[]', 'local function map(l, fn) return {} end', 'local r = map({1, 2}, function(x) return tostring(x) end)'), 'r', 'string[]', '' },
    -- several type parameters
    { 'two params, second',  L('---@generic A, B', '---@param a A', '---@param b B', '---@return A, B', 'local function pair(a, b) return a, b end', 'local x, y = pair(1, "s")'), 'y', 'string', '' },
    { 'two params, first',   L('---@generic A, B', '---@param a A', '---@param b B', '---@return A, B', 'local function pair(a, b) return a, b end', 'local x, y = pair(1, "s")'), 'x', 'integer', '' },
    { 'wrapper in a generic', L('---@generic T', '---@param v T', '---@return T', 'local function id(v) return v end', '---@generic U', '---@param v U', '---@return U', 'local function wrap(v) return id(v) end', 'local r = wrap("x")'), 'r', 'string', '' },
    -- several parameters of the SAME T: the first one binds the type (the generic-param-mismatch diagnostic checks the rest)
    { 'same T, widening',    L('---@generic T', '---@param a T', '---@param b T', '---@return T', 'local function pick(a, b) return a end', 'local r = pick(1, 2.5)'), 'r', 'integer', 'first candidate binds T; TS unifies to number', 'integer' },
    { 'same T, union later', L('---@generic T', '---@param a T', '---@param b T', '---@return T', 'local function pick(a, b) return a end', '---@type string|number', 'local m', 'local r = pick(1, m)'), 'r', 'integer', 'first candidate binds T; TS: string | number', 'integer' },
    -- varargs, constraints, function types
    { 'vararg',              L('---@generic T', '---@param ... T', '---@return T', 'local function first(...) return ... end', 'local r = first(1, 2)'), 'r', 'integer', '' },
    { 'constraint',          L('---@generic T: number', '---@param v T', '---@return T', 'local function f(v) return v end', 'local r = f(1)'), 'r', 'integer', 'the result keeps the argument type, not the bound' },
    { 'generic function type', L('---@type fun<T>(v: T): T', 'local f', 'local r = f(1)'), 'r', 'integer', '' },
    -- class generics
    { 'class field',         L('---@class Box<T>', '---@field value T', 'local Box = {}', '---@type Box<number>', 'local b', 'local r = b.value'), 'r', 'number', '' },
    { 'class method',        L('---@class Box<T>', 'local Box = {}', '---@return T', 'function Box:get() end', '---@type Box<string>', 'local b', 'local r = b:get()'), 'r', 'string', '' },
    { 'class inheritance',   L('---@class Box<T>', '---@field value T', '---@class IntBox : Box<integer>', 'local ib', 'local r = ib.value'), 'r', 'integer', '' },
    { 'self type',           L('---@class Chain', 'local Chain = {}', '---@generic T', '---@param self T', '---@return T', 'function Chain.me(self) return self end', '---@type Chain', 'local c', 'local r = c:me()'), 'r', 'Chain', '' },
    { 'generic class result', L('---@class Prom<T>', '---@field value T', '---@generic T', '---@param v T', '---@return Prom<T>', 'local function resolve(v) return {} end', 'local r = resolve(1).value'), 'r', 'integer', '' },
    -- keyof and indexed access: classes, inline object types and table literals alike
    { 'keyof class',         L('---@class P', '---@field name string', '---@field age number', '---@generic T', '---@param t T', '---@return keyof T', 'local function keys(t) end', '---@type P', 'local o', 'local r = keys(o)'), 'r', '"age"|"name"', '' },
    { 'keyof inline type',   L('---@generic T', '---@param t T', '---@return keyof T', 'local function keys(t) end', '---@type {name: string, age: number}', 'local o', 'local r = keys(o)'), 'r', '"age"|"name"', '' },
    { 'keyof table literal', L('---@generic T', '---@param t T', '---@return keyof T', 'local function keys(t) end', 'local o = {name = "x", age = 1}', 'local r = keys(o)'), 'r', '"age"|"name"', '' },
    { 'T["key"] class',      L('---@class P', '---@field age number', '---@generic T', '---@param t T', '---@return T["age"]', 'local function get(t) return t.age end', '---@type P', 'local o', 'local r = get(o)'), 'r', 'number', '' },
    { 'T["key"] inline type', L('---@generic T', '---@param t T', '---@return T["age"]', 'local function get(t) return t.age end', '---@type {name: string, age: number}', 'local o', 'local r = get(o)'), 'r', 'number', '' },
    { 'T["key"] table literal', L('---@generic T', '---@param t T', '---@return T["age"]', 'local function get(t) return t.age end', 'local o = {name = "x", age = 1}', 'local r = get(o)'), 'r', 'integer', '' },
    { 'T[K] class',          L('---@class P', '---@field name string', '---@field age number', '---@generic T, K: keyof T', '---@param t T', '---@param k K', '---@return T[K]', 'local function get(t, k) return t[k] end', '---@type P', 'local o', 'local r = get(o, "age")'), 'r', 'number', 'TS: the classic get<T, K extends keyof T>' },
    { 'T[K] inline type',    L('---@generic T, K: keyof T', '---@param t T', '---@param k K', '---@return T[K]', 'local function get(t, k) return t[k] end', '---@type {name: string, age: number}', 'local o', 'local r = get(o, "age")'), 'r', 'number', '' },
    { 'T[K] table literal',  L('---@generic T, K: keyof T', '---@param t T', '---@param k K', '---@return T[K]', 'local function get(t, k) return t[k] end', 'local o = {name = "x", age = 1}', 'local r = get(o, "age")'), 'r', 'integer', '' },
    { 'T["key"] missing key', L('---@generic T', '---@param t T', '---@return T["nope"]', 'local function get(t) end', '---@type {name: string}', 'local o', 'local r = get(o)'), 'r', 'unknown', 'no such member: unknown, like T[K] on a class' },
    { 'keyof a number',      L('---@generic T', '---@param t T', '---@return keyof T', 'local function keys(t) end', 'local r = keys(1)'), 'r', 'string', 'not an object shape: plain string' },
    { 'keyof empty literal', L('---@generic T', '---@param t T', '---@return keyof T', 'local function keys(t) end', 'local o = {}', 'local r = keys(o)'), 'r', 'string', 'no members: plain string' },
    { 'T[K] missing key',    L('---@generic T, K', '---@param t T', '---@param k K', '---@return T[K]', 'local function get(t, k) return t[k] end', 'local o = {name = "x"}', 'local r = get(o, "age")'), 'r', 'unknown', 'no such member: unknown' },
    -- containers of containers, callbacks returning containers, nested function types
    { 'nested array typed',  L('---@generic T', '---@param l T[][]', '---@return T', 'local function f(l) return l[1][1] end', '---@type string[][]', 'local s', 'local r = f(s)'), 'r', 'string', '' },
    { 'nested array literal', L('---@generic T', '---@param l T[][]', '---@return T', 'local function f(l) return l[1][1] end', 'local r = f({{1}})'), 'r', 'integer', 'a nested table literal binds T (it used to stay <T>: the literal was typed as the expected T[])' },
    { 'nested literal, two rows', L('---@generic T', '---@param l T[][]', '---@return T', 'local function f(l) return l[1][1] end', 'local r = f({{1}, {2}})'), 'r', 'integer', '' },
    { 'nested literal, strings', L('---@generic T', '---@param l T[][]', '---@return T', 'local function f(l) return l[1][1] end', 'local r = f({{"a"}})'), 'r', 'string', '' },
    { 'nested, row in a local', L('---@generic T', '---@param l T[][]', '---@return T', 'local function f(l) return l[1][1] end', 'local row = {true}', 'local r = f({row})'), 'r', 'boolean', '' },
    { 'nested, local table', L('---@generic T', '---@param l T[][]', '---@return T', 'local function f(l) return l[1][1] end', 'local x = {{1}}', 'local r = f(x)'), 'r', 'integer', '' },
    { 'table of arrays',     L('---@generic K, T', '---@param t table<K, T[]>', '---@return T', 'local function f(t) return next(t)[1] end', '---@type table<string, boolean[]>', 'local s', 'local r = f(s)'), 'r', 'boolean', '' },
    { 'array of tables',     L('---@generic T', '---@param l table<string, T>[]', '---@return T', 'local function f(l) return next(l[1]) end', '---@type table<string, number>[]', 'local s', 'local r = f(s)'), 'r', 'number', '' },
    { 'callback returns array', L('---@generic T, U', '---@param l T[]', '---@param fn fun(x: T): U[]', '---@return U[]', 'local function flat(l, fn) return {} end', 'local r = flat({1}, function(x) return {"a"} end)'), 'r', 'string[]', '' },
    { 'nested function type', L('---@generic T', '---@param f fun(): fun(): T', '---@return T', 'local function f(g) return g()() end', 'local r = f(function() return function() return 1 end end)'), 'r', 'integer', 'a callback that returns a callback does not bind T', 'unknown' },
    -- aliases, builders, methods, tuples
    { 'generic alias, table', L('---@alias Dict<V> table<string, V>', '---@type Dict<number>', 'local d', 'local r = d.x'), 'r', 'number', '' },
    { 'generic alias, param', L('---@alias Maybe<T> T?', '---@param v Maybe<string>', 'local function f(v) local inner = v end'), 'inner', 'string?', 'the alias is shown next to its expansion', '(string|Maybe<string>)?' },
    { 'generic alias, return', L('---@alias Maybe<T> T?', '---@generic T', '---@param v T', '---@return Maybe<T>', 'local function wrap(v) return v end', 'local r = wrap(1)'), 'r', 'integer?', 'the alias name is shown, not its expansion', 'Maybe<integer>?' },
    { 'builder chain',       L('---@class Box<T>', '---@field value T', 'local Box = {}', '---@generic U', '---@param v U', '---@return Box<U>', 'function Box.of(v) return {} end', '---@generic U', '---@param fn fun(x: T): U', '---@return Box<U>', 'function Box:map(fn) return {} end', 'local r = Box.of(1):map(function(x) return tostring(x) end).value'), 'r', 'string', '' },
    { 'T|nil parameter',    L('---@generic T', '---@param v T|nil', '---@return T', 'local function f(v) return v end', 'local r = f(1)'), 'r', 'integer', '' },
    { 'generic function in a table', L('local util = {}', '---@generic T', '---@param v T', '---@return T', 'function util.id(v) return v end', 'local r = util.id("s")'), 'r', 'string', '' },
    { 'generic method',     L('---@class Cls', 'local Cls = {}', '---@generic T', '---@param v T', '---@return T', 'function Cls:echo(v) return v end', '---@type Cls', 'local c', 'local r = c:echo(1)'), 'r', 'integer', '' },
    { 'varargs to array',   L('---@generic T', '---@param ... T', '---@return T[]', 'local function all(...) return {...} end', 'local r = all(1, 2)'), 'r', 'integer[]', '' },
    { 'T twice',            L('---@generic T', '---@param v T', '---@return T, T', 'local function twice(v) return v, v end', 'local a, b = twice(1)'), 'b', 'integer', '' },
    { 'recursive generic',  L('---@generic T', '---@param v T', '---@return T', 'local function rec(v) if v then return rec(v) end return v end', 'local r = rec(1)'), 'r', 'integer', '' },
    { 'constraint with a class', L('---@class Pt', '---@field x number', '---@generic T: table', '---@param v T', '---@return T', 'local function f(v) return v end', '---@type Pt', 'local p', 'local r = f(p)'), 'r', 'Pt', '' },
    { 'self return, chained', L('---@class Fluent', 'local Fluent = {}', '---@return self', 'function Fluent:set() return self end', '---@type Fluent', 'local f', 'local r = f:set():set()'), 'r', 'Fluent', '' },
    { 'nilable array argument', L('---@generic T', '---@param l T[]?', '---@return T?', 'local function first(l) return l and l[1] end', 'local r = first(nil)'), 'r', 'unknown?', '' },
    { 'tuple result',       L('---@generic A, B', '---@param a A', '---@param b B', '---@return [A, B]', 'local function t(a, b) return {a, b} end', 'local r = t(1, "s")'), 'r', '[integer, string]', 'a tuple is viewed as a table with indices', '{ [1]: integer, [2]: string }' },
    { 'pcall result',       L('local function f() return 1 end', 'local ok, r = pcall(f)'), 'r', 'integer', '' },
    { 'K itself',            L('---@generic T, K: keyof T', '---@param t T', '---@param k K', '---@return K', 'local function key(t, k) return k end', '---@type {name: string, age: number}', 'local o', 'local r = key(o, "age")'), 'r', '"age"', 'TS: K is the literal "age"', 'string' },
}

for _, case in ipairs(cases) do
    local name, code, var, expected, note, actualGap = table.unpack(case)
    files.setText(TESTURI, code)
    local state = assert(files.getState(TESTURI))
    ---@type string?
    local got
    guide.eachSourceType(state.ast, 'local', function (source)
        if source[1] == var then
            got = vm.getInfer(source):view(TESTURI)
        end
    end)
    local want = actualGap or expected
    assert(got == want, ('generics matrix `%s`: got `%s`, %s `%s` (%s)'):format(
        name, tostring(got), actualGap and 'the pinned gap value is' or 'expected', want, note))
end
files.remove(TESTURI)
