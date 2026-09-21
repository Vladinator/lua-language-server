TEST [[
---@type fun():number
local function f()
<!!>end
]]

TEST [[
---@type fun():number?
local function f()
end
]]

TEST [[
---@type fun():...
local function f()
end
]]

TEST [[
---@return number
function F()
    X = 1<!!>
end
]]
TEST [[
local A
---@return number
function F()
    if A then
        return 1
    end<!!>
end
]]

TEST [[
local A, B
---@return number
function F()
    if A then
        return 1
    elseif B then
        return 2
    end<!!>
end
]]

TEST [[
local A, B
---@return number
function F()
    if A then
        return 1
    elseif B then
        return 2
    else
        return 3
    end
end
]]

TEST [[
local A, B
---@return number
function F()
    if A then
    elseif B then
        return 2
    else
        return 3
    end<!!>
end
]]

TEST [[
---@return any
function F()
    X = 1
end
]]

TEST [[
---@return any, number
function F()
    X = 1<!!>
end
]]

TEST [[
---@return number, any
function F()
    X = 1<!!>
end
]]

TEST [[
---@return any, any
function F()
    X = 1
end
]]

TEST [[
local A
---@return number
function F()
    for _ = 1, 10 do
        if A then
            return 1
        end
    end
    error('should not be here')
end
]]

TEST [[
local A
---@return number
function F()
    while true do
        if A then
            return 1
        end
    end
end
]]

TEST [[
local A
---@return number
function F()
    while A do
        if A then
            return 1
        end
    end<!!>
end
]]

TEST [[
local A
---@return number
function F()
    while A do
        if A then
            return 1
        else
            return 2
        end
    end
end
]]

TEST [[
---@return number?
function F()

end
]]

TEST [[
---@generic T
---@param t T
---@return T
function F(t)
	return t
end
]]

TEST [[
---@generic T
---@param t T
---@return T?
function F(t)

end
]]

-- `---@return never`: a call of a function that never returns ends the function like `error` does,
-- and the function itself is not asked for a return
TEST [[
---@return never
local function fail(msg)
    error(msg)
end

---@return integer
local function f(x)
    if x then
        return 1
    end
    fail('no')
end

---@return integer
local function g(x)
    if x then
        return 1
    else
        fail('no')
    end
end

local M = {}

---@return never
function M.die() error('x') end

---@return integer
function M.h()
    M.die()
end
]]

-- an ordinary function is still asked for its return
TEST [[
---@return integer
local function plain(msg)
    return 1
end

---@return integer
local function f(x)
    plain('no')<!!>
end
]]
