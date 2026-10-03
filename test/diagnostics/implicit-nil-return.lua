-- a bare return where the first @return can be nil
TEST [[
---@return string?
local function f(a)
    if a then
        <!return!>
    end
    return 'x'
end

---@return number?, string
local function g(a)
    if a then
        <!return!>
    end
    return 1, 'x'
end
]]

-- explicit nil, a value, a non-optional first return, no @return, a nested function: not reported
TEST [[
---@return string?
local function f(a)
    if a then
        return nil
    end
    if a == 1 then
        return 'y'
    end
    return 'x'
end

---@return string
local function g(a)
    if a then
        return
    end
    return 'x'
end

local function h(a)
    if a then
        return
    end
    return 'x'
end

---@return string?
local function k()
    local function inner(a)
        if a then
            return
        end
    end
    return inner(1)
end

---@return nil
local function n()
    return
end
]]

-- `any` and a nil-only first return: only the one that can be nil is reported ... nil itself is fine to write bare
TEST [[
---@return any
local function a(x)
    if x then
        return
    end
    return 1
end
]]
