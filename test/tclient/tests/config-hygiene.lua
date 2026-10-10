-- Config hygiene (script/core/config-hygiene.lua): an entry of `Lua.diagnostics.globals` / `globalsRegex` in a project's settings file that
-- does nothing is reported (`unused-config-global`), with a quick fix that removes it; an entry that is needed is left alone.
local lclient = require 'lclient'
local ws      = require 'workspace'
local files   = require 'files'
local await   = require 'await'
local config  = require 'config'
local furi    = require 'file-uri'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local kinds   = require 'file-kinds'
local hygiene = require 'core.config-hygiene'

local DIR = fs.path(LOGPATH) / 'hygiene-ws'
local LIB = fs.path(LOGPATH) / 'hygiene-lib'
pcall((fs --[[@as any]]).remove_all, DIR)
pcall((fs --[[@as any]]).remove_all, LIB)
fs.create_directories(DIR)
fs.create_directories(LIB)
util.saveFile((LIB / 'lib.lua'):string(), 'print(OnlyLib)' .. string.char(10))
util.saveFile((LIB / 'meta.lua'):string(), '---@meta' .. string.char(10) .. 'metaThing = 1' .. string.char(10))
local rootUri = assert(furi.encode(DIR:string()))
local luaUri  = rootUri .. '/addon.lua'
local cfgUri  = rootUri .. '/.vscode/settings.json'

local LUA = table.concat({
    'Defined = 1',
    'lowerThing = 1',
    '---@class boundThing',
    'boundThing = {}',
    '---@deprecated',
    'OldThing = 1',
    'print(Needed, Defined, MyAddon_Thing)',
    '',
}, string.char(10))
util.saveFile((DIR / 'addon.lua'):string(), LUA)

local TEXT = table.concat({
    '{',
    '    "Lua.diagnostics.globals": [',
    '        "Defined",',
    '        "Unused",',
    '        "Needed"',
    '    ],',
    '    // a comment with "Quoted" text',
    '    "Lua.diagnostics.globalsRegex": ["^MyAddon", "^Nothing"]',
    '}',
}, '\n')

--- Apply LSP text edits (one line, ASCII) to a text.
---@param text  string
---@param edits table[]
---@return string
local function apply(text, edits)
    ---@type string[]
    local lines = {}
    for line in (text .. '\n'):gmatch('(.-)\n') do
        lines[#lines+1] = line
    end
    local function offsetOf(pos)
        local offset = 0
        for i = 1, pos.line do
            offset = offset + #lines[i] + 1
        end
        return offset + pos.character
    end
    table.sort(edits, function (a, b) return offsetOf(a.range.start) > offsetOf(b.range.start) end)
    for _, edit in ipairs(edits) do
        text = text:sub(1, offsetOf(edit.range.start)) .. edit.newText .. text:sub(offsetOf(edit['range']['end']) + 1)
    end
    return text
end

---@async
lclient():start(function (client)
    client:registerFakers()

    ---@type table<uri, any[]>
    local published = {}
    client:register('textDocument/publishDiagnostics', function (params)
        published[params.uri] = params.diagnostics
        return nil
    end)

    client:register('workspace/configuration', function ()
        return { { ['workspace.library'] = { LIB:string() } } }
    end)
    client:initialize { rootUri = rootUri }
    ws.awaitReady(rootUri)

    -- (the verdict depends on the checks that consult the list: pin them, an earlier group may have left them in another state)
    ---@param globalElement string
    local function pinChecks(globalElement)
        config.set(rootUri, 'Lua.diagnostics.disable', {})
        config.set(rootUri, 'Lua.diagnostics.groupFileStatus', {})
        config.set(rootUri, 'Lua.diagnostics.neededFileStatus', { ['global-element'] = globalElement, ['lowercase-global'] = 'Any' })
    end
    pinChecks('None')

    ---@async
    ---@param condition fun(): boolean
    ---@param what      string
    local function waitFor(condition, what)
        for _ = 1, 30 do
            if condition() then
                return
            end
            await.sleep(0.1)
        end
        error('timed out: ' .. what)
    end

    --- Open a settings text and return what the server published for it.
    ---@async
    ---@param uri  uri
    ---@param text string
    ---@return table[]
    local function open(uri, text)
        published[uri] = nil
        client:notify('textDocument/didOpen', { textDocument = { uri = uri, languageId = 'jsonc', version = 1, text = text } })
        waitFor(function () return published[uri] ~= nil end, 'diagnostics of ' .. uri)
        return published[uri]
    end

    ---@param diags table[]
    ---@return table<integer, string>
    local function byLine(diags)
        ---@type table<integer, string>
        local result = {}
        for _, diag in ipairs(diags) do
            assert(diag.code == hygiene.CODE and diag.severity == 2, 'a warning of the hygiene check')
            result[diag.range.start.line] = diag.message
        end
        return result
    end

    -- the Lua file that defines `Defined` and reads `Needed`, `Defined` and `MyAddon_Thing`
    client:notify('textDocument/didOpen', { textDocument = { uri = luaUri, languageId = 'lua', version = 1, text = assert(files.getText(luaUri) or util.loadFile((DIR / 'addon.lua'):string())) } })
    await.sleep(0.5)

    -- which settings files are ours
    assert(kinds.of(cfgUri) and kinds.of(rootUri .. '/.luarc.json') and kinds.of(rootUri .. '/.luarc.jsonc'), 'the project settings files')
    assert(not kinds.of(rootUri .. '/settings.json') and not kinds.of(rootUri .. '/other.json'), 'other json files are not')

    -- defined / unused / needed, and the same for the patterns; a comment and a quoted word in it are no entries
    local diags = open(cfgUri, TEXT)
    local found = byLine(diags)
    assert(found[2] and found[2]:find('`Defined` is defined', 1, true), 'a defined global: ' .. tostring(found[2]))
    assert(found[3] and found[3]:find('Nothing in the workspace uses `Unused`', 1, true), 'a global nothing uses: ' .. tostring(found[3]))
    assert(found[4] == nil, 'a global that is read and not defined is needed')
    assert(found[7] and found[7]:find('`^Nothing`', 1, true), 'a pattern nothing matches: ' .. tostring(found[7]))
    local count = 0
    for _ in pairs(found) do count = count + 1 end
    assert(count == 3, 'three entries, not more: ' .. count)
    for _, diag in ipairs(diags) do
        if diag.message:find('`^MyAddon`', 1, true) then
            error('the pattern `^MyAddon` matches a used undefined global: it is needed')
        end
    end

    -- the quick fix removes exactly the entry
    ---@async
    ---@param text string
    ---@param diag table
    ---@return string text
    ---@return string title
    local function fixOf(text, diag)
        ---@type table[]?
        local actions = client:awaitRequest('textDocument/codeAction', {
            textDocument = { uri = cfgUri }, range = (diag --[[@as table<string, any>]]).range,
            context = { diagnostics = { diag } },
        })
        -- the one way to silence the warning in a JSON file is the setting of the workspace (no comment can hold a line or file switch)
        assert(actions and #actions == 2, 'two quick fixes: ' .. tostring(actions and #actions))
        local disable = actions[1]
        assert(disable.command and disable.command.command == 'lua.setConfig' and disable.data == 'disable', 'the workspace switch first')
        local argument = (disable.command.arguments --[[@as table[] ]])[1]
        assert(argument.key == 'Lua.diagnostics.disable' and argument.action == 'add' and argument.value == hygiene.CODE, 'adds the code to the disable list')
        assert(not disable.title:find('line', 1, true) and not disable.title:find('file', 1, true), 'not a line or file switch')
        assert(actions[2].edit, 'the removal second')
        return apply(text, actions[2].edit.changes[cfgUri]), actions[2].title
    end
    ---@type table?
    local middle
    for _, diag in ipairs(diags) do
        if diag.range.start.line == 3 then
            middle = diag
        end
    end
    local fixed, title = fixOf(TEXT, assert(middle))
    assert(title == 'Remove `Unused` from the list', title)
    assert(fixed == TEXT:gsub('        "Unused",\n', ''), 'a middle entry goes with its comma:\n' .. fixed)

    -- last entry (the comma before it goes), only entry (an empty list stays)
    local LAST = '{ "Lua.diagnostics.globals": ["Needed", "Gone"] }'
    local lastDiags = open(cfgUri, LAST)
    assert(#lastDiags == 1, 'one stale entry: ' .. #lastDiags)
    assert(fixOf(LAST, lastDiags[1]) == '{ "Lua.diagnostics.globals": ["Needed"] }', 'the last entry goes with the comma before it')
    local ONLY = '{ "Lua.diagnostics.globals": ["Gone"] }'
    local onlyDiags = open(cfgUri, ONLY)
    assert(fixOf(ONLY, onlyDiags[1]) == '{ "Lua.diagnostics.globals": [] }', 'the only entry leaves an empty list')

    -- a pattern that only matches a global the workspace defines is not needed either (and one that matches a used undefined one is)
    local patterns = open(cfgUri, '{ "Lua.diagnostics.globalsRegex": ["^Defin", "^Need"] }')
    assert(#patterns == 1 and patterns[1].message:find('`^Defin`', 1, true), 'a pattern of defined globals only')

    -- a defined global can still be needed: `lowercase-global` skips the names of the list (and so does `deprecated`); a class and a global of a meta file are skipped anyway
    local defined = open(cfgUri, '{ "Lua.diagnostics.globals": ["lowerThing", "boundThing", "OldThing", "Defined", "metaThing"] }')
    ---@type string[]
    local definedNames = {}
    for _, diag in ipairs(defined) do
        definedNames[#definedNames+1] = diag.message:match('`(%w+)`')
    end
    table.sort(definedNames)
    assert(table.concat(definedNames, ',') == 'Defined,boundThing,metaThing', 'only the defined ones that nothing needs: ' .. table.concat(definedNames, ','))

    -- with `global-element` on, every defined global is flagged without its entry: the entry is needed
    pinChecks('Any')
    local flagged = open(cfgUri, '{ "Lua.diagnostics.globals": ["Defined", "boundThing", "metaThing"] }')
    ---@type string[]
    local flaggedNames = {}
    for _, diag in ipairs(flagged) do
        flaggedNames[#flaggedNames+1] = diag.message:match('`(%w+)`')
    end
    table.sort(flaggedNames)
    assert(table.concat(flaggedNames, ',') == 'boundThing,metaThing', 'global-element needs the entry of Defined: ' .. table.concat(flaggedNames, ','))
    pinChecks('None')

    -- a broken pattern is not reported as unused
    assert(#open(cfgUri, '{ "Lua.diagnostics.globalsRegex": ["["] }') == 0, 'a broken pattern')

    -- a global that only a library reads is not used by the project
    local libDiags = open(cfgUri, '{ "Lua.diagnostics.globals": ["OnlyLib", "Needed"] }')
    assert(#libDiags == 1 and libDiags[1].message:find('`OnlyLib`', 1, true), 'read by a library only')

    assert(#open(cfgUri, '{ "Lua.diagnostics.globalsRegex": ["^OnlyLi"] }') == 1, 'a pattern of globals that only a library reads')

    -- the verdict follows the code: a global gets a user, then loses it again
    open(cfgUri, '{ "Lua.diagnostics.globals": ["Late"] }')
    assert(#published[cfgUri] == 1, 'nothing uses it yet')
    client:notify('textDocument/didChange', {
        textDocument   = { uri = luaUri, version = 2 },
        contentChanges = { { text = (LUA:gsub('MyAddon_Thing%)', 'MyAddon_Thing, Late)')) } },
    })
    waitFor(function () return #published[cfgUri] == 0 end, 'a new user of the global')
    client:notify('textDocument/didChange', {
        textDocument   = { uri = luaUri, version = 3 },
        contentChanges = { { text = LUA } },
    })
    waitFor(function () return #published[cfgUri] == 1 end, 'the user is gone again')

    -- the `.luarc.json` spellings find the same entries
    for _, text in ipairs {
        '{ "diagnostics.globals": ["Gone"] }',
        '{ "diagnostics": { "globals": ["Gone"] } }',
        '{ "Lua": { "diagnostics": { "globals": ["Gone"] } } }',
    } do
        assert(#open(rootUri .. '/.luarc.json', text) == 1, 'a spelling of the setting: ' .. text)
    end
    -- other lists and other values are not entries
    assert(#open(cfgUri, '{ "Lua.diagnostics.disable": ["Gone"], "Lua.workspace.library": ["Gone"], "Lua.runtime.special": { "Gone": "require" } }') == 0,
        'only the lists of globals')

    -- a settings file that is in no folder of the workspace says nothing about it (the settings of the user)
    local outside = 'file:///somewhere-else/project/.vscode/settings.json'
    assert(#open(outside, '{ "Lua.diagnostics.globals": ["Gone"] }') == 0, 'outside the workspace')

    -- the disable list and the severity apply like for any diagnostic
    config.set(cfgUri, 'Lua.diagnostics.disable', { hygiene.CODE })
    waitFor(function () return #(published[cfgUri] or {}) == 0 end, 'disabled')
    config.set(cfgUri, 'Lua.diagnostics.disable', {})
    open(cfgUri, LAST)

    client:notify('textDocument/didClose', { textDocument = { uri = cfgUri } })
    client:notify('textDocument/didClose', { textDocument = { uri = luaUri } })
    pcall((fs --[[@as any]]).remove_all, DIR)
    pcall((fs --[[@as any]]).remove_all, LIB)
end)
