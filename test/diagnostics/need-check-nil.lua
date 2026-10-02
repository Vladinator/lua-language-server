TEST [[
---@type string?
local x

local s = <!x!>:upper()
]]

TEST [[
---@type string?
local x

S = <!x!>:upper()
]]

TEST [[
---@type string?
local x

if x then
    S = x:upper()
end
]]

TEST [[
---@type string?
local x

if not x then
    x = ''
end

S = x:upper()
]]

TEST [[
---@type fun()?
local x

S = <!x!>()
]]

TEST [[
---@type integer?
local x

T = {}
T[<!x!>] = 1
]]

TEST [[
local x, y
local z = x and y

print(z.y)
]]

TEST [[
local x, y
function x()
    y()
end

function y()
    x()
end

x()
]]

-- #3056
TEST [[
---@class A
---@field b string
---@field c 'string'|string1'
---@field d 0|1|2

---@type A?
local a

if <!a!>.b == "string1" then end
if <!a!>.b == "string" then end
]]

-- 安全导航（?. 等）访问可空变量：不应触发 need-check-nil
TEST [[
---@type string?
local x

local s = x?.upper()
]]

TEST [[
---@type string?
local x

local s = x?.:upper()
]]

TEST [[
---@type string?
local x

local s = x?.[1]
]]

TEST [[
---@type fun()?
local x

x?.()
]]

TEST [[
---@type string?
local x

local s = x?.field
]]

TEST [[
---@type string?
local x

local s = x?.field?.sub
]]

TEST [[
---@type string?
local x

local s = x?.upper()?.field
]]

TEST [[
---@type string?
local x

local s = <!x!>.upper()?.field
]]

TEST [[
---@type string?
local x

local s = x?:upper()
]]

-- 算术/比较/拼接/位运算/一元运算/数值 for 循环对 nil 操作数会直接报错
TEST [[
---@type number?
local n

print(<!n!> + 5)
]]

TEST [[
---@type number?
local n

print(5 + <!n!>)
]]

TEST [[
---@type number?
local n

print(<!n!> - 1)
print(<!n!> * 1)
print(<!n!> / 1)
print(<!n!> % 1)
print(<!n!> // 1)
print(<!n!> ^ 1)
]]

TEST [[
---@type number?
local n

print(-<!n!>)
]]

TEST [[
---@type number?
local n

print(<!n!> < 5)
print(<!n!> > 5)
print(<!n!> <= 5)
print(<!n!> >= 5)
]]

TEST [[
---@type string?
local s

print(<!s!> .. "x")
]]

TEST [[
---@type table?
local t

print(#<!t!>)
]]

TEST [[
---@type integer?
local n

print(<!n!> & 1)
print(<!n!> | 1)
print(<!n!> ~ 1)
print(<!n!> << 1)
print(<!n!> >> 1)
print(~<!n!>)
]]

TEST [[
---@type number?
local n

for i = <!n!>, 10 do end
]]

TEST [[
---@type number?
local n

for i = 1, <!n!> do end
]]

TEST [[
---@type number?
local n

for i = 1, 10, <!n!> do end
]]

-- `and`/`or`/`==`/`~=`/`not`/条件判断对 nil 是安全的：不应触发 need-check-nil
TEST [[
---@type boolean?
local b

if b then end
print(b == true)
print(b ~= true)
print(b and 1 or 2)
print(not b)
]]

-- 经过窄化后不应再触发 need-check-nil
TEST [[
---@type number?
local n

if n then
    print(n + 1)
end
]]

TEST [[
---@type number?
local n

n = n or 0
print(n + 1)
]]

-- 字段访问也要检查（不仅是局部变量），且窄化同样适用
TEST [[
---@class A
---@field n? number
local t = { n = 0 }

print(<!t.n!> + 5)
]]

TEST [[
---@class A
---@field n? number
local t = { n = 0 }

if t.n then
    print(t.n + 5)
end
]]

-- 字段赋值之后合流：`if not t.x then t.x = {} end` 之后 t.x 不再可能为 nil
TEST [[
---@class A
---@field list? table[]
local t = {}

if not t.list then
    t.list = {}
end
print(#t.list)
]]

TEST [[
---@class A
---@field list? table[]
---@param t A
---@param maybe table[]?
local function f(t, maybe)
    if not t.list then
        t.list = maybe
    end
    print(#<!t.list!>)
end
]]

TEST [[
---@class A
---@field list? number[]
---@param t A
---@param maybe number[]?
local function f(t, maybe)
    t.list = maybe or {}
    print(#t.list)
    t.list = maybe
    print(#<!t.list!>)
end
]]

-- 字段赋值右侧是算术/一元/拼接表达式：结果不可能为 nil，即使字段本身声明为可选
TEST [[
---@class A
---@field n? number
---@param t A
---@param a number
local function f(t, a)
    t.n = a + 1
    print(t.n + 1)
end
]]

TEST [[
---@class A
---@field n? number
---@param t A
---@param a number
local function f(t, a)
    t.n = -a
    print(t.n + 1)
end
]]

-- 反例：算术表达式仍可能包含未收窄的一侧，但结果本身从不为 nil，故不应报告
TEST [[
---@class A
---@field n? number
---@param t A
---@param a number?
local function f(t, a)
    t.n = (a or 0) + 1
    print(t.n + 1)
end
]]

-- 字段赋值右侧是函数调用（单值，解析为 `select` 包裹 `call`）：被调用者声明的返回类型不可为 nil 时，
-- 字段赋值之后不再可能为 nil
TEST [[
---@class A
---@field n? number
---@return number
local function g() return 1 end
---@param t A
local function f(t)
    t.n = g()
    print(t.n + 1)
end
]]

TEST [[
---@class A
---@field n? number
---@param t A
local function f(t)
    t.n = math.max(0, 1)
    print(t.n + 1)
end
]]

-- 反例：被调用者的声明返回类型本身可选，字段赋值之后仍可能为 nil
TEST [[
---@class A
---@field n? number
---@return number?
local function g() return nil end
---@param t A
local function f(t)
    t.n = g()
    print(<!t.n!> + 1)
end
]]

-- 循环体内 `t.x = t.x or {}`：右侧读取与追踪器自身循环依赖，不能因此放弃窄化
TEST [[
---@class A
---@field list? number[]
---@param t A
local function f(t)
    repeat
        t.list = t.list or {}
    until #t.list > 0
    print(#t.list)
end
]]

-- `while true`: the loop is left by its `break`s, so what the variable is after it is what it is
-- at each `break` (not what it was when the loop was entered)
TEST [[
---@type integer[]?
local l
while true do
    l = l or {}
    if #l > 3 then
        break
    end
    l[#l+1] = 1
end
S = #l
]]

TEST [[
---@type string?
local x
while true do
    x = 'a'
    if math.random() > 0.5 then
        break
    end
end
S = #x
]]

-- ... but it stays a finding when a `break` can be reached before the assignment,
TEST [[
---@type string?
local x
while true do
    if math.random() > 0.5 then
        break
    end
    x = 'a'
end
S = #<!x!>
]]

-- when the variable is nil at one of the `break`s,
TEST [[
---@type string?
local x = 'a'
while true do
    x = 'b'
    if math.random() > 0.5 then
        x = nil
        break
    end
end
S = #<!x!>
]]

TEST [[
---@type string?
local x
while true do
    x = 'a'
    if math.random() > 0.5 then
        break
    end
    x = nil
    if math.random() > 0.5 then
        break
    end
    x = 'b'
end
S = #<!x!>
]]

-- when a `goto` may jump over the assignment,
TEST [[
---@type string?
local x
while true do
    x = 'a'
    if math.random() > 0.5 then
        goto continue
    end
    x = nil
    if math.random() > 0.5 then
        break
    end
    ::continue::
end
S = #<!x!>
]]

-- and with a condition that can be false
TEST [[
---@type integer[]?
local l
while math.random() > 0.5 do
    l = l or {}
end
S = #<!l!>
]]

-- a guarded initialisation before the first `break` makes the variable non-nil at every `break`
TEST [[
---@type integer[]?
local x
while true do
    if not x then
        x = {}
    end
    if math.random() > 0.5 then
        break
    end
end
S = #x
]]

TEST [[
---@type integer[]?
local x
while true do
    if x == nil then
        x = {}
    end
    x[#x+1] = 1
    if #x > 3 then
        break
    end
end
S = #x
]]

-- ... unless something after it can make it nil again,
TEST [[
---@type integer[]?
local x
while true do
    if not x then
        x = {}
    end
    x = math.random() > 0.5 and {} or nil
    if math.random() > 0.5 then
        break
    end
end
S = #<!x!>
]]

-- or the guard has another branch, or comes after a `break`
TEST [[
---@type integer[]?
local x
while true do
    if not x then
        x = {}
    else
        x = nil
    end
    if math.random() > 0.5 then
        break
    end
end
S = #<!x!>
]]

TEST [[
---@type integer[]?
local x
while true do
    if math.random() > 0.5 then
        break
    end
    if not x then
        x = {}
    end
end
S = #<!x!>
]]

-- a `goto` to a label after the last `break` (the usual `continue`) does not matter
TEST [[
---@type string?
local x
while true do
    x = 'a'
    if math.random() > 0.5 then
        goto continue
    end
    if math.random() > 0.5 then
        break
    end
    ::continue::
end
S = #x
]]

-- but one that can land before a `break`, after skipping the assignment, does,
TEST [[
---@type string?
local x
while true do
    if math.random() > 0.5 then
        goto skip
    end
    x = 'a'
    ::skip::
    if math.random() > 0.5 then
        break
    end
end
S = #<!x!>
]]

-- and one that leaves the loop is another way out of it
TEST [[
---@type string?
local x
while true do
    x = 'a'
    if math.random() > 0.5 then
        x = nil
        goto out
    end
    if math.random() > 0.5 then
        break
    end
end
::out::
S = #<!x!>
]]

-- (a later assignment of something optional)
TEST [[
---@type integer[]?
local x
---@type integer[]?
local y
while true do
    if not x then
        x = {}
    end
    x = y
    if math.random() > 0.5 then
        break
    end
end
S = #<!x!>
]]

-- a plain else that does not touch x cannot undo the guard's guarantee (fixed 2026-09-27)
TEST [[
---@type integer[]?
local x
while true do
    if not x then
        x = {}
    else
        print(1)
    end
    if math.random() > 0.5 then
        break
    end
end
S = #x
]]

-- an elseif is a real extra condition, not a plain else -- still not recognised by the old walk;
-- the flow analysis (LLS_FLOW=1) sees that every way through the `if` leaves `x` non-nil
TEST ((os.getenv('LLS_FLOW_EVAL') ~= '0' or os.getenv('LLS_FLOW') == '1') and [[
---@type integer[]?
local x
while true do
    if not x then
        x = {}
    elseif math.random() > 0.5 then
        print(1)
    end
    if math.random() > 0.5 then
        break
    end
end
S = #x
]] or [[
---@type integer[]?
local x
while true do
    if not x then
        x = {}
    elseif math.random() > 0.5 then
        print(1)
    end
    if math.random() > 0.5 then
        break
    end
end
S = #<!x!>
]])

-- (something optional assigned after the last `break`: the guard comes before any `break` again)
TEST [[
---@type integer[]?
local x
---@type integer[]?
local y
while true do
    if not x then
        x = {}
    end
    if math.random() > 0.5 then
        break
    end
    x = y
end
S = #x
]]

-- (and between the guard and a `break`: not)
TEST [[
---@type integer[]?
local x
---@type integer[]?
local y
while true do
    if not x then
        x = {}
    end
    if math.random() > 0.5 then
        break
    end
    x = y
    if math.random() > 0.5 then
        break
    end
end
S = #<!x!>
]]

-- (an assignment that reads the variable itself, in a loop with a `goto`: what the reader of a
-- protocol header does; the type comes from the approximation, and stays known)
TEST [[
local line = ''
while true do
    line = line .. 'x'
    if line == 'xx' then
        break
    end
    if #line > 5 then
        goto continue
    end
    line = ''
    ::continue::
end
S = line:upper()
]]

-- `---@correlated a, b` (wowlua-ls interop): locals that are always nil/non-nil together --
-- narrowing one (even one the checker could not otherwise prove narrows the other, like an
-- `if math.random() > 0.5 then` guard with no relation to either variable) narrows its sibling too.
TEST [[
---@type string?
local tradeType = nil
---@type number?
local money = nil
---@correlated tradeType, money

if math.random() > 0.5 then
    tradeType = "buy"
    money = 100
end

if tradeType then
    S = money + 1
else
    S = money
end
]]

-- without the `---@correlated` tag, the same shape is correctly still flagged -- the narrowing
-- extension only applies to a declared group, not a general property of the guard.
TEST [[
---@type string?
local tradeType = nil
---@type number?
local money = nil

if math.random() > 0.5 then
    tradeType = "buy"
    money = 100
end

if tradeType then
    S = <!money!> + 1
else
    S = money
end
]]

-- the `nil` edge correlates too: once `tradeType` is known nil (the `else` branch), a correlated
-- sibling is known nil as well, not just "possibly nil" -- reading it is still fine (`nil` itself
-- is never an error to read), but a correlated sibling that is *not* nil-checkable this way stays
-- flagged, confirming the correlation only ever adds narrowing, never removes a real check.
TEST [[
---@type string?
local tradeType = nil
---@type number?
local money = nil
---@correlated tradeType, money

if math.random() > 0.5 then
    tradeType = "buy"
    money = 100
end

if not tradeType then
    S = money
else
    S = money + 1
end
]]

-- `---@correlated` on a `@class`'s own fields (TODO.md's field half of this): a field's base
-- object is only known at narrowing time, unlike a local's fixed declaration, so the class/field
-- lookup (`getClassCorrelatedInfo`/`fieldSiblingKeys`) has to run dynamically, from inside
-- `narrowRef`'s own propagation, not from the static per-function scan the local case uses.
TEST [[
---@class Pair
---@field a string?
---@field b string?
---@correlated a, b

---@type Pair
local p = {}

if p.a then
    S = p.b:len()
end
]]

-- without the `---@correlated` tag, the same shape is correctly still flagged.
TEST [[
---@class Pair2
---@field a string?
---@field b string?

---@type Pair2
local p = {}

if p.a then
    S = <!p.b!>:len()
end
]]

-- the `nil` edge correlates too, same as the local case: once `p.a` is known nil, `p.b` is known
-- nil as well (reading it is fine), but a non-nil-checkable use of it stays flagged.
TEST [[
---@class Pair3
---@field a string?
---@field b string?
---@correlated a, b

---@type Pair3
local p = {}

if not p.a then
    S = p.b
else
    S = p.b:len()
end
]]

-- a boolean local aliasing an `and`-chain whose operands are themselves plain narrowable refs (not
-- just calls/comparisons) composes the same way the matching unaliased condition does: missing
-- this made `isAliasableCond` bottom out at `false` for every operand down the chain, so the
-- alias registered nothing at all (2026-10-01).
TEST [[
---@class Box
---@field value string?
---@field blocked boolean?

---@return Box?
local function getBox() return nil end

local box = getBox()
local isShown = box and (box.value and not box.blocked)
if isShown then
    S = box.value:len()
end
]]

-- without the alias (the matching direct condition) already worked -- a negative control confirming
-- the alias case above is testing the alias path specifically, not `and`-chain narrowing itself.
TEST [[
---@class Box2
---@field value string?
---@field blocked boolean?

---@return Box2?
local function getBox() return nil end

local box = getBox()
if box and (box.value and not box.blocked) then
    S = box.value:len()
end
]]

-- a bare single-ref alias (`local isShown = box`, no `and`/`or`/comparison wrapper at all) stays
-- unsupported -- out of scope for this fix, and deliberately so (the function's own comment:
-- registering every `local x = <anything>` would defeat `hasBoolCond`'s whole point). Confirms the
-- fix above is scoped to and/or-chain operands, not a general "any alias of any ref" change.
TEST [[
---@class Box3
---@field value string?

---@return Box3?
local function getBox() return nil end

local box = getBox()
local isShown = box
if isShown then
    S = <!box!>.value
end
]]

-- Inferred correlated returns (no `---@correlated` needed): `f`'s own return statements make its
-- two return slots always nil/non-nil together (one statement returns `nil, nil`, the other two
-- real values) -- narrowing the first narrows the second, the same as the explicit tag would.
TEST [[
---@return string?, number?
local function f(cond)
    if cond then
        return nil, nil
    end
    return "x", 5
end

local a, b = f(true)
if a then
    S = b + 1
end
]]

-- without a shared `nil` return anywhere, there is nothing to correlate (and inference finds no
-- group: the correlation check requires at least one statement to actually return `nil` there) --
-- an unguarded read of either slot is still correctly flagged on its own, same as always.
TEST [[
---@return string?, number?
local function f2(cond)
    if cond then
        return "y", 10
    end
    return "x", 5
end

local a, b = f2(true)
S = <!a!>:len()
S = <!b!> + 1
]]

-- the two slots are each sometimes nil, but *not* together (anti-correlated) -- inference must not
-- group them: narrowing one says nothing reliable about the other, so the same shape as the
-- correlated case above stays correctly flagged.
TEST [[
---@return string?, number?
local function f3(cond)
    if cond then
        return nil, 5
    end
    return "x", nil
end

local a, b = f3(true)
if a then
    S = <!b!> + 1
end
]]

-- tuple-union `---@return (A, B) | (C, D)` (wowlua-ls interop): a declared contract -- the cases
-- themselves say which slots are nil together (here both are, or neither), so narrowing one
-- narrows the other with no `---@correlated` and no reliance on how the body returns.
TEST [[
---@return (string, number) | (nil, nil)
local function f(cond)
    if cond then return "x", 1 end
    return nil, nil
end

local a, b = f(true)
if a then
    S = b + 1
end
]]

-- anti-correlated cases (`string, nil` or `nil, number`): never nil together, so narrowing the
-- first says nothing safe about the second -- still flagged.
TEST [[
---@return (string, nil) | (nil, number)
local function g(cond)
    if cond then return "x", nil end
    return nil, 1
end

local c, d = g(true)
if c then
    S = <!d!> + 1
end
]]

-- the declared cases win over the body: the body here would infer *no* correlation (it returns
-- `nil, 1` and `"x", nil`), but the contract says the slots are nil together.
TEST [[
---@return (string, number) | (nil, nil)
local function h(cond)
    if cond then return nil, 1 end
    return "x", nil
end

local e, f = h(true)
if e then
    S = f + 1
end
]]

-- case elimination (tuple-union returns): narrowing one slot's *type* narrows the others to what the
-- surviving cases say -- in the `string` case the second slot is a plain `number`, not `number?`
TEST [[
---@return (string, number) | (boolean, nil)
local function f() return "x", 1 end

local a, b = f()
if type(a) == 'string' then
    S = b + 1
end
]]

-- ... outside any narrowing it is still `number?`: the elimination only applies where a case was
-- actually ruled out
TEST [[
---@return (string, number) | (boolean, nil)
local function f() return "x", 1 end

local a, b = f()
S = <!b!> + 1
]]

-- ... and a slot assigned to later left the call's tuple: no elimination through it
TEST [[
---@return (string, number) | (boolean, nil)
local function f() return "x", 1 end

local a, b = f()
a = "other"
if type(a) == 'string' then
    S = <!b!> + 1
end
]]

-- Shape guard for a closure's read of an upvalue declared in a chunk too large for a flow
-- (`MAX_LINES`, 6000 -- `vm.getFlow` builds none for it; fork 68c3f456f defers such reads to the old
-- tracer, the real case was a ~16,700-line addon file). The chunk is padded past the cap with
-- comment lines: a local assigned once in an unconditional `do ... end` at chunk scope, read from a
-- function nested two levels down, must not be flagged. NOT a mutation test: like the commit's own
-- notes say, no small synthetic fixture was found that fails without the deferral (checked again
-- 2026-10-02 with this one) -- the real-corpus run is that change's regression evidence; this only
-- keeps the shape from regressing through some other path.
TEST(([[
---@type string?
local x
do
    x = 'a'
end
local function outer()
    local function inner()
        S = x:len()
    end
end
]]) .. string.rep('-- padding\n', 6100))
