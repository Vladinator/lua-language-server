-- always falsy on the left: the right one is dead; always truthy: the `and` is a no-op
TEST [[
local _ = nil and <!1!>
local _ = false and <!1!>
---@type string
local s
local _ = <!s!> and 1
local _ = <!{}!> and 1
]]

-- real conditions are fine
TEST [[
---@type string?
local a
---@type boolean
local b
---@type any
local c
---@type string | false
local d

local _ = a and 1
local _ = b and 1
local _ = c and 1
local _ = d and 1
local _ = unknownGlobal and 1
local function f(p) return p and 1 end
]]
