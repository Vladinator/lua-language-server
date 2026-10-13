-- `Lua.runtime.pluginArgs`: handed to every plugin as its third chunk argument; a table keyed by a part of a plugin's path gives each
-- plugin its own entry (a string), a plugin no key matches gets the whole table. The plugins load with the workspace: a client per case.
local lclient = require 'lclient'
local ws      = require 'workspace'
local plugin  = require 'plugin'
local furi    = require 'file-uri'
local fs      = require 'bee.filesystem'
local util    = require 'utility'

local DIR = fs.path(LOGPATH) / 'settings-plugin-args'
pcall((fs --[[@as any]]).remove_all, DIR)
fs.create_directories(DIR)
local nl = string.char(10)
-- a plugin that keeps the arguments it was started with
for _, name in ipairs { 'alpha.lua', 'beta.lua' } do
    util.saveFile((DIR / name):string(), 'local _, _, args = ...' .. nl .. 'ARGS = args' .. nl)
end
util.saveFile((DIR / 'main.lua'):string(), 'X = 1' .. nl)
local root = assert(furi.encode(DIR:string()))

--- Start a client with these arguments, load both plugins and say what each one received.
---@param pluginArgs any
---@return any alphaArgs, any betaArgs
local function receivedBy(pluginArgs)
    local alpha, beta
    ---@async
    lclient():start(function (client)
        client:registerFakers()
        client:register('workspace/configuration', function ()
            return { {
                ['runtime.plugin']     = { 'alpha.lua', 'beta.lua' },
                ['runtime.pluginArgs'] = pluginArgs,
                ['workspace.useGitIgnore'] = false,
            } }
        end)
        client:initialize { rootUri = root }
        ws.awaitReady(root)
        local interfaces = plugin.getPluginInterfaces(root) or {}
        alpha = interfaces[1] and rawget(interfaces[1], 'ARGS')
        beta  = interfaces[2] and rawget(interfaces[2], 'ARGS')
    end)
    return alpha, beta
end

-- an array: every plugin gets it
do
    local alpha, beta = receivedBy { 'x', 'y' }
    assert(type(alpha) == 'table' and alpha[1] == 'x' and alpha[2] == 'y', 'array: the first plugin')
    assert(type(beta) == 'table' and beta[1] == 'x' and beta[2] == 'y', 'array: the second plugin')
end

-- a table keyed by a part of the path: each plugin its own entry
do
    local alpha, beta = receivedBy { alpha = 'for-alpha', beta = 'for-beta' }
    assert(alpha == 'for-alpha', 'keyed: alpha gets its own entry: ' .. require('json').encode(alpha))
    assert(beta == 'for-beta', 'keyed: beta gets its own entry')
end

-- a key that matches one plugin only: the other one gets the whole table
do
    local alpha, beta = receivedBy { alpha = 'for-alpha' }
    assert(alpha == 'for-alpha', 'partial: alpha gets its entry')
    assert(type(beta) == 'table' and beta.alpha == 'for-alpha', 'partial: beta gets the whole table')
end

-- nothing set: an empty table
do
    local alpha, beta = receivedBy(nil)
    assert(type(alpha) == 'table' and next(alpha) == nil, 'unset: an empty table for the first plugin')
    assert(type(beta) == 'table' and next(beta) == nil, 'unset: an empty table for the second plugin')
end

pcall((fs --[[@as any]]).remove_all, DIR)
