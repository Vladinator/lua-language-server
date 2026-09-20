-- The order in which the diagnostics run on a file is reproducible, complete, and comes from the
-- live registry. It matters because what the first diagnostic compiles is cached for the ones
-- after it (see core/diagnostics/init.lua, LLS_DIAG_ORDER, and tools/validate.py --seeds).
local define = require 'proto.define'
local diagd  = require 'proto.diagnostic'
require 'core.diagnostics'

-- `define` keeps LIVE tables: diagnostics that registered after it loaded (the self-registering
-- plugins) are in them, so `--checklevel`, completion and `isEnabled` know them
assert(define.DiagnosticDefaultSeverity == diagd.getDefaultSeverity())
assert(define.DiagnosticDefaultNeededFileStatus == diagd.getDefaultStatus())
for name, data in pairs(diagd.diagnosticDatas) do
    assert(define.DiagnosticDefaultSeverity[name] == data.severity, name)
    assert(define.DiagnosticDefaultNeededFileStatus[name] == data.status, name)
end
assert(define.DiagnosticDefaultSeverity['need-check-secret'], 'plugin diagnostic missing from define')
assert(define.DiagnosticDefaultGroupSeverity['secret'], 'plugin group missing from define')

-- every registered diagnostic runs exactly once, `unfulfilled-expect` (always last) is not in the list
local order = diagd.getRunOrder()
---@type table<string, integer>
local count = {}
for _, name in ipairs(order) do
    count[name] = (count[name] or 0) + 1
    assert(diagd.diagnosticDatas[name], name .. ' is not registered')
end
for name in pairs(diagd.diagnosticDatas) do
    if name == 'unfulfilled-expect' then
        assert(not count[name], 'unfulfilled-expect must not be in the list')
    else
        assert(count[name] == 1, name .. ' must run exactly once')
    end
end

-- asking again gives the same order (ties used to be broken arbitrarily, and the list was
-- re-sorted in place on every file)
local first = table.concat(order, ' ')
for _ = 1, 5 do
    assert(table.concat(diagd.getRunOrder(), ' ') == first, 'the run order changed between calls')
end
