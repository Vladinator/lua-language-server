-- Lives next to mutate-readonly.lua: it only runs if the plugin is there.

-- a readonly parameter: assigning a field or index
TEST [[
---@class Config
---@field name string
---@field volume number

---@param t readonly Config
local function f(t)
    t.<!name!> = 'x'
    t[<!'volume'!>] = 1
    print(t.name) -- reading is fine
end
]]

-- a readonly local (`---@type`)
TEST [[
---@class Point
---@field x number
---@field y number

---@param p Point
local function f(p)
    ---@type readonly Point
    local t = p
    t.<!x!> = 1
end
]]

-- an array parameter, and mutating calls
TEST [[
---@param arr readonly integer[]
local function f(arr)
    arr[<!1!>] = 0
    table.insert(<!arr!>, 1)
    table.remove(<!arr!>)
    table.sort(<!arr!>)
    rawset(<!arr!>, 1, 0)
    table.insert(<!arr!>, 1, 0) -- still reported: the array is the first argument
    print(#arr, arr[1]) -- reading is fine
end
]]

-- self, declared explicitly
TEST [[
---@class Widget
---@field name string
local Widget = {}

---@param self readonly Widget
function Widget:rename()
    self.<!name!> = 'x'
end
]]

-- a parameter without the keyword: unaffected
TEST [[
---@class Config
---@field name string

---@param t Config
local function f(t)
    t.name = 'x'
    table.insert({}, t)
end
]]

-- only a direct reference is followed: an alias, or what a call returns, is not seen
TEST [[
---@param t readonly integer[]
local function f(t)
    local u = t
    u[1] = 0 -- not `u` itself declared readonly
end

---@return readonly integer[]
local function g()
    return {}
end

local function h()
    g()[1] = 0 -- not a direct reference either
end
]]

-- `table.move` is not covered at all (documented limitation: which argument it mutates depends on
-- whether the destination `a2` is given)
TEST [[
---@param t readonly integer[]
local function f(t)
    table.move(t, 1, 2, 1) -- the source: not checked
    table.move({1, 2, 3}, 1, 2, 1, t) -- the destination `a2`: not checked either
end
]]

-- silenced where wanted
TEST [[
---@param t readonly integer[]
local function f(t)
    ---@diagnostic disable-next-line: mutate-readonly
    t[1] = 0
end
]]
