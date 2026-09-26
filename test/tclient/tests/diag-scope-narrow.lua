-- provider.diagnostic + workspace.diagnostic-affected: an OnSave/OnChange-style request that
-- names the file that changed is narrowed to that file and whatever workspace.diagnostic-affected
-- says it could affect; every other trigger (no changed file given) still diagnoses everyone, as
-- covered by test/tclient/tests/diag-scope.lua.
local lclient = require 'lclient'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local furi    = require 'file-uri'
local ws      = require 'workspace'
local files   = require 'files'
local scope   = require 'workspace.scope'
local await   = require 'await'
local diag    = require 'provider.diagnostic'

local rootPath = LOGPATH .. '/diag-scope-narrow'
local rootUri  = furi.encode(rootPath)

fs.create_directories(fs.path(rootPath))
-- f1 declares a global; f2 references it by name (must be pulled in); f3/f4/f5 share nothing.
util.saveFile(rootPath .. '/f1.lua', 'Shared = 1')
util.saveFile(rootPath .. '/f2.lua', 'print(Shared)')
util.saveFile(rootPath .. '/f3.lua', 'local x = 3')
util.saveFile(rootPath .. '/f4.lua', 'local x = 4')
util.saveFile(rootPath .. '/f5.lua', 'local x = 5')

---@async
lclient():start(function (client)
    client:registerFakers()
    client:initialize {
        rootPath = rootPath,
        rootUri  = rootUri,
    }
    ws.awaitReady(rootUri)

    local uri1      = furi.encode(rootPath .. '/f1.lua')
    local scopeName = scope.getScope(uri1):getName()

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
    waitIdle()

    local count = #files.getAllUris(uri1)
    assert(count >= 5)

    ---@type table<uri, true>
    local seen = {}
    local doDiagnostic = diag.doDiagnostic
    ---@async
    diag.doDiagnostic = function (fileUri)
        seen[fileUri] = true
        await.sleep(0.01)
    end

    local function reset()
        seen = {}
        diag.pending = {}
    end

    -- a request naming the changed file is narrowed: f1 and f2, not f3/f4/f5.
    reset()
    diag.diagnosticsScope(uri1, nil, nil, nil, uri1)
    waitIdle()
    assert(seen[uri1], 'the changed file itself must be diagnosed')
    assert(seen[furi.encode(rootPath .. '/f2.lua')], 'a file referencing the changed global must be diagnosed')
    assert(not seen[furi.encode(rootPath .. '/f3.lua')], 'an unrelated file must be skipped')
    assert(not seen[furi.encode(rootPath .. '/f4.lua')], 'an unrelated file must be skipped')
    assert(not seen[furi.encode(rootPath .. '/f5.lua')], 'an unrelated file must be skipped')

    -- the exact same request with no changed file falls back to the whole scope, unchanged.
    reset()
    diag.diagnosticsScope(uri1)
    waitIdle()
    local fullCount = 0
    for _ in pairs(seen) do
        fullCount = fullCount + 1
    end
    assert(fullCount == count, ('a request with no changed file must diagnose everything, got %d of %d'):format(fullCount, count))

    -- a settings-driven request (no changed file) merged with a save (changed file) must not
    -- narrow: the untracked part could be anything, so the merged request stays full-scope.
    reset()
    local loading = require 'workspace.loading'
    local loadingCount = loading.count
    loading.count = function () return 1 end
    diag.diagnosticsScope(uri1, nil, nil, nil, uri1)
    diag.diagnosticsScope(uri1, nil, nil, { ['undefined-global'] = true })
    loading.count = loadingCount
    waitIdle()
    local mergedCount = 0
    for _ in pairs(seen) do
        mergedCount = mergedCount + 1
    end
    assert(mergedCount == count, ('a merged request with one untracked contributor must diagnose everything, got %d of %d'):format(mergedCount, count))

    diag.doDiagnostic = doDiagnostic
end)
