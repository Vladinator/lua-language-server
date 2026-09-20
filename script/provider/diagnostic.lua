local await     = require 'await'
local proto     = require 'proto.proto'
local define    = require 'proto.define'
local lang      = require 'language'
local files     = require 'files'
local config    = require 'config'
local core      = require 'core.diagnostics'
local util      = require 'utility'
local ws        = require 'workspace'
local progress  = require "progress"
local client    = require 'client'
local converter = require 'proto.converter'
local loading   = require 'workspace.loading'
local scope     = require 'workspace.scope'
local time      = require 'bee.time'
local ltable    = require 'linked-table'
local furi      = require 'file-uri'
local json      = require 'json'
local fw        = require 'filewatch'
local vm        = require 'vm.vm'
local diagd     = require 'proto.diagnostic'

---@alias diagnosticProvider.errRelated { uri?: uri, message?: string, start: integer, finish: integer }
---@alias diagnosticProvider.errInfo { version?: string[]|string, related?: diagnosticProvider.errRelated[] }

--- An LSP Diagnostic as sent to the client.
---@class diagnosticProvider.diagnostic
---@field range               table
---@field source?             string
---@field severity?           integer
---@field message             string
---@field code?               string
---@field tags?               integer[]
---@field data?               any
---@field relatedInformation? table[]

---@class diagnosticProvider
---@field cache table<uri, diagnosticProvider.diagnostic[]|false>
local m = {}
m.cache = {}
m.sleepRest = 0.0

--- The files whose cached diagnostics are the result of a run of every diagnostic. Only for
--- those can a run of a few diagnostics take the rest from the cache (see `only` below).
---@type table<uri, true>
m.complete = {}

--- What a scope still has to diagnose. A configuration change that only concerns some of the
--- diagnostics asks for those, anything else asks for all of them.
---@class diagnosticProvider.request
---@field all   boolean
---@field names table<string, true>

---@type table<string, diagnosticProvider.request>
m.pending = {}
--- The scopes with a workspace diagnosis running.
---@type table<string, true>
m.scopeRunning = {}

--- Adds to what the scope has to diagnose.
---@param scpName string
---@param only?   table<string, true> nil: every diagnostic
function m.addRequest(scpName, only)
    local request = m.pending[scpName]
    if not request then
        request = { all = false, names = {} }
        m.pending[scpName] = request
    end
    if not only then
        request.all = true
        return
    end
    for name in pairs(only) do
        request.names[name] = true
    end
end

--- Takes what the scope has to diagnose, for a pass that is about to run it.
---@param scpName string
---@return diagnosticProvider.request?
function m.takeRequest(scpName)
    local request = m.pending[scpName]
    m.pending[scpName] = nil
    return request
end

--- Puts back what a pass that did not finish had taken.
---@param scpName string
---@param request diagnosticProvider.request
function m.restoreRequest(scpName, request)
    if request.all then
        m.addRequest(scpName)
    end
    m.addRequest(scpName, request.names)
end
m.scopeDiagCount = 0
m.pauseCount = 0

local function concat(t, sep)
    if type(t) ~= 'table' then
        return t
    end
    return table.concat(t, sep)
end

---@param uri uri
---@param err parser.state.err
---@return diagnosticProvider.diagnostic?
local function buildSyntaxError(uri, err)
    local state = files.getState(uri)
    local text  = files.getText(uri)
    if not text or not state then
        return
    end
    local info = err.info --[[@as diagnosticProvider.errInfo?]]
    local message = lang.script('PARSER_' .. err.type, err.info)

    if err.version then
        local version = info and info.version or config.get(uri, 'Lua.runtime.version')
        message = (message .. ('(%s)'):format(lang.script('DIAG_NEED_VERSION'
            , concat(err.version, '/')
            , version
        ))) --[[@as string]]
    end

    local related = info and info.related
    ---@type table[]?
    local relatedInformation
    if related then
        relatedInformation = {}
        for _, rel in ipairs(related --[[@as diagnosticProvider.errRelated[] ]]) do
            ---@type string
            local rmessage
            if rel.message then
                rmessage = lang.script('PARSER_' .. rel.message)
            else
                rmessage = text:sub(rel.start, rel.finish)
            end
            local relUri = rel.uri or uri
            local relState = files.getState(relUri)
            if relState then
                relatedInformation[#relatedInformation+1] = {
                    message  = rmessage,
                    location = converter.location(relUri, converter.packRange(relState, rel.start, rel.finish)),
                }
            end
        end
    end

    return {
        code     = err.type:lower():gsub('_', '-'),
        range    = converter.packRange(state, err.start, err.finish),
        severity = define.DiagnosticSeverity[err.level --[[@as string]]],
        source   = lang.script.DIAG_SYNTAX_CHECK,
        message  = message,
        data     = 'syntax',

        relatedInformation = relatedInformation,
    }
end

---@param uri uri
---@param diag proto.diagnostic.result
---@return diagnosticProvider.diagnostic?
local function buildDiagnostic(uri, diag)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@type table[]?
    local relatedInformation
    if diag.related then
        relatedInformation = {}
        for _, rel in ipairs(diag.related) do
            local rtext = files.getText(rel.uri)
            if not rtext then
                goto CONTINUE
            end
            local relState = files.getState(rel.uri)
            if not relState then
                goto CONTINUE
            end
            relatedInformation[#relatedInformation+1] = {
                message  = rel.message or rtext:sub(rel.start, rel.finish),
                location = converter.location(rel.uri, converter.packRange(relState, rel.start, rel.finish))
            }
            ::CONTINUE::
        end
    end

    return {
        range    = converter.packRange(state, diag.start, diag.finish),
        source   = lang.script.DIAG_DIAGNOSTICS,
        severity = diag.level,
        message  = diag.message,
        code     = diag.code,
        tags     = diag.tags,
        data     = diag.data,

        relatedInformation = relatedInformation,
    }
end

---@param a diagnosticProvider.diagnostic[]?
---@param b diagnosticProvider.diagnostic[]?
---@param c diagnosticProvider.diagnostic[]?
---@return diagnosticProvider.diagnostic[]?
local function mergeDiags(a, b, c)
    if not a and not b and not c then
        return nil
    end
    ---@type diagnosticProvider.diagnostic[]
    local t = {}

    ---@param diags diagnosticProvider.diagnostic[]?
    local function merge(diags)
        if not diags then
            return
        end
        for i = 1, #diags do
            local diag = diags[i]
            local severity = diag.severity
            if severity == define.DiagnosticSeverity.Hint
            or severity == define.DiagnosticSeverity.Information then
                if #t > 10000 then
                    goto CONTINUE
                end
            end
            t[#t+1] = diag
            ::CONTINUE::
        end
    end

    merge(a)
    merge(b)
    merge(c)

    if #t == 0 then
        return nil
    end

    return t
end

-- enable `push`, disable `clear`
function m.clear(uri, force)
    await.close('diag:' .. uri)
    if m.cache[uri] == nil and not force then
        return
    end
    m.cache[uri] = nil
    m.complete[uri] = nil
    proto.notify('textDocument/publishDiagnostics', {
        uri = uri,
        diagnostics = {},
    })
    log.info('clearDiagnostics', uri)
end

---@param uris uri[]
function m.clearCacheExcept(uris)
    ---@type table<uri, boolean>
    local excepts = {}
    for _, uri in ipairs(uris) do
        excepts[uri] = true
    end
    for uri in pairs(m.cache) do
        if not excepts[uri] then
            m.cache[uri] = false
            m.complete[uri] = nil
        end
    end
end

---@param uri? uri
---@param force? boolean
function m.clearAll(uri, force)
    ---@type scope?
    local scp
    if uri then
        scp = scope.getScope(uri)
    end
    if force then
        for luri in files.eachFile() do
            if not scp or scope.getScope(luri) == scp then
                m.clear(luri, force)
            end
        end
    else
        for luri in pairs(m.cache) do
            if not scp or scope.getScope(luri) == scp then
                m.clear(luri)
            end
        end
    end
end

---@param uri uri
---@param ast parser.state
---@return diagnosticProvider.diagnostic[]?
function m.syntaxErrors(uri, ast)
    if #ast.errs == 0 then
        return nil
    end

    ---@type diagnosticProvider.diagnostic[]
    local results = {}

    pcall(function ()
        local disables = util.arrayToHash(config.get(uri, 'Lua.diagnostics.disable'))
        for _, err in ipairs(ast.errs) do
            local id = err.type:lower():gsub('_', '-')
            if  not disables[id]
            and not vm.isDiagDisabledAt(uri, err.start, id, true) then
                results[#results+1] = buildSyntaxError(uri, err)
            end
        end
    end)

    return results
end

---@param diags diagnosticProvider.diagnostic[]?
---@return diagnosticProvider.diagnostic[]?
local function copyDiagsWithoutSyntax(diags)
    if not diags then
        return nil
    end
    ---@type diagnosticProvider.diagnostic[]
    local copyed = {}
    for _, diag in ipairs(diags) do
        if diag.data ~= 'syntax' then
            copyed[#copyed+1] = diag
        end
    end
    return copyed
end

---@async
---@param uri uri
---@return boolean
local function isValid(uri)
    if not config.get(uri, 'Lua.diagnostics.enable') then
        return false
    end
    if not ws.isReady(uri) then
        return false
    end
    if files.isLibrary(uri, true) then
        local status = config.get(uri, 'Lua.diagnostics.libraryFiles')
        if status == 'Disable' then
            return false
        elseif status == 'Opened' then
            if not files.isOpen(uri) then
                return false
            end
        end
    end
    if ws.isIgnored(uri) then
        local status = config.get(uri, 'Lua.diagnostics.ignoredFiles')
        if status == 'Disable' then
            return false
        elseif status == 'Opened' then
            if not files.isOpen(uri) then
                return false
            end
        end
    end
    local scheme = furi.split(uri)
    local enableScheme = config.get(uri, 'Lua.diagnostics.enableScheme')
    if not util.arrayHas(enableScheme, scheme) then
        return false
    end
    return true
end

--- Whether the file has `---@diagnostic expect-next-line` / `expect-line` comments: the
--- `unfulfilled-expect` check reads what every other diagnostic suppressed, so such a file
--- always gets all of them.
---@param state parser.state
---@return boolean
local function hasExpectDirective(state)
    for _, doc in ipairs(state.ast.docs or {}) do
        if  doc.type == 'doc.diagnostic'
        and (doc.mode == 'expect-next-line' or doc.mode == 'expect-line') then
            return true
        end
    end
    return false
end

---@async
---@param uri uri
---@param isScopeDiag? boolean
---@param ignoreFileState? boolean
---@param only? table<string, true> run just these diagnostics and keep the cached results of the others. Ignored (all of them run) when the file has no complete result cached yet
function m.doDiagnostic(uri, isScopeDiag, ignoreFileState, only)
    if not isValid(uri) then
        return
    end

    await.delay()

    local state = files.getState(uri)
    if not state then
        m.clear(uri)
        return
    end

    if only
    and (not m.complete[uri]
      or only['unfulfilled-expect']
      or hasExpectDirective(state)) then
        only = nil
    end

    local version = files.getVersion(uri)

    local prog <close> = progress.create(uri, lang.script.WINDOW_DIAGNOSING, 0.5)
    prog:setMessage(ws.getRelativePath(uri))

    --log.debug('Diagnostic file:', uri)

    local syntax = m.syntaxErrors(uri, state)

    ---@type diagnosticProvider.diagnostic[]
    local diags = {}
    local lastDiag = copyDiagsWithoutSyntax(m.cache[uri])
    local function pushResult()
        tracy.ZoneBeginN 'mergeSyntaxAndDiags'
        local _ <close> = tracy.ZoneEnd
        local full = mergeDiags(syntax, lastDiag, diags)
        --log.debug(('Pushed [%d] results'):format(full and #full or 0))
        if not full then
            m.clear(uri)
            return
        end

        if util.equal(m.cache[uri], full) then
            return
        end
        m.cache[uri] = full

        if not files.exists(uri) then
            m.clear(uri)
            return
        end

        proto.notify('textDocument/publishDiagnostics', {
            uri = uri,
            version = version,
            diagnostics = full,
        })
        log.debug('publishDiagnostics', uri, #full)
    end

    pushResult()

    local lastPushClock = time.time()
    ---@async
    local suc = xpcall(core, log.error, uri, isScopeDiag, function (result)
        diags[#diags+1] = buildDiagnostic(uri, result)

        if not isScopeDiag and time.time() - lastPushClock >= 500 then
            lastPushClock = time.time()
            pushResult()
        end
    end, function (checkedName)
        if not lastDiag then
            return
        end
        -- drop the old results of what was just checked (in place, keeping the order; the
        -- swap-with-the-last version this replaces skipped the item it moved into the gap)
        local size = #lastDiag
        local kept = 0
        for i = 1, size do
            local diag = lastDiag[i]
            if diag.code ~= checkedName then
                kept = kept + 1
                lastDiag[kept] = diag
            end
        end
        for i = kept + 1, size do
            lastDiag[i] = nil
        end
    end, ignoreFileState, only)

    -- what a run of everything did not report again is gone; a run of a few diagnostics keeps
    -- the cached results of the others
    if not only then
        lastDiag = nil
    end
    pushResult()
    if suc and not only then
        m.complete[uri] = true
    end
end

---@param uri uri
function m.resendDiagnostic(uri)
    local full = m.cache[uri]
    if not full then
        return
    end

    if not files.exists(uri) then
        m.clear(uri)
        return
    end

    local version = files.getVersion(uri)

    proto.notify('textDocument/publishDiagnostics', {
        uri = uri,
        version = version,
        diagnostics = full,
    })
    log.debug('publishDiagnostics', uri, #full)
end

---@async
---@param uri uri
---@param isScopeDiag boolean
---@return table|nil result
---@return boolean? unchanged
function m.pullDiagnostic(uri, isScopeDiag)
    if not isValid(uri) then
        return nil, util.equal(m.cache[uri], nil)
    end

    await.delay()

    local state = files.getState(uri)
    if not state then
        return nil, util.equal(m.cache[uri], nil)
    end

    local prog <close> = progress.create(uri, lang.script.WINDOW_DIAGNOSING, 0.5)
    prog:setMessage(ws.getRelativePath(uri))

    local syntax = m.syntaxErrors(uri, state)
    ---@type diagnosticProvider.diagnostic[]
    local diags = {}

    xpcall(core, log.error, uri, isScopeDiag, function (result)
        diags[#diags+1] = buildDiagnostic(uri, result)
    end)

    local full = mergeDiags(syntax, diags)

    if util.equal(m.cache[uri], full) then
        return full, true
    end

    m.cache[uri] = full

    return full
end

---@param uri uri
function m.stopScopeDiag(uri)
    local scp     = scope.getScope(uri)
    local scopeID = 'diagnosticsScope:' .. scp:getName()
    await.close(scopeID)
end

---@param event string
---@param uri uri
function m.refreshScopeDiag(event, uri)
    if not ws.isReady(uri) then
        return
    end

    local eventConfig = config.get(uri, 'Lua.diagnostics.workspaceEvent')

    if eventConfig ~= event then
        return
    end

    ---@async
    await.call(function ()
        local delay = (config.get(uri, 'Lua.diagnostics.workspaceDelay') --[[@as number]]) / 1000
        if delay < 0 then
            return
        end
        await.sleep(math.max(delay, 0.2))
        m.diagnosticsScope(uri)
    end)
end

---@param uri uri
function m.refresh(uri)
    if not ws.isReady(uri) then
        return
    end

    await.close('diag:' .. uri)
    ---@async
    await.call(function ()
        await.setID('diag:' .. uri)
        repeat
            await.sleep(0.1)
        until not m.isPaused()
        xpcall(m.doDiagnostic, log.error, uri)
    end)
end

---@async
local function askForDisable(uri)
    if m.dontAskedForDisable then
        return
    end
    local delay = 30
    local delayTitle = lang.script('WINDOW_DELAY_WS_DIAGNOSTIC', delay)
    local item = proto.awaitRequest('window/showMessageRequest', {
        type    = define.MessageType.Info,
        message = lang.script.WINDOW_SETTING_WS_DIAGNOSTIC,
        actions = {
            {
                title = lang.script.WINDOW_DONT_SHOW_AGAIN,
            },
            {
                title = delayTitle,
            },
            {
                title = lang.script.WINDOW_DISABLE_DIAGNOSTIC,
            },
        }
    })
    if not item then
        return
    end
    if     item.title == lang.script.WINDOW_DONT_SHOW_AGAIN then
        m.dontAskedForDisable = true
    elseif item.title == delayTitle then
        client.setConfig {
            {
                key    = 'Lua.diagnostics.workspaceDelay',
                action = 'set',
                value  = delay * 1000,
                uri    = uri,
            }
        }
    elseif item.title == lang.script.WINDOW_DISABLE_DIAGNOSTIC then
        client.setConfig {
            {
                key    = 'Lua.diagnostics.workspaceDelay',
                action = 'set',
                value  = -1,
                uri    = uri,
            }
        }
    end
end

local function clearMemory(finished)
    if m.scopeDiagCount > 0 then
        return
    end
    vm.clearNodeCache()
    if finished then
        collectgarbage()
        collectgarbage()
    end
end

---@async
---@param suri     uri
---@param callback async fun(uri: uri)
---@return boolean completed every file was diagnosed (not cancelled, by the user or by being replaced)
function m.awaitDiagnosticsScope(suri, callback)
    local scp = scope.getScope(suri)
    if scp.type == 'fallback' then
        return true
    end
    while loading.count() > 0 do
        await.sleep(1.0)
    end
    local finished
    local completed = false
    -- (the caches keep what the checks concluded: undefinedGlobal, ... under the configuration
    -- of the time they were made)
    if m.scopeDiagCount == 0 then
        vm.clearNodeCache()
    end
    m.scopeDiagCount = m.scopeDiagCount + 1
    local scopeDiag <close> = util.defer(function ()
        m.scopeDiagCount = m.scopeDiagCount - 1
        clearMemory(finished)
    end)
    local clock = os.clock()
    local bar <close> = progress.create(suri, lang.script.WORKSPACE_DIAGNOSTIC, 1)
    ---@type boolean?
    local cancelled
    bar:onCancel(function ()
        log.info('Cancel workspace diagnostics')
        cancelled = true
        ---@async
        await.call(function ()
            askForDisable(suri)
        end)
    end)
    local uris = files.getAllUris(suri)
    local sortedUris = ltable()
    for _, uri in ipairs(uris) do
        if files.isOpen(uri) then
            sortedUris:pushHead(uri)
        else
            sortedUris:pushTail(uri)
        end
    end
    log.info(('Diagnostics scope [%s], files count:[%d]'):format(scp:getName(), #uris))
    local i = 0
    for uri in sortedUris:pairs() do
        while loading.count() > 0 do
            await.sleep(1.0)
        end
        i = (i + 1)
        bar:setMessage(('%d/%d'):format(i, #uris))
        bar:setPercentage(i / #uris * 100)
        callback(uri)
        await.delay()
        if cancelled then
            log.info('Break workspace diagnostics')
            break
        end
    end
    bar:remove()
    log.info(('Diagnostics scope [%s] finished, takes [%.3f] sec.'):format(scp:getName(), os.clock() - clock))
    finished = true
    completed = not cancelled
    return completed
end

--- Diagnoses the scope until nothing is left to do: what was asked for while a pass was running
--- is done by the next pass.
---@async
---@param uri uri
---@param ignoreFileOpenState? boolean
function m.runScopeDiag(uri, ignoreFileOpenState)
    local name = scope.getScope(uri):getName()
    m.scopeRunning[name] = true
    ---@type diagnosticProvider.request?
    local request
    local completed = false
    -- however the pass ends (it can be cancelled at any of its waits), what it took but did not
    -- do goes back
    local _ <close> = util.defer(function ()
        m.scopeRunning[name] = nil
        if request and not completed then
            m.restoreRequest(name, request)
        end
    end)
    while true do
        request = m.takeRequest(name)
        if not request then
            return
        end
        local only = (not request.all) and request.names or nil
        completed = false
        completed = m.awaitDiagnosticsScope(uri, function (fileUri)
            xpcall(m.doDiagnostic, log.error, fileUri, true, ignoreFileOpenState, only)
        end)
        if not completed then
            return
        end
    end
end

---@param uri uri
---@param force? boolean
---@param ignoreFileOpenState? boolean
---@param only? table<string, true> only these diagnostics have to run again (nil: all of them)
function m.diagnosticsScope(uri, force, ignoreFileOpenState, only)
    if not ws.isReady(uri) then
        return
    end
    if not force and not config.get(uri, 'Lua.diagnostics.enable') then
        m.clearAll(uri)
        return
    end
    if not force and config.get(uri, 'Lua.diagnostics.workspaceDelay') < 0 then
        return
    end
    local scp = scope.getScope(uri)
    local name = scp:getName()
    m.addRequest(name, only)
    -- a pass that is running is not cancelled for a few diagnostics: it goes on, and then
    -- the next one does them (a client that writes settings while the workspace is being
    -- diagnosed would keep it from ever getting past the first files)
    if only and m.scopeRunning[name] then
        return
    end
    local id = 'diagnosticsScope:' .. name
    await.close(id)
    await.call(function () ---@async
        await.sleep(0.0)
        m.runScopeDiag(uri, ignoreFileOpenState)
    end, id)
end

---@alias provider.diagnostic.pullResult { uri: uri, result: table?, unchanged: boolean?, version: integer? }

---@async
---@param callback fun(result: provider.diagnostic.pullResult)
function m.pullDiagnosticScope(callback)
    local processing = 0

    for _, scp in ipairs(scope.folders) do
        if  ws.isReady(scp.uri)
        and config.get(scp.uri, 'Lua.diagnostics.enable') then
            local id = 'diagnosticsScope:' .. scp:getName()
            await.close(id)
            await.call(function () ---@async
                processing = processing + 1
                local _ <close> = util.defer(function ()
                    processing = processing - 1
                end)

                local delay = (config.get(scp.uri, 'Lua.diagnostics.workspaceDelay') --[[@as number]]) / 1000
                if delay < 0 then
                    return
                end
                print(delay)
                await.sleep(math.max(delay, 0.2))
                print('start')

                m.awaitDiagnosticsScope(scp.uri, function (fileUri)
                    local suc, result, unchanged = xpcall(m.pullDiagnostic, log.error, fileUri, true)
                    if suc then
                        callback {
                            uri       = fileUri,
                            result    = result,
                            unchanged = unchanged,
                            version   = files.getVersion(fileUri),
                        }
                    end
                end)
            end, id)
        end
    end

    -- sleep for ever
    while true do
        await.sleep(1.0)
    end
end

function m.refreshClient()
    if not client.isReady() then
        return
    end
    if not client.getAbility 'workspace.diagnostics.refreshSupport' then
        return
    end
    log.debug('Refresh client diagnostics')
    proto.request('workspace/diagnostic/refresh', json.null)
end

---@return boolean
function m.isPaused()
    return m.pauseCount > 0
end

function m.pause()
    m.pauseCount = m.pauseCount + 1
end

function m.resume()
    m.pauseCount = m.pauseCount - 1
end

ws.watch(function (ev, uri)
    if ev == 'reload' then
        m.diagnosticsScope(uri)
        m.refreshClient()
    end
end)

files.watch(function (ev, uri) ---@async
    -- what was cached is about the old text
    if ev == 'remove' or ev == 'create' or ev == 'update' then
        m.complete[uri] = nil
    end
    if ev == 'remove' then
        m.clear(uri)
        m.stopScopeDiag(uri)
        m.refresh(uri)
        m.refreshScopeDiag('OnSave', uri)
    elseif ev == 'create' then
        m.stopScopeDiag(uri)
        m.refresh(uri)
        m.refreshScopeDiag('OnSave', uri)
    elseif ev == 'update' then
        m.stopScopeDiag(uri)
        m.refresh(uri)
        m.refreshScopeDiag('OnChange', uri)
    elseif ev == 'open' then
        if ws.isReady(uri) then
            m.resendDiagnostic(uri)
            xpcall(m.doDiagnostic, log.error, uri)
        end
    elseif ev == 'close' then
        if files.isLibrary(uri, true)
        or ws.isIgnored(uri) then
            m.clear(uri)
        end
    elseif ev == 'save' then
        m.refreshScopeDiag('OnSave', uri)
    end
end)

--- The diagnostics that read these settings.
---@type table<string, string[]>
local readers = {
    ['Lua.diagnostics.globals']            = { 'undefined-global', 'deprecated', 'global-element', 'lowercase-global' },
    ['Lua.diagnostics.globalsRegex']       = { 'undefined-global', 'deprecated', 'global-element', 'lowercase-global' },
    ['Lua.diagnostics.unusedLocalExclude'] = { 'unused-local' },
    ['Lua.spell.dict']                     = { 'spell-check' },
    -- read by the pass itself, when it sleeps between two checks
    ['Lua.diagnostics.workspaceRate']      = {},
}

--- The keys of a table (or the items of a list) that differ between two.
---@param a any
---@param b any
---@return table<string, true>
local function differences(a, b)
    ---@type table<string, true>
    local result = {}
    ---@param t any
    ---@return table<any, any>
    local function asMap(t)
        ---@type table<any, any>
        local map = {}
        if type(t) ~= 'table' then
            return map
        end
        for k, v in pairs(t --[[@as table<any, any>]]) do
            if math.type(k) == 'integer' then
                map[v] = true
            else
                map[k] = v
            end
        end
        return map
    end
    local mapA, mapB = asMap(a), asMap(b)
    for k, v in pairs(mapA) do
        if not util.equal(v, mapB[k]) then
            result[tostring(k)] = true
        end
    end
    for k, v in pairs(mapB) do
        if not util.equal(v, mapA[k]) then
            result[tostring(k)] = true
        end
    end
    return result
end

--- Which diagnostics can give another result after this setting changed: what a workspace
--- diagnosis has to run again. `nil` means all of them (any setting that is not known here:
--- a wrong guess must cost time, never an out of date result); an empty table means none.
---@param key      string
---@param value    any
---@param oldValue any
---@return table<string, true>?
function m.getAffectedDiagnostics(key, value, oldValue)
    ---@type table<string, true>?
    local names
    local reading = readers[key]
    if reading then
        names = {}
        for _, name in ipairs(reading) do
            names[name] = true
        end
    elseif key == 'Lua.diagnostics.disable'
    or     key == 'Lua.diagnostics.severity'
    or     key == 'Lua.diagnostics.neededFileStatus' then
        -- a list of names, or a map from names
        names = differences(value, oldValue)
    elseif key == 'Lua.diagnostics.groupSeverity'
    or     key == 'Lua.diagnostics.groupFileStatus' then
        local groups = differences(value, oldValue)
        names = {}
        for name in pairs(diagd.diagnosticDatas) do
            for _, group in ipairs(diagd.getGroups(name)) do
                if groups[group] then
                    names[name] = true
                end
            end
        end
    end
    -- `unfulfilled-expect` needs the outcome of every other diagnostic
    if names and names['unfulfilled-expect'] then
        return nil
    end
    return names
end

config.watch(function (uri, key, value, oldValue)
    if util.stringStartWith(key, 'Lua.diagnostics')
    or util.stringStartWith(key, 'Lua.spell')
    or util.stringStartWith(key, 'Lua.doc') then
        if value ~= oldValue then
            local names = m.getAffectedDiagnostics(key, value, oldValue)
            if not names or next(names) then
                m.diagnosticsScope(uri, nil, nil, names)
            end
            m.refreshClient()
        end
    end
end)

fw.event(function (_ev, path)
    if util.stringEndWith(path, '.editorconfig') then
        for _, scp in ipairs(ws.folders) do
            m.diagnosticsScope(scp.uri)
            m.refreshClient()
        end
    end
end)

return m
