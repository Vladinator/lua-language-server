-- wowlua-ls names for diagnostics we have under their original LuaLS name: accepted in `---@diagnostic`,
-- in `diagnostics.disable` and in `severity`, naming the canonical diagnostic. The canonical name keeps working.
-- DIAG_CARE is the three codes (and unfulfilled-expect) the cases are about.
local config = require 'config'
local core   = require 'core.diagnostics'
local files  = require 'files'

---@diagnostic disable: await-in-sync

DIAG_CARE = {
    ['param-type-mismatch']  = true,
    ['return-type-mismatch'] = true,
    ['invisible']            = true,
    ['unfulfilled-expect']   = true,
    ['unknown-diag-code']    = true,
}

-- param-type-mismatch: no alias, a report
TEST [[
---@param x number
local function f(x) end
f(<!'a'!>)
]]

-- the alias silences it, in every mode of the comment
TEST [[
---@param x number
local function f(x) end
---@diagnostic disable-next-line: type-mismatch
f('a')
]]
TEST [[
---@diagnostic disable: type-mismatch
---@param x number
local function f(x) end
f('a')
]]
-- the alias of another diagnostic does not
TEST [[
---@param x number
local function f(x) end
---@diagnostic disable-next-line: return-mismatch
f(<!'a'!>)
]]
-- and the alias is the same as the canonical name, for expect-next-line too (no unfulfilled-expect)
TEST [[
---@param x number
local function f(x) end
---@diagnostic expect-next-line: type-mismatch
f('a')
]]

-- return-type-mismatch
TEST [[
---@return number
local function f()
    ---@diagnostic disable-next-line: return-mismatch
    return 'a'
end
]]
TEST [[
---@return number
local function f()
    return <!'a'!>
end
]]

-- invisible: both wowlua-ls codes
TEST [[
---@class A
---@field private x number
---@field protected y number
---@type A
local t
---@diagnostic disable-next-line: access-private
print(t.x)
---@diagnostic disable-next-line: access-protected
print(t.y)
]]
TEST [[
---@class A
---@field private x number
---@type A
local t
print(t.<!x!>)
]]

--- Whether `type-mismatch` code is reported for `script` under the current config.
---@param script string
---@return boolean
local function reports(script)
    files.setText(TESTURI, script)
    files.open(TESTURI)
    local found = false
    core(TESTURI, false, function (result)
        if result.code == 'param-type-mismatch' then
            found = true
        end
    end)
    files.remove(TESTURI)
    return found
end

local script = '---@param x number\nlocal function f(x) end\nf("a")\n'
assert(reports(script), 'reported without a setting')

-- diagnostics.disable with the alias
local disable = config.get(nil, 'Lua.diagnostics.disable')
config.set(nil, 'Lua.diagnostics.disable', { 'type-mismatch' })
assert(not reports(script), 'disabled by the alias')
config.set(nil, 'Lua.diagnostics.disable', { 'return-mismatch' })
assert(reports(script), 'another alias disables another diagnostic')
config.set(nil, 'Lua.diagnostics.disable', disable)
assert(reports(script), 'enabled again')

-- severity under the alias is the severity of the canonical diagnostic
local severity = config.get(nil, 'Lua.diagnostics.severity')
---@type table<string, string>
local newSeverity = {}
for k, v in pairs(severity --[[@as table<string, string>]]) do
    newSeverity[k] = v
end
newSeverity['type-mismatch'] = 'Hint!'
config.set(nil, 'Lua.diagnostics.severity', newSeverity)
---@type integer?
local level
files.setText(TESTURI, script)
files.open(TESTURI)
core(TESTURI, false, function (result)
    if result.code == 'param-type-mismatch' then
        level = result.level
    end
end)
files.remove(TESTURI)
config.set(nil, 'Lua.diagnostics.severity', severity)
assert(level == 4, 'Hint, not the default: ' .. tostring(level))

-- neededFileStatus under the alias: None switches the canonical diagnostic off; another alias does not
local statuses = config.get(nil, 'Lua.diagnostics.neededFileStatus')
---@type table<string, string>
local newStatuses = {}
for k, v in pairs(statuses --[[@as table<string, string>]]) do
    newStatuses[k] = v
end
-- (the suite forces every status to `Any!`, which would win over an alias: put the default back)
newStatuses['param-type-mismatch'] = 'Opened'
newStatuses['type-mismatch'] = 'None'
config.set(nil, 'Lua.diagnostics.neededFileStatus', newStatuses)
assert(not reports(script), 'status None by the alias')
---@type table<string, string>
local otherStatuses = {}
for k, v in pairs(statuses --[[@as table<string, string>]]) do
    otherStatuses[k] = v
end
otherStatuses['param-type-mismatch'] = 'Opened'
otherStatuses['return-mismatch'] = 'None'
config.set(nil, 'Lua.diagnostics.neededFileStatus', otherStatuses)
assert(reports(script), 'the status of another diagnostic')
config.set(nil, 'Lua.diagnostics.neededFileStatus', statuses)
