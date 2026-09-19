local helper = require 'plugins.astHelper'
local parser = require 'parser'

---@param script string
---@param plugin fun(state: parser.state)
---@return parser.state
function Run(script, plugin)
    local state = parser.compile(script, "Lua", "Lua 5.4")
    plugin(state)
    parser.luadoc(state)
    return state
end

local function TestInsertDoc(script)
    local state = assert(Run(script, function (state)
        assert(state)
        local comment = assert(helper.buildComment("class", "AA", state.ast[1].start))
        helper.InsertDoc(state.ast, comment)
    end))
    local ast = assert(state.ast)
    local first = assert(ast[1])
    assert(first.bindDocs)
end

TestInsertDoc("A={}")

local function TestaddClassDoc(script)
    local state = assert(Run(script, function (state)
        assert(state)
        assert(helper.addClassDoc(state.ast, state.ast[1], "AA"))
    end))
    local ast = assert(state.ast)
    local first = assert(ast[1])
    assert(first.bindDocs)
end

TestaddClassDoc [[a={}]]

TestaddClassDoc [[local a={}]]

---@param script string
---@param index? integer
local function TestaddClassDocAtParam(script, index)
    index = index or 1
    ---@type parser.object?
    local arg
    local state = Run(script, function (state)
        local func = assert(state.ast[1].value)
        local ok
        ok, arg = helper.addClassDocAtParam(state.ast, "AA", func, index)
        assert(ok)
    end)
    local arg2 = assert(arg)
    assert(arg2.bindDocs)
end

TestaddClassDocAtParam [[
    function a(b) end
]]

---@param script string
---@param index? integer
local function TestaddParamTypeDoc(script, index)
    index = index or 1
    ---@type parser.object?
    local func
    Run(script, function (state)
        func = state.ast[1].value --[[@as parser.object]]
        assert(helper.addParamTypeDoc(state.ast, "string", func.args[index]))
    end)
    local func2 = assert(func)
    assert(func2.args[index].bindDocs)
end

TestaddParamTypeDoc [[
    local function t(a)end
]]

TestaddParamTypeDoc([[
    local function t(a,b,c,d)end
]], 4)
