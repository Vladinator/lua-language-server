local util = require 'utility'

---@class proto.diagnostic
---@field diagnosticDatas  table<string, {severity: DiagnosticSeverity, status: DiagnosticNeededFileStatus}>
---@field diagnosticGroups table<string, table<string, boolean>>
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
    local severity = {}
    for name, info in pairs(m.diagnosticDatas) do
        severity[name] = info.severity
    end
    return severity
end

---@return table<string, DiagnosticNeededFileStatus>
function m.getDefaultStatus()
    local status = {}
    for name, info in pairs(m.diagnosticDatas) do
        status[name] = info.status
    end
    return status
end

function m.getGroupSeverity()
    local group = {}
    for name in pairs(m.diagnosticGroups) do
        group[name] = 'Fallback'
    end
    return group
end

function m.getGroupStatus()
    local group = {}
    for name in pairs(m.diagnosticGroups) do
        group[name] = 'Fallback'
    end
    return group
end

---@param name string
---@return string[]
m.getGroups = util.cacheReturn(function (name)
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
        local names = {}
        for _, fileName in ipairs {'parser.compile', 'parser.luadoc'} do
            local path = package.searchpath(fileName, package.path)
            if path then
                local f = io.open(path)
                if f then
                    for line in f:lines() do
                        local name = line:match([=[type%s*=%s*['"](%u[%u_]+%u)['"]]=])
                        if name then
                            local id = name:lower():gsub('_', '-')
                            names[id] = true
                        end
                    end
                    f:close()
                end
            end
        end
        m._errNames = names
    end
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
