-- File kinds (script/file-kinds.lua): a document that is not Lua is kept apart, never parsed as Lua, and a registered kind answers its
-- diagnostics, completion, hover and definition. Tested with a fake kind for `.zzkind` files, so the test passes without any plugin.
local lclient = require 'lclient'
local ws      = require 'workspace'
local files   = require 'files'
local await   = require 'await'
local config  = require 'config'
local define  = require 'proto.define'
local diagd   = require 'proto.diagnostic'
local kinds   = require 'file-kinds'

local CODE = 'zz-kind-bad'

-- the diagnostic of the fake kind: registered like a plugin would, removed again at the end (a fake name left behind would be a
-- diagnostic nobody can run for the rest of the suite)
diagd.register { CODE } {
    group       = 'zz-kind',
    severity    = 'Warning',
    status      = 'Any',
    fileKind    = 'zzkind',
    description = 'test only',
}

---@type fileKind
local kind = {
    id    = 'zzkind',
    match = function (uri) return uri:sub(-7) == '.zzkind' end,
    triggerCharacters = { '~' },
    diagnose = function (_uri, text)
        ---@type fileKind.diagnostic[]
        local found = {}
        local row = 0
        for line in (text .. '\n'):gmatch('(.-)\r?\n') do
            local first, last = line:find('BAD', 1, true)
            if first and last then
                found[#found+1] = {
                    code    = CODE,
                    message = 'a BAD word',
                    range   = {
                        start = { line = row, character = kinds.toCharacter(line, first - 1) },
                        ['end'] = { line = row, character = kinds.toCharacter(line, last) },
                    },
                }
            end
            row = row + 1
        end
        return found
    end,
    complete = function (_uri, text, position)
        return { { label = 'zz-choice-' .. position.line .. '-' .. position.character, kind = 1 } }
    end,
    hover = function (_uri, text, position)
        return { value = 'fake hover at ' .. position.line .. ':' .. position.character }
    end,
    definition = function (uri, _text, position)
        return { { uri = uri, range = { start = position, ['end'] = position } } }
    end,
    codeAction = function (uri, _text, range, diagnostics)
        return { {
            title = 'zz fix ' .. #diagnostics,
            kind  = 'quickfix',
            edit  = { changes = { [uri] = { { range = range, newText = 'GOOD' } } } },
        } }
    end,
}
kinds.register(kind)

-- a kind whose verdict is about the whole workspace (`needsWorkspace`): it is prepared before every verdict, and nothing is
-- published before that ended
local PREP_CODE = 'zz-prep-note'
diagd.register { PREP_CODE } {
    group       = 'zz-kind',
    severity    = 'Hint',
    status      = 'Any',
    fileKind    = 'zzprep',
    description = 'test only',
}
local prepared = 0
---@type string[]
local order = {}
kinds.register {
    id             = 'zzprep',
    needsWorkspace = true,
    match          = function (u) return u:sub(-7) == '.zzprep' end,
    prepare        = function (_u, _text)
        prepared = prepared + 1
        order[#order+1] = 'prepare'
    end,
    diagnose       = function (_u, _text)
        order[#order+1] = 'diagnose'
        return { {
            code    = PREP_CODE,
            message = 'prepared ' .. prepared,
            range   = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } },
        } }
    end,
}

local uri = 'file:///kinds/test.zzkind'
local prepUri = 'file:///kinds/test.zzprep'

---@async
lclient():start(function (client)
    client:registerFakers()

    ---@type { uri: string, version: integer?, diagnostics: any[] }[]
    local published = {}
    ---@type { uri: string, version: integer?, diagnostics: any[] }[]
    local prepPublished = {}
    client:register('textDocument/publishDiagnostics', function (params)
        if params.uri == uri then
            published[#published+1] = params
        end
        if params.uri == prepUri then
            prepPublished[#prepPublished+1] = params
        end
        return nil
    end)

    client:initialize()
    ws.awaitReady()

    ---@return { uri: string, version: integer?, diagnostics: any[] }?
    local function last()
        return published[#published]
    end

    --- (a change of a setting reaches the watchers on a later tick)
    ---@async
    ---@param condition fun(): boolean
    ---@param what      string
    local function waitFor(condition, what)
        for _ = 1, 20 do
            if condition() then
                return
            end
            await.sleep(0.1)
        end
        error('timed out: ' .. what)
    end

    client:notify('textDocument/didOpen', {
        textDocument = { uri = uri, languageId = 'zzkind', version = 1, text = 'fine\nthis is BAD\n' },
    })
    await.sleep(0.2)
    local diags = assert(last()).diagnostics
    assert(#diags == 1, 'one diagnostic: ' .. #diags)
    assert(diags[1].code == CODE and diags[1].range.start.line == 1 and diags[1].range.start.character == 8, 'its place')
    assert(diags[1].severity == define.DiagnosticSeverity.Warning, 'the severity of the registration')
    assert(last().version == 1, 'the version')

    -- needsWorkspace + prepare: the preparation runs before the verdict, and the verdict is only sent after it
    client:notify('textDocument/didOpen', {
        textDocument = { uri = prepUri, languageId = 'zzprep', version = 1, text = 'x' },
    })
    waitFor(function () return #prepPublished >= 1 end, 'the prepared document')
    assert(prepared >= 1 and order[1] == 'prepare' and order[2] == 'diagnose', 'prepare, then diagnose: ' .. table.concat(order, ','))
    assert(prepPublished[1].diagnostics[1].message == 'prepared 1', 'the verdict knows the preparation ended: ' .. prepPublished[1].diagnostics[1].message)
    -- every new text is prepared again (the picture of the workspace may have changed since)
    client:notify('textDocument/didChange', {
        textDocument = { uri = prepUri, version = 2 }, contentChanges = { { text = 'y' } },
    })
    waitFor(function () return prepared >= 2 and #prepPublished >= 2 end, 'prepared again')
    assert(prepPublished[#prepPublished].diagnostics[1].message == 'prepared ' .. prepared, 'the latest verdict follows the latest preparation')
    client:notify('textDocument/didClose', { textDocument = { uri = prepUri } })

    -- the Lua pipeline does not run the diagnostic of a kind
    for _, name in ipairs(diagd.getRunOrder()) do
        assert(name ~= CODE, 'the diagnostic of a file kind is not in the run order of the Lua files')
    end

    -- the text is NOT a Lua file: nothing in `files`, nothing parsed
    assert(not files.exists(uri) and not files.getText(uri), 'never stored as a Lua file')
    assert(kinds.isOpen(uri), 'kept by the kind')

    -- completion, hover and definition ask the kind
    local items = client:awaitRequest('textDocument/completion', { textDocument = { uri = uri }, position = { line = 1, character = 3 } })
    assert(items and items[1].label == 'zz-choice-1-3', 'completion')
    local hover = client:awaitRequest('textDocument/hover', { textDocument = { uri = uri }, position = { line = 0, character = 2 } })
    assert(hover and hover.contents.value == 'fake hover at 0:2', 'hover')
    local defs = client:awaitRequest('textDocument/definition', { textDocument = { uri = uri }, position = { line = 1, character = 5 } })
    assert(defs and defs[1].uri == uri and defs[1].range.start.character == 5, 'definition')

    -- code actions ask the kind, with the range and the diagnostics the client sent
    local range = { start = { line = 1, character = 8 }, ['end'] = { line = 1, character = 11 } }
    local actions = client:awaitRequest('textDocument/codeAction', {
        textDocument = { uri = uri }, range = range,
        context = { diagnostics = { { range = range, message = 'x', code = CODE } } },
    })
    assert(actions and actions[1].title == 'zz fix 1' and actions[1].edit.changes[uri][1].newText == 'GOOD', 'code action')

    -- an incremental change is merged and the diagnostics are sent again
    client:notify('textDocument/didChange', {
        textDocument   = { uri = uri, version = 2 },
        contentChanges = { { range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 4 } }, text = 'BAD' } },
    })
    await.sleep(0.2)
    diags = assert(last()).diagnostics
    assert(#diags == 2 and last().version == 2, 'the changed text has two')
    assert(kinds.getText(uri) == 'BAD\nthis is BAD\n', 'the merged text: ' .. tostring(kinds.getText(uri)))
    assert(not files.exists(uri), 'a change does not turn the document into a Lua file either')

    -- a setting that the client sends for the first time (its configuration arrives after the document was opened) applies too
    config.update(ws.getFirstScope(), { Lua = { diagnostics = { disable = { CODE } } } })
    waitFor(function () return #assert(last()).diagnostics == 0 end, 'disabled by the first configuration of the client')
    config.update(ws.getFirstScope(), {})
    waitFor(function () return #assert(last()).diagnostics == 2 end, 'enabled again by the next configuration')

    -- the diagnostic settings apply: disabled, another severity
    config.set(uri, 'Lua.diagnostics.disable', { CODE })
    waitFor(function () return #assert(last()).diagnostics == 0 end, 'disabled by Lua.diagnostics.disable')
    config.set(uri, 'Lua.diagnostics.disable', {})
    config.set(uri, 'Lua.diagnostics.severity', { [CODE] = 'Error' })
    waitFor(function ()
        local now = assert(last()).diagnostics
        return #now == 2 and now[1].severity == define.DiagnosticSeverity.Error
    end, 'the severity setting')
    config.set(uri, 'Lua.diagnostics.severity', {})

    -- columns are characters in the encoding of the client, not bytes: `é` is two bytes and one character
    client:notify('textDocument/didChange', {
        textDocument   = { uri = uri, version = 3 },
        contentChanges = { { text = 'é BAD' .. string.char(10) } },
    })
    waitFor(function () return last().version == 3 end, 'the full text change')
    diags = assert(last()).diagnostics
    assert(#diags == 1 and diags[1].range.start.character == 2 and diags[1].range['end'].character == 5,
        'characters, not bytes: ' .. tostring(diags[1] and diags[1].range.start.character))
    config.set(uri, 'Lua.diagnostics.disable', {})

    -- the trigger characters of the kind open completion
    assert(kinds.getTriggerCharacters()[1] == '~', 'trigger characters')

    -- closing clears them
    client:notify('textDocument/didClose', { textDocument = { uri = uri } })
    await.sleep(0.2)
    assert(#assert(last()).diagnostics == 0 and not kinds.isOpen(uri), 'closed')
    assert(not files.exists(uri), 'closing does not leave a Lua file behind')

    -- a Lua file next to it is untouched by all this
    local luaUri = 'file:///kinds/test.lua'
    client:notify('textDocument/didOpen', {
        textDocument = { uri = luaUri, languageId = 'lua', version = 1, text = 'local BAD = 1\nprint(BAD)\n' },
    })
    await.sleep(0.2)
    assert(files.exists(luaUri) and not kinds.isOpen(luaUri), 'a Lua file is still a Lua file')
    client:notify('textDocument/didClose', { textDocument = { uri = luaUri } })

    -- (the fake diagnostic goes again)
    diagd.diagnosticDatas[PREP_CODE] = nil
    define.DiagnosticDefaultSeverity[PREP_CODE] = nil
    define.DiagnosticDefaultNeededFileStatus[PREP_CODE] = nil
    diagd.diagnosticDatas[CODE] = nil
    diagd.diagnosticGroups['zz-kind'] = nil
    define.DiagnosticDefaultSeverity[CODE] = nil
    define.DiagnosticDefaultNeededFileStatus[CODE] = nil
end)
