-- `Lua.runtime.meta`: the folder the built-in library definitions are written to is named by this template
-- (`${version}`, `${language}`, `${encoding}`). The libraries load with the workspace, so every case is a client of its own.
local lclient = require 'lclient'
local ws      = require 'workspace'
local furi    = require 'file-uri'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local lang    = require 'language'

local DIR = fs.path(LOGPATH) / 'settings-runtime-meta'
pcall((fs --[[@as any]]).remove_all, DIR)
fs.create_directories(DIR)
util.saveFile((DIR / 'main.lua'):string(), 'X = 1' .. string.char(10))
local root = assert(furi.encode(DIR:string()))

--- Start a client with this `runtime.meta` and `runtime.version`, wait for the workspace and say whether the folder exists.
---@param template string
---@param expected string the folder name the template must give
---@return boolean
local function wroteFolder(template, expected)
    local folder = fs.path(METAPATH) / expected
    pcall((fs --[[@as any]]).remove_all, folder)
    ---@async
    lclient():start(function (client)
        client:registerFakers()
        client:register('workspace/configuration', function ()
            return { { ['runtime.meta'] = template, ['runtime.version'] = 'Lua 5.3', ['workspace.useGitIgnore'] = false } }
        end)
        client:initialize { rootUri = root }
        ws.awaitReady(root)
    end)
    local exists = fs.exists(folder)
    pcall((fs --[[@as any]]).remove_all, folder)
    return exists
end

local name = 'zebra-Lua 5.3-' .. lang.id
assert(wroteFolder('zebra-${version}-${language}', name), 'the template names the folder: ' .. name)
-- the template decides: another one does not write this folder
assert(not wroteFolder('giraffe-${version}', name), 'a different template does not write the first folder')

pcall((fs --[[@as any]]).remove_all, DIR)
