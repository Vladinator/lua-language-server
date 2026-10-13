---@diagnostic disable: await-in-sync
local core  = require 'core.linked-editing'
local files = require 'files'
local catch = require 'catch'

--- `<!x!>` marks every range that must be edited together, `<?x?>` the cursor (which is one of them or, for `none`, nowhere special).
---@param script string
function TEST(script)
    local newScript, catched = catch(script, '!?')
    files.setText(TESTURI, newScript)
    local input = catched['?'][1]
    local pos = (input[1] --[[@as integer]] + input[2] --[[@as integer]]) // 2
    local ranges = core(TESTURI, pos)
    assert(ranges, 'no linked ranges')
    local expect = catched['!']
    assert(#ranges == #expect, ('%d ranges, wanted %d'):format(#ranges, #expect))
    for _, target in ipairs(expect) do
        local found = false
        for _, range in ipairs(ranges) do
            if range.start == target[1] and range.finish == target[2] then
                found = true
            end
        end
        assert(found, 'missing range ' .. target[1])
    end
    files.remove(TESTURI)
end

---@param script string
function NONE(script)
    local newScript, catched = catch(script, '?')
    files.setText(TESTURI, newScript)
    local input = catched['?'][1]
    local pos = (input[1] --[[@as integer]] + input[2] --[[@as integer]]) // 2
    assert(core(TESTURI, pos) == nil, 'wanted no linked ranges')
    files.remove(TESTURI)
end

-- a local variable: its declaration and every use
TEST [[
local <?<!x!>?> = 5
local y = <!x!> + 2
local z = <!x!> * 3
]]

-- from a use
TEST [[
local <!x!> = 5
local y = <?<!x!>?> + 2
]]

-- a parameter, with the `---@param` line
TEST [[
---@param <!name!> string
local function greet(<!name!>)
    return "Hello " .. <?<!name!>?>
end
]]

-- a reassigned local: every version
TEST [[
local <!m!> = 1
<!m!> = "hello"
local n = <?<!m!>?>
]]

-- a local function and its call
TEST [[
local function <!helper!>()
end
<?<!helper!>?>()
]]

-- loop variables
TEST [[
for <!i!> = 1, 10 do
    local val = <?<!i!>?> * 2
end
]]

-- shadowing: only the inner variable
TEST [[
local x = 1
do
    local <!x!> = 20
    local b = <?<!x!>?> + 1
end
print(x)
]]

-- a field named like a local is a field, not the local
TEST [[
local <!key!> = 1
local t = { key = <?<!key!>?> }
]]

-- a global, a field, the key of a constructor and a standard function are not eligible
NONE [[
function GlobalFunc()
end
<?GlobalFunc?>()
]]

NONE [[
local t = {}
t.foo = 1
local v = t.<?foo?>
]]

NONE [[
local key = 1
local t = { <?key?> = key }
]]

NONE [[
<?print?>("hi")
]]

-- nothing under the cursor
NONE [[
local x = 1 <??>
]]

-- `self` is not edited by typing
NONE [[
local obj = {}
function obj:method()
    return <?self?>
end
]]

-- from an assignment to the variable
TEST [[
local <!m!> = 1
<?<!m!>?> = "hello"
print(<!m!>)
]]
