-- the arguments of a WoW addon file (`local addonName, ns = ...`): typed only with the setting on and a `.toc`
local config = require 'config'
local files  = require 'files'
local fs     = require 'bee.filesystem'
local guide  = require 'parser.guide'
local vm     = require 'vm'

---@diagnostic disable: await-in-sync

---@param script string
---@return table<string, string>  local name -> its type as shown
local function typesOf(script)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    local state = assert(files.getState(TESTURI))
    ---@type table<string, string>
    local result = {}
    guide.eachSourceType(state.ast, 'local', function (source)
        local name = source[1]
        if type(name) == 'string' then
            result[name] = vm.getInfer(source):view(TESTURI)
        end
    end)
    files.remove(TESTURI)
    return result
end

local tocPath = TESTROOT .. 'unittest.toc'
local createdDir = not fs.exists(fs.path(TESTROOT))
if createdDir then
    fs.create_directories(fs.path(TESTROOT))
end
local file = assert(io.open(tocPath, 'wb'))
file:write('## Title: Test\nunittest.lua\n')
file:close()

local script = 'local addonName, ns, third = ...\nlocal function f(...)\n    local inner = ...\n    return inner\nend\nreturn addonName, ns, third, f\n'
local ok, err = pcall(function ()
    -- off (the default): unknown, as for any file
    config.set(nil, 'Lua.workspace.tocFileArguments', false)
    local off = typesOf(script)
    assert(off.addonName == 'unknown' and off.ns == 'unknown', 'off: ' .. tostring(off.addonName) .. ' ' .. tostring(off.ns))
    -- on, with a .toc (one that declares no saved variables is still the addon's .toc)
    config.set(nil, 'Lua.workspace.tocFileArguments', true)
    require 'core.diagnostics.extra.wow-toc'.clearCache()
    local on = typesOf(script)
    assert(on.addonName == 'string', 'first argument: ' .. tostring(on.addonName))
    assert(on.ns == 'table', 'second argument: ' .. tostring(on.ns))
    assert(on.third == 'unknown', 'a third one is not typed: ' .. tostring(on.third))
    assert(on.inner == 'unknown', 'the `...` of a function is not the file argument: ' .. tostring(on.inner))
    -- `select(2, ...)`, the other usual way to take the second one
    local selected = typesOf('local ns = select(2, ...)\nreturn ns\n')
    assert(selected.ns == 'table', 'select(2, ...): ' .. tostring(selected.ns))
    local first = typesOf('local name = select(1, ...)\nreturn name\n')
    assert(first.name == 'string', 'select(1, ...): ' .. tostring(first.name))
    -- no .toc: nothing
    os.remove(tocPath)
    require 'core.diagnostics.extra.wow-toc'.clearCache()
    local gone = typesOf(script)
    assert(gone.addonName == 'unknown' and gone.ns == 'unknown', 'no .toc: ' .. tostring(gone.addonName))
end)
config.set(nil, 'Lua.workspace.tocFileArguments', false)
os.remove(tocPath)
if createdDir then
    fs.remove(fs.path(TESTROOT))
end
require 'core.diagnostics.extra.wow-toc'.clearCache()
assert(ok, err)
