-- nothing secret to unwrap: reported on the tag
TEST [[
---@<!secret-unwrap!>
local x = 1
]]

-- inherited secrecy is cleared: the tag did its job
TEST [[
---@secret
---@class A
---@field a number

local function f()
    ---@type A
    return { a = 0 }
end

---@secret-unwrap
local x = f()
print(x.a)
]]
