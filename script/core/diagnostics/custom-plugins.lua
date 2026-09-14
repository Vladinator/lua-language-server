-- Loads user-provided diagnostic plugin files from a directory configured
-- via `Lua.diagnostics.pluginsDir` (blank by default -- opt-in). Each
-- `.lua` file directly inside that directory is loaded and run exactly
-- like a built-in core/diagnostics/*.lua plugin: it self-registers via
-- proto.diagnostic.register and returns a `function(uri, callback)` check
-- function -- see core/diagnostics/need-check-secret.lua for what a full
-- self-contained plugin looks like. The one convention a custom plugin
-- must follow that built-ins don't have to: its filename (without .lua)
-- must be the name it registers, since that's how this loader locates
-- the check function core/diagnostics/init.lua's check() needs to call
-- for it (a custom plugin isn't reachable via the normal
-- require('core.diagnostics.'..name) convention, since it doesn't live
-- under script/core/diagnostics/).
--
-- Mirrors plugin.lua's existing Lua.runtime.plugin loading (same
-- load/xpcall/trust-prompt shape, same trusted-paths file) rather than
-- introducing a second pattern for "run arbitrary Lua from a configured
-- path" -- loading a directory of files is still loading arbitrary code
-- the language server didn't ship with.

local config = require 'config'
local util   = require 'utility'
local client = require 'client'
local lang   = require 'language'
local await  = require 'await'
local ws     = require 'workspace'
local diag   = require 'proto.diagnostic'
local fs     = require 'bee.filesystem'

---@class core.diagnostics.customPlugins
local m = {}

-- core/diagnostics/init.lua's check() calls this with a 3rd `name`
-- argument that no diagnostic function actually declares or uses (every
-- built-in is `function (uri, callback) ... end`) -- Lua discards extra
-- call arguments a function doesn't declare params for, so this is
-- harmless, but the alias includes it to match the real call site
-- instead of just narrowly matching what plugins happen to read.
---@alias core.diagnostics.checkFn async fun(uri: uri, callback: fun(result: any), name?: string)

---@type table<string, core.diagnostics.checkFn>
local registry = {}
---@type table<string, string> # diagnostic name -> the plugin file path that currently owns it
local owner = {}

--- Look up the check function a custom plugin registered under `name`, if
--- any. core/diagnostics/init.lua's check() calls this before falling
--- back to require('core.diagnostics.'..name) for built-ins.
---@param name string
---@return core.diagnostics.checkFn?
function m.get(name)
    return registry[name]
end

---@type table<string, true>
local hasShowedError = {}

---@param dirPath string
---@param err     string?
local function showError(dirPath, err)
    if hasShowedError[dirPath] then
        return
    end
    hasShowedError[dirPath] = true
    client.showMessage('Error', lang.script('DIAG_PLUGIN_RUNTIME_ERROR', dirPath, err))
end

---@async
---@param dirPath string
---@return boolean
local function checkTrustLoad(dirPath)
    if TRUST_ALL_PLUGINS then
        return true
    end
    if client.getOption('trustByClient') then
        return true
    end
    local filePath = LOGPATH .. '/trusted'
    local trusted = util.loadFile(filePath)
    local lines = {}
    if trusted then
        for line in util.eachLine(trusted) do
            lines[#lines+1] = line
            if line == dirPath then
                return true
            end
        end
    end
    local _, index = client.awaitRequestMessage('Warning', lang.script('DIAG_PLUGIN_TRUST_LOAD', dirPath), {
        lang.script('PLUGIN_TRUST_YES'),
        lang.script('PLUGIN_TRUST_NO'),
    })
    if not index then
        return false
    end
    lines[#lines+1] = dirPath
    util.saveFile(filePath, table.concat(lines, '\n'))
    return true
end

---@async
---@param dirPath string absolute filesystem path to scan
local function loadDirectory(dirPath)
    local dir = fs.path(dirPath)
    if not fs.exists(dir) or not fs.is_directory(dir) then
        return
    end
    if not checkTrustLoad(dirPath) then
        return
    end
    for path in fs.pairs(dir) do
        if not fs.is_directory(path) and path:extension() == '.lua' then
            local filePath = path:string()
            local name     = path:stem():string()
            local before   = diag.diagnosticDatas[name]

            local src, readErr = util.loadFile(filePath)
            if not src then
                log.warn(('Custom diagnostic plugin: failed to read [%s]: %s'):format(filePath, readErr))
                goto CONTINUE
            end

            local f, loadErr = load(src, '@' .. filePath, 't')
            if not f then
                log.error(('Custom diagnostic plugin: failed to parse [%s]: %s'):format(filePath, loadErr))
                showError(dirPath, loadErr)
                goto CONTINUE
            end

            local suc, result = xpcall(f, debug.traceback)
            if not suc then
                log.error(('Custom diagnostic plugin: error running [%s]: %s'):format(filePath, result))
                showError(dirPath, result)
                diag.diagnosticDatas[name] = before
                goto CONTINUE
            end

            if before and owner[name] ~= filePath then
                log.warn(('Custom diagnostic plugin [%s] registers %q, which collides with an existing diagnostic of the same name. Skipped.'):format(filePath, name))
                diag.diagnosticDatas[name] = before
                goto CONTINUE
            end

            if not diag.diagnosticDatas[name] then
                log.warn(('Custom diagnostic plugin [%s] must self-register as %q (its own filename) via proto.diagnostic.register -- see core/diagnostics/need-check-secret.lua for the expected shape.'):format(filePath, name))
                goto CONTINUE
            end

            if type(result) ~= 'function' then
                log.warn(('Custom diagnostic plugin [%s] must `return function(uri, callback) ... end`.'):format(filePath))
                diag.diagnosticDatas[name] = before
                goto CONTINUE
            end

            registry[name] = result
            owner[name]    = filePath

            ::CONTINUE::
        end
    end
end

ws.watch(function (ev, uri) ---@async
    if ev ~= 'startReload' then
        return
    end
    local dirSetting = config.get(uri, 'Lua.diagnostics.pluginsDir')
    if not dirSetting or dirSetting == '' then
        return
    end
    local dirPath = ws.getAbsolutePath(uri, dirSetting)
    if not dirPath then
        return
    end
    await.call(function () ---@async
        loadDirectory(dirPath)
    end)
end)

return m
