---@diagnostic disable: await-in-sync
local core  = require 'core.call-hierarchy'
local files = require 'files'
local catch = require 'catch'
local guide = require 'parser.guide'

local SCRIPT = [[
---@class CHFoo
local CHFoo = {}

function CHFoo:greet(name)
    return "hello " .. name
end

function CHFoo:wave()
    self:greet("world")
end

local function <!helper!>(x)
    return x + 1
end

local function caller_a()
    helper(10)
    helper(20)
end

local function caller_b()
    helper(30)
end

local function nested_example()
    helper(40)
    local inner = function()
        helper(50)
    end
    caller_a()
end

local alone = function () end
local function unused() end
local function printer()
    print("standard library")
end

helper(99)
]]

--- The items at the mark `<?x?>` in `script`, which is the file for the call.
---@param script string
---@return core.call-hierarchy.item[]?
local function prepareAt(script)
    local newScript, catched = catch(script, '?')
    files.setText(TESTURI, newScript)
    assert(files.getState(TESTURI))
    local input = catched['?'][1]
    return core.prepare(TESTURI, (input[1] --[[@as integer]] + input[2] --[[@as integer]]) // 2)
end

---@param calls core.call-hierarchy.call[]
---@return string
local function summary(calls)
    ---@type string[]
    local list = {}
    for _, call in ipairs(calls) do
        list[#list+1] = ('%s x%d'):format(call.item.name, #call.ranges)
    end
    return table.concat(list, ', ')
end

--- Items by name from a prepare at the first use of each.
local function itemNamed(name)
    local items = prepareAt(SCRIPT:gsub('<!helper!>', 'helper'):gsub('local function ' .. name .. '%(', 'local function <?' .. name .. '?>('))
    assert(items and items[1], 'no item for ' .. name)
    return items[1]
end

-- prepare: a definition, a method definition, a call, nothing
do
    local items = itemNamed('helper')
    assert(items.name == 'helper' and not items.isMethod, 'a local function')
end
do
    local items = prepareAt [[
local Foo = {}
function Foo:<?greet?>(name) end
]]
    assert(items and items[1].name == 'Foo:greet' and items[1].isMethod, 'a method keeps its class and colon')
end
do
    local items = prepareAt [[
local Foo = {}
function Foo.<?make?>() end
]]
    assert(items and items[1].name == 'Foo.make' and not items[1].isMethod, 'a field function keeps its class and dot')
end
do
    local items = prepareAt [[
local function helper() end
<?helper?>()
]]
    assert(items and items[1].name == 'helper', 'from a call')
end
do
    local items = prepareAt [[
local x = 1
print(<?x?>)
]]
    assert(items == nil, 'a number is not a function')
end

-- outgoing: the direct calls of a body, grouped by callee; nested functions do not count
do
    local item = itemNamed('caller_a')
    assert(summary(core.outgoing(item)) == 'helper x2', item.name .. ' ' .. item.start .. '-' .. item.finish .. ': ' .. summary(core.outgoing(item)))
end
do
    local item = itemNamed('nested_example')
    local outgoing = summary(core.outgoing(item))
    assert(outgoing == 'helper x1, caller_a x1', 'direct calls only, helper(50) is the inner function\'s: ' .. outgoing)
end
do
    local item = itemNamed('unused')
    assert(summary(core.outgoing(item)) == '', 'a function that calls nothing')
end

-- the standard library is not an outgoing call
do
    local item = itemNamed('printer')
    assert(summary(core.outgoing(item)) == '', summary(core.outgoing(item)))
end

-- incoming: every call of the function, grouped by the function it is written in
do
    local item = itemNamed('helper')
    local incoming = summary(core.incoming(item))
    assert(incoming == 'caller_a x2, caller_b x1, nested_example x1, inner x1', 'the call at file level has no function: ' .. incoming)
end
do
    local item = itemNamed('caller_a')
    assert(summary(core.incoming(item)) == 'nested_example x1', summary(core.incoming(item)))
end
do
    local item = itemNamed('unused')
    assert(summary(core.incoming(item)) == '', 'nobody calls it')
end

-- a method: found through `self:greet(...)` inside another method
do
    local items = prepareAt [[
local CHFoo = {}
function CHFoo:<?greet?>(name) end
function CHFoo:wave()
    self:greet("world")
end
]]
    local item = assert(items and items[1])
    assert(summary(core.incoming(item)) == 'CHFoo:wave x1', summary(core.incoming(item)))
    local waveItems = prepareAt [[
local CHFoo = {}
function CHFoo:greet(name) end
function CHFoo:<?wave?>()
    self:greet("world")
end
]]
    local wave = assert(waveItems and waveItems[1])
    assert(summary(core.outgoing(wave)) == 'CHFoo:greet x1', summary(core.outgoing(wave)))
end

-- the call ranges are where the callee's name is written
do
    local item = itemNamed('caller_b')
    local calls = core.outgoing(item)
    local range = assert(calls[1]).ranges[1]
    local text  = assert(files.getText(TESTURI))
    local state = assert(files.getState(TESTURI))
    local from  = guide.positionToOffset(state, range.start)
    local to    = guide.positionToOffset(state, range.finish)
    assert(text:sub(from + 1, to) == 'helper', 'the name at the call')
end

files.remove(TESTURI)
