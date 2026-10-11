-- `excess-field` and the classes of an API stub: a class declared in a library file (the annotations of the game API) is not checked,
-- the same class in the project is. Needs a real workspace with a library folder, so it is a client test.
local lclient = require 'lclient'
local ws      = require 'workspace'
local files   = require 'files'
local furi    = require 'file-uri'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local core    = require 'core.diagnostics'

local DIR = fs.path(LOGPATH) / 'excess-field-ws'
local LIB = fs.path(LOGPATH) / 'excess-field-lib'
pcall((fs --[[@as any]]).remove_all, DIR)
pcall((fs --[[@as any]]).remove_all, LIB)
fs.create_directories(DIR)
fs.create_directories(LIB)
local nl = string.char(10)
util.saveFile((LIB / 'stub.lua'):string(), table.concat({
    '---@meta',
    '---@class StubLine',
    '---@field label string',
    '',
}, nl))
util.saveFile((DIR / 'own.lua'):string(), table.concat({
    '---@class OwnLine',
    '---@field label string',
    'local OwnLine = {}',
    '',
    '---@type OwnLine',
    'local fromProject = { label = "a", extra = true }',
    '',
    '---@type StubLine',
    'local fromStub = { label = "a", extra = true }',
    '',
}, nl))
local root = assert(furi.encode(DIR:string()))
local uri  = root .. '/own.lua'

---@type string[]
local reported = {}

---@async
lclient():start(function (client)
    client:registerFakers()
    client:register('workspace/configuration', function ()
        return { { ['workspace.library'] = { LIB:string() }, ['workspace.useGitIgnore'] = false } }
    end)
    client:initialize { rootUri = root }
    ws.awaitReady(root)
    files.open(uri)
    core(uri, false, function (result)
        if result.code == 'excess-field' then
            reported[#reported+1] = result.message
        end
    end)
end)

assert(#reported == 1, 'one finding, the class of the project: ' .. table.concat(reported, ' | '))
assert(reported[1]:find('OwnLine', 1, true), 'a class of the project is checked: ' .. reported[1])

pcall((fs --[[@as any]]).remove_all, DIR)
pcall((fs --[[@as any]]).remove_all, LIB)
