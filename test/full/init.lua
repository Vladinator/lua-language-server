local parser  = require 'parser'
local util    = require 'utility'

rawset(_G, 'TEST', true)

---@param script string
function TEST(script)
    local clock = os.clock()
    local state = parser.compile(script, 'Lua', 'Lua 5.4')
    ---@diagnostic disable-next-line: inject-field -- test-only timing instrumentation, not a real parser.state field
    state.compileClock = os.clock() - clock
    return state
end

local function startCollectDiagTimes()
    DIAGTIMES = {} --[[@as table<string, number>]]
end

startCollectDiagTimes()
require 'full.normal'
require 'full.example'
require 'full.dirty'
require 'full.projects'
require 'full.self'

---@type string[]
local times = {}
for name, time in util.sortPairs(DIAGTIMES --[[@as table<string, number>]], function (k1, k2)
    return DIAGTIMES[k1] > DIAGTIMES[k2]
end) do
    times[#times+1] = ('诊断任务耗时：%05.3f [%s]'):format(time, name)
    if #times >= 10 then
        break
    end
end

util.revertArray(times)
for _, time in ipairs(times) do
    print(time)
end
