local kinds  = require 'file-kinds'
local diagd  = require 'proto.diagnostic'
local vm     = require 'vm'
local files  = require 'files'
local guide  = require 'parser.guide'
local scope  = require 'workspace.scope'
local furi   = require 'file-uri'
local util   = require 'utility'
local ws     = require 'workspace'
local await  = require 'await'
local lang   = require 'language'

-- Config hygiene: the lists in a project's settings grow and are never cleaned. This kind of document (`.luarc.json`, `.luarc.jsonc`,
-- `.vscode/settings.json` of a project) is read for `Lua.diagnostics.globals` and `Lua.diagnostics.globalsRegex`, and every entry that
-- no longer does anything is reported as `unused-config-global` (a warning), with a quick fix that removes it:
--
-- * a name of `globals` that the workspace (or a library, or a plugin) defines: the entry changes nothing, `undefined-global` would stay quiet;
-- * a name that nothing in the workspace reads or writes;
-- * a pattern of `globalsRegex` that no global the project uses without defining it matches.
--
-- The verdict needs the whole workspace, so it waits for it (`needsWorkspace`) and is made again when the workspace reloads. The same
-- analysis runs in `--check` (script/cli/check_worker.lua).

local CODE = 'unused-config-global'
local KIND = 'luaconfig'

diagd.register { CODE } {
    group       = 'unused',
    severity    = 'Warning',
    status      = 'Any',
    fileKind    = KIND,
    description = 'Enable diagnostics for an entry of `Lua.diagnostics.globals` or `Lua.diagnostics.globalsRegex` in a project\'s settings file that does nothing: the global is defined, or nothing in the workspace uses it.',
}

---@class configHygiene.entry
---@field key          'globals'|'globalsRegex'
---@field name         string
---@field start        integer byte offset of the opening quote
---@field finish       integer byte offset of the closing quote
---@field removeStart  integer byte range a quick fix deletes
---@field removeFinish integer

---@class configHygiene.element
---@field value  string?
---@field start  integer
---@field finish integer

local m = {}

---@param text string
---@return configHygiene.entry[]
function m.scan(text)
    local pos = 1
    local len = #text
    ---@type configHygiene.entry[]
    local entries = {}

    local function skipSpace()
        while pos <= len do
            local c = text:sub(pos, pos)
            if c == ' ' or c == '\t' or c == '\r' or c == '\n' then
                pos = pos + 1
            elseif text:sub(pos, pos + 1) == '//' then
                local e = text:find('\n', pos, true)
                pos = e and e + 1 or len + 1
            elseif text:sub(pos, pos + 1) == '/*' then
                local _, e = text:find('*/', pos + 2, true)
                pos = e and e + 1 or len + 1
            else
                return
            end
        end
    end

    --- (the string at `pos`: its decoded value, the byte of the opening and of the closing quote)
    ---@return string value
    ---@return integer start
    ---@return integer finish
    local function parseString()
        local start = pos
        pos = pos + 1
        ---@type string[]
        local parts = {}
        while pos <= len do
            local c = text:sub(pos, pos)
            if c == '\\' then
                local n = text:sub(pos + 1, pos + 1)
                parts[#parts+1] = ({ n = '\n', t = '\t', r = '\r', b = '\b', f = '\f' })[n] or n
                pos = pos + 2
            elseif c == '"' then
                pos = pos + 1
                return table.concat(parts), start, pos - 1
            else
                parts[#parts+1] = c
                pos = pos + 1
            end
        end
        return table.concat(parts), start, len
    end

    local parseValue

    ---@param path string
    ---@return configHygiene.element[]
    local function parseArray(path)
        pos = pos + 1
        ---@type configHygiene.element[]
        local elements = {}
        ---@type integer[]
        local commas = {}
        while true do
            skipSpace()
            if pos > len then
                break
            end
            local c = text:sub(pos, pos)
            if c == ']' then
                pos = pos + 1
                break
            elseif c == '}' then
                -- (a damaged text: the array was never closed, the object around it ends here)
                break
            elseif c == ',' then
                commas[#elements] = pos
                pos = pos + 1
            elseif c == '"' then
                local value, start, finish = parseString()
                elements[#elements+1] = { value = value, start = start, finish = finish }
            else
                local start = pos
                parseValue(path .. '[]')
                elements[#elements+1] = { start = start, finish = pos - 1 }
            end
        end
        local key = (path == 'Lua.diagnostics.globals' or path == 'diagnostics.globals') and 'globals'
                 or (path == 'Lua.diagnostics.globalsRegex' or path == 'diagnostics.globalsRegex') and 'globalsRegex'
        if not key then
            return elements
        end
        for i, element in ipairs(elements) do
            if element.value then
                local removeStart, removeFinish = element.start, element.finish
                if i < #elements then
                    removeFinish = elements[i+1].start - 1
                elseif i > 1 and commas[i-1] then
                    removeStart = commas[i-1]
                end
                entries[#entries+1] = {
                    key          = key,
                    name         = element.value,
                    start        = element.start,
                    finish       = element.finish,
                    removeStart  = removeStart,
                    removeFinish = removeFinish,
                }
            end
        end
        return elements
    end

    ---@param path string
    local function parseObject(path)
        pos = pos + 1
        while true do
            skipSpace()
            if pos > len then
                return
            end
            local c = text:sub(pos, pos)
            if c == '}' then
                pos = pos + 1
                return
            elseif c == ',' then
                pos = pos + 1
            elseif c == '"' then
                local key = parseString()
                skipSpace()
                if text:sub(pos, pos) == ':' then
                    pos = pos + 1
                    skipSpace()
                    parseValue(path == '' and key or (path .. '.' .. key))
                end
            else
                pos = pos + 1
            end
        end
    end

    ---@param path string
    function parseValue(path)
        skipSpace()
        local c = text:sub(pos, pos)
        if c == '{' then
            parseObject(path)
        elseif c == '[' then
            parseArray(path)
        elseif c == '"' then
            parseString()
        else
            local start = pos
            while pos <= len and not text:sub(pos, pos):find('[%s,%]}]') do
                pos = pos + 1
            end
            if pos == start and pos <= len then
                -- (a stray `]` or `,` where a value should be: always move on, a text that is being typed is damaged most of the time)
                pos = pos + 1
            end
        end
    end

    parseValue('')
    return entries
end

--- Whether a file of the project (not a library) reads the global.
---@param suri uri
---@param name string
---@return boolean
local function isUsed(suri, name)
    local globalVar = vm.getGlobal('variable', name)
    if not globalVar then
        return false
    end
    local scp = scope.getScope(suri)
    for uri, link in pairs(globalVar.links) do
        if link.gets and #link.gets > 0 and scp:isVisible(uri) and not files.isLibrary(uri) then
            return true
        end
    end
    return false
end

--- Whether the workspace defines the global (or a plugin says it exists).
---@param suri uri
---@param name string
---@return boolean
local function isDefined(suri, name)
    return vm.hasGlobalSets(suri, 'variable', name) or vm.isProvidedGlobal(suri, name)
end

--- Whether the entry still silences something on the assignments that define the global: `lowercase-global` and `global-element`
--- skip the names of the list, and `deprecated` does for a global marked `---@deprecated`. Nothing the list does for a name that only
--- a meta file (a library) assigns, or that is bound to a `---@class`, because those checks leave them alone anyway.
---@param suri uri
---@param name string
---@return boolean
local function silencesTheDefinition(suri, name)
    local globalVar = vm.getGlobal('variable', name)
    if not globalVar then
        return false
    end
    local lowercase = name:match('%w') ~= nil and name:match('%w'):match('%l') ~= nil
    ---@type boolean
    local flagged = false
    for _, set in ipairs(globalVar:getSets(suri)) do
        local setUri = guide.getUri(set)
        if vm.isMetaFile(setUri) then
            return false
        end
        for _, doc in ipairs(set.bindDocs or {}) do
            if doc.type == 'doc.deprecated' then
                return true
            end
        end
        if set.type == 'setglobal' and not set.declare and not vm.isProvidedGlobal(setUri, name) then
            local bound = false
            for _, doc in ipairs(set.bindDocs or {}) do
                if doc.type == 'doc.class' then
                    bound = true
                end
            end
            if not bound
            and ((lowercase and diagd.isEnabled(setUri, 'lowercase-global', true))
              or diagd.isEnabled(setUri, 'global-element', true)) then
                flagged = true
            end
        end
    end
    return flagged
end

--- The names of the globals that the project reads without anything defining them, by scope. Walking every global of the workspace
--- (a WoW project has ten thousand from its API annotations) is far too much to repeat for each entry on each keystroke: the list is
--- kept until a file is compiled, changed or removed.
---@type table<string, string[]>?
local usedUndefinedCache

files.watch(function (ev)
    if ev == 'compile' or ev == 'update' or ev == 'remove' or ev == 'create' then
        usedUndefinedCache = nil
    end
end)

---@param suri uri
---@return string[]
local function usedUndefinedNames(suri)
    local cache = usedUndefinedCache
    if not cache then
        cache = {}
        usedUndefinedCache = cache
    end
    local scp = scope.getScope(suri)
    local key = scp.uri or ''
    local names = cache[key]
    if names then
        return names
    end
    names = {}
    for _, globalVar in ipairs(vm.getGlobals('variable')) do
        local name = globalVar.name
        if isUsed(suri, name) and not isDefined(suri, name) then
            names[#names+1] = name
        end
    end
    cache[key] = names
    return names
end

--- Whether a global that the project uses without defining it matches the pattern.
---@param suri     uri
---@param pattern  string
---@return boolean
local function patternIsNeeded(suri, pattern)
    for _, name in ipairs(usedUndefinedNames(suri)) do
        local ok, matched = pcall(string.match, name, pattern)
        if ok and matched then
            return true
        end
    end
    return false
end

--- The reason an entry can go, or nil when it is needed.
---@param suri  uri
---@param entry configHygiene.entry
---@return string?
function m.verdict(suri, entry)
    if entry.key == 'globals' then
        if isDefined(suri, entry.name) then
            if silencesTheDefinition(suri, entry.name) then
                return nil
            end
            return ('`%s` is defined in the workspace or a library: the entry is not needed, `undefined-global` stays quiet without it.'):format(entry.name)
        end
        if not isUsed(suri, entry.name) then
            return ('Nothing in the workspace uses `%s`: remove it from `Lua.diagnostics.globals`.'):format(entry.name)
        end
        return nil
    end
    -- (a broken pattern is a different problem: `undefined-global` would raise on it, this check does not call it unused)
    if not pcall(string.match, '', entry.name) then
        return nil
    end
    if not patternIsNeeded(suri, entry.name) then
        return ('No global that the project uses without defining it matches the pattern `%s`: remove it from `Lua.diagnostics.globalsRegex`.'):format(entry.name)
    end
    return nil
end

--- The line and character of a byte offset (1-based) in the client's encoding.
---@param text   string
---@param offset integer
---@return fileKind.position
local function positionOf(text, offset)
    local before = text:sub(1, offset - 1)
    local _, lines = before:gsub('\n', '')
    local lineStart = (before:match('.*\n()') or 1)
    local lineText = text:sub(lineStart, offset - 1)
    return { line = lines, character = kinds.toCharacter(lineText, #lineText) }
end

---@param uri uri
---@return boolean
local function hasFolder(uri)
    local scp = scope.getScope(uri)
    return scp ~= scope.fallback and scp.uri ~= nil
end

---@type fileKind
local kind = {
    id             = KIND,
    needsWorkspace = true,
    match = function (uri)
        local path = furi.decode(uri)
        if not path then
            return false
        end
        path = path:gsub('\\', '/'):lower()
        return util.stringEndWith(path, '/.luarc.json')
            or util.stringEndWith(path, '/.luarc.jsonc')
            or util.stringEndWith(path, '/.vscode/settings.json')
    end,
    --- Every file of the project has to be compiled before the verdict: the globals of a file are known once it was compiled, and the
    --- workspace diagnosis only compiles the files it needs (the checks of an open file, the ones that run on every file).
    ---@async
    prepare = function (uri, text)
        if not hasFolder(uri) or not diagd.isEnabled(uri, CODE, true) or #m.scan(text) == 0 then
            return
        end
        for _, fileUri in ipairs(files.getChildFiles(scope.getScope(uri).uri)) do
            if not ws.isIgnored(fileUri) and not files.isLibrary(fileUri) then
                files.compileState(fileUri)
                await.delay()
            end
        end
    end,
    diagnose = function (uri, text)
        ---@type fileKind.diagnostic[]
        local found = {}
        -- a file that is not in a folder of the workspace says nothing about it (a settings file of the user, shared by many projects)
        if not hasFolder(uri) then
            return found
        end
        for _, entry in ipairs(m.scan(text)) do
            local message = m.verdict(uri, entry)
            if message then
                found[#found+1] = {
                    code    = CODE,
                    message = message,
                    range   = {
                        start   = positionOf(text, entry.start),
                        ['end'] = positionOf(text, entry.finish + 1),
                    },
                }
            end
        end
        return found
    end,
    codeAction = function (uri, text, range, diagnostics)
        ---@type table[]
        local actions = {}
        local entries = m.scan(text)
        for _, diag in ipairs(diagnostics) do
            if diag.code == CODE then
                -- (a JSON file has no comments: the one way to silence the warning is the setting of the workspace)
                actions[#actions+1] = {
                    title       = lang.script('ACTION_DISABLE_DIAG', CODE),
                    kind        = 'quickfix',
                    data        = 'disable',
                    diagnostics = { diag },
                    command     = {
                        title     = lang.script.COMMAND_DISABLE_DIAG,
                        command   = 'lua.setConfig',
                        arguments = { { key = 'Lua.diagnostics.disable', action = 'add', value = CODE, uri = uri } },
                    },
                }
                for _, entry in ipairs(entries) do
                    local start = positionOf(text, entry.start)
                    if start.line == diag.range.start.line and start.character == diag.range.start.character then
                        actions[#actions+1] = {
                            title       = ('Remove `%s` from the list'):format(entry.name),
                            kind        = 'quickfix',
                            diagnostics = { diag },
                            edit        = {
                                changes = {
                                    [uri] = { {
                                        range   = {
                                            start   = positionOf(text, entry.removeStart),
                                            ['end'] = positionOf(text, entry.removeFinish + 1),
                                        },
                                        newText = '',
                                    } },
                                },
                            },
                        }
                    end
                end
            end
        end
        return actions
    end,
}

kind.samples = {
    {
        name = '/.vscode/settings.json',
        text = table.concat({
            '{',
            '    // the globals of the addon',
            '    "Lua.diagnostics.globals": ["Foo", "Bar"],',
            '    "Lua.diagnostics.globalsRegex": ["^Addon", "^Other"],',
            '    "Lua": { "diagnostics": { "globals": ["Baz"] } }',
            '}',
        }, string.char(10)),
    },
}

kinds.register(kind)

m.kind = kind
m.CODE = CODE

return m
