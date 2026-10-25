TEST [[
---@return number
function F()
    return <!true!>
end
]]

TEST [[
---@return number?
function F()
    return 1
end
]]

TEST [[
---@return number?
function F()
    return nil
end
]]

TEST [[
---@return number, number
local function f()
    return 1, 1
end

---@return number, boolean
function F()
    return <!f()!>
end
]]

TEST [[
---@return boolean, number
local function f()
    return true, 1
end

---@return number, boolean
function F()
    return <!f()!>
end
]]

TEST [[
---@return boolean, number?
local function f()
    return true, 1
end

---@return number, boolean
function F()
    return 1, f()
end
]]

TEST [[
---@return number, number?
local function f()
    return 1, 1
end

---@return number, boolean, number
function F()
    return 1, <!f()!>
end
]]

TEST [[
---@class A
---@field x number?

---@return number
function F()
    ---@type A
    local t
    return t.x
end
]]

TEST [[
---@class A
---@field x number?
local t = {}

---@return number
function F()
    return t.x
end
]]

TEST [[
---@param ... number
local function f(...)
end

f(nil)
]]

TEST [[
---@return number
function F()
    local n = 0
    if true then
        n = 1
    end
    return n
end
]]

TEST [[
---@param x boolean
---@return number
---@overload fun(): boolean
local function f(x)
    if x then
        return 1
    else
        return false
    end
end
]]

TEST [[
---@param x boolean
---@return number
---@overload fun()
local function f(x)
    if x then
        return 1
    else
        return
    end
end
]]

TEST [[
---@param x boolean
---@return number
---@overload fun()
local function f(x)
    if x then
        return 1
    end
end
]]

TEST [[
---@param x boolean
---@return number
---@overload fun(): boolean, boolean
local function f(x)
    if x then
        return 1
    else
        return false, false
    end
end
]]

TEST [[
---@type fun():number
local function f()
    return <!true!>
end
]]

-- tuple-union returns: each returned value is still checked against its slot's union
TEST [[
---@return (string, nil) | (nil, number)
local function f()
    return <!1!>, 2
end
]]

TEST [[
---@return (string, nil) | (nil, number)
local function f(cond)
    if cond then return 'a', nil end
    return nil, 3
end
]]

-- a value that fails its own slot reports the slot only, not the combination too
TEST [[
---@return (string, number) | (nil, nil)
local function f()
    return <!true!>, 1
end
]]

-- a returned array: the element type has to fit
TEST [[
---@type number[]
local nums = {}

---@return string[]
local function wrong()
    return <!nums!>
end

---@return number[]
local function right()
    return nums
end
]]

-- a returned value against a type nothing declares is not a mismatch (undefined-doc-name reports the name)
TEST [[
---@return GhostType
local function ghost() return 1 end
---@return GhostType?
local function ghostOptional() return 'x' end
---@class RealOne
---@return RealOne
local function real() return <!1!> end
]]

-- the fallback literal of a returned `x or "lit"` is checked against the declared return type
TEST [[
---@alias RfMode "queue"|"latest"
---@return string
local function str() end
---@return boolean
local function flag() end
---@return RfMode
local function bad1() return str() or <!"quue"!> end
---@return RfMode
local function bad2() return <!flag() and "quue" or "latest"!> end
---@return RfMode
local function good1() return str() or "queue" end
---@return RfMode
local function good2() return flag() and "queue" or "latest" end
---@return string
local function plain() return str() or "anything" end
]]
