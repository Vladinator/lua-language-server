local util = require 'utility'

---@class proto.diagnostic
---@field diagnosticDatas  table<string, {severity: DiagnosticSeverity, status: DiagnosticNeededFileStatus, description?: string, reads?: string[], narrowSettings?: string[], afterAll?: boolean, fullRunWhen?: fun(state: parser.state): boolean}>
---@field diagnosticGroups table<string, table<string, boolean>>
---@field _errNames? table<string, true>
---@field isEnabled fun(uri: uri, name: string, ignoreFileOpenState?: boolean): boolean set by core.diagnostics; whether a diagnostic runs for a file under the current config
---@field getRunOrder fun(): string[] set by core.diagnostics; the diagnostics in the order they run on a file (`unfulfilled-expect`, which always runs last, not included)
local m = {}

---@alias DiagnosticSeverity
---| 'Hint'
---| 'Information'
---| 'Warning'
---| 'Error'

---@alias DiagnosticNeededFileStatus
---| 'Any'
---| 'Opened'
---| 'None'

---@class proto.diagnostic.related
---@field uri?     uri
---@field message? string
---@field start    integer
---@field finish   integer

--- What a diagnostic check reports through its callback. `level` and `code`
--- are filled in by core.diagnostics; `data` is an opaque payload handed back
--- to code actions.
---@class proto.diagnostic.result
---@field start    integer
---@field finish   integer
---@field message  string
---@field level?   integer
---@field code?    string
---@field tags?    integer[]
---@field data?    any
---@field related? proto.diagnostic.related[]

---@class proto.diagnostic.info
---@field severity DiagnosticSeverity
---@field status   DiagnosticNeededFileStatus
---@field group    string
---@field description? string English text for the settings docs/schema (`config.diagnostics.<name>`); each plugin carries its own so deleting it removes everything
---@field reads? string[] settings the diagnostic reads beyond its own severity / status, for example `Lua.diagnostics.globals`. When one of them changes, a workspace diagnosis runs this diagnostic again (the ones the server knows about are listed in provider/diagnostic.lua); leave it out and the diagnostic keeps its old results until the next full pass
---@field narrowSettings? string[] settings that ONLY diagnostics naming them read (`Lua.diagnostics.globals` is read by the global checks and nothing else): when one changes, a workspace diagnosis runs just those diagnostics again instead of all of them. List a setting others read too and their results go stale, so it is for settings that belong to the diagnostic
---@field afterAll? boolean the diagnostic reads the outcome of all the others (`unfulfilled-expect` reports what the other diagnostics did with `---@diagnostic expect-*`): it runs after every other one on a file, and asking for it, or a change that concerns it, means all of them
---@field fullRunWhen? fun(state: parser.state): boolean for an `afterAll` diagnostic: a file it returns true for is never diagnosed partially

m.diagnosticDatas  = {}
m.diagnosticGroups = {}

-- The default severity / status per diagnostic and per group. They are LIVE tables that
-- `register` fills in, and the getters below hand out those very tables: diagnostics register
-- themselves from their own files, some after proto.define (which keeps a reference to
-- them) has loaded, so a copy taken at load time would miss them.
---@type table<string, DiagnosticSeverity>
local defaultSeverity = {}
---@type table<string, DiagnosticNeededFileStatus>
local defaultStatus = {}
---@type table<string, string>
local groupSeverity = {}
---@type table<string, string>
local groupStatus = {}

---@param names string[]
---@return fun(info: proto.diagnostic.info)
function m.register(names)
    ---@param info proto.diagnostic.info
    return function (info)
        for _, name in ipairs(names) do
            m.diagnosticDatas[name] = {
                severity    = info.severity,
                status      = info.status,
                description = info.description,
                reads       = info.reads,
                narrowSettings = info.narrowSettings,
                afterAll    = info.afterAll,
                fullRunWhen = info.fullRunWhen,
            }
            defaultSeverity[name] = info.severity
            defaultStatus[name]   = info.status
            if not m.diagnosticGroups[info.group] then
                m.diagnosticGroups[info.group] = {}
            end
            m.diagnosticGroups[info.group][name] = true
            groupSeverity[info.group] = 'Fallback'
            groupStatus[info.group]   = 'Fallback'
        end
    end
end

-- Names other tools use for one of our diagnostics (wowlua-ls: `type-mismatch` is our
-- `param-type-mismatch`). The canonical name stays the original LuaLS one; an alias is
-- accepted wherever a name is read from a user: `---@diagnostic`, `diagnostics.disable`,
-- `severity` and `neededFileStatus`. It is no diagnostic of its own (no code, no setting entry).
---@type table<string, string>
local aliases = {}

--- Accept `alias` as another name of the diagnostic `canonical`.
---@param alias     string
---@param canonical string
function m.registerAlias(alias, canonical)
    aliases[alias] = canonical
end

--- The canonical name for a name that may be an alias (a name that is none is returned as it is).
---@param name string
---@return string
function m.resolveAlias(name)
    return aliases[name] or name
end

-- wowlua-ls spellings of diagnostics we have under their original LuaLS name
for alias, canonical in pairs {
    ['type-mismatch']       = 'param-type-mismatch',
    ['return-mismatch']     = 'return-type-mismatch',
    ['access-private']      = 'invisible',
    ['access-protected']    = 'invisible',
    ['unknown-param-type']  = 'no-unknown',
    ['unknown-return-type'] = 'no-unknown',
    ['unknown-local-type']  = 'no-unknown',
    ['unknown-field-type']  = 'no-unknown',
} do
    m.registerAlias(alias, canonical)
end

--- The names a per-diagnostic setting (`severity`, `neededFileStatus`) takes as key, sorted: the
--- registered diagnostics and the aliases.
---@return string[]
function m.getDiagAndAliasNames()
    ---@type table<string, true>
    local names = {}
    for name in pairs(m.diagnosticDatas) do
        names[name] = true
    end
    for alias in pairs(aliases) do
        names[alias] = true
    end
    return util.getTableKeys(names, true)
end

--- The aliases registered for the canonical name `canonical`.
---@param canonical string
---@return string[]
function m.aliasesOf(canonical)
    ---@type string[]
    local list = {}
    for alias, target in pairs(aliases) do
        if target == canonical then
            list[#list+1] = alias
        end
    end
    table.sort(list)
    return list
end

--- The live table of default severities (see above): do not modify it.
---@return table<string, DiagnosticSeverity>
function m.getDefaultSeverity()
    return defaultSeverity
end

--- The live table of default file statuses: do not modify it.
---@return table<string, DiagnosticNeededFileStatus>
function m.getDefaultStatus()
    return defaultStatus
end

--- The live table of group severities (all 'Fallback'): do not modify it.
---@return table<string, string>
function m.getGroupSeverity()
    return groupSeverity
end

--- The live table of group file statuses (all 'Fallback'): do not modify it.
---@return table<string, string>
function m.getGroupStatus()
    return groupStatus
end

---@param name string
---@return string[]
m.getGroups = util.cacheReturn(function (name)
    ---@type string[]
    local groups = {}
    for groupName, nameMap in pairs(m.diagnosticGroups) do
        if nameMap[name] then
            groups[#groups+1] = groupName
        end
    end
    table.sort(groups)
    return groups
end)

-- Diagnostics that self-register from within their own file (see
-- core/diagnostics/init.lua) aren't necessarily required yet the first
-- time this is called -- config/template.lua reaches it very early,
-- transitively from `require 'files'`, well before core.diagnostics'
-- eager-require list runs. So only the syntax-error names (read once
-- from the parser source files below) are cached; the diagnostic names
-- themselves come from proto.diagnostic's live diagnosticDatas table
-- on every call, same fix as core/diagnostics/init.lua's getSeverity/
-- getStatus/buildDiagList.
---@return table<string, true>
function m.getDiagAndErrNameMap()
    if not m._errNames then
        ---@type table<string, true>
        local names = {}
        for _, fileName in ipairs {'parser.compile', 'parser.luadoc'} do
            local path = package.searchpath(fileName, package.path)
            if path then
                local f = io.open(path)
                if f then
                    for line in f:lines() do
                        local name = line:match([=[type%s*=%s*['"](%u[%u_]+%u)['"]]=]) --[[@as string?]]
                        if name then
                            local id = (name:lower():gsub('_', '-'))
                            names[id] = true
                        end
                    end
                    f:close()
                end
            end
        end
        m._errNames = names
    end
    ---@type table<string, true>
    local names = {}
    for name in pairs(m._errNames) do
        names[name] = true
    end
    for name in pairs(m.getDefaultSeverity()) do
        names[name] = true
    end
    for alias in pairs(aliases) do
        names[alias] = true
    end
    return names
end

return m
