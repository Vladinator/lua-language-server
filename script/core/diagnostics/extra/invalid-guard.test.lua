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
        local name = s[1]
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

-- completion in `---@guard x is T` / `---@asserts x is T`: the parameters of the function the tag is bound to where the parameter goes;
-- the rest of the line is a type, which completes as any type does
do
    ---@diagnostic disable: await-in-sync
    local completion = require 'core.completion'
    local define     = require 'proto.define'
    local nl = string.char(10)

    ---@param script string a script with one `<??>`
    ---@return table<string, integer> labels with their kinds
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
    local variable = define.CompletionItemKind.Variable

    for _, tag in ipairs { 'guard', 'asserts' } do
        local labels = offered('---@' .. tag .. ' <??>' .. nl .. 'local function f(value, other) end' .. nl)
        assert(labels['value'] == variable and labels['other'] == variable, '`@' .. tag .. '`: the parameters')
        labels = offered('---@' .. tag .. ' va<??>' .. nl .. 'local function f(value, other) end' .. nl)
        assert(labels['value'] == variable and labels['other'] == nil, '`@' .. tag .. '`: a half typed parameter')
        -- after the parameter the line is a type: no parameter name is offered there
        labels = offered('---@' .. tag .. ' value is <??>' .. nl .. 'local function f(value, other) end' .. nl)
        assert(labels['value'] == nil and labels['other'] == nil, '`@' .. tag .. '`: no parameter where the type goes')
        assert(labels['string'] ~= nil, '`@' .. tag .. '`: the type completes as any type does')
    end
end

-- `---@type-narrows` (wowlua-ls): the index form, the receiver form, the method form
do
    local defs = [[
---@class TnWidget
---@class TnSlider: TnWidget
---@field value number
---@class TnButton: TnWidget

---@param element TnWidget
---@param typeName string
---@type-narrows 1 2
---@return boolean
local function IsType(element, typeName) return true end

---@class TnBase
local TnBase = {}

---@param typeName string
---@type-narrows 0 1
---@return boolean
function TnBase:IsType(typeName) return true end

---@type-narrows TnSlider
---@return boolean
function TnBase:IsSlider() return true end
]]

    -- the narrowed argument, where the call holds
    INFER 'TnSlider' (defs .. [[
---@param w TnWidget
local function f(w)
    if IsType(w, "TnSlider") then
        print(<?w?>)
    end
end
]])
    -- the class given as a table
    INFER 'TnSlider' (defs .. [[
local TnSlider = {}
---@param w TnWidget
local function f(w)
    if IsType(w, TnSlider) then
        print(<?w?>)
    end
end
]])
    -- the other branch: the class is taken away
    INFER 'TnButton' (defs .. [[
---@param w TnSlider|TnButton
local function f(w)
    if IsType(w, "TnSlider") then
        return
    else
        print(<?w?>)
    end
end
]])
    -- an early exit, and `assert`
    INFER 'TnSlider' (defs .. [[
---@param w TnWidget
local function f(w)
    if not IsType(w, "TnSlider") then return end
    print(<?w?>)
end
]])
    INFER 'TnSlider' (defs .. [[
---@param w TnWidget
local function f(w)
    assert(IsType(w, "TnSlider"))
    print(<?w?>)
end
]])
    -- nothing narrowed: the class is unknown, or not a literal, or the code is outside of the branch
    INFER 'TnWidget' (defs .. [[
---@param w TnWidget
local function f(w)
    if IsType(w, "NoSuchTnClass") then
        print(<?w?>)
    end
end
]])
    INFER 'TnWidget' (defs .. [[
---@param w TnWidget
---@param name string
local function f(w, name)
    if IsType(w, name) then
        print(<?w?>)
    end
end
]])
    INFER 'TnWidget' (defs .. [[
---@param w TnWidget
local function f(w)
    print(<?w?>)
    if IsType(w, "TnSlider") then
    end
end
]])
    -- the receiver of a colon call (`0`), and the method form
    INFER 'TnSlider' (defs .. [[
---@param b TnBase
local function f(b)
    if b:IsType("TnSlider") then
        print(<?b?>)
    end
end
]])
    INFER 'TnSlider' (defs .. [[
---@param b TnBase
local function f(b)
    if b:IsSlider() then
        print(<?b?>)
    end
end
]])
    INFER 'TnBase' (defs .. [[
---@param b TnBase
local function f(b)
    if b:IsSlider() then
    else
        print(<?b?>)
    end
end
]])
    INFER 'TnSlider' (defs .. [[
---@param b TnBase
local function f(b)
    assert(b:IsSlider())
    print(<?b?>)
end
]])
    -- a call with a missing argument narrows nothing, and does not fail
    INFER 'TnWidget' (defs .. [[
---@param w TnWidget
local function f(w)
    if IsType(w) then
        print(<?w?>)
    end
end
]])
end

-- the diagnostic of `---@type-narrows`
TEST [[
---@class TnDiagClass

---@param element any
---@param typeName string
---@type-narrows 1 2
local function Ok1(element, typeName) end

local TnDiag = {}

---@param typeName string
---@type-narrows 0 1
function TnDiag:Ok2(typeName) end

---@type-narrows TnDiagClass
function TnDiag:Ok3() end

---@param element any
---@type-narrows <!3!> 1
local function PositionPastTheEnd(element) end

---@param element any
---@type-narrows 1 <!0!>
local function ReceiverAsClass(element) end

---@param element any
---@param typeName string
---@type-narrows <!0!> 1
local function NoReceiver(element, typeName) end

---@<!type-narrows 1!>
---@param element any
local function OnePosition(element) end

---@<!type-narrows!>
---@param element any
local function Nothing(element) end

---@<!type-narrows TnDiagClass!>
local function NotAMethod(element) end

---@type-narrows <!NoSuchTnDiagClass!>
function TnDiag:Unknown() end

---@<!type-narrows 1 2!>
local notAFunction = 1
]]

-- the same for a parameter of a generic type: that read goes through the other narrowing engine (vm/tracer.lua)
do
    local defs = [[
---@class TnGWidget
---@class TnGSlider: TnGWidget
---@class TnGButton: TnGWidget

---@param element any
---@param typeName string
---@type-narrows 1 2
---@return boolean
local function IsGType(element, typeName) return true end
]]
    INFER 'TnGSlider' (defs .. [[
---@generic T: TnGWidget
---@param w T
local function f(w)
    if IsGType(w, "TnGSlider") then
        print(<?w?>)
    end
end
]])
    -- (an unknown class narrows nothing)
    INFER '<T:TnGWidget>' (defs .. [[
---@generic T: TnGWidget
---@param w T
local function f(w)
    if IsGType(w, "NoSuchTnGClass") then
        print(<?w?>)
    end
end
]])
end
