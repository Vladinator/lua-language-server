local files         = require 'files'
local define        = require 'proto.define'
local config        = require 'config'
local await         = require 'await'
local vm            = require "vm.vm"
local util          = require 'utility'
local diagd         = require 'proto.diagnostic'
local customPlugins = require 'core.diagnostics.custom-plugins'

-- Diagnostics that fully self-register (LuaDoc tags, narrowing/genesis
-- rules, proto registration, their own message text) from within their
-- own file, instead of being wired in from proto/diagnostic.lua and
-- friends. Required here once, purely to run that top-level registration
-- code -- the actual per-check dispatch still goes through
-- require('core.diagnostics.'..name) as normal further down, which Lua's
-- require cache makes a no-op re-load.
--
-- Deliberately NOT relied on to run before `define` above takes its
-- one-time snapshot of the registered diagnostics: `define` is reached
-- transitively from `require 'files'`, itself required from vm/node.lua,
-- so a self-registering diagnostic that needs `vm` cannot safely load
-- before that snapshot without risking a require cycle. getSeverity/
-- getStatus/buildDiagList below fall back to proto.diagnostic's live
-- registry instead, so registration order here doesn't matter.
--
-- Anything non-standard or specialized enough that it shouldn't need a
-- line added and removed here doesn't belong in this list at all --
-- drop it in core/diagnostics/extra/ instead (see need-check-secret.lua
-- there), which custom-plugins.lua above scans and loads on its own,
-- with no eager-require line to maintain: adding or deleting a file
-- there is the whole story, no edits needed anywhere else.
require 'core.diagnostics.deprecated'
require 'core.diagnostics.code-after-break'
require 'core.diagnostics.param-type-mismatch'
require 'core.diagnostics.inject-field'
require 'core.diagnostics.undefined-doc-name'
require 'core.diagnostics.unused-local'
require 'core.diagnostics.unused-function'
require 'core.diagnostics.assign-type-mismatch'
require 'core.diagnostics.missing-fields'
require 'core.diagnostics.incomplete-signature-doc'
require 'core.diagnostics.duplicate-set-field'
require 'core.diagnostics.return-type-mismatch'
require 'core.diagnostics.duplicate-doc-field'
require 'core.diagnostics.lowercase-global'
require 'core.diagnostics.unreachable-code'
require 'core.diagnostics.ambiguity-1'
require 'core.diagnostics.missing-return'
require 'core.diagnostics.global-element'
require 'core.diagnostics.redundant-parameter'
require 'core.diagnostics.invisible'
require 'core.diagnostics.duplicate-index'
require 'core.diagnostics.not-yieldable'
require 'core.diagnostics.redundant-return-value'
require 'core.diagnostics.circle-doc-class'
require 'core.diagnostics.newline-call'
require 'core.diagnostics.need-check-nil'
require 'core.diagnostics.empty-block'
require 'core.diagnostics.duplicate-doc-alias'
require 'core.diagnostics.different-requires'
require 'core.diagnostics.cast-local-type'
require 'core.diagnostics.trailing-space'
require 'core.diagnostics.missing-return-value'
require 'core.diagnostics.missing-local-export-doc'
require 'core.diagnostics.missing-global-doc'
require 'core.diagnostics.count-down-loop'
require 'core.diagnostics.undefined-env-child'
require 'core.diagnostics.unbalanced-assignments'
require 'core.diagnostics.newfield-call'
require 'core.diagnostics.undefined-doc-class'
require 'core.diagnostics.cast-type-mismatch'
require 'core.diagnostics.global-in-nil-env'
require 'core.diagnostics.doc-field-no-class'
require 'core.diagnostics.codestyle-check'
require 'core.diagnostics.close-non-object'
require 'core.diagnostics.unused-vararg'
require 'core.diagnostics.undefined-global'
require 'core.diagnostics.redefined-local'
require 'core.diagnostics.duplicate-doc-param'
require 'core.diagnostics.no-unknown'
require 'core.diagnostics.spell-check'
require 'core.diagnostics.name-style-check'
require 'core.diagnostics.unknown-operator'
require 'core.diagnostics.missing-parameter'
require 'core.diagnostics.unknown-diag-code'
require 'core.diagnostics.unknown-cast-variable'
require 'core.diagnostics.discard-returns'
require 'core.diagnostics.await-in-sync'
require 'core.diagnostics.redundant-return'
require 'core.diagnostics.redundant-value'
require 'core.diagnostics.undefined-doc-param'
require 'core.diagnostics.unused-label'
require 'core.diagnostics.undefined-field'
-- unnecessary-assert.lua is NOT required here: it's disabled upstream
-- (09900e7daf) and its own protoDiagnostic.register call is commented
-- out, so requiring it would have nothing to trigger.

local sleepRest = 0.0

---@async
---@param uri uri
---@param passed number
local function checkSleep(uri, passed)
    ---@type number
    local speedRate = config.get(uri, 'Lua.diagnostics.workspaceRate')
    if speedRate <= 0 or speedRate >= 100 then
        return
    end
    local sleepTime = passed * (100 - speedRate) / speedRate
    if sleepTime + sleepRest < 0.001 then
        sleepRest = sleepRest + sleepTime
        return
    end
    sleepRest = sleepTime + sleepRest
    sleepTime = sleepRest
    if sleepTime > 0.1 then
        sleepTime = 0.1
    end
    local clock = os.clock()
    await.sleep(sleepTime)
    local sleeped = os.clock() - clock

    sleepRest = sleepRest - sleeped
end

---@param uri  uri
---@param name string
---@return string
local function getSeverity(uri, name)
    local severity =   config.get(uri, 'Lua.diagnostics.severity')[name]
                    or define.DiagnosticDefaultSeverity[name]
                    -- fallback for a diagnostic that self-registered after
                    -- `define` took its one-time startup snapshot
                    or (diagd.diagnosticDatas[name] and diagd.diagnosticDatas[name].severity)
    if severity:sub(-1) == '!' then
        return severity:sub(1, -2)
    end
    local groupSeverity = config.get(uri, 'Lua.diagnostics.groupSeverity')
    local groups = diagd.getGroups(name)
    local groupLevel = 999
    for _, groupName in ipairs(groups) do
        ---@type string?
        local gseverity = groupSeverity[groupName]
        if gseverity and gseverity ~= 'Fallback' then
            groupLevel = math.min(groupLevel, define.DiagnosticSeverity[gseverity]) --[[@as integer]]
        end
    end
    if groupLevel == 999 then
        return severity
    end
    for severityName, level in pairs(define.DiagnosticSeverity) do
        if level == groupLevel then
            return severityName
        end
    end
    return severity
end

---@param uri  uri
---@param name string
---@return string
local function getStatus(uri, name)
    local status = config.get(uri, 'Lua.diagnostics.neededFileStatus')[name]
                or define.DiagnosticDefaultNeededFileStatus[name]
                or (diagd.diagnosticDatas[name] and diagd.diagnosticDatas[name].status)
    if status:sub(-1) == '!' then
        return status:sub(1, -2)
    end
    local groupStatus = config.get(uri, 'Lua.diagnostics.groupFileStatus')
    local groups = diagd.getGroups(name)
    local groupLevel = 0
    for _, groupName in ipairs(groups) do
        ---@type string?
        local gstatus = groupStatus[groupName]
        if gstatus and gstatus ~= 'Fallback' then
            groupLevel = math.max(groupLevel, define.DiagnosticFileStatus[gstatus]) --[[@as integer]]
        end
    end
    if groupLevel == 0 then
        return status
    end
    for statusName, level in pairs(define.DiagnosticFileStatus) do
        if level == groupLevel then
            return statusName
        end
    end
    return status
end

---@async
---@param uri uri
---@param name string
---@param isScopeDiag boolean
---@param response async fun(result: any)
---@param ignoreFileOpenState? boolean
---@return boolean
local function check(uri, name, isScopeDiag, response, ignoreFileOpenState)
    local disables = config.get(uri, 'Lua.diagnostics.disable')
    if util.arrayHas(disables, name) then
        return false
    end
    local severity = getSeverity(uri, name)
    local status   = getStatus(uri, name)

    if status == 'None' then
        return false
    end

    if not ignoreFileOpenState and status == 'Opened' and not files.isOpen(uri) then
        return false
    end

    local level = define.DiagnosticSeverity[severity]
    local clock = os.clock()
    ---@type table<integer, boolean>
    local mark = {}
    -- Custom plugins loaded from Lua.diagnostics.pluginsDir aren't
    -- reachable via require('core.diagnostics.'..name) -- they don't
    -- live under script/core/diagnostics/ -- so check that registry
    -- first and only fall back to the require() convention for built-ins.
    local diagnosticFn = customPlugins.get(name) or require('core.diagnostics.' .. name)
    ---@async
    ---@param result any
    diagnosticFn(uri, function (result)
        if vm.isDiagDisabledAt(uri, result.start, name) then
            return
        end
        if result.start < 0 then
            return
        end
        if mark[result.start] then
            return
        end
        mark[result.start] = true

        result.level = level or result.level
        result.code  = name
        response(result)
    end, name)
    local passed = os.clock() - clock
    if passed >= 0.5 then
        log.warn(('Diagnostics [%s] @ [%s] takes [%.3f] sec!'):format(name, uri, passed))
    end
    if isScopeDiag then
        checkSleep(uri, passed)
    end
    if DIAGTIMES then
        local diagTimes = DIAGTIMES
        diagTimes[name] = (diagTimes[name] or 0) + passed
    end
    return true
end

---@type string[]?
local diagList
---@type table<string, number>
local diagCosts = {}
---@type table<string, integer>
local diagCount = {}
---@return string[]
local function buildDiagList()
    if not diagList then
        diagList = {}
        ---@type table<string, boolean>
        local seen = {}
        for name in pairs(define.DiagnosticDefaultSeverity) do
            seen[name] = true
            diagList[#diagList+1] = name
        end
        -- names registered after `define`'s one-time startup snapshot
        -- (see the self-registering diagnostics note above)
        for name in pairs(diagd.diagnosticDatas) do
            if not seen[name] then
                diagList[#diagList+1] = name
            end
        end
    end
    table.sort(diagList, function (a, b)
        local time1 = (diagCosts[a] or 0) / (diagCount[a] or 1)
        local time2 = (diagCosts[b] or 0) / (diagCount[b] or 1)
        return time1 < time2
    end)
    return diagList
end

---@async
---@param uri uri
---@param isScopeDiag boolean
---@param response async fun(result: any)
---@param checked? async fun(name: string)
---@param ignoreFileOpenState? boolean
return function (uri, isScopeDiag, response, checked, ignoreFileOpenState)
    local ast = files.getState(uri)
    if not ast then
        return nil
    end

    for _, name in ipairs(buildDiagList()) do
        await.delay()
        local clock = os.clock()
        local suc = check(uri, name, isScopeDiag, response, ignoreFileOpenState)
        if suc then
            local cost = os.clock() - clock
            diagCosts[name] = (diagCosts[name] or 0) + cost
            diagCount[name] = (diagCount[name] or 0) + 1
        end
        if checked then
            checked(name)
        end
    end
end
