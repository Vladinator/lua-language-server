local util = require 'utility'

---@class proto.diagnostic
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

m.register {
    'unused-label',
    'redundant-return',
} {
    group    = 'unused',
    severity = 'Hint',
    status   = 'Opened',
}

m.register {
    'redundant-value',
    'missing-parameter',
} {
    group    = 'unbalanced',
    severity = 'Warning',
    status   = 'Any',
}

m.register {
    'undefined-field',
    --'unnecessary-assert',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
}

m.register {
    'undefined-doc-param',
    'unknown-diag-code',
    'unknown-cast-variable',
    'unknown-operator',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'Any',
}

m.register {
    'spell-check'
} {
    group    = 'codestyle',
    severity = 'Information',
    status   = 'None',
}

m.register {
    'name-style-check'
} {
    group    = 'codestyle',
    severity = 'Warning',
    status   = 'None',
}

m.register {
    'await-in-sync',
} {
    group    = 'await',
    severity = 'Warning',
    status   = 'None',
}

m.register {
    'discard-returns',
} {
    group    = 'strict',
    severity = 'Warning',
    status   = 'Any',
}

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

---@return table<string, true>
function m.getDiagAndErrNameMap()
    if not m._diagAndErrNames then
        local names = {}
        for name in pairs(m.getDefaultSeverity()) do
            names[name] = true
        end
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
        table.sort(names)
        m._diagAndErrNames = names
    end
    return m._diagAndErrNames
end

return m
