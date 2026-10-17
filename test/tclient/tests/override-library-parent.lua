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

util.saveFile(rootPath .. '/plain.lua', [[
---@class OlpPlainBase
---@field known integer

---@class OlpFnBase
---@field callback fun(n: number): boolean
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

---@class OlpFnChild : OlpFnBase
---@field callback fun(n: string): boolean
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

    assert(#messages == 2, 'two reports (the owned parent, a method and a function field): ' .. #messages)
    table.sort(messages)
    -- (the message shows both signatures to compare at a glance: the method as written, the field as a fun type)
    assert(messages[1]:find('OlpFnBase', 1, true), 'the field against its owned parent: ' .. messages[1])
    assert(messages[1]:find('(n: number) -> boolean', 1, true) and messages[1]:find('(n: string) -> boolean', 1, true),
        'both signatures of the field: ' .. messages[1])
    assert(messages[2]:find('OlpOwnBase', 1, true), 'it is the one against the owned parent, not a library one: ' .. messages[2])
    assert(messages[2]:find('OlpOwnBase: `(n: number)`', 1, true) and messages[2]:find('OlpOwnChild: `(n: string)`', 1, true),
        'both signatures of the method, without the self: ' .. messages[2])

    -- the quick fix of `excess-field` declares the field in the file of the class, even from another file, and never for a class of a
    -- library (the diagnostic does not report those either: the same rule, so a fix is offered only where the diagnostic can fire)
    local actions = require 'core.code-action'
    local function declareActions(className)
        local diag = {
            code  = 'excess-field',
            range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } },
            data  = { class = className, key = 'extra', type = 'integer' },
        }
        ---@type core.code-action.result[]
        local found = {}
        for _, result in ipairs(actions(uri, 0, 1, { diag }) or {}) do
            if result.title:sub(1, 11) == 'Declare the' then
                found[#found+1] = result
            end
        end
        return found
    end
    local plain = declareActions('OlpPlainBase')
    assert(#plain == 1, 'a fix for a class of the workspace: ' .. #plain)
    local plainUri = furi.encode(rootPath .. '/plain.lua')
    local changes = assert(plain[1].edit).changes
    assert(changes[plainUri] and #changes[plainUri] == 1 and not changes[uri], 'the field is declared in the file of the class, not in the file with the typo')
    assert(#declareActions('OlpLibBase') == 0, 'no fix for a class of a library outside the workspace')
    assert(#declareActions('OlpOwnBase') == 0, 'no fix for a class of a folder the project lists as a library')
end)
