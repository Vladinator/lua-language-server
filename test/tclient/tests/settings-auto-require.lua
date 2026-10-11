-- `Lua.completion.autoRequire`: typing the name of a module of the workspace offers it with a command that adds the `require`;
-- off, nothing of the kind is offered. Needs a real workspace (the module files are found by the scan), so it is a client test.
local lclient = require 'lclient'
local ws      = require 'workspace'
local furi    = require 'file-uri'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local await   = require 'await'

local DIR = fs.path(LOGPATH) / 'settings-auto-require'
pcall((fs --[[@as any]]).remove_all, DIR)
fs.create_directories(DIR)
local nl = string.char(10)
util.saveFile((DIR / 'zebramodule.lua'):string(), 'local M = {}' .. nl .. 'function M.go() end' .. nl .. 'return M' .. nl)
local root = assert(furi.encode(DIR:string()))
local uri  = root .. '/main.lua'
local TEXT = 'zebram'

--- Complete at the end of `zebram` with the setting at `value` and say whether the module is offered with the require command.
---@param value boolean
---@return boolean
local function offered(value)
    local found = false
    ---@async
    lclient():start(function (client)
        client:registerFakers()
        client:register('workspace/configuration', function ()
            return { { ['completion.autoRequire'] = value, ['workspace.useGitIgnore'] = false } }
        end)
        client:initialize { rootUri = root }
        ws.awaitReady(root)
        client:notify('textDocument/didOpen', {
            textDocument = { uri = uri, languageId = 'lua', version = 1, text = TEXT },
        })
        await.sleep(0.5)
        ---@type any
        local result = client:awaitRequest('textDocument/completion', {
            textDocument = { uri = uri }, position = { line = 0, character = #TEXT },
        })
        ---@type any[]
        local items = result and (result.items or result) or {}
        for _, item in ipairs(items) do
            if item.label == 'zebramodule' and item.command and item.command.command == 'lua.autoRequire' then
                found = true
            end
        end
    end)
    return found
end

assert(offered(true), 'autoRequire on: the module is offered with the require command')
assert(not offered(false), 'autoRequire off: it is not')

pcall((fs --[[@as any]]).remove_all, DIR)
