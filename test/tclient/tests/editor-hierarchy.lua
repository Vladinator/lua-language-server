-- The requests behind "Show Type Hierarchy", "Show Call Hierarchy" and linked editing, through the real protocol: the answers carry what the client needs to ask again (the item's `data`) and to place the result (ranges).
local lclient = require 'lclient'
local ws      = require 'workspace'
local furi    = require 'file-uri'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local await   = require 'await'

local DIR = fs.path(LOGPATH) / 'editor-hierarchy'
pcall((fs --[[@as any]]).remove_all, DIR)
fs.create_directories(DIR)
local nl = string.char(10)
local TEXT = table.concat({
    '---@class HProtoAnimal',
    'local Animal = {}',
    '',
    '---@class HProtoDog : HProtoAnimal',
    'local Dog = {}',
    '',
    'local count = 1',
    'local sum = count + 1',
    'print(count)',
    '',
    'local function helper()',
    'end',
    'local function caller()',
    '    helper()',
    '    helper()',
    'end',
    '',
}, nl)
util.saveFile((DIR / 'main.lua'):string(), TEXT)
local root = assert(furi.encode(DIR:string()))
local uri  = root .. '/main.lua'

---@type any
local prepared
---@type any
local supers
---@type any
local subs
---@type any
local callPrepared
---@type any
local callIncoming
---@type any
local callOutgoing
---@type any
local linked
---@type any
local notLinked

---@async
lclient():start(function (client)
    client:registerFakers()
    client:register('workspace/configuration', function ()
        return { { ['workspace.useGitIgnore'] = false } }
    end)
    client:initialize { rootUri = root }
    ws.awaitReady(root)
    client:notify('textDocument/didOpen', {
        textDocument = { uri = uri, languageId = 'lua', version = 1, text = TEXT },
    })
    await.sleep(0.5)
    -- the class name on line 4 (0-based 3), after `---@class HProtoDog : `
    prepared = client:awaitRequest('textDocument/prepareTypeHierarchy', {
        textDocument = { uri = uri }, position = { line = 3, character = 12 },
    })
    ---@type any
    local item = prepared and prepared[1]
    if item then
        supers = client:awaitRequest('typeHierarchy/supertypes', { item = item })
        subs   = client:awaitRequest('typeHierarchy/subtypes', { item = item })
    end
    -- `helper` is declared on line 11 (0-based 10), called twice by `caller`
    callPrepared = client:awaitRequest('textDocument/prepareCallHierarchy', {
        textDocument = { uri = uri }, position = { line = 10, character = 16 },
    })
    ---@type any
    local helperItem = callPrepared and callPrepared[1]
    if helperItem then
        callIncoming = client:awaitRequest('callHierarchy/incomingCalls', { item = helperItem })
    end
    local callerPrepared = client:awaitRequest('textDocument/prepareCallHierarchy', {
        textDocument = { uri = uri }, position = { line = 12, character = 16 },
    })
    ---@type any
    local callerItem = callerPrepared and callerPrepared[1]
    if callerItem then
        callOutgoing = client:awaitRequest('callHierarchy/outgoingCalls', { item = callerItem })
    end
    -- `count` declared on line 7, used on lines 8 and 9
    linked = client:awaitRequest('textDocument/linkedEditingRange', {
        textDocument = { uri = uri }, position = { line = 6, character = 7 },
    })
    -- nothing linked on a keyword
    notLinked = client:awaitRequest('textDocument/linkedEditingRange', {
        textDocument = { uri = uri }, position = { line = 6, character = 1 },
    })
end)

assert(prepared and prepared[1] and prepared[1].name == 'HProtoDog', 'prepare names the class under the cursor')
assert(prepared[1].kind == 5, 'a class')
assert(prepared[1].data and prepared[1].data.name == 'HProtoDog', 'the item carries what the next request needs')
assert(supers and #supers == 1 and supers[1].name == 'HProtoAnimal', 'supertypes')
assert(subs and #subs == 0, 'no subtypes of a leaf class')
assert(callPrepared and callPrepared[1] and callPrepared[1].name == 'helper' and callPrepared[1].kind == 12, 'a function item')
assert(callIncoming and #callIncoming == 1 and callIncoming[1].from.name == 'caller', 'helper is called by caller')
assert(#callIncoming[1].fromRanges == 2, 'twice, with the places of the calls')
assert(callIncoming[1].fromRanges[1].start.line == 13, 'the first call on its line')
assert(callOutgoing and #callOutgoing == 1 and callOutgoing[1].to.name == 'helper', 'caller calls helper')
assert(#callOutgoing[1].fromRanges == 2, 'the calls are in the file of the caller')
assert(linked and linked.ranges and #linked.ranges == 3, 'the declaration and both uses of `count`')
assert(notLinked == nil, 'a keyword has no linked ranges')

pcall((fs --[[@as any]]).remove_all, DIR)
