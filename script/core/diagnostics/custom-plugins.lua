-- Loads diagnostic plugin files from a directory. Each is run exactly
-- like a built-in core/diagnostics/*.lua plugin: it self-registers via
-- proto.diagnostic.register and returns a `function(uri, callback)`
-- check function -- see core/diagnostics/extra/need-check-secret.lua for
-- what a full self-contained plugin looks like. The one convention a
-- plugin loaded this way must follow that a plain core/diagnostics/*.lua
-- file (wired in through init.lua's eager-require list) doesn't: its
-- filename (without .lua) must be the name it registers, since that's
-- how this loader locates the check function core/diagnostics/init.lua's
-- check() needs to call for it later -- a plugin loaded from here isn't
-- reachable via the normal require('core.diagnostics.'..name)
-- convention.
--
-- A plugin can optionally ship its own tests right alongside it, as
-- `<name>.test.lua` (see need-check-secret.test.lua) -- this loader
-- skips those (they're not plugins themselves), and
-- test/diagnostics/init.lua's checkPluginDir runs one only if its
-- `<name>.lua` is still there next to it.
--
-- Two directories are loaded this way, both through loadDirectoryFiles()
-- below:
--   - script/core/diagnostics/extra/ -- shipped with the server, always
--     scanned once at load (see loadBuiltinExtras below, called at the
--     bottom of this file), no trust prompt: it's part of the software
--     the user already installed, same trust level as
--     core/diagnostics/*.lua itself. A diagnostic here doesn't need a
--     matching line in init.lua's eager-require list to be added or
--     removed -- drop a file in, it's live on the next start; delete
--     it, it's gone, no errors anywhere else. Use this for anything
--     non-standard or specialized enough that it doesn't belong in the
--     eager-require list, e.g. need-check-secret.lua's secret-value
--     tracking.
--   - Lua.diagnostics.pluginsDir -- user/workspace-configured, blank by
--     default. Same self-contained-file contract, but since it can
--     point anywhere on disk, loading from it goes through the same
--     trust-prompt flow as plugin.lua's existing Lua.runtime.plugin
--     (same load/xpcall shape, same trusted-paths file) rather than
--     introducing a second pattern for "run arbitrary Lua from a
--     configured path".

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
---@alias core.diagnostics.checkFn async fun(uri: uri, callback: async fun(result: any), name?: string)

---@type table<string, core.diagnostics.checkFn>
local registry = {}
---@type table<string, string> # diagnostic name -> the plugin file path that currently owns it
local owner = {}

--- Look up the check function a plugin loaded from either directory
--- registered under `name`, if any. core/diagnostics/init.lua's check()
--- calls this before falling back to require('core.diagnostics.'..name)
--- for eager-required built-ins.
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

--- Loads every `.lua` file directly inside `dirPath` (already confirmed
--- to exist) as a diagnostic plugin. Purely synchronous file I/O -- no
--- trust gating here, callers decide whether that's needed first. Skips
--- `*.test.lua` -- that's a plugin's own test file (see
--- test/diagnostics/init.lua's checkPluginDir), not part of the plugin
--- itself, so it must never run here.
---@param dirPath string absolute filesystem path to scan
local function loadDirectoryFiles(dirPath)
    local dir = fs.path(dirPath)
    for path in fs.pairs(dir) do
        if not fs.is_directory(path) and path:extension() == '.lua'
        and not path:filename():string():match('%.test%.lua$') then
            local filePath = path:string()
            local name     = path:stem():string()
            local before   = diag.diagnosticDatas[name]

            local src, readErr = util.loadFile(filePath)
            if not src then
                log.warn(('Diagnostic plugin: failed to read [%s]: %s'):format(filePath, readErr))
                goto CONTINUE
            end

            local f, loadErr = load(src, '@' .. filePath, 't')
            if not f then
                log.error(('Diagnostic plugin: failed to parse [%s]: %s'):format(filePath, loadErr))
                showError(dirPath, loadErr)
                goto CONTINUE
            end

            local suc, result = xpcall(f, debug.traceback)
            if not suc then
                log.error(('Diagnostic plugin: error running [%s]: %s'):format(filePath, result))
                showError(dirPath, result)
                diag.diagnosticDatas[name] = before
                goto CONTINUE
            end

            if before and owner[name] ~= filePath then
                log.warn(('Diagnostic plugin [%s] registers %q, which collides with an existing diagnostic of the same name. Skipped.'):format(filePath, name))
                diag.diagnosticDatas[name] = before
                goto CONTINUE
            end

            if not diag.diagnosticDatas[name] then
                log.warn(('Diagnostic plugin [%s] must self-register as %q (its own filename) via proto.diagnostic.register -- see core/diagnostics/extra/need-check-secret.lua for the expected shape.'):format(filePath, name))
                goto CONTINUE
            end

            if type(result) ~= 'function' then
                log.warn(('Diagnostic plugin [%s] must `return function(uri, callback) ... end`.'):format(filePath))
                diag.diagnosticDatas[name] = before
                goto CONTINUE
            end

            registry[name] = result
            owner[name]    = filePath

            ::CONTINUE::
        end
    end
end

--- Scans script/core/diagnostics/extra/ -- shipped with the server, no
--- trust prompt needed (same trust level as core/diagnostics/*.lua
--- itself), no workspace-scoping (it's the same everywhere). Called once
--- below, at this module's own load time -- the same timing
--- core/diagnostics/init.lua's eager-require list already runs at, since
--- that list requires this module before it requires any built-in.
local function loadBuiltinExtras()
    local dirPath = (ROOT / 'script' / 'core' / 'diagnostics' / 'extra'):string()
    local dir = fs.path(dirPath)
    if not fs.exists(dir) or not fs.is_directory(dir) then
        return
    end
    loadDirectoryFiles(dirPath)
end

loadBuiltinExtras()

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
        local dir = fs.path(dirPath)
        if not fs.exists(dir) or not fs.is_directory(dir) then
            return
        end
        if not checkTrustLoad(dirPath) then
            return
        end
        loadDirectoryFiles(dirPath)
    end)
end)

return m
