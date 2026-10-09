-- Two generic registries, tested with fake names only (no plugin): a `late` genesis rule runs after every ordinary rule of the type whatever
-- the registration order was, and `vm.createTaggedIndex` finds the callees that carry a tag (by name first, then through the definitions).
local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'
require 'docfixture'

---@diagnostic disable: await-in-sync

-- late genesis rules ------------------------------------------------------------------------------------------------------------------

local FLAG = 'zz-late-test-flag'
vm.registerPropagatingFlag(FLAG)

--- Registered BEFORE the ordinary rule below: a late rule must still run after it.
vm.registerGenesisRule('local', function (source, node)
    if type(source[1]) == 'string' and source[1]:find('^zzLateCleared') then
        node:clearFlag(FLAG)
    end
end, true)
vm.registerGenesisRule('local', function (source, node)
    if type(source[1]) == 'string' and source[1]:find('^zzLate') then
        node:setFlag(FLAG)
    end
end)

---@param name string
---@return boolean
local function flagged(name)
    local state = assert(files.getState(TESTURI))
    ---@type boolean?
    local result
    guide.eachSourceType(state.ast, 'local', function (source)
        if source[1] == name then
            result = vm.compileNode(source):hasFlag(FLAG)
        end
    end)
    assert(result ~= nil, name .. ': not found')
    return result
end

files.setText(TESTURI, 'local zzLateKept = 1' .. string.char(10) .. 'local zzLateCleared = 1' .. string.char(10) .. 'local zzOther = 1' .. string.char(10))
assert(flagged('zzLateKept'), 'an ordinary rule sets the flag')
assert(not flagged('zzLateCleared'), 'a late rule runs after it, although registered before')
assert(not flagged('zzOther'), 'nothing else is flagged')
files.remove(TESTURI)

-- the tagged index ------------------------------------------------------------------------------------------------------------------

local index = vm.createTaggedIndex('zz-test-index', function (doc)
    return doc.type == 'doc.fixture-names'
end)

---@param script string
---@return parser.object[] calls
local function callsOf(script)
    files.setText(TESTURI, script)
    local state = assert(files.getState(TESTURI))
    ---@type parser.object[]
    local calls = {}
    guide.eachSourceType(state.ast, 'call', function (call)
        calls[#calls+1] = call
    end)
    table.sort(calls, function (a, b) return a.start < b.start end)
    return calls
end

local nl = string.char(10)
local calls = callsOf(table.concat({
    '---@fixture-names a',
    'local function zzTagged() end',
    'local function zzPlain() end',
    'local M = {}',
    '---@fixture-names b',
    'function M.zzTaggedField() end',
    '---@fixture-names c',
    'function M:zzTaggedMethod() end',
    'zzTagged()',
    'zzPlain()',
    'M.zzTaggedField()',
    'M:zzTaggedMethod()',
    'M.zzPlain()',
}, nl) .. nl)
assert(#calls == 5, 'five calls')
assert(index.match(calls[1].node), 'a tagged local function')
assert(not index.match(calls[2].node), 'a plain one')
assert(index.match(calls[3].node), 'a tagged field function')
assert(index.match(calls[4].node), 'a tagged method')
assert(not index.match(calls[5].node), 'a field that is not tagged')

local found = index.docsOf(calls[1].node)
assert(#found == 1 and found[1].doc.type == 'doc.fixture-names' and found[1].func.type == 'function', 'the tag and its function')
assert(#index.docsOf(calls[2].node) == 0, 'no tag on a plain function')
assert(#index.docsOf(calls[4].node) == 1, 'the tag of a method')

-- a change of the text changes the answer
calls = callsOf('local function zzTagged() end' .. nl .. 'zzTagged()' .. nl)
assert(not index.match(calls[1].node), 'the tag is gone with the text')
files.remove(TESTURI)
