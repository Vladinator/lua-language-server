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
