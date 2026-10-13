---@diagnostic disable: await-in-sync
local core  = require 'core.type-hierarchy'
local files = require 'files'
local catch = require 'catch'

--- The class names of a list of items, in the order given.
---@param items core.type-hierarchy.item[]
---@return string
local function names(items)
    ---@type string[]
    local list = {}
    for _, item in ipairs(items) do
        list[#list+1] = item.name
    end
    return table.concat(list, ',')
end

local HIERARCHY = [[
---@class HAnimal
local Animal = {}

---@class HDog : HAnimal
local Dog = {}

---@class HCat : HAnimal
local Cat = {}

---@class HPoodle : HDog
local Poodle = {}

---@class HPet : HDog, HCat
local Pet = {}

---@class HAlone : HMissing
local Alone = {}

---@type HAnimal
local pet
]]

--- Run `check` with the hierarchy as the open file.
---@param check fun()
local function withHierarchy(check)
    files.setText(TESTURI, HIERARCHY)
    assert(files.getState(TESTURI))
    check()
    files.remove(TESTURI)
end

--- The item of the class whose name starts at the mark `<?x?>`.
---@param script string
---@return core.type-hierarchy.item[]?
local function prepareAt(script)
    local newScript, catched = catch(script, '?')
    files.setText(TESTURI, newScript)
    local input = catched['?'][1]
    local result = core.prepare(TESTURI, (input[1] --[[@as integer]] + input[2] --[[@as integer]]) // 2)
    files.remove(TESTURI)
    return result
end

-- supertypes: the classes after the colon
withHierarchy(function ()
    assert(names(core.supertypes(TESTURI, 'HDog')) == 'HAnimal', 'one parent')
    assert(names(core.supertypes(TESTURI, 'HPoodle')) == 'HDog', 'the parent, not the grandparent')
    assert(names(core.supertypes(TESTURI, 'HPet')) == 'HDog,HCat', 'two parents in the order written')
    assert(names(core.supertypes(TESTURI, 'HAnimal')) == '', 'a class without a parent')
    assert(names(core.supertypes(TESTURI, 'HAlone')) == '', 'a parent that is not defined is left out')
end)

-- subtypes: the classes that name it after their colon
withHierarchy(function ()
    assert(names(core.subtypes(TESTURI, 'HAnimal')) == 'HCat,HDog', 'direct children only, by name')
    assert(names(core.subtypes(TESTURI, 'HDog')) == 'HPet,HPoodle', 'a class with two parents is a child of both')
    assert(names(core.subtypes(TESTURI, 'HCat')) == 'HPet')
    assert(names(core.subtypes(TESTURI, 'HPoodle')) == '', 'a class nobody extends')
end)

-- an item points at the `---@class` line and its name
withHierarchy(function ()
    local item = core.supertypes(TESTURI, 'HDog')[1]
    assert(item and item.uri == TESTURI, 'the file of the class')
    assert(item.nameFinish - item.nameStart + 1 == #'HAnimal' or item.nameFinish - item.nameStart == #'HAnimal', 'the span of the name')
    assert(item.start <= item.nameStart and item.finish >= item.nameFinish, 'the name is inside the item')
end)

-- prepare: from the name in the annotation, from a variable of that class, and nothing elsewhere
do
    local items = prepareAt [[
---@class HNamed
local N = {}

---@type <?HNamed?>
local v
]]
    assert(items and names(items) == 'HNamed', 'a class name in a type')
end
do
    local items = prepareAt [[
---@class <?HDef?>
local D = {}
]]
    assert(items and names(items) == 'HDef', 'the name of the class itself')
end
do
    local items = prepareAt [[
---@class HVar
local V = {}

---@type HVar
local value
print(<?value?>)
]]
    assert(items and names(items) == 'HVar', 'a variable that holds the class')
end
do
    local items = prepareAt [[
local plain = 1
print(<?plain?>)
]]
    assert(items == nil, 'a number is no class')
end
do
    local items = prepareAt [[
---@class HParent
local P = {}

---@class HChild : <?HParent?>
local C = {}
]]
    assert(items and names(items) == 'HParent', 'the parent named after the colon')
end

-- a class declared in two places names its parent twice: one item
do
    files.setText(TESTURI, [[
---@class HBase
local B = {}

---@class HTwice : HBase
local T1 = {}

---@class HTwice : HBase
local T2 = {}
]])
    assert(files.getState(TESTURI))
    assert(names(core.supertypes(TESTURI, 'HTwice')) == 'HBase', 'the parent once')
    assert(names(core.subtypes(TESTURI, 'HBase')) == 'HTwice', 'the child once')
    files.remove(TESTURI)
end
