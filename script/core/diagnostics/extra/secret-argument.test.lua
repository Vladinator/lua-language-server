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
    local items = completion.completion(TESTURI, catched['?'][1][2] --[[@as integer]], nil) or {}
    files.remove(TESTURI)
    local found = false
    for _, item in ipairs(items) do
        if item.label == 'nosecret' and item.kind == define.CompletionItemKind.Keyword then
            found = true
        end
    end
    assert(found, '`nosecret` is offered as a keyword')
end
