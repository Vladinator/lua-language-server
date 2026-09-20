local config = require 'config'
local util   = require 'utility'
local client = require 'client'
local lang   = require 'language'
local await  = require 'await'
local scope  = require 'workspace.scope'
local ws     = require 'workspace'
local trust  = require 'plugin-trust'
local fs     = require 'bee.filesystem'

-- The user plugin system (`Lua.runtime.plugin`, see doc/en-us/plugin.md). A plugin is a Lua file
-- whose globals are its hooks. This is a different thing from the diagnostic plugins of
-- core/diagnostics/custom-plugins.lua, which register new diagnostics.

---@alias plugin.compileParam fun(func: parser.object, source: parser.object): boolean?

--- the new text, or the diffs (`string.merger.diff`) to apply to the old one
---@alias plugin.textResult string|string.merger.diff[]

---@class plugin.vm
---@field OnCompileFunctionParam? fun(next: plugin.compileParam, func: parser.object, source: parser.object): boolean?

--- What a plugin file defines. Every hook is optional.
---@class plugin.interface
---@field OnSetText?      fun(uri: uri, text: string): plugin.textResult?
---@field OnTransformAst? fun(uri: uri, ast: parser.object): parser.object?
---@field ResolveRequire? fun(uri: uri, name: string, suri: uri): uri[]?
---@field VM?             plugin.vm

---@alias plugin.event 'OnSetText' | 'OnTransformAst' | 'ResolveRequire'

---@class plugin
local m = {}

---@type table<plugin.interface, string> # the file each loaded interface came from
local paths = setmetatable({}, { __mode = 'k' })

--- The plugins that already reported an error since the last reload: one message box each, not
--- one per event.
---@type table<string, true>
local hasShowedError = {}

---@param pluginPath string?
---@param err any
function m.showError(pluginPath, err)
    local key = pluginPath or ''
    if hasShowedError[key] then
        return
    end
    hasShowedError[key] = true
    client.showMessage('Error', lang.script('PLUGIN_RUNTIME_ERROR', pluginPath or '?', err))
end

--- `xpcall` handler: log where it failed and hand the message on (`log.error` alone returns
--- nothing, which used to leave the caller with a `nil` error to show).
---@param err any
---@return string
local function onError(err)
    local message = tostring(err)
    log.error(message)
    return message
end

--- Runs `event` in every plugin that defines it.
---
--- Returns whether all of them succeeded (`false` also when none defines the event), then what the
--- last plugin that returned something returned. That is whatever the handler returns --
--- genuinely untyped, since a plugin is arbitrary user-supplied Lua; callers for a specific event
--- know its real shape and narrow it themselves (see files.lua's pluginOnTransformAst for an
--- example).
---@param event plugin.event
---@param uri uri
---@param ... any
---@return boolean success
---@return any     result
function m.dispatch(event, uri, ...)
    local scp = scope.getScope(uri)
    local interfaces = scp:get('pluginInterfaces') --[[@as plugin.interface[]? ]]
    if not interfaces then
        return false
    end
    local ran    = 0
    local failed = 0
    ---@type any
    local result
    for _, interface in ipairs(interfaces) do
        local method = interface[event] --[[@as function?]]
        if type(method) == 'function' then
            ran = ran + 1
            local clock = os.clock()
            tracy.ZoneBeginN('plugin dispatch:' .. event)
            local suc, res = xpcall(method, onError, uri, ...)
            tracy.ZoneEnd()
            local passed = os.clock() - clock
            if passed > 0.1 then
                log.warn(('Call plugin event [%s] takes [%.3f] sec'):format(event, passed))
            end
            if not suc then
                m.showError(paths[interface], res)
                failed = failed + 1
            elseif res ~= nil then
                result = res
            end
        end
    end
    if ran == 0 then
        return false
    end
    return failed == 0, result
end

---@param uri uri
---@return plugin.interface[]?
function m.getPluginInterfaces(uri)
    return scope.getScope(uri):get('pluginInterfaces') --[[@as plugin.interface[]? ]]
end

--- `Lua.runtime.pluginArgs` is either the arguments for every plugin (an array) or a table keyed
--- by a part of the plugin path.
---@param args any
---@param pluginConfigPath string
---@return any
local function argsFor(args, pluginConfigPath)
    if args and not args[1] then
        for k, v in pairs(args --[[@as table<any, any>]]) do
            if pluginConfigPath:find(k, 1, true) then
                return v
            end
        end
    end
    return args
end

--- Loads one plugin file into a fresh interface. Any failure is reported and leaves the other
--- plugins alone.
---@async
---@param scp scope
---@param uri uri
---@param pluginConfigPath string
---@param args any
---@return plugin.interface?
local function loadPlugin(scp, uri, pluginConfigPath, args)
    local pluginPath = ws.getAbsolutePath(scp.uri, pluginConfigPath)
    log.info('plugin path:', pluginPath)
    if not pluginPath then
        return
    end

    local pluginLua = util.loadFile(pluginPath)
    if not pluginLua then
        log.warn('plugin not found:', pluginPath)
        return
    end

    ---@type plugin.interface
    local interface = setmetatable({}, { __index = _ENV })
    local f, err = load(pluginLua, '@' .. pluginPath, "t", interface)
    if not f then
        log.error(err)
        m.showError(pluginPath, err)
        return
    end
    if not trust.check(pluginPath, 'PLUGIN_TRUST_LOAD') then
        return
    end

    -- Adding the plugin's folder to package.path lets the plugin `require` files next to itself.
    local added = ';' .. (fs.path(pluginPath):parent_path() / '?.lua'):string()
    local hadIt = package.path:find(added, 1, true) ~= nil
    if not hadIt then
        package.path = package.path .. added
    end

    -- the chunk receives itself, the workspace uri and its arguments
    local suc, runErr = xpcall(f, onError, f, uri, args)
    if not suc then
        m.showError(pluginPath, runErr)
        if not hadIt then
            local from, to = package.path:find(added, 1, true)
            if from and to then
                package.path = package.path:sub(1, from - 1) .. package.path:sub(to + 1)
            end
        end
        return
    end
    paths[interface] = pluginPath
    return interface
end

---@param uri uri
local function initPlugin(uri)
    await.call(function () ---@async
        local scp = scope.getScope(uri)
        ---@type plugin.interface[]
        local interfaces = {}
        scp:set('pluginInterfaces', interfaces)
        hasShowedError = {}

        if not scp.uri then
            return
        end
        ---@type string[]|string
        local pluginConfigPaths = config.get(scp.uri, 'Lua.runtime.plugin')
        if not pluginConfigPaths then
            return
        end
        local args = config.get(scp.uri, 'Lua.runtime.pluginArgs')
        if args == nil then args = {} end
        if type(pluginConfigPaths) == 'string' then
            pluginConfigPaths = { pluginConfigPaths }
        end
        for _, pluginConfigPath in ipairs(pluginConfigPaths) do
            local interface = loadPlugin(scp, uri, pluginConfigPath, argsFor(args, pluginConfigPath))
            if interface then
                interfaces[#interfaces+1] = interface
            end
        end

        if #interfaces > 0 then
            ws.resetFiles(scp)
        end
    end)
end

ws.watch(function (ev, uri)
    if ev == 'startReload' then
        require 'plugins'
        initPlugin(uri)
    end
end)

return m
