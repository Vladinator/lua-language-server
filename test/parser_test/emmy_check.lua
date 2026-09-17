local parser = require 'parser'

local EXISTS = {}

---@param a any
---@param b any
---@return boolean
local function eq(a, b)
    if a == EXISTS and b ~= nil then
        return true
    end
    local tp1, tp2 = type(a), type(b)
    if tp1 ~= tp2 then
        return false
    end
    if tp1 == 'table' then
        ---@type table<any, true>
        local mark = {}
        for k in pairs(a --[[@as table<any, any>]]) do
            if not eq(a[k], b[k]) then
                return false
            end
            mark[k] = true
        end
        for k in pairs(b --[[@as table<any, any>]]) do
            if not mark[k] then
                return false
            end
        end
        return true
    end
    return a == b
end

---@alias emmy_check.target [integer, integer]

---@param script string
---@param sep    string
---@return string
---@return emmy_check.target[]
local function catchTarget(script, sep)
    ---@type emmy_check.target[]
    local list = {}
    local cur = 1
    local cut = 0
    while true do
        local start, finish  = script:find(('<%%%s.-%%%s>'):format(sep, sep), cur)
        if not start or not finish then
            break
        end
        list[#list+1] = { start - cut, math.max(start - cut, finish - 4 - cut) }
        cur = finish + 1
        cut = cut + 4 --[[@as integer]]
    end
    local new_script = script:gsub(('<%%%s(.-)%%%s>'):format(sep, sep), '%1')
    return new_script, list
end

---@type string?
local Version

---@class emmy_check.expect
---@field type    string
---@field multi?  integer
---@field version? any
---@field info?    any

---@param script string
---@return fun(expect?: emmy_check.expect)
local function TEST(script)
    return function (expect)
        local newScript, list = catchTarget(script, '!')
        local state = parser.compile(newScript, 'Lua', Version)
        local errs, emmy = state.errs, state.comms
        assert(emmy)
        assert(errs)
        local first = errs[1]
        local target = list[1]
        if not expect then
            assert(#errs == 0)
            return
        end
        if expect.multi then
            assert(#errs > 1)
            first = errs[expect.multi]
        else
            assert(#errs == 1)
        end
        assert(first)
        assert(target)
        assert(first.type == expect.type)
        assert(first.start == target[1])
        assert(first.finish == target[2])
        assert(eq(first.version, expect.version))
        assert(eq(first.info, expect.info))
    end
end

TEST[[
---@class <!!>
]]
{
    type = 'MISS_NAME',
}

TEST[[
---@class Class :<!!>
]]
{
    type = 'MISS_NAME',
}

TEST[[
---@type <!!>
]]
{
    type = 'MISS_NAME',
}

TEST[[
---@type Type1|<!!>
]]
{
    type = 'MISS_NAME',
}
