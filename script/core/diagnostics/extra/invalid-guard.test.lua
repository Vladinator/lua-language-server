-- Lives next to invalid-guard.lua: it only runs if the plugin is there.

local files = require 'files'
local guide = require 'parser.guide'
local catch = require 'catch'
local vm    = require 'vm'

--- The type the marked source (`<?x?>`) has, like the type inference tests.
---@param wanted string
---@return fun(script: string)
local function INFER(wanted)
    return function (script)
        local newScript, catched = catch(script, '?')
        files.setText(TESTURI, newScript)
        local state = files.getState(TESTURI)
        assert(state)
        ---@type parser.object?
        local source
        guide.eachSourceContain(state.ast, catched['?'][1][1], function (s)
            if s.type == 'getlocal' or s.type == 'local' or s.type == 'getfield' then
                source = s
            end
        end)
        assert(source)
        local result = vm.getInfer(source):view(TESTURI)
        assert(result == wanted, ('wanted `%s`, got `%s`\n%s'):format(wanted, result, script))
        files.remove(TESTURI)
    end
end

-- a predicate: the type in the branch where it holds, without it in the other one
INFER 'string' [[
---@guard v is string
---@param v any
---@return boolean
local function IsString(v) return type(v) == 'string' end

---@type string|number
local x
if IsString(x) then
    print(<?x?>)
end
]]

INFER 'number' [[
---@guard v is string
---@param v any
---@return boolean
local function IsString(v) return type(v) == 'string' end

---@type string|number
local x
if IsString(x) then
    return
else
    print(<?x?>)
end
]]

-- `any` becomes the type
INFER 'string' [[
---@guard v is string
---@param v any
---@return boolean
local function IsString(v) return type(v) == 'string' end

---@param x any
local function f(x)
    if IsString(x) then
        print(<?x?>)
    end
end
]]

-- `is not`
INFER 'string' [[
---@guard v is not nil
---@param v any
---@return boolean
local function IsSet(v) return v ~= nil end

---@type string?
local x
if IsSet(x) then
    print(<?x?>)
end
]]

INFER 'nil' [[
---@guard v is not nil
---@param v any
---@return boolean
local function IsSet(v) return v ~= nil end

---@type string?
local x
if not IsSet(x) then
    print(<?x?>)
end
]]

-- a union of types, `not`, `and`, early return
INFER 'string|number' [[
---@guard v is string|number
---@param v any
---@return boolean
local function IsScalar(v) return true end

---@type string|number|boolean
local x
if IsScalar(x) then
    print(<?x?>)
end
]]

INFER 'string' [[
---@guard v is string
---@param v any
---@return boolean
local function IsString(v) return type(v) == 'string' end

---@type string|number
local x
if not IsString(x) then
    return
end
print(<?x?>)
]]

INFER 'string' [[
---@guard v is string
---@param v any
---@return boolean
local function IsString(v) return type(v) == 'string' end

---@type string|number
local x
local ok = IsString(x) and print(<?x?>)
]]

-- through a table: `M.IsString(x)`, and a method: `obj:IsString(x)` (the second parameter, after `self`)
INFER 'string' [[
local M = {}

---@guard v is string
---@param v any
---@return boolean
function M.IsString(v) return type(v) == 'string' end

---@type string|number
local x
if M.IsString(x) then
    print(<?x?>)
end
]]

INFER 'string' [[
local M = {}

---@guard v is string
---@param v any
---@return boolean
function M:IsString(v) return type(v) == 'string' end

---@type string|number
local x
if M:IsString(x) then
    print(<?x?>)
end
]]

-- the object of a method call, by `self`
INFER 'Dog' [[
---@class Animal
---@class Dog: Animal
local Dog = {}

---@guard self is Dog
---@return boolean
function Animal.IsDog(self) return true end

---@type Animal
local a
if Animal.IsDog(a) then
    print(<?a?>)
end
]]

-- a function that is not a guard narrows nothing, and neither does a guard called as a statement
INFER 'string|number' [[
---@param v any
---@return boolean
local function IsString(v) return type(v) == 'string' end

---@type string|number
local x
if IsString(x) then
    print(<?x?>)
end
]]

INFER 'string|number' [[
---@guard v is string
---@param v any
---@return boolean
local function IsString(v) return type(v) == 'string' end

---@type string|number
local x
IsString(x)
print(<?x?>)
]]

-- an assertion function: after the call
INFER 'string' [[
---@asserts v is string
---@param v any
local function AssertString(v) end

---@type string|number
local x
AssertString(x)
print(<?x?>)
]]

INFER 'string|number' [[
---@asserts v is string
---@param v any
local function AssertString(v) end

---@type string|number
local x
if math.random() > 0.5 then
    AssertString(x)
end
print(<?x?>)
]]

-- a guard of another file works too (the name is what is looked up first)
do
    local libUri = require 'file-uri'.encode(TESTROOT .. 'guard-lib.lua')
    files.setText(libUri, [[
---@guard v is string
---@param v any
---@return boolean
function GuardLibIsString(v) return type(v) == 'string' end
]])
    INFER 'string' [[
---@type string|number
local x
if GuardLibIsString(x) then
    print(<?x?>)
end
]]
    files.remove(libUri)
end

-- the diagnostic
TEST [[
---@<!guard!>
---@param v any
---@return boolean
local function A(v) return true end

---@guard <!w!> is string
---@param v any
---@return boolean
local function B(v) return true end

---@<!asserts!> v string
---@param v any
local function C(v) end

---@guard v is string
---@param v any
---@return boolean
local function Ok(v) return true end

---@guard self is string
---@return boolean
function Ok2(self) return true end
]]

-- a file that is not part of any workspace (VS Code with a single file open) is in no scope's list of
-- files: its own guards have to be found all the same
do
    local looseUri = 'file:///outside-of-the-workspace/loose-guard.lua'
    local looseText = [[
---@guard v is string
---@param v any
---@return boolean
local function IsString(v) return type(v) == 'string' end

---@asserts v is table
---@param v any
local function AssertTable(v) end

---@param x string|number
---@param y any
local function f(x, y)
    if IsString(x) then
        print(x)
    end
    AssertTable(y)
    print(y)
end
]]
    files.setText(looseUri, looseText)
    local state = files.getState(looseUri)
    assert(state)
    ---@type string[]
    local seen = {}
    guide.eachSourceType(state.ast, 'getlocal', function (s)
        local name = s[1] --[[@as string]]
        if (name == 'x' or name == 'y') and s.parent and s.parent.type == 'callargs' then
            seen[#seen+1] = vm.getInfer(s):view(looseUri)
        end
    end)
    -- (the arguments of the guard calls are what they were declared: `any` and `string|number`; the ones
    -- of `print` are what the guards made them)
    local joined = ',' .. table.concat(seen, ',') .. ','
    assert(joined:find(',string,', 1, true) and joined:find(',table,', 1, true), 'loose file: ' .. joined)
    files.remove(looseUri)
end
