---@diagnostic disable: await-in-sync
local core  = require 'core.code-lens'
local files = require 'files'
local guide = require 'parser.guide'

--- The hierarchy lenses of a text, `line: title` (the reference lenses are left out).
---@param text string
---@return string[]
local function lenses(text)
    files.remove(TESTURI)
    files.setText(TESTURI, text)
    ---@type string[]
    local list = {}
    for _, lens in ipairs(core.codeLens(TESTURI) or {}) do
        local command = core.resolve(TESTURI, lens.id)
        local title = command and command.title or ''
        if title:find('implementation', 1, true) or title:find('overrides', 1, true) then
            list[#list+1] = (guide.rowColOf(lens.position) + 1) .. ': ' .. title
        end
    end
    files.remove(TESTURI)
    table.sort(list, function (a, b)
        return tonumber(a:match('^%d+')) < tonumber(b:match('^%d+'))
    end)
    return list
end

local function check(text, expected)
    local got = table.concat(lenses(text), '; ')
    assert(got == expected, 'wanted [' .. expected .. '] got [' .. got .. ']')
end

-- the number of direct subclasses on the class, `overrides Class` on a method the nearest ancestor also defines
check([[
---@class LAnimal
local Animal = {}

function Animal:GetName() end

---@class LDog : LAnimal
local Dog = {}

function Dog:GetName() end

function Dog:Bark() end

---@class LCat : LAnimal
local Cat = {}

function Cat:GetName() end

---@class LKitten : LCat
local Kitten = {}

function Kitten:GetName() end

function Kitten:Bark() end
]], table.concat({
    '1: 2 implementations',
    '6: 0 implementations',
    '9: overrides LAnimal',
    '13: 1 implementation',
    '16: overrides LAnimal',
    '18: 0 implementations',
    '21: overrides LCat',
}, '; '))

-- negative: a parent without that method, or a method of a class that extends nothing, has no `overrides`
check([[
---@class LEmptyBase
local EmptyBase = {}

---@class LDerived : LEmptyBase
local Derived = {}

function Derived:DoStuff() end
function EmptyBase:Own() end
]], '1: 1 implementation; 4: 0 implementations')

-- a method found further up the chain is attributed to the class that defines it
check([[
---@class LGrand
local Grand = {}
function Grand:Walk() end

---@class LParent : LGrand
local Parent = {}

---@class LChild : LParent
local Child = {}
function Child:Walk() end
]], '1: 1 implementation; 5: 1 implementation; 8: 0 implementations; 10: overrides LGrand')

-- a field written as an assignment counts too, a non-function field does not
check([[
---@class LBase
local Base = {}
Base.run = function () end
Base.size = 1

---@class LSub : LBase
local Sub = {}
Sub.run = function () end
Sub.size = 2
]], '1: 1 implementation; 6: 0 implementations; 8: overrides LBase')

-- negative: a class that is not a subclass (a sibling) is not an ancestor
check([[
---@class LSiblingA
local A = {}
function A:Bark() end

---@class LSiblingB
local B = {}
function B:Bark() end
]], '1: 0 implementations; 5: 0 implementations')

-- no class, no hierarchy lens
check([[
local t = {}
function t.method() end
]], '')

files.remove(TESTURI)

-- with the client option the lens opens the list of the subclasses; without it the lens is only a title
do
    local client = require 'client'
    local text = '---@class LViewBase\nlocal Base = {}\n\n---@class LViewA : LViewBase\nlocal A = {}\n\n---@class LViewB : LViewBase\nlocal B = {}\n'
    ---@param viewReferences boolean
    ---@return proto.command?
    local function firstLens(viewReferences)
        files.remove(TESTURI)
        files.setText(TESTURI, text)
        ---@type table<string, any>
        local options = client.info.initializationOptions or {}
        client.info.initializationOptions = options
        options.codeLensViewReferences = viewReferences
        local result = core.codeLens(TESTURI) or {}
        local command = result[1] and core.resolve(TESTURI, result[1].id)
        options.codeLensViewReferences = nil
        files.remove(TESTURI)
        return command
    end
    local plain = assert(firstLens(false))
    assert(plain.title == '2 implementations' and plain.command == '', 'a title only: ' .. tostring(plain.command))
    local viewing = assert(firstLens(true))
    assert(viewing.command == 'lua.showReferences', 'opens the list: ' .. tostring(viewing.command))
    assert(#viewing.arguments[3] == 2, 'the two subclasses: ' .. #viewing.arguments[3])
end
