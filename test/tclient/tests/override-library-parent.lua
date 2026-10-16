-- incompatible-override only judges a class against parents the user owns: a parent whose member is declared in a library OUTSIDE the
-- workspace (third-party annotations: a polyfill class that re-annotates a library type on purpose) is left alone, and a library folder that
-- sits inside the workspace (a project that lists its own folders in `Lua.workspace.library`) still counts as owned.
local lclient = require 'lclient'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local furi    = require 'file-uri'
local ws      = require 'workspace'
local files   = require 'files'
local core    = require 'core.diagnostics'

local rootPath = LOGPATH .. '/override-library-parent'
local outPath  = LOGPATH .. '/override-library-parent-outside'
local ownPath  = rootPath .. '/own'
local rootUri  = furi.encode(rootPath)

fs.create_directories(fs.path(ownPath))
fs.create_directories(fs.path(outPath))

util.saveFile(outPath .. '/lib.lua', [[
---@class OlpLibBase
local OlpLibBase = {}
---@param n number
function OlpLibBase:go(n) end
---@class OlpLibData
---@field level integer
]])

util.saveFile(ownPath .. '/own.lua', [[
---@class OlpOwnBase
local OlpOwnBase = {}
---@param n number
function OlpOwnBase:go(n) end
]])

util.saveFile(rootPath .. '/child.lua', [[
---@class OlpLibChild : OlpLibBase
---@field level string
local OlpLibChild = {}
---@param n string
function OlpLibChild:go(n) end

---@class OlpLibDataChild : OlpLibData
---@field level string

---@class OlpOwnChild : OlpOwnBase
local OlpOwnChild = {}
---@param n string
function OlpOwnChild:go(n) end
]])

---@async
lclient():start(function (client)
    client:registerFakers()

    client:register('workspace/configuration', function ()
        return {
            {
                ['workspace.library'] = { outPath, ownPath },
            },
        }
    end)

    client:initialize {
        rootPath = rootPath,
        rootUri  = rootUri,
    }
    ws.awaitReady(rootUri)

    local uri = furi.encode(rootPath .. '/child.lua')
    assert(files.isLibrary(furi.encode(outPath .. '/lib.lua')), 'the outside folder is a library')
    assert(files.isLibrary(furi.encode(ownPath .. '/own.lua')), 'the inside folder is listed as a library too')

    ---@type string[]
    local messages = {}
    core(uri, false, function (result)
        if result.code == 'incompatible-override' then
            messages[#messages+1] = result.message
        end
    end, nil, true, { ['incompatible-override'] = true })

    assert(#messages == 1, 'exactly one report (the owned parent): ' .. #messages)
    assert(messages[1]:find('OlpOwnBase', 1, true), 'it is the one against the owned parent, not a library one: ' .. messages[1])
end)
