-- A file that changes on disk while it is not open (a `git checkout`, a formatter, another editor) is a save as far as the files that use it
-- are concerned: the workspace diagnosis runs again, like it does when such a file is created or removed. A file that is open and edited is not a save
-- (that waits for the save), and `Lua.diagnostics.workspaceEvent` still decides: `None` runs nothing, `OnChange` runs once (not twice).
local lclient = require 'lclient'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local furi    = require 'file-uri'
local ws      = require 'workspace'
local files   = require 'files'
local scope   = require 'workspace.scope'
local config  = require 'config'
local await   = require 'await'
local diag    = require 'provider.diagnostic'

local rootPath = LOGPATH .. '/diag-disk-change'
local rootUri  = furi.encode(rootPath)

fs.create_directories(fs.path(rootPath))
util.saveFile(rootPath .. '/definer.lua', 'function Defined() end\n')
util.saveFile(rootPath .. '/user.lua', 'Defined()\n')
util.saveFile(rootPath .. '/editor.lua', 'local x = 1\n')

---@async
lclient():start(function (client)
    client:registerFakers()
    client:initialize {
        rootPath = rootPath,
        rootUri  = rootUri,
    }
    ws.awaitReady(rootUri)

    local definerUri = furi.encode(rootPath .. '/definer.lua')
    local editorUri  = furi.encode(rootPath .. '/editor.lua')
    local scopeName  = scope.getScope(definerUri):getName()

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

    -- the passes that are asked for (the changed file of each), without running them
    ---@type (uri|false)[]
    local passes = {}
    local diagnosticsScope = diag.diagnosticsScope
    diag.diagnosticsScope = function (_, _, _, _, changedUri)
        passes[#passes+1] = changedUri or false
    end

    -- (more than the delay of the setting, 3 s)
    ---@async
    local function settle()
        await.sleep(4)
    end

    -- the default (`OnSave`): a closed file rewritten on disk is a save
    passes = {}
    files.setText(definerUri, 'function Defined2() end\n')
    settle()
    assert(#passes == 1 and passes[1] == definerUri, ('a closed file changed on disk: one pass for it, got %d'):format(#passes))

    -- ... an open file that is edited is not (the editor sends the save)
    files.open(editorUri)
    passes = {}
    files.setText(editorUri, 'local x = 2\n')
    settle()
    assert(#passes == 0, ('an open file edited: no pass before the save, got %d'):format(#passes))
    files.close(editorUri)

    -- `None`: nothing runs
    config.set(rootUri, 'Lua.diagnostics.workspaceEvent', 'None')
    settle()
    passes = {}
    files.setText(definerUri, 'function Defined3() end\n')
    settle()
    assert(#passes == 0, ('workspaceEvent None: no pass, got %d'):format(#passes))

    -- `OnChange`: once per change of a closed file (not once as a change and once as a save)
    config.set(rootUri, 'Lua.diagnostics.workspaceEvent', 'OnChange')
    settle()
    passes = {}
    files.setText(definerUri, 'function Defined4() end\n')
    settle()
    assert(#passes == 1, ('workspaceEvent OnChange: one pass, got %d'):format(#passes))

    config.set(rootUri, 'Lua.diagnostics.workspaceEvent', 'OnSave')
    diag.diagnosticsScope = diagnosticsScope
end)
