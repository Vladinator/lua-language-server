TEST [[
local _ <close> = <!1!>
]]

TEST [[
local _ <close> = <!''!>
]]

TEST [[
local c <close> = <!(function () return 1 end)()!>
]]

TEST [[
---@type unknown
local t

local _ <close> = t
]]

-- `nil` and `false` are the two values that are not closed: fine
TEST [[
local a <close> = nil
local b <close> = false
]]

-- ... `true` and the other values are not
TEST [[
local a <close> = <!true!>
local b <close> = <!0!>
]]
