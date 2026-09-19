local util = require 'utility'

---@class proto.diagnostic
---@field diagnosticDatas  table<string, {severity: DiagnosticSeverity, status: DiagnosticNeededFileStatus}>
---@field diagnosticGroups table<string, table<string, boolean>>
---@field _errNames? table<string, true>
---@field isEnabled fun(uri: uri, name: string, ignoreFileOpenState?: boolean): boolean set by core.diagnostics; whether a diagnostic runs for a file under the current config
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

m.diagnosticDatas  = {}
m.diagnosticGroups = {}

---@param names string[]
---@return fun(info: proto.diagnostic.info)
function m.register(names)
    ---@param info proto.diagnostic.info
    return function (info)
        for _, name in ipairs(names) do
            m.diagnosticDatas[name] = {
                severity = info.severity,
                status   = info.status,
            }
            if not m.diagnosticGroups[info.group] then
                m.diagnosticGroups[info.group] = {}
            end
            m.diagnosticGroups[info.group][name] = true
        end
    end
end

---@return table<string, DiagnosticSeverity>
function m.getDefaultSeverity()
    ---@type table<string, DiagnosticSeverity>
    local severity = {}
    for name, info in pairs(m.diagnosticDatas) do
        severity[name] = info.severity
    end
    return severity
end

---@return table<string, DiagnosticNeededFileStatus>
function m.getDefaultStatus()
    ---@type table<string, DiagnosticNeededFileStatus>
    local status = {}
    for name, info in pairs(m.diagnosticDatas) do
        status[name] = info.status
    end
    return status
end

---@return table<string, string>
function m.getGroupSeverity()
    ---@type table<string, string>
    local group = {}
    for name in pairs(m.diagnosticGroups) do
        group[name] = 'Fallback'
    end
    return group
end

---@return table<string, string>
function m.getGroupStatus()
    ---@type table<string, string>
    local group = {}
    for name in pairs(m.diagnosticGroups) do
        group[name] = 'Fallback'
    end
    return group
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
                            local id = (name:lower():gsub('_', '-')) --[[@as string]]
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
