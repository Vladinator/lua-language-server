TEST [[
---@type fun():number
local function f()
    return 1, <!true!>
end
]]

TEST [[
---@return number, number?
function F()
    return 1, 1, <!1!>
end
]]

TEST [[
---@return number, number?
function F()
    return 1, 1, <!1!>, <!2!>, <!3!>
end
]]

TEST [[
---@meta

---@return number, number
local function r2() end

---@return number, number?
function F()
    return 1, <!r2()!>
end
]]

-- 返回列表以 `...` 结尾：最大数量是无穷，格式化消息时不能崩溃
TEST [[
---@return number
function F(...)
    return 1, <!2!>, <!...!>
end
]]
