-- Lives next to need-check-secret.lua on purpose: this test only runs if
-- its plugin does too (see the checkPluginDir scan in
-- test/diagnostics/init.lua), so deleting the plugin also removes its
-- test with nothing left over to update elsewhere.

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

-- a class that is called `secret` still works as a plain type name
TEST [[
---@class secret
---@field a number

---@type secret
local s = { a = 1 }
print(s.a)
]]

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
        local items = completion.completion(TESTURI, catched['?'][1][2] --[[@as integer]], nil) or {}
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
    for _, tag in ipairs { 'secret', 'secret-unwrap', 'secret-check', 'secret-access-check' } do
        assertOffers('---@' .. tag:sub(1, 5) .. '<??>\nlocal x\n', tag, event)
    end
    assertOffers('---@secret-u<??>\nlocal x\n', 'secret-unwrap', event)
    -- the keyword in front of a field name and in front of a type
    assertOffers('---@class A\n---@field sec<??> string\n', 'secret', keyword)
    assertOffers('---@param token sec<??>\nlocal function f(token) end\n', 'secret', keyword)
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
