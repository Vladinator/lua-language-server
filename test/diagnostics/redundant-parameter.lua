TEST [[
local function x(a, b)
    return a, b
end
x(1, 2, <!3!>)
]]

TEST [[
local function x(a, b, ...)
    return a, b, ...
end
x(1, 2, 3, 4, 5)
]]

TEST [[
---@type fun(a, b, ...)
local x
x(1, 2, 3, 4, 5)
]]

TEST [[
local m = {}
function m:x(a, b)
    return a, b
end
m:x(1, 2, <!3!>)
]]

TEST [[
local m = {}
function m:x(a, b)
    return a, b
end
m.x(m, 2, 3, <!4!>)
]]

TEST [[
local m = {}
function m.x(a, b)
    return a, b
end
m:x(1, <!2!>, <!3!>, <!4!>)
]]

TEST [[
local m = {}
function m.x()
end
m:x()
]]

TEST [[
local function f(a, b)
    return a, b
end
f(1, 2, <!3!>, <!4!>)
]]

TEST [[
local mt = {}
function mt:f(a, b)
    return a, b
end
mt.f(mt, 2, 3, <!4!>)
]]

TEST [[
local mt = {}
function mt.f(a, b)
    return a, b
end
mt:f(1, <!2!>, <!3!>, <!4!>)
]]

TEST [[
local mt = {}
function mt:f(a, b)
    return a, b
end
mt:f(1, 2, <!3!>, <!4!>)
]]

TEST [[
local function f(a, b, ...)
    return a, b, ...
end
f(1, 2, 3, 4)
]]

TEST [[
local _ = next({}, 1, <!2!>)
print(1, 2, 3, 4, 5)
]]

TEST [[
local function f(callback)
    callback(1, 2, 3)
end
f(function () end)
]]

--TEST [[
--local realTostring = tostring
--tostring = function () end
--tostring(<!1!>)
--tostring = realTostring
--tostring(1)
--]]

TEST [[
local f = load('')
if f then
    f(1, 2, 3)
end
]]

TEST [[
local m = {}
function m.open()
end

m:open()
]]

TEST [[
local m = {}
function m:open()
end

m.open(m)
]]

TEST [[
table.insert({}, 1, 2, <!3!>)
]]

TEST [[
---@overload fun(...)
local function f() end

f(1)
]]

TEST [[
function F() end

---@param x boolean
function F(x) end

F(k())
]]

TEST [[
local function f()
    return 1, 2, 3
end

local function k()
end

k(<!f()!>)
]]

TEST [[
---@diagnostic disable: unused-local
local function f()
    return 1, 2, 3
end

---@param x integer
local function k(x)
end

k(f())
]]

TEST [[
---@meta

---@param x fun()
local function f1(x)
end

---@return fun()
local function f2()
end

f1(f2())
]]

TEST [[
---@meta

---@type fun():integer
local f

---@param x integer
local function foo(x) end

foo(f())
]]

TEST [[
---@meta
---@diagnostic disable: duplicate-set-field
---@class A
local m = {}

function m.ff() end

function m.ff(x) end

m.ff(1)
]]

-- a function that takes nothing: any argument is wrong, even when the last one is a call
TEST [[
local function foo() end

local function bar() return 1 end

foo(<!bar()!>)
foo(<!1!>, <!bar()!>)
]]

-- a function that takes parameters forgives a trailing call while the count could still fit (it may expand)
TEST [[
local function foo(a, b) end

local function bar() return 1, 2 end

foo(1, bar())
foo(bar())
]]

-- a function literal with more parameters than the `fun()` type it is assigned to declares
TEST [[
---@type fun(a: number)
local f = function(a, <!b!>) end
]]

-- `---@param ... params<F>`: no more arguments than F has parameters, unless F has a `...` itself
TEST [[
---@generic F: fun(...)
---@param fn F
---@param ... params<F>
---@return returns<F>
local function call(fn, ...) return fn(...) end

---@param name string
---@param count integer
---@return boolean
local function spawn(name, count) return true end

---@param a string
---@param ... number
local function rest(a, ...) end

call(spawn, 'orc', 3)
call(spawn, 'orc', 3, <!4!>)
call(rest, 'a', 1, 2, 3, 4)
]]

-- `params<F>` where F is a type parameter of the class: no more arguments than F has parameters
TEST [[
---@class Registry<F>
local Registry = {}

---@param key string
---@param ... params<F>
function Registry:Call(key, ...) end

---@class Plain
local Plain = {}

---@param key string
---@param ... number
function Plain:Call(key, ...) end

---@class Child : Registry<fun(name: string)>

---@type Registry<fun(name: string, count: number)>
local reg

---@type Registry<fun(name: string, count?: number)>
local optional

---@type Child
local child

---@type Registry
local unbound

reg:Call('k', 'orc', 3)
reg:Call('k', 'orc', 3, <!4!>)
optional:Call('k', 'orc', 3, <!4!>)
child:Call('k', 'orc', <!3!>)
unbound:Call('k', 1, 2, 3, 4)
]]

-- a table called through the `__call` of its metatable: one argument less than the function has parameters (the table is the first)
TEST [[
---@diagnostic disable: unused-local
local counter = setmetatable({}, {
    ---@param self table
    ---@param step integer
    __call = function (self, step) end,
})

counter(1)
counter(1, <!2!>)
]]

-- no `__call` function is known: nothing to compare with
TEST [[
local plain = setmetatable({}, { __index = {} })
plain(1, 2, 3)
]]

-- a trailing `...` may expand to nothing (`return original(self, ...)`, the hooking idiom)
TEST [[
local function one(a) end
local function none() end
local function hook(self, ...)
    one(self, ...)
    none(...)
    return one(self, ...)
end
]]

-- ... a real extra argument before the `...` is still reported
TEST [[
local function one(a) end
local function hook(self, ...)
    one(self, <!self!>, ...)
end
]]

-- ... a `...` alone, and a `...` that is not last (it gives one value there)
TEST [[
local function one(a) end
local function h(...)
    one(...)
    one(1, <!...!>, ...)
end
]]
