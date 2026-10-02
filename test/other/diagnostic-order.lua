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
-- (whichever plugin diagnostics are there: core/diagnostics/extra/)
for _, name in ipairs(require 'extra_diagnostics'()) do
    assert(define.DiagnosticDefaultSeverity[name], name .. ': plugin diagnostic missing from define')
    for _, group in ipairs(diagd.getGroups(name)) do
        assert(define.DiagnosticDefaultGroupSeverity[group], group .. ': plugin group missing from define')
    end
end

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

-- Every call returns a list of its own. A file's diagnoses walk the list across `await.delay()`
-- yields while other files' diagnoses ask for it again, and in `cost` mode that call re-sorts the
-- order as costs are measured: when the list was one shared table, an entry moving under a live
-- `ipairs` was skipped, so a diagnostic never ran on that file -- only in the editor (files are
-- diagnosed concurrently), only in `cost` mode, and so chaotically that the `unfulfilled-expect` of
-- the suppression it did not run for was the only symptom (found 2026-10-02, `editor_sim`).
local a = diagd.getRunOrder()
local b = diagd.getRunOrder()
assert(a ~= b, 'getRunOrder returned the same table twice: callers walking it across yields see the re-sorts of the others')
for i = 1, #a // 2 do
    a[i], a[#a - i + 1] = a[#a - i + 1], a[i]    -- what a re-sort does to a list somebody is still walking
end
table.remove(a)
assert(table.concat(diagd.getRunOrder(), ' ') == first, 'a caller changing its list changed what the next call returns')
assert(table.concat(b, ' ') == first, 'a caller changing its list changed the list of another caller')
