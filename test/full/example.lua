local util   = require 'utility'
local files  = require 'files'
local diag   = require 'core.diagnostics'
local config = require 'config'
local fs     = require 'bee.filesystem'
local luadoc = require "parser".luadoc

-- 临时
---@diagnostic disable: await-in-sync
---@param path fs.path
local function testIfExit(path)
    config.set(nil, 'Lua.workspace.preloadFileSize', 1000000000)
    local buf = util.loadFile(path:string())
    if buf then
        ---@type table<string, any>?
        local state

        local clock = os.clock()
        local max = 1
        ---@type number
        local need
        local compileClock = 0
        local luadocClock = 0
        local noderClock = 0
        ---@type integer
        local total
        for i = 1, max do
            state = TEST(buf) --[[@as table<string, any>]]
            local luadocStart = os.clock()
            luadoc(state)
            local luadocPassed = os.clock() - luadocStart
            local passed = os.clock() - clock
            local noderStart = os.clock()
            local noderPassed = os.clock() - noderStart
            local curState = state --[[@as table<string, any>]]
            local curCompileClock = curState.compileClock --[[@as number]]
            compileClock = (compileClock + curCompileClock) --[[@as number]]
            luadocClock  = (luadocClock  + luadocPassed) --[[@as number]]
            noderClock   = (noderClock   + noderPassed) --[[@as number]]
            if passed >= 1.0 or i == max then
                need = passed / i
                total = i
                break
            end
        end
        print(('基准编译测试[%s]单次耗时：%.10f(解析：%.10f, LuaDoc: %.10f, Noder: %.10f)'):format(
            path:filename():string(),
            need,
            compileClock / total,
            luadocClock / total,
            noderClock / total
        ))

        local clock = os.clock()
        local max = 100
        ---@type number
        local need
        for i = 1, max do
            files.open(TESTURI)
            files.setText(TESTURI, buf)
            diag(TESTURI, false, function () end)
            local passed = os.clock() - clock
            if passed >= 1.0 or i == max then
                need = passed / i
                break
            end
            files.remove(TESTURI)
        end
        print(('基准诊断测试[%s]单次耗时：%.10f'):format(path:filename():string(), need))
    end
end

testIfExit(ROOT / 'test' / 'example' / 'vm.txt')
testIfExit(ROOT / 'test' / 'example' / 'largeGlobal.txt')
testIfExit(ROOT / 'test' / 'example' / 'guide.txt')
testIfExit(ROOT / 'test' / 'example' / 'jass-common.txt')
testIfExit(fs.path [[D:\github\test\ECObject.lua]])
