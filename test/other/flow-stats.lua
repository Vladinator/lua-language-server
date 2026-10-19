local stats = require 'vm.flow-stats'

-- The counters of the flow engine (`LLS_FLOW_STATS=<file>`, see PERF-ANALYSIS.md in the docs repo). The callers test `stats.enabled`
-- first; this checks the module they call: the sums, the distributions, the file that is written and its order.

assert(type(stats.enabled) == 'boolean', 'enabled is a boolean')

stats.reset()
assert(stats.get('nothing yet') == 0, 'an unknown counter is zero')

stats.add('calls')
stats.add('calls')
stats.add('items', 5)
assert(stats.get('calls') == 2, 'one per add')
assert(stats.get('items') == 5, 'an amount')

stats.time('work', 0.25)
stats.time('work', 0.5)
stats.sample('size', 3)
stats.sample('size', 10)
stats.sample('size', 4)

local path = TESTROOT .. 'flow-stats-dump.txt'
stats.dump(path)
local file = assert(io.open(path, 'r'))
---@type string
local text = assert(file:read('a'))
file:close()
os.remove(path)

---@type table<string, string>
local lines = {}
---@type string[]
local order = {}
for line in text:gmatch('[^\n]+') do
    local tab  = assert(line:find('\t', 1, true), 'a name, a tab and a value')
    local name = line:sub(1, tab - 1)
    lines[name] = line:sub(tab + 1)
    order[#order+1] = name
end
assert(lines['calls'] == '2', 'calls: ' .. tostring(lines['calls']))
assert(lines['items'] == '5', 'items')
assert(lines['work (s)'] == '0.750', 'time sums: ' .. tostring(lines['work (s)']))
assert(lines['work calls'] == '2', 'time counts its samples')
assert(lines['size sum'] == '17' and lines['size n'] == '3' and lines['size max'] == '10', 'distribution: ' .. text)
---@type string[]
local sorted = {}
for i, name in ipairs(order) do
    sorted[i] = name
end
table.sort(sorted)
assert(table.concat(order, '|') == table.concat(sorted, '|'), 'the lines are sorted by name')

-- negative: reset forgets everything, a dump to a path that cannot be written does not raise
stats.reset()
assert(stats.get('calls') == 0 and stats.get('items') == 0, 'reset')
assert(pcall(stats.dump, TESTROOT .. 'no-such-folder/never/stats.txt'), 'an unwritable path is ignored')
