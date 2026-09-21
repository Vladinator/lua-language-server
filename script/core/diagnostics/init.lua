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
-- Registration order here does not matter: `define` is reached transitively
-- from `require 'files'`, itself required from vm/node.lua, so a
-- self-registering diagnostic that needs `vm` cannot safely load before
-- `define`. `define.DiagnosticDefault*` are therefore live tables that
-- proto.diagnostic's `register` fills in (see there), not a startup snapshot.
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
require 'core.diagnostics.unfulfilled-expect'
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

--- `LLS_DIAG_PROFILE=<file>` writes what each diagnostic has cost so far (seconds in all, files, the
--- longest single run and where) to the file, at most every 5 seconds: for a workspace that is slow to
--- diagnose, to see which checks it is. What a check compiles for the first time is charged to it,
--- so the checks that run first pay for the compile of what the ones after them reuse.
---@type string?
local PROFILE_FILE = os.getenv('LLS_DIAG_PROFILE')
---@type table<string, { total: number, files: integer, longest: number, where: string }>
local profile = {}
local profileFlushed = 0

---@param name   string
---@param uri    uri
---@param passed number
local function recordProfile(name, uri, passed)
    local entry = profile[name]
    if not entry then
        entry = { total = 0, files = 0, longest = 0, where = '' }
        profile[name] = entry
    end
    entry.total = entry.total + passed
    entry.files = entry.files + 1
    if passed > entry.longest then
        entry.longest = passed
        entry.where   = uri
    end
    if PROFILE_FILE and os.clock() - profileFlushed > 5 then
        profileFlushed = os.clock()
        ---@type string[]
        local names = {}
        for n in pairs(profile) do
            names[#names+1] = n
        end
        table.sort(names, function (a, b)
            return profile[a].total > profile[b].total
        end)
        ---@type string[]
        local lines = {}
        for _, n in ipairs(names) do
            local e = profile[n]
            lines[#lines+1] = ('%-28s %8.1f s  %6d files  %7.1f ms avg  %7.1f ms max  %s'):format(
                n, e.total, e.files, e.total / e.files * 1000, e.longest * 1000, e.where)
        end
        util.saveFile(PROFILE_FILE, table.concat(lines, string.char(10)))
    end
end

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
            groupLevel = math.min(groupLevel, define.DiagnosticSeverity[gseverity])
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
            groupLevel = math.max(groupLevel, define.DiagnosticFileStatus[gstatus])
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

--- Whether `name` runs for this file under the current configuration.
---@param uri uri
---@param name string
---@param ignoreFileOpenState? boolean
---@return boolean
local function isEnabled(uri, name, ignoreFileOpenState)
    -- a name that is not a registered diagnostic (a typo, or half typed in an
    -- `expect-next-line` comment) can never fire; getStatus has no status for it
    if not define.DiagnosticDefaultSeverity[name] then
        return false
    end
    local disables = config.get(uri, 'Lua.diagnostics.disable')
    if util.arrayHas(disables, name) then
        return false
    end
    local status = getStatus(uri, name)
    if status == 'None' then
        return false
    end
    if not ignoreFileOpenState and status == 'Opened' and not files.isOpen(uri) then
        return false
    end
    return true
end
diagd.isEnabled = isEnabled

---@async
---@param uri uri
---@param name string
---@param isScopeDiag boolean
---@param response async fun(result: proto.diagnostic.result)
---@param ignoreFileOpenState? boolean
---@return boolean
local function check(uri, name, isScopeDiag, response, ignoreFileOpenState)
    if not isEnabled(uri, name, ignoreFileOpenState) then
        return false
    end
    local severity = getSeverity(uri, name)

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
    ---@param result proto.diagnostic.result
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
    if PROFILE_FILE then
        recordProfile(name, uri, passed)
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
--- how many diagnostics `diagList` was built from
local diagListSize = 0
---@type table<string, number>
local diagCosts = {}
---@type table<string, integer>
local diagCount = {}

--- In which order the checks run on a file matters more than it looks: what a check compiles
--- is cached, so a different first check can change what the following ones infer, and every
--- order-dependent inference bug this project has hit showed up as "the CLI check and the
--- editor disagree". `LLS_DIAG_ORDER` picks the order, for testing:
---   (unset) | cost     cheapest measured first, ties by name (what runs by default)
---   name               alphabetical
---   reverse            reverse alphabetical
---   shuffle:<seed>     a fixed pseudo-random permutation, the same for every file and process
---   first:<name>       alphabetical, but with that diagnostic first (to bisect an order dependence)
---@type string
local ORDER_MODE = os.getenv('LLS_DIAG_ORDER') or 'cost'

---@param names string[]
---@param seed  integer
local function shuffle(names, seed)
    local state = seed
    for i = #names, 2, -1 do
        state = (state * 1103515245 + 12345) % 2147483648
        local j = state % i + 1
        names[i], names[j] = names[j], names[i]
    end
end

---@return string[]
local function buildDiagList()
    local registered = 0
    for _ in pairs(diagd.diagnosticDatas) do
        registered = registered + 1
    end
    if not diagList or diagListSize ~= registered then
        ---@type string[]
        local names = {}
        for name in pairs(diagd.diagnosticDatas) do
            -- a diagnostic that reads the outcome of all the others (`afterAll`) always runs
            -- last (see the tail of the exported function)
            if not diagd.diagnosticDatas[name].afterAll then
                names[#names+1] = name
            end
        end
        table.sort(names)   -- pairs() order is arbitrary: start from a defined one
        local shuffleSeed = ORDER_MODE:match('^shuffle:(%d+)$')
        if shuffleSeed then
            shuffle(names, tonumber(shuffleSeed) --[[@as integer]])
        elseif ORDER_MODE:match('^first:') then
            local first = ORDER_MODE:sub(#'first:' + 1)
            for k, name in ipairs(names) do
                if name == first then
                    table.remove(names, k)
                    table.insert(names, 1, name)
                    break
                end
            end
        elseif ORDER_MODE == 'reverse' then
            for a = 1, #names // 2 do
                local b = #names - a + 1
                names[a], names[b] = names[b], names[a]
            end
        end
        diagList     = names
        diagListSize = registered
    end
    if ORDER_MODE == 'cost' then
        table.sort(diagList, function (a, b)
            local time1 = (diagCosts[a] or 0) / (diagCount[a] or 1)
            local time2 = (diagCosts[b] or 0) / (diagCount[b] or 1)
            if time1 ~= time2 then
                return time1 < time2
            end
            return a < b
        end)
    end
    return diagList
end
diagd.getRunOrder = buildDiagList

---@async
---@param uri uri
---@param isScopeDiag boolean
---@param response async fun(result: proto.diagnostic.result)
---@param checked? async fun(name: string)
---@param ignoreFileOpenState? boolean
---@param only? table<string, true> run just these diagnostics (`checked` is called for them, also when they are disabled, so that the caller can drop their old results); not `unfulfilled-expect`, which needs every one of them
---@return nil
return function (uri, isScopeDiag, response, checked, ignoreFileOpenState, only)
    local ast = files.getState(uri)
    if not ast then
        return nil
    end

    for _, name in ipairs(buildDiagList()) do
        if only and not only[name] then
            goto continue
        end
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
        ::continue::
    end
    if only then
        return nil
    end
    -- ran the whole list for this file: now the diagnostics that need the outcome of all
    -- of it (`unfulfilled-expect`: `expect-*` comments that suppressed nothing)
    ---@type string[]
    local afterAll = {}
    for name, data in pairs(diagd.diagnosticDatas) do
        if data.afterAll then
            afterAll[#afterAll+1] = name
        end
    end
    table.sort(afterAll)
    for _, name in ipairs(afterAll) do
        await.delay()
        if check(uri, name, isScopeDiag, response, ignoreFileOpenState) and checked then
            checked(name)
        end
    end
end
