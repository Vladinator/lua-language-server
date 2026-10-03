-- tuple-union returns: the values must also fit ONE of the declared cases together (each value
-- fitting its own slot is not enough)
TEST [[
---@return (string, nil) | (nil, number)
local function f(cond)
    if cond then <!return 'a', 1!> end
    <!return nil, nil!>
end
]]

-- the cases that do fit are accepted, in any branch
TEST [[
---@return (string, number) | (nil, nil)
local function f(cond)
    if cond then return 'x', 1 end
    return nil, nil
end
]]

-- fewer values than slots, a value of unknown shape, and a call spread are not judged
TEST [[
---@return (string, number) | (nil, nil)
local function f(cond, g)
    if cond then return end
    if cond then return 'x' end
    return g()
end
]]

-- a declared-type value (not a literal) is judged by its type
TEST [[
---@return (string, number) | (nil, nil)
local function f(s, n)
    ---@type string
    local a = s
    ---@type number?
    local b = n
    <!return a, b!>
end
]]

-- a value that fails its own slot is return-type-mismatch's, not reported here
TEST [[
---@return (string, number) | (nil, nil)
local function f()
    return true, 1
end
]]
