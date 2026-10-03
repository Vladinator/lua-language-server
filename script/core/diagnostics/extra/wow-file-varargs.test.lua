-- the arguments of a WoW addon file (`local addonName, ns = ...`): typed only with the setting on and a `.toc`; the
-- first is the folder name as a string literal, the second the class `<Folder>NS` that accepts new keys
local config = require 'config'
local files  = require 'files'
local fs     = require 'bee.filesystem'
local guide  = require 'parser.guide'
local vm     = require 'vm'
local core   = require 'core.diagnostics'
local converter = require 'proto.converter'

---@diagnostic disable: await-in-sync

--- The type of each local of `script` as shown, and the codes the diagnostics report for it.
---@param script string
---@return table<string, string> types
---@return string[] codes
local function analyse(script)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    files.open(TESTURI)
    local state = assert(files.getState(TESTURI))
    ---@type table<string, string>
    local types = {}
    guide.eachSourceType(state.ast, 'local', function (source)
        local name = source[1]
        if type(name) == 'string' then
            types[name] = vm.getInfer(source):view(TESTURI)
        end
    end)
    ---@type string[]
    local codes = {}
    core(TESTURI, false, function (result)
        if result.code == 'inject-field' or result.code == 'undefined-field' then
            codes[#codes+1] = result.code
        end
    end)
    files.remove(TESTURI)
    table.sort(codes)
    return types, codes
end

---@type {clearCache: fun()}
local toc = require 'core.diagnostics.extra.wow-toc'

-- the folder of the test project is `test_root`: the addon's name, and the class `test_rootNS`
local tocPath = TESTROOT .. 'unittest.toc'
local createdDir = not fs.exists(fs.path(TESTROOT))
if createdDir then
    fs.create_directories(fs.path(TESTROOT))
end
local file = assert(io.open(tocPath, 'wb'))
file:write('## Title: Test\nunittest.lua\n')
file:close()

local script = 'local addonName, ns = ...\nns.Foo = 1\nlocal function f(...)\n    local inner = ...\n    return inner\nend\nreturn addonName, ns, f\n'
local ok, err = pcall(function ()
    -- off (the default): unknown, as for any file, and nothing is added to the text
    config.set(nil, 'Lua.workspace.tocFileArguments', false)
    local off = analyse(script)
    assert(off.addonName == 'unknown' and off.ns == 'unknown', 'off: ' .. tostring(off.addonName) .. ' ' .. tostring(off.ns))

    -- on, with a .toc (one that declares no saved variables is still the addon's .toc)
    config.set(nil, 'Lua.workspace.tocFileArguments', true)
    toc.clearCache()
    local on, codes = analyse(script)
    assert(on.addonName == '"test_root"', 'the folder name as a literal: ' .. tostring(on.addonName))
    assert(on.ns == 'test_rootNS', 'a class named after the folder: ' .. tostring(on.ns))
    assert(#codes == 0, 'a key written to the namespace is no injection and no undefined field: ' .. table.concat(codes, ' '))
    assert(on.inner == 'unknown', 'the `...` of a function is not the file argument: ' .. tostring(on.inner))

    -- the class name is a template
    config.set(nil, 'Lua.workspace.tocNamespaceClass', '{addon}.ns')
    local dotted = analyse('local ns = select(2, ...)\nreturn ns\n')
    config.set(nil, 'Lua.workspace.tocNamespaceClass', 'Shared{addon}_ns')
    local custom = analyse('local addonName, ns = ...\nreturn ns\n')
    config.set(nil, 'Lua.workspace.tocNamespaceClass', '{addon}NS')
    assert(dotted.ns == 'test_root.ns', 'a dotted template: ' .. tostring(dotted.ns))
    assert(custom.ns == 'Sharedtest_root_ns', 'a template with a prefix: ' .. tostring(custom.ns))
    -- the line that is written into the declaration does not move what follows: a diagnostic in the next line
    -- is reported there, in the text the user sees
    files.remove(TESTURI)
    files.setText(TESTURI, 'local addonName, ns = ...\nprint(notDefinedAnywhere)\n')
    files.open(TESTURI)
    local mapped = assert(files.getState(TESTURI))
    ---@type table?
    local range
    core(TESTURI, false, function (result)
        if result.code == 'undefined-global' then
            range = converter.packRange(mapped, result.start, result.finish)
        end
    end)
    files.remove(TESTURI)
    assert(range and range.start.line == 1 and range.start.character == 6,
        'the original line of the next statement: ' .. (range and (range.start.line .. ':' .. range.start.character) or 'none'))
    -- `select(2, ...)`: the same class, no rewrite needed
    local selected, selectedCodes = analyse('local ns = select(2, ...)\nns.Bar = 1\nreturn ns\n')
    assert(selected.ns == 'test_rootNS' and #selectedCodes == 0, 'select(2, ...): ' .. tostring(selected.ns))
    local first = analyse('local name = select(1, ...)\nreturn name\n')
    assert(first.name == '"test_root"', 'select(1, ...): ' .. tostring(first.name))

    -- a third value is not typed; three names are not the usual declaration (no class is written for them)
    local three = analyse('local a, b, c = ...\nreturn a, b, c\n')
    assert(three.a == '"test_root"' and three.b == 'table' and three.c == 'unknown',
        'three names: ' .. tostring(three.a) .. ' ' .. tostring(three.b) .. ' ' .. tostring(three.c))

    -- the user's own annotation wins, and nothing is added to the line
    local own, ownCodes = analyse('local ns = select(2, ...) ---@class MyOwnNS\nns.Baz = 1\nreturn ns\n')
    assert(own.ns == 'MyOwnNS' and #ownCodes == 0, 'own class: ' .. tostring(own.ns))
    local typed = analyse('---@type table\nlocal ns = select(2, ...)\nreturn ns\n')
    assert(typed.ns == 'table', 'own type above the line: ' .. tostring(typed.ns))

    -- only the top level of the file: a declaration inside a block is left as it is
    local nested = analyse('do\n    local addonName, ns = ...\n    return addonName, ns\nend\n')
    assert(nested.ns == 'table', 'indented: ' .. tostring(nested.ns))

    -- no .toc: nothing
    os.remove(tocPath)
    toc.clearCache()
    local gone = analyse(script)
    assert(gone.addonName == 'unknown' and gone.ns == 'unknown', 'no .toc: ' .. tostring(gone.addonName))
end)
config.set(nil, 'Lua.workspace.tocFileArguments', false)
config.set(nil, 'Lua.workspace.tocNamespaceClass', '{addon}NS')
os.remove(tocPath)
if createdDir then
    fs.remove(fs.path(TESTROOT))
end
toc.clearCache()
assert(ok, err)
