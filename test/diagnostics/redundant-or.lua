-- the left side is always truthy: the right one is dead
TEST [[
---@type string
local s
---@type table
local t

local _ = s or <!'x'!>
local _ = t or <!{}!>
local _ = 1 or <!2!>
local _ = 'a' or <!nil!>
]]

-- an optional, boolean, `any`, unknown or narrowed-to-maybe left side is a real default
TEST [[
---@type string?
local a
---@type boolean
local b
---@type any
local c
---@type string | false
local d

local _ = a or 'x'
local _ = b or 1
local _ = c or 1
local _ = d or 1
local _ = unknownGlobal or 1
local function f(p) return p or 1 end
]]

-- a chain: the middle one is what is dead
TEST [[
---@type string?
local a
---@type string
local s

local _ = a or s or <!'x'!>
]]
