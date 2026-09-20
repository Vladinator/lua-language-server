local util = require 'utility'

---@class proto.diagnostic
---@field diagnosticDatas  table<string, {severity: DiagnosticSeverity, status: DiagnosticNeededFileStatus, description?: string, reads?: string[]}>
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
    return names
end

return m
