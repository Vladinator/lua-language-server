-- plugin.dispatch and the way files.lua uses what a `Lua.runtime.plugin` plugin hands back.
local plugin = require 'plugin'
local scope  = require 'workspace.scope'
local client = require 'client'
local files  = require 'files'

---@diagnostic disable: await-in-sync

--- Runs `callback` with `interfaces` installed as the plugins of the test workspace.
---@param interfaces plugin.interface[]
---@param callback fun()
local function withPlugins(interfaces, callback)
    local scp = scope.getScope(TESTURI)
    local old = scp:get('pluginInterfaces')
    scp:set('pluginInterfaces', interfaces)
    local ok, err = pcall(callback)
    scp:set('pluginInterfaces', old)
    assert(ok, err)
end

--- Collects what would be shown to the user while `callback` runs.
---@param callback fun()
---@return string[]
local function collectMessages(callback)
    ---@type string[]
    local messages = {}
    local showMessage = client.showMessage
    client.showMessage = function (_, ...)
        messages[#messages+1] = table.concat({ ... }, ' ')
    end
    local ok, err = pcall(callback)
    client.showMessage = showMessage
    assert(ok, err)
    return messages
end

-- no plugin at all: nothing ran
do
    local scp = scope.getScope(TESTURI)
    local old = scp:get('pluginInterfaces')
    scp:set('pluginInterfaces', nil)
    assert(plugin.dispatch('OnSetText', TESTURI, 'x') == false)
    scp:set('pluginInterfaces', old)
end

-- a plugin that does not define the event is skipped, it does not stop the ones after it
withPlugins({
    { OnTransformAst = function () end },
    { OnSetText = function (_, text) return text .. '!' end },
}, function ()
    local suc, res = plugin.dispatch('OnSetText', TESTURI, 'x')
    assert(suc == true)
    assert(res == 'x!')
end)

-- nobody defines the event: not a success, callers fall back to what they had
withPlugins({
    { OnTransformAst = function () end },
}, function ()
    assert(plugin.dispatch('OnSetText', TESTURI, 'x') == false)
end)

-- a later plugin that returns nothing does not wipe the result of an earlier one
withPlugins({
    { OnSetText = function () return 'first' end },
    { OnSetText = function () end },
}, function ()
    local suc, res = plugin.dispatch('OnSetText', TESTURI, 'x')
    assert(suc == true)
    assert(res == 'first')
end)

-- a list comes through as it is
withPlugins({
    { ResolveRequire = function () return { 'file:///a.lua' } end },
}, function ()
    local suc, res = plugin.dispatch('ResolveRequire', TESTURI, 'a', TESTURI)
    assert(suc == true)
    assert(res[1] == 'file:///a.lua')
end)

-- a failing plugin: the user gets the error text (once), the plugins after it still run
local messages = collectMessages(function ()
    withPlugins({
        { OnSetText = function () error('boom', 0) end },
        { OnSetText = function () return 'after' end },
    }, function ()
        local suc, res = plugin.dispatch('OnSetText', TESTURI, 'x')
        assert(suc == false)
        assert(res == 'after')
        assert(plugin.dispatch('OnSetText', TESTURI, 'x') == false)
    end)
end)
assert(#messages == 1)
assert(messages[1]:find('boom', 1, true))

-- the parameter hook: a failing plugin does not stop the ones after it, or the compile
-- (a plugin is arbitrary Lua, its `VM` can be anything)
---@type any
local notATable = 'not a table'
withPlugins({
    { VM = { OnCompileFunctionParam = function () error('boom', 0) end } },
    { VM = {} },
    { VM = notATable },
    { VM = { OnCompileFunctionParam = function () return true end } },
}, function ()
    local function default() return false end
    local answered = collectMessages(function ()
        assert(plugin.compileFunctionParam(TESTURI, default, {}, {}) == true)
    end)
    assert(#answered <= 1)
end)

withPlugins({
    { VM = { OnCompileFunctionParam = function () return false end } },
}, function ()
    assert(plugin.compileFunctionParam(TESTURI, function () return false end, {}, {}) == false)
end)

-- what the file machinery does with the results
---@param interfaces plugin.interface[]
---@param text string
---@param checker fun(state: parser.state)
local function withFile(interfaces, text, checker)
    withPlugins(interfaces, function ()
        files.open(TESTURI)
        files.setText(TESTURI, text, true)
        local state = files.getState(TESTURI)
        assert(state)
        checker(state)
        files.remove(TESTURI)
    end)
end

-- OnSetText can rewrite the text that is parsed
withFile({
    { OnSetText = function () return 'local rewritten = 1' end },
}, 'local original = 1', function (state)
    assert(state.lua == 'local rewritten = 1')
end)

-- OnTransformAst can hand back a replacement tree, but anything else keeps the tree there was
-- (a plugin is arbitrary Lua: nothing stops it from returning the wrong thing)
---@return any
local function notATree() return 'not a tree' end
withFile({
    { OnTransformAst = notATree },
}, 'local x = 1', function (state)
    assert(type(state.ast) == 'table')
    assert(state.ast.type == 'main')
end)
