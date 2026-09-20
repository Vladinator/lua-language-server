-- How a workspace diagnosis takes what is asked for while it runs (provider.diagnostic): a few
-- diagnostics that have to run again are queued behind a pass that is running, not cancelling it;
-- everything asked for is done, also when a pass is cancelled. (The result of running just some
-- of the diagnostics is tested in test/diag_partial.)
local lclient = require 'lclient'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local furi    = require 'file-uri'
local ws      = require 'workspace'
local files   = require 'files'
local scope   = require 'workspace.scope'
local await   = require 'await'
local diag    = require 'provider.diagnostic'

local rootPath = LOGPATH .. '/diag-scope'
local rootUri  = furi.encode(rootPath)

fs.create_directories(fs.path(rootPath))
for i = 1, 5 do
    util.saveFile(rootPath .. '/f' .. i .. '.lua', 'local x = ' .. i)
end

---@param names table<string, true>
---@return string
local function nameList(names)
    ---@type string[]
    local list = {}
    for name in pairs(names) do
        list[#list+1] = name
    end
    table.sort(list)
    return '{' .. table.concat(list, ', ') .. '}'
end

---@async
lclient():start(function (client)
    client:registerFakers()
    client:initialize {
        rootPath = rootPath,
        rootUri  = rootUri,
    }
    ws.awaitReady(rootUri)

    local uri       = furi.encode(rootPath .. '/f1.lua')
    local scopeName = scope.getScope(uri):getName()

    ---@async
    local function waitIdle()
        for _ = 1, 2000 do
            await.sleep(0.1)
            if not diag.scopeRunning[scopeName] and not diag.pending[scopeName] then
                await.sleep(0.1)
                if not diag.scopeRunning[scopeName] and not diag.pending[scopeName] then
                    return
                end
            end
        end
        error('the workspace diagnosis did not finish')
    end
    -- what the loading of the workspace started
    waitIdle()

    local count = #files.getAllUris(uri)
    assert(count >= 5)

    -- each file takes 50 ms
    ---@type { uri: uri, only: string }[]
    local calls = {}
    local doDiagnostic = diag.doDiagnostic
    ---@async
    diag.doDiagnostic = function (fileUri, _, _, only)
        calls[#calls+1] = { uri = fileUri, only = only and nameList(only) or 'all' }
        await.sleep(0.05)
    end

    ---@param from integer
    ---@param to   integer
    ---@param only string
    local function assertCalls(from, to, only)
        for i = from, to do
            assert(calls[i] and calls[i].only == only,
                ('call %d: expected %s, got %s'):format(i, only, calls[i] and calls[i].only or 'nothing'))
        end
    end

    local function reset()
        calls = {}
        diag.pending = {}
    end

    local globalsOnly = { ['undefined-global'] = true }

    -- nothing running: the pass does what was asked
    reset()
    diag.diagnosticsScope(uri, nil, nil, globalsOnly)
    waitIdle()
    assert(#calls == count, 'a partial request: every file once, got ' .. #calls)
    assertCalls(1, count, '{undefined-global}')

    -- a full pass is running: it is not cancelled for a few diagnostics, it goes on and the next pass does them
    reset()
    diag.diagnosticsScope(uri)
    await.sleep(0.12)
    assert(#calls >= 1 and #calls < count, 'the full pass is running')
    diag.diagnosticsScope(uri, nil, nil, globalsOnly)
    waitIdle()
    assert(#calls == 2 * count, ('the full pass finished, then the partial one: %d calls'):format(#calls))
    assertCalls(1, count, 'all')
    assertCalls(count + 1, 2 * count, '{undefined-global}')

    -- a partial pass is running and more comes in: one more pass, of what was asked for meanwhile
    reset()
    diag.diagnosticsScope(uri, nil, nil, { ['unused-local'] = true })
    await.sleep(0.12)
    diag.diagnosticsScope(uri, nil, nil, globalsOnly)
    waitIdle()
    assert(#calls == 2 * count)
    assertCalls(1, count, '{unused-local}')
    assertCalls(count + 1, 2 * count, '{undefined-global}')

    -- a full request cancels a partial pass that is running and does everything
    reset()
    diag.diagnosticsScope(uri, nil, nil, globalsOnly)
    await.sleep(0.12)
    local partial = #calls
    assert(partial >= 1 and partial < count)
    diag.diagnosticsScope(uri)
    waitIdle()
    assert(#calls == partial + count, ('cancelled, then everything: %d calls'):format(#calls))
    assertCalls(partial + 1, partial + count, 'all')

    -- a pass that is cancelled otherwise (a file changed) puts back what it had taken
    reset()
    diag.diagnosticsScope(uri, nil, nil, globalsOnly)
    await.sleep(0.12)
    diag.stopScopeDiag(uri)
    await.sleep(0.1)
    assert(not diag.scopeRunning[scopeName], 'stopped')
    local request = assert(diag.pending[scopeName], 'what it had taken is back')
    assert(request.all == false and request.names['undefined-global'])
    local stopped = #calls
    -- ... and the next pass does it together with what comes in then
    diag.diagnosticsScope(uri, nil, nil, { ['unused-local'] = true })
    waitIdle()
    assert(#calls == stopped + count)
    assertCalls(stopped + 1, stopped + count, '{undefined-global, unused-local}')

    -- a full pass that is cancelled, with a partial request queued meanwhile: everything is still to do
    reset()
    diag.diagnosticsScope(uri)
    await.sleep(0.12)
    diag.diagnosticsScope(uri, nil, nil, globalsOnly)
    diag.stopScopeDiag(uri)
    await.sleep(0.1)
    request = assert(diag.pending[scopeName])
    assert(request.all == true and request.names['undefined-global'])
    stopped = #calls
    diag.diagnosticsScope(uri, nil, nil, { ['unused-local'] = true })
    waitIdle()
    assertCalls(stopped + 1, #calls, 'all')
    assert(#calls == stopped + count)

    -- cancelled while it waits for the loading of files, before the first file: also then
    reset()
    local loading = require 'workspace.loading'
    local loadingCount = loading.count
    loading.count = function () return 1 end
    diag.diagnosticsScope(uri, nil, nil, globalsOnly)
    await.sleep(0.5)
    assert(diag.scopeRunning[scopeName] and #calls == 0, 'waiting for the loading')
    diag.stopScopeDiag(uri)
    await.sleep(0.1)
    request = assert(diag.pending[scopeName], 'put back although no file was diagnosed')
    assert(request.names['undefined-global'])
    loading.count = loadingCount

    diag.doDiagnostic = doDiagnostic
end)
