-- Which opened files get diagnostics: `Lua.diagnostics.ignoredFiles` (a file that `Lua.workspace.ignoreDir` skips, opened in the editor) and
-- `Lua.diagnostics.enableScheme` (the URI schemes that are diagnosed). Each case is a client of its own, the settings are read as it starts.
local lclient = require 'lclient'
local ws      = require 'workspace'
local furi    = require 'file-uri'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local await   = require 'await'

local DIR = fs.path(LOGPATH) / 'settings-diag-scope'
pcall((fs --[[@as any]]).remove_all, DIR)
fs.create_directories(DIR / 'ignored')
local nl = string.char(10)
local TEXT = 'print(UndefinedName)' .. nl
util.saveFile((DIR / 'normal.lua'):string(), TEXT)
util.saveFile((DIR / 'ignored' / 'skipped.lua'):string(), TEXT)
local root = assert(furi.encode(DIR:string()))

local NORMAL   = root .. '/normal.lua'
local IGNORED  = root .. '/ignored/skipped.lua'
local UNTITLED = 'untitled:Untitled-1'

--- Start a client with these settings, open the three files and say how many `undefined-global` each was published with.
---@param settings table
---@return table<string, integer>
local function diagnosed(settings)
    ---@type table<string, integer>
    local counts = {}
    ---@async
    lclient():start(function (client)
        client:registerFakers()
        client:register('workspace/configuration', function ()
            return { settings }
        end)
        ---@param params { uri: string, diagnostics: { code: string? }[] }
        client:register('textDocument/publishDiagnostics', function (params)
            local n = 0
            for _, diag in ipairs(params.diagnostics) do
                if diag.code == 'undefined-global' then
                    n = n + 1
                end
            end
            counts[params.uri] = n
            return nil
        end)
        client:initialize { rootUri = root }
        ws.awaitReady(root)
        for _, uri in ipairs { NORMAL, IGNORED, UNTITLED } do
            client:notify('textDocument/didOpen', {
                textDocument = { uri = uri, languageId = 'lua', version = 1, text = TEXT },
            })
        end
        await.sleep(1)
        -- what was published before the settings reached the server does not count: edit every document and look at what follows
        for uri in pairs(counts) do
            counts[uri] = nil
        end
        for _, uri in ipairs { NORMAL, IGNORED, UNTITLED } do
            client:notify('textDocument/didChange', {
                textDocument = { uri = uri, version = 2 },
                contentChanges = { { text = TEXT .. 'print(AnotherUndefined)' .. string.char(10) } },
            })
        end
        await.sleep(1)
    end)
    return counts
end

local BASE = { ['workspace.useGitIgnore'] = false, ['workspace.ignoreDir'] = { '/ignored' } }

---@param extra table<string, any>
---@return table<string, any>
local function with(extra)
    ---@type table<string, any>
    local settings = {}
    for k, v in pairs(BASE) do
        settings[k] = v
    end
    for k, v in pairs(extra) do
        settings[k] = v
    end
    return settings
end

-- ignoredFiles: Enable and Opened diagnose an opened file of an ignored folder, Disable does not; an ordinary file is always diagnosed
for _, mode in ipairs { 'Enable', 'Opened' } do
    local counts = diagnosed(with { ['diagnostics.ignoredFiles'] = mode })
    assert((counts[IGNORED] or 0) >= 1, 'ignoredFiles = ' .. mode .. ': the opened ignored file is diagnosed')
    assert((counts[NORMAL] or 0) >= 1, 'ignoredFiles = ' .. mode .. ': an ordinary file is diagnosed')
end
do
    local counts = diagnosed(with { ['diagnostics.ignoredFiles'] = 'Disable' })
    assert((counts[IGNORED] or 0) == 0, 'ignoredFiles = Disable: the ignored file is not diagnosed')
    assert((counts[NORMAL] or 0) >= 1, 'ignoredFiles = Disable: an ordinary file still is')
end

-- enableScheme: `file` by default, another scheme only when listed
do
    local counts = diagnosed(with { ['diagnostics.enableScheme'] = { 'file' } })
    assert((counts[UNTITLED] or 0) == 0, 'enableScheme = file: an untitled document is not diagnosed')
    assert((counts[NORMAL] or 0) >= 1, 'enableScheme = file: a file is')
end
do
    local counts = diagnosed(with { ['diagnostics.enableScheme'] = { 'file', 'untitled' } })
    assert((counts[UNTITLED] or 0) >= 1, 'enableScheme = file, untitled: an untitled document is diagnosed')
end

-- Lua.runtime.builtin: a builtin library set to "disable" is not defined (its globals are undefined), "default" keeps it
do
    ---@param settings table<string, any>
    ---@return string[] the names reported as undefined globals in a file that uses `string` and `table`
    local function undefinedGlobals(settings)
        ---@type string[]
        local names = {}
        local text = 'print(string.upper("a"), table.concat({}))' .. nl
        util.saveFile((DIR / 'uses.lua'):string(), text)
        ---@async
        lclient():start(function (client)
            client:registerFakers()
            client:register('workspace/configuration', function ()
                return { settings }
            end)
            ---@param params { uri: string, diagnostics: { code: string?, message: string }[] }
            client:register('textDocument/publishDiagnostics', function (params)
                if params.uri == root .. '/uses.lua' then
                    for _, diag in ipairs(params.diagnostics) do
                        if diag.code == 'undefined-global' then
                            names[#names+1] = diag.message
                        end
                    end
                end
                return nil
            end)
            client:initialize { rootUri = root }
            ws.awaitReady(root)
            client:notify('textDocument/didOpen', {
                textDocument = { uri = root .. '/uses.lua', languageId = 'lua', version = 1, text = text },
            })
            await.sleep(1)
        end)
        return names
    end
    local default = undefinedGlobals(with { ['runtime.builtin'] = { string = 'default' } })
    local disabled = undefinedGlobals(with { ['runtime.builtin'] = { string = 'disable' } })
    assert(#default == 0, 'builtin string = default: nothing is undefined: ' .. table.concat(default, ' | '))
    assert(#disabled >= 1, 'builtin string = disable: `string` is an undefined global')
    for _, message in ipairs(disabled) do
        assert(message:find('string', 1, true) and not message:find('table', 1, true), 'only string: ' .. message)
    end
end

pcall((fs --[[@as any]]).remove_all, DIR)
