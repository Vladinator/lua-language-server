-- a name that matches no local of the statement
TEST [[
---@secret <!nothere!>
local a = 1
]]

TEST [[
---@secret a, <!nothere!>
local a, b = 1, 2
]]

TEST [[
---@secret-unwrap <!oops!>
local a = 1
]]

TEST [[
---@nosecret a, <!oops!>
local a, b = 1, 2
]]

-- all names found: fine
TEST [[
---@secret b
local a, b = 1, 2
]]
