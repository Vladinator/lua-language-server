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
