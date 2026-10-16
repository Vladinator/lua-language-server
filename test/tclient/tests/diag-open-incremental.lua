-- A file the user has open shows what the diagnoses have found so far while the rest of them still run, also when the workspace pass
-- reaches it first (provider.diagnostic: the throttled push in the `response` callback was only for diagnoses of one file).
-- A file that is not open gets one publication, at the end of its diagnosis.
local lclient = require 'lclient'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local furi    = require 'file-uri'
local ws      = require 'workspace'
local files   = require 'files'
local await   = require 'await'
local time    = require 'bee.time'
local diag    = require 'provider.diagnostic'

local rootPath = LOGPATH .. '/diag-open-incremental'
local rootUri  = furi.encode(rootPath)

-- several diagnoses find something in this text, so there are several results to publish
local TEXT = table.concat({
    'local unusedOne = 1',
    'local unusedTwo = 2',
    'print(zzUndefinedOne)',
    'print(zzUndefinedTwo)',
    'globalLower = 1',
    '',
}, '\n')

fs.create_directories(fs.path(rootPath))
util.saveFile(rootPath .. '/open.lua', TEXT)
util.saveFile(rootPath .. '/closed.lua', TEXT)

---@async
lclient():start(function (client)
    client:registerFakers()

    ---@type table<string, integer>
    local publications = {}
    client:register('textDocument/publishDiagnostics', function (params)
        publications[params.uri] = (publications[params.uri] or 0) + 1
        return nil
    end)

    client:initialize {
        rootPath = rootPath,
        rootUri  = rootUri,
    }
    ws.awaitReady(rootUri)
    await.sleep(1)

    local openUri   = furi.encode(rootPath .. '/open.lua')
    local closedUri = furi.encode(rootPath .. '/closed.lua')

    -- (the diagnoses that opening a file starts are not the ones to count: only the call below runs, and a replaced function is put back)
    local provider = diag --[[@as table<string, any>]]
    ---@type table<string, any>
    local saved = {}
    for _, name in ipairs { 'diagnosticsScope', 'refreshClient', 'refresh', 'refreshScopeDiag', 'stopScopeDiag' } do
        saved[name] = provider[name]
        provider[name] = function () end
    end
    files.open(openUri)
    await.sleep(1)

    -- every look at the clock is half a second later than the one before, so each result is due a push
    local realTime = time.time
    local now = 0
    time.time = function ()
        now = now + 600
        return now
    end

    ---@async
    local function diagnoseAsScope(uri)
        publications[uri] = nil
        -- the cache of what was shown before would make the same text look unchanged
        diag.cache[uri] = nil
        diag.doDiagnostic(uri, true, true)
        await.sleep(0.2)
        return publications[uri] or 0
    end

    local openCount   = diagnoseAsScope(openUri)
    local closedCount = diagnoseAsScope(closedUri)
    time.time = realTime
    for name, original in pairs(saved) do
        provider[name] = original
    end

    assert(openCount >= 2, 'an open file is published while its diagnosis runs: ' .. openCount)
    assert(closedCount <= 1, 'a file that is not open is published once, when it is done: ' .. closedCount)
end)
