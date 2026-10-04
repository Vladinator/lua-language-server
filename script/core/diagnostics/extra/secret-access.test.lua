-- Lives next to secret-access.lua on purpose: this test only runs if
-- its plugin does too (see the checkPluginDir scan in
-- test/diagnostics/init.lua), so deleting the plugin also removes its
-- test with nothing left over to update elsewhere.

-- (the file is named after one of the five codes the plugin registers: its tests care about all of them)
DIAG_CARE = {
    ['secret-arithmetic'] = true,
    ['secret-comparison'] = true,
    ['secret-condition']  = true,
    ['secret-table-key']  = true,
    ['secret-access']     = true,
}

TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-check
---@param v any
---@return boolean
local function chk(v) return false end

local x = f()
print(x)
print(<!x!> + 5)
]]

TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-check
---@param v any
---@return boolean
local function chk(v) return false end

local x = f()
if not chk(x) then
    print(x + 5)
else
    print(<!x!> + 5)
end
]]

-- The result of a call is a use like any other read: an operand, an index base, a condition or a table key is checked
-- where it stands, not only after it was stored in a local (found 2026-10-04: `GetSecretNumber() + 1` was silent).
TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret
---@return string
local function s() return '' end

---@secret
---@return boolean
local function b() return false end

local t = {}
print(<!f()!> + 1)
print(-<!f()!>)
print(<!s()!> == 'x')
print(<!s()!>:upper())
print(#<!s()!>)
t[<!f()!>] = 1
if <!b()!> then end
print(not <!b()!>)
-- (not a use of the value: argument, assignment, concatenation, statement, a `local`)
print(f())
local x = f()
print(s() .. 'x')
f()
local y = (f())
]]

-- parentheses around a secret read do not hide it
TEST [[
---@secret
---@return number
local function f() return 0 end

local x = f()
print(<!(x)!> + 1)
print(<!(f())!> + 1)
local y = (x)
]]

-- a `nosecret` return is a sanitiser: whatever secrecy a generic result would inherit stops there. Without the
-- declaration (`---@return T`) the secrecy of the argument is inherited.
TEST [[
---@secret
---@return number
local function f() return 0 end

---@generic T
---@param v T
---@param fallback? nosecret<T>
---@return nosecret<T>
local function clean(v, fallback) return v end

---@generic T
---@param v T
---@return T
local function keep(v) return v end

---@param v any
---@return nosecret number
local function plain(v) return 0 end

---@param v any
---@return nosecret string, any
local function slots(v) return '', v end

local x = f()
print(clean(x, 2) + 5)
local a = clean(x, 2)
print(a + 5)
print(plain(x) + 5)
local first = slots(x)
print(first .. 'x')
print(<!keep(x)!> + 5)
local b = keep(x)
print(<!b!> + 5)
]]

-- only the declared slot is clean: the other one of the same function still carries the secrecy of `T`
TEST [[
---@secret
---@return number
local function f() return 0 end

---@generic T
---@param v T
---@return nosecret string, T
local function pair(v) return '', v end

local x = f()
local c, d = pair(x)
print(c .. 'x')
print(<!d!> + 1)
]]

-- the same on an `---@overload` signature (no fallback: `T?`): the overload's return is a signature of its own
TEST [[
---@secret
---@return number
local function f() return 0 end

---@generic T
---@param v T
---@param fallback nosecret<T>
---@return nosecret<T>
---@overload fun<T>(v: T): nosecret<T>?
local function clean(v, fallback) return v end

---@generic T
---@param v T
---@param fallback T
---@return T
---@overload fun<T>(v: T): T?
local function keep(v, fallback) return v end

local x = f()
print(clean(x) + 1)
print(clean(x, 2) + 1)
local a = clean(x)
print(a + 1)
print(<!keep(x)!> + 1)
print(<!keep(x, 2)!> + 1)
]]

-- a secret that enters a generic through a LATER argument of the same `T` (the type of `T` is the first one's, the
-- secrecy of every argument comes out of it), and through the return of a callback typed `fun(): T`
TEST [[
---@secret
---@return number
local function f() return 0 end

---@generic T
---@param first T
---@param second T
---@return T
local function pick(first, second) return first end

---@generic T
---@param fn fun(): T
---@return T
local function call(fn) return fn() end

---@generic T
---@param fn fun(): T
---@return nosecret<T>
local function callClean(fn) return fn() end

---@secret
---@return number
function GlobalSecret() return 0 end

local x = f()
print(<!pick(x, 1)!> + 1)
print(<!pick(1, x)!> + 1)
print(pick(1, 2) + 1)
print(<!call(f)!> + 1)
print(<!call(GlobalSecret)!> + 1)
print(callClean(GlobalSecret) + 1)
print(callClean(f) + 1)
print(call(function() return 1 end) + 1)
]]

-- the same through a table the function is exported in (a shared namespace), read through an alias
TEST [[
---@secret
---@return number
local function f() return 0 end

---@generic T
---@param v T
---@return nosecret<T>
local function clean(v) return v end

---@generic T
---@param v T
---@return T
local function keep(v) return v end

local ns = { Util = { clean = clean, keep = keep } }
local aliasClean = ns.Util.clean
local x = f()
print(aliasClean(x) + 1)
print(ns.Util.clean(x) + 1)
print(<!ns.Util.keep(x)!> + 1)
]]

-- `secretguard` on a non-first parameter: the check narrows whichever argument it marks, not
-- just the first one (2026-09-27, closes the gap found comparing against wowlua-ls)
-- (`secretguard`, the earlier spelling, stays an alias: tested right after)
TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-check
---@param a any
---@param b secretguard any
local function chk2(a, b) return false end

local x = f()
local y = f()
if not chk2(y, x) then
    print(x + 5)
else
    print(<!x!> + 5)
end
]]

-- `---@secret-guard <param> <kind>` (wowlua-ls's spelling of the check tags, naming the checked parameter):
-- `accessible` = @secret-access-check (true: safe), `is-secret` / `any-secret` = @secret-check (true: secret)
TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-guard value accessible
---@param value any
---@return boolean
local function canAccess(value) return true end

local x = f()
if canAccess(x) then
    print(x + 5)
else
    print(<!x!> + 6)
end
]]

TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-guard value is-secret
---@param value any
---@return boolean
local function isSecret(value) return true end

---@secret-guard value any-secret
---@param value any
---@return boolean
local function anySecret(value) return true end

local x = f()
if isSecret(x) then
    print(<!x!> + 5)
else
    print(x + 6)
end
if anySecret(x) then
    print(<!x!> + 5)
else
    print(x + 6)
end
]]

-- the named parameter is the one that narrows, not the first
TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-guard b is-secret
---@param a any
---@param b any
---@return boolean
local function chk(a, b) return true end

local x = f()
local y = f()
if not chk(y, x) then
    print(x + 5)
end
if not chk(x, y) then
    print(<!x!> + 5)
end
]]

-- `secretcheck` and `secretcheck<T>`: the earlier spelling, an alias with the same behavior
TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-check
---@param a any
---@param b secretcheck any
local function chk2(a, b) return false end

---@secret-check
---@param a any
---@param b secretcheck<any>
local function chk3(a, b) return false end

local x = f()
local y = f()
if not chk2(y, x) then
    print(x + 5)
end
if not chk3(y, x) then
    print(x + 5)
end
]]

-- `secretguard<T>` (the generic-wrapper spelling) is pure sugar for the `secretguard T` prefix
-- form -- same behavior, same narrowing
TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-check
---@param a any
---@param b secretguard<any>
local function chk2(a, b) return false end

local x = f()
local y = f()
if not chk2(y, x) then
    print(x + 5)
else
    print(<!x!> + 5)
end
]]

-- without `secretguard` on either parameter, only the first still narrows -- the pre-existing,
-- backward-compatible default
TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-check
---@param a any
---@param b any
local function chk2(a, b) return false end

local x = f()
local y = f()
if not chk2(y, x) then
    print(<!x!> + 5)
end
]]

-- two parameters both marked `secretguard`: both narrow together on the same call, the
-- equivalent of a multi-value guard like `canaccessallvalues(a, b)`
TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-check
---@param a secretguard any
---@param b secretguard any
local function chk3(a, b) return false end

local x = f()
local y = f()
if not chk3(x, y) then
    print(x + 5)
    print(y + 5)
else
    print(<!x!> + 5)
    print(<!y!> + 5)
end
]]

-- a secret-check function reached through a field, then aliased to a local (`local chk =
-- t.chk`): the alias's own declaration isn't a function literal, so isDirectOrAliasedSecretCheck
-- has to chase one more hop through the field it was assigned from
TEST [[
---@secret
---@return number
local function f() return 0 end

local t = {}

---@secret-check
---@param v any
---@return boolean
function t.chk(v) return false end

local chk = t.chk

local x = f()
if not chk(x) then
    print(x + 5)
else
    print(<!x!> + 5)
end
]]

TEST [[
---@secret
---@return boolean
local function f() return false end

local x = f()
if <!x!> then end
]]

TEST [[
---@secret
---@return number
local function f() return 0 end

local x = f()
print(#<!x!>)
]]

TEST [[
---@class A
---@field a number
---@field secret b number

local function f()
    ---@type A
    return { a = 0, b = 0 }
end

local x = f()
print(x.a + 5)
print(<!x.b!> + 5)
]]

TEST [[
---@secret
---@class A
---@field a number

local function f()
    ---@type A
    return { a = 0 }
end

local x = f()
print(<!x!>.a)
]]

TEST [[
---@secret
---@class A
---@field a number

local function f()
    ---@type A
    return { a = 0 }
end

local x = f()
<!x!>.a = 1
]]

TEST [[
---@secret
---@return number
local function f() return 0 end

local x = f()
print(x .. "")
]]

TEST [[
---@secret
---@return number
local function f() return 0 end

local x = f()
local t = {}
t[<!x!>] = true
]]

TEST [[
---@secret
---@class A
---@field a number

local function f()
    ---@type A
    return { a = 0 }
end

local x = f()
for k, v in pairs(<!x!>) do end
]]

TEST [[
---@secret
---@return number
local function f() return 0 end

local x = f()
<!x!>()
]]

TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-access-check
---@param v any
---@return boolean
local function ok(v) return false end

local x = f()
if ok(x) then
    print(x + 5)
else
    print(<!x!> + 5)
end
]]

TEST [[
---@secret
---@return boolean
local function f() return false end

local x = f()
if <!x!> then end
if not <!x!> then end
]]

TEST [[
---@secret
---@return number
local function f() return 0 end

local x = f()
print(-<!x!>)
]]

TEST [[
---@secret
---@class A
---@field a number

local function f()
    ---@type A
    return { a = 0 }
end

local x = f()
next(<!x!>)
]]

TEST [[
---@secret
---@generic T
---@param v T
---@return T
local function pass(v) return v end

---@secret
---@return number
local function f() return 0 end

local x = pass(f())
print(<!x!> + 5)
]]

TEST [[
---@secret
---@return number
local function f() return 0 end

local x = f()
local t = type(x)
print(t == "number")
]]

-- 直接对字段（非局部变量）判空/判密同样应生效（field-path narrowing）

TEST [[
---@secret-check
local function issecretvalue(v) return false end

---@class A
---@field secret s number
local t = { s = 0 }

print(<!t.s!> + 5)
if not issecretvalue(t.s) then
    print(t.s + 5)
end
]]

TEST [[
---@secret-check
local function issecretvalue(v) return false end

---@class A
---@field secret s number
local t = { s = 0 }

-- 未经过判密守卫的分支仍应触发
if not issecretvalue(t.s) then
else
    print(<!t.s!> + 5)
end
]]

TEST [[
---@secret-check
local function issecretvalue(v) return false end

---@class A
---@field secret s number
local t = { s = 0 }

-- 显式重新赋值字段后，窄化依旧生效
t.s = 1
if not issecretvalue(t.s) then
    print(t.s + 5)
end
]]

TEST [[
---@secret-check
local function issecretvalue(v) return false end

---@class A
---@field secret s number
local t1 = { s = 0 }

-- 通过别名访问的字段是独立追踪的路径，需要各自的守卫
local t2 = t1

print(<!t2.s!> + 5)
if not issecretvalue(t2.s) then
    print(t2.s + 5)
end
]]

-- `---@secret b` before a multi-local declaration marks only `b`
TEST [[
---@secret b
local a, b = 1, 2
print(a + 5)
print(<!b!> + 5)
]]

-- a name list can name several
TEST [[
---@secret a, c
local a, b, c = 1, 2, 3
print(<!a!> + 5)
print(b + 5)
print(<!c!> + 5)
]]

-- no list: every local of the statement, as before
TEST [[
---@secret
local a, b = 1, 2
print(<!a!> + 5)
print(<!b!> + 5)
]]

-- a description after the tag is still just a comment (not a name list)
TEST [[
---@secret the api token
local a = 1
print(<!a!> + 5)
]]

-- `---@secret-unwrap` on a declaration drops inherited secrecy (here: a secret class type)
TEST [[
---@secret
---@class A
---@field a number

local function f()
    ---@type A
    return { a = 0 }
end

---@secret-unwrap
local x = f()
print(x.a)
]]

-- ...only for the named local
TEST [[
---@secret
---@class A
---@field a number

local function f()
    ---@type A
    return { a = 0 }
end

---@secret-unwrap y
local x, y = f(), f()
print(<!x!>.a)
print(y.a)
]]

-- a `---@secret-unwrap` function is a sanitizer: its results are plain
TEST [[
---@secret
---@class A
---@field a number

---@secret-unwrap
---@return A
local function open() return { a = 0 } end

local s = open()
print(s.a)
]]

-- `secret` in front of a type item marks exactly that item of a type list
TEST [[
---@type number, secret string, boolean
local a, b, c = 1, 'x', true
print(a + 5)
print(<!b!>:len())
print(c and 1)
]]

-- ...on a parameter
TEST [[
---@param token secret string
local function f(token)
    print(<!token!>:len())
end
]]

-- ...an optional secret parameter of a method: passing it on is fine, using it is not until it is
-- checked (the check clears the secret, not the `?`)
TEST [[
local ns = {}

---@secret-check
---@param v any
---@return boolean
local function issecretvalue(v) return false end

---@param guidOrUnit secret string?
---@return number? id
function ns:UnitID(guidOrUnit)
    print(guidOrUnit)
    print(#<!guidOrUnit!>)
    print(<!guidOrUnit!>:upper())
    if not issecretvalue(guidOrUnit) then
        print(#guidOrUnit)
    end
end

ns:UnitID('abc')
]]

-- ...on a return value
TEST [[
---@return secret string
local function f() return 'x' end

local x = f()
print(<!x!>:len())
]]

-- ...and combined with an optional/union type
TEST [[
---@type secret string?
local s
print(<!s!>:len())
]]

-- `secret<T>` (the generic-wrapper spelling) is pure sugar for the `secret T` prefix form -- same
-- behavior, same diagnostic, on a local, a parameter and a return value
TEST [[
---@type secret<string>?
local s
print(<!s!>:len())
]]

TEST [[
---@param token secret<string>
local function f(token)
    print(<!token!>:len())
end
]]

TEST [[
---@return secret<string>
local function f() return 'x' end

local x = f()
print(<!x!>:len())
]]

-- the flag also survives a generic identity call, an array element read and a union member
-- (it was dropped when the node was rebuilt from the bound type, 2026-10-02)
TEST [[
---@generic T
---@param v T
---@return T
local function id(v) return v end

---@secret
---@return string
local function f() return 'x' end

local s = f()
local t = id(s)
print(<!t!>:len())
local u = id('plain')
print(u:len())
]]

TEST [[
---@type secret<string>[]
local arr = {}
print(<!arr[1]!>:len())
]]

TEST [[
---@type string[]
local arr = {}
print(arr[1]:len())
]]

TEST [[
---@type secret<string>|number
local un
print(<!un!> + 1)
]]

-- a boolean local holding a guard call's own result (`local isSecretVal = issecretvalue(x)`)
-- narrows the same way the guard call would narrow directly as the condition -- `false` = safe,
-- not negated (flow.lua's `local x = f()` wraps a single-value call RHS in a `select` node;
-- the alias-registration scan missed it, so nothing composed, 2026-10-01)
TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-check
---@param v any
---@return boolean
local function chk(v) return false end

local x = f()
local isSecretVal = chk(x)
if isSecretVal then
    print(<!x!> + 5)
else
    print(x + 5)
end
]]

-- same shape, negated (the originally reported gap)
TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-check
---@param v any
---@return boolean
local function chk(v) return false end

local x = f()
local isSecretVal = chk(x)
if not isSecretVal then
    print(x + 5)
end
]]

-- same alias composition, `---@secret-access-check` polarity (`true` = safe)
TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-access-check
---@param v any
---@return boolean
local function ok(v) return false end

local x = f()
local canAccess = ok(x)
if canAccess then
    print(x + 5)
else
    print(<!x!> + 5)
end
]]

TEST [[
---@secret
---@return number
local function f() return 0 end

---@secret-access-check
---@param v any
---@return boolean
local function ok(v) return false end

local x = f()
local canAccess = ok(x)
if not canAccess then
    print(<!x!> + 5)
else
    print(x + 5)
end
]]

-- a class that is called `secret` still works as a plain type name
TEST [[
---@class secret
---@field a number

---@type secret
local s = { a = 1 }
print(s.a)
]]

-- The five codes each report only their own kind of use: one script with every kind, checked once per code
-- (a use of another kind must NOT be reported under this code, and a code that has no use reports nothing)
local ALL_KINDS = [[
---@secret
---@return number
local function f() return 0 end

---@secret
---@return boolean
local function fb() return true end

local s = f()
local b = fb()
local t = {}
local r1 = %s
]]

---@param use string the expression with the secret in it
---@return string
local function script(use)
    return (ALL_KINDS:gsub('%%s', function () return use end))
end

---@type table<string, string[]> code -> uses that must be reported under it
local kinds = {
    ['secret-arithmetic'] = { '<!s!> + 1', '-<!s!>', '#<!s!>' },
    ['secret-comparison'] = { '<!s!> == 1', '<!s!> < 2', '1 >= <!s!>' },
    ['secret-condition']  = { 'not <!b!>', '<!b!> and 1' },
    ['secret-table-key']  = { 't[<!s!>]' },
    ['secret-access']     = { '<!s!>.x', '<!s!>()', 'pairs(<!s!>)' },
}
for code, uses in pairs(kinds) do
    DIAG_CARE = code
    for _, use in ipairs(uses) do
        TEST(script(use))
    end
    -- the other kinds are not reported under this code
    for otherCode, otherUses in pairs(kinds) do
        if otherCode ~= code then
            for _, use in ipairs(otherUses) do
                TEST(script((use:gsub('<!', ''):gsub('!>', ''))))
            end
        end
    end
end
-- a use that needs no check: nothing under any of the five
for code in pairs(kinds) do
    DIAG_CARE = code
    TEST(script('s .. "x"'))
    TEST(script('s and 1'))
end

-- What the plugin teaches the editor features: its tags, its `secret` field and type keywords, the
-- names in `---@secret a, b`, hover text and colours. The generic machinery is tested with the
-- fixture in test/docfixture.lua; this is the part that belongs to this plugin, so it goes when
-- the plugin goes.
do
    local files      = require 'files'
    local catch      = require 'catch'
    local define     = require 'proto.define'
    local completion = require 'core.completion'
    local hover      = require 'core.hover'
    local semantic   = require 'core.semantic-tokens'

    ---@diagnostic disable: await-in-sync

    --- The labels (with kinds) that completion offers at the `<??>` of a script.
    ---@param script string
    ---@return table<string, integer>
    local function offered(script)
        local text, catched = catch(script, '?')
        files.setText(TESTURI, text)
        local items = completion.completion(TESTURI, catched['?'][1][2], nil) or {}
        ---@type table<string, integer>
        local labels = {}
        for _, item in ipairs(items) do
            labels[item.label] = item.kind
        end
        files.remove(TESTURI)
        return labels
    end

    ---@param script string
    ---@param label  string
    ---@param kind   integer
    local function assertOffers(script, label, kind)
        local labels = offered(script)
        assert(labels[label] == kind, ('`%s` (kind %d) not offered, got kind %s'):format(label, kind, tostring(labels[label])))
    end

    local event, keyword, variable = define.CompletionItemKind.Event, define.CompletionItemKind.Keyword, define.CompletionItemKind.Variable

    -- the tags
    for _, tag in ipairs { 'secret', 'secret-unwrap', 'secret-check', 'secret-access-check', 'secret-guard' } do
        assertOffers('---@' .. tag:sub(1, 5) .. '<??>\nlocal x\n', tag, event)
    end
    assertOffers('---@secret-u<??>\nlocal x\n', 'secret-unwrap', event)
    -- the keyword in front of a field name and in front of a type
    assertOffers('---@class A\n---@field sec<??> string\n', 'secret', keyword)
    assertOffers('---@param token sec<??>\nlocal function f(token) end\n', 'secret', keyword)
    -- the parameter keyword: `secretguard` is offered, its alias `secretcheck` is not
    assertOffers('---@param token secretg<??>\nlocal function f(token) end\n', 'secretguard', keyword)
    assert(offered('---@param token secretc<??>\nlocal function f(token) end\n')['secretcheck'] == nil, 'the alias is not offered')
    -- the locals a `---@secret a, b` can name
    local names = offered('---@secret a<??>\nlocal abc, xyz = 1, 2\n')
    assert(names['abc'] == variable and not names['xyz'], 'names in `---@secret a`')

    -- hover
    local text, catched = catch('---@<?secret?>\nlocal x = 1\n', '?')
    files.setText(TESTURI, text)
    local shown = assert(hover.byUri(TESTURI, catched['?'][1][1] --[[@as integer]], 1))
    assert(shown:string():find('`@secret`', 1, true), shown:string())
    assert(shown:string():find('secret', 1, true))
    files.remove(TESTURI)

    -- a type keyword on a nested type keeps showing in the inferred type (`secret<string>[]`)
    local vm = require 'vm'
    local guide = require 'parser.guide'
    local function viewOf(script, name)
        files.setText(TESTURI, script)
        local state = assert(files.getState(TESTURI))
        ---@type string?
        local view
        guide.eachSource(state.ast, function (src)
            if src.type == 'local' and src[1] == name and not view then
                view = vm.getInfer(src):view(TESTURI)
            end
        end)
        files.remove(TESTURI)
        return view
    end
    assert(viewOf('---@type secret<string>[]\nlocal arr\n', 'arr') == 'secret<string>[]')
    assert(viewOf('---@type (secret string)[]\nlocal arr\n', 'arr') == 'secret<string>[]')
    assert(viewOf('---@type string[]\nlocal arr\n', 'arr') == 'string[]')
    assert(viewOf('---@type (string|number)[]\nlocal arr\n', 'arr') == '(string|number)[]')

    -- the flag a generic call hands back must not depend on which node is compiled first
    do
        local script = table.concat({
            '---@secret', '---@return string', 'local function getSecret() return "" end',
            'local s = getSecret()',
            '---@generic T', '---@param v T', '---@return T', 'local function id(v) return v end',
            'local t = id(s)', 'local u = id("plain")', '',
        }, string.char(10))
        for _, order in ipairs { { 'call', 'local' }, { 'local', 'call' }, { 'arg', 'local' } } do
            files.setText(TESTURI, script)
            local state = assert(files.getState(TESTURI))
            ---@type table<string, parser.object>
            local picked = {}
            guide.eachSource(state.ast, function (src)
                if src.type == 'call' and src.node and src.node[1] == 'id' and not picked.call then
                    picked.call = src
                    picked.arg  = src.args and src.args[1]
                elseif src.type == 'local' and src[1] == 't' then
                    picked['local'] = src
                end
            end)
            for _, which in ipairs(order) do
                vm.compileNode(picked[which])
            end
            assert(vm.compileNode(picked['local']):hasFlag('secret'), 'secret through id(): ' .. table.concat(order, ','))
            files.remove(TESTURI)
        end
    end

    -- colours: the tag word is a documentation keyword like every other tag
    files.setText(TESTURI, '---@secret\nlocal a\n---@secret-unwrap a\nlocal b\n')
    local data = semantic(TESTURI, 0, math.huge) --[[@as integer[] ]]
    files.remove(TESTURI)
    ---@type table<string, integer>
    local found = {}
    local line, char = 0, 0
    for i = 1, #data, 5 do
        line = line + data[i]
        char = (data[i] == 0) and (char + data[i + 1]) or data[i + 1]
        if data[i + 3] == define.TokenTypes.keyword and data[i + 4] == define.TokenModifiers.documentation then
            found[line .. ':' .. char] = data[i + 2]
        end
    end
    assert(found['0:3'] == 7, '`@secret` is a documentation keyword')
    assert(found['2:3'] == 14, '`@secret-unwrap` is a documentation keyword')
end

-- A guard written as a LOCAL function and exported through a table field (`ns.Util = { guard = guard }`, or
-- `ns.Util.guard = guard`), used from another file through `local alias = ns.Util.guard`: the usual way a WoW
-- addon's util file shares it (found from a real addon, 2026-10-04: a false `secret-condition` on
-- `not guard(state.isAFK) and state.isAFK`). The name registry only knew functions declared directly as a
-- global / field, so the other file's alias was not recognised as a guard.
do
    local furi   = require 'file-uri'
    local core   = require 'core.diagnostics'
    local files  = require 'files'
    local guide  = require 'parser.guide'

    ---@diagnostic disable: await-in-sync
    local SECRET_CODES = {
        ['secret-arithmetic'] = true, ['secret-comparison'] = true, ['secret-condition'] = true,
        ['secret-table-key'] = true, ['secret-access'] = true,
    }
    local utilUri = furi.encode(TESTROOT .. 'exported-guard-util.lua')
    local useUri  = furi.encode(TESTROOT .. 'exported-guard-use.lua')

    ---@param utilText string
    ---@param useText  string
    ---@return string[] codes the secret diagnostics report in the using file, as `code@line`
    local function secretFindings(utilText, useText)
        files.setText(utilUri, utilText)
        files.setText(useUri, useText)
        files.open(useUri)
        ---@type string[]
        local found = {}
        local state = assert(files.getState(useUri))
        core(useUri, false, function (result)
            if SECRET_CODES[result.code or ''] then
                found[#found+1] = (result.code or '') .. '@' .. (guide.rowColOf(result.start) + 1)
            end
        end)
        files.remove(useUri)
        files.remove(utilUri)
        table.sort(found)
        _ = state
        return found
    end

    local NL = string.char(10)
    local function lines(...)
        return table.concat({ ... }, NL) .. NL
    end

    local state = lines(
        '---@class ExportedState',
        '---@field public isAFK? secret<boolean>',
        '---@field public isDND? secret boolean',
        '---@field public isPlayer boolean'
    )

    for _, case in ipairs {
        { name = 'secret-check, table constructor',
          tag  = '---@secret-check',
          body = 'ns.Util = { guard = guard }' },
        { name = 'secret-check, field assignment',
          tag  = '---@secret-check',
          body = 'ns.Util = {}' .. NL .. 'ns.Util.guard = guard' },
        { name = 'secret-guard tag, table constructor',
          tag  = '---@secret-guard value is-secret',
          body = 'ns.Util = { guard = guard }' },
    } do
        local util = state .. lines(
            'local ns = {} ---@class ExportedNS',
            case.tag,
            '---@param value any',
            '---@return boolean',
            'local function guard(value) return false end',
            case.body
        )
        local use = lines(
            'local ns = {} ---@class ExportedNS',
            'local guard = ns.Util.guard',
            '---@param state ExportedState',
            'local function status(state)',
            '    local text = ""',
            '    if state.isPlayer then',
            '        if not state.isPlayer then',
            '            text = "a"',
            '        elseif not guard(state.isAFK) and state.isAFK then',
            '            text = "b"',
            '        elseif not guard(state.isDND) and state.isDND then',
            '            text = "c"',
            '        elseif state.isDND then',
            '            text = "d"',
            '        end',
            '    end',
            '    local n = GetNumber()',
            '    if not guard(n) then',
            '        return n + 1',
            '    end',
            '    return text',
            'end'
        )
        -- (`GetNumber` is secret: declared in the using file's own text so the case stands alone)
        local withApi = lines(
            '---@secret',
            '---@return number',
            'function GetNumber() return 0 end'
        ) .. use
        local found = secretFindings(util, withApi)
        -- the guarded uses are quiet; the unguarded `elseif state.isDND` (line 13 of the using text, below the 3 lines of the API)
        -- is the only report
        assert(#found == 1 and found[1] == 'secret-condition@' .. (3 + 13),
            case.name .. ': only the unguarded condition is reported, got ' .. table.concat(found, ' '))
    end
end
