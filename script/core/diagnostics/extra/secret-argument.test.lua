-- Lives next to secret-argument.lua: it only runs if the plugin is there.

-- the parameter that is declared `nosecret` refuses a secret, the others take anything
TEST [[
---@secret
---@return string
local function get() return '' end

---@param delimiter string
---@param str nosecret string
---@param pieces? number
---@return string ...
---@nodiscard
local function split(delimiter, str, pieces) end

local id = get()
split(',', <!id!>)
split(id, 'a,b')
split(',', 'a,b', 2)
]]

-- `nosecret<T>` (the generic-wrapper spelling) is pure sugar for the `nosecret T` prefix form --
-- same behavior, same diagnostic
TEST [[
---@secret
---@return string
local function get() return '' end

---@param delimiter string
---@param str nosecret<string>
---@param pieces? number
---@return string ...
---@nodiscard
local function split(delimiter, str, pieces) end

local id = get()
split(',', <!id!>)
split(id, 'a,b')
split(',', 'a,b', 2)
]]

-- a value that was checked is not secret any more
TEST [[
---@secret
---@return string
local function get() return '' end

---@secret-check
---@param v any
---@return boolean
local function issecretvalue(v) return false end

---@param str nosecret string
local function use(str) end

local id = get()
if not issecretvalue(id) then
    use(id)
end
use(<!id!>)
]]

-- through an alias, and a call result
TEST [[
---@secret
---@return string
local function get() return '' end

---@param str nosecret string
local function use(str) end

local id = get()
local same = id
use(<!same!>)
use(<!get()!>)
]]

-- a global function of a library table, as an API definition (no body)
TEST [[
---@secret
---@return string
local function get() return '' end

string = {}
---@param delimiter string
---@param str nosecret string
---@param pieces? number
---@return string ...
---@nodiscard
function string.split(delimiter, str, pieces) end

string.split(',', <!get()!>)
]]

-- a method: `self` is not a parameter of the call
TEST [[
---@secret
---@return string
local function get() return '' end

local obj = {}
---@param name nosecret string
function obj:setName(name) end

obj:setName(<!get()!>)
obj.setName(obj, <!get()!>)
]]

-- a function type
TEST [[
---@secret
---@return string
local function get() return '' end

---@type fun(name: nosecret string)
local f

f(<!get()!>)
]]

-- overloads: a call one of them takes is fine
TEST [[
---@secret
---@return string
local function get() return '' end

---@param str nosecret string
---@overload fun(str: string, extra: number)
local function use(str, extra) end

use(<!get()!>)
use(get(), 1)
]]

-- a parameter without the keyword takes a secret, a plain parameter of a plain function too
TEST [[
---@secret
---@return string
local function get() return '' end

---@param str string
local function use(str) end

use(get())
]]

-- the keyword is offered where a type can start, with its description
do
    local files      = require 'files'
    local catch      = require 'catch'
    local define     = require 'proto.define'
    local completion = require 'core.completion'

    ---@diagnostic disable: await-in-sync
    local text, catched = catch('---@param str nosec<??>\nlocal function f(str) end\n', '?')
    files.setText(TESTURI, text)
    local items = completion.completion(TESTURI, catched['?'][1][2], nil) or {}
    files.remove(TESTURI)
    local found = false
    for _, item in ipairs(items) do
        if item.label == 'nosecret' and item.kind == define.CompletionItemKind.Keyword then
            found = true
        end
    end
    assert(found, '`nosecret` is offered as a keyword')
end

-- wowlua-ls's `---@secret-args none|untainted [param...]` is the function-level spelling of `nosecret` slots: the named
-- parameters (all of them with no list) refuse a secret value. `tainted` accepts one, like a plain parameter.
TEST [[
---@secret
---@return string
local function get() return '' end

---@secret-args none str
---@param delimiter string
---@param str string
---@param pieces? number
local function split(delimiter, str, pieces) end

local id = get()
split(',', <!id!>)
split(id, 'a,b')
split(',', 'a,b', 2)
]]

-- no parameter list: every parameter refuses a secret
TEST [[
---@secret
---@return string
local function get() return '' end

---@secret-args none
---@param a string
---@param b string
local function two(a, b) end

local id = get()
two(<!id!>, 'x')
two('x', <!id!>)
two('x', 'y')
]]

-- `untainted` is rejected in addon code like `none`
TEST [[
---@secret
---@return string
local function get() return '' end

---@secret-args untainted a
---@param a string
---@param b string
local function f(a, b) end

local id = get()
f(<!id!>, 'x')
f('x', id)
]]

-- `tainted` takes a secret: nothing is reported
TEST [[
---@secret
---@return string
local function get() return '' end

---@secret-args tainted a
---@param a string
local function f(a) end

local id = get()
f(id)
]]

-- several names, a vararg, a checked value, a plain parameter list
TEST [[
---@secret
---@return string
local function get() return '' end

---@secret-check
---@param v any
---@return boolean
local function issecretvalue(v) return false end

---@secret-args none a c
---@param a string
---@param b string
---@param c string
local function f(a, b, c) end

local id = get()
f(<!id!>, id, <!id!>)
if not issecretvalue(id) then
    f(id, id, id)
end
]]

-- `...` names the variadic parameter: every extra argument refuses a secret
TEST [[
---@secret
---@return string
local function get() return '' end

---@secret-args none ...
---@param first string
---@param ... string
local function f(first, ...) end

local id = get()
f(id, 'a')
f('a', <!id!>, <!id!>)
]]

-- a name the function does not have, and a tag on something that is not a function, do nothing
TEST [[
---@secret
---@return string
local function get() return '' end

---@secret-args none nothere
---@param a string
local function f(a) end

local id = get()
f(id)
]]

-- the original spelling keeps working next to it
TEST [[
---@secret
---@return string
local function get() return '' end

---@param a nosecret string
local function f(a) end

---@secret-args none b
---@param b string
local function g(b) end

local id = get()
f(<!id!>)
g(<!id!>)
]]

-- both spellings on the same parameter report once
TEST [[
---@secret
---@return string
local function get() return '' end

---@secret-args none a
---@param a nosecret string
local function f(a) end

local id = get()
f(<!id!>)
]]

-- a method called with a colon: the receiver is the first argument, the tag names parameters as written
TEST [[
---@secret
---@return string
local function get() return '' end

---@class Obj
local Obj = {}

---@secret-args none text
---@param text string
function Obj:say(text) end

---@type Obj
local o
local id = get()
o:say(<!id!>)
o:say('plain')
]]

-- the original spelling on a variadic parameter: every extra argument refuses a secret too
TEST [[
---@secret
---@return string
local function get() return '' end

---@param first string
---@param ... nosecret string
local function f(first, ...) end

local id = get()
f(id, 'a')
f('a', <!id!>, <!id!>)
]]
