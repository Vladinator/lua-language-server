-- tools/configuration.lua builds the settings schema the VS Code extension ships. It must
-- list every diagnostic the server can report, including the ones that self-register
-- from core/diagnostics/extra/ (they only exist in the registry once their file ran),
-- and it must cope with the template's function-valued enums.
local config = dofile('tools/configuration.lua')

---@param list any[]?
---@return table<any, true>
local function toSet(list)
    ---@type table<any, true>
    local set = {}
    for _, v in ipairs(list or {}) do
        set[v] = true
    end
    return set
end

local pluginNames = {
    'need-check-secret',
    'redundant-secret-unwrap',
    'undefined-secret-name',
    'unfulfilled-expect',
}

local severity = assert(config['Lua.diagnostics.severity'].properties)
local status   = assert(config['Lua.diagnostics.neededFileStatus'].properties)
local disable  = toSet(assert(config['Lua.diagnostics.disable'].items).enum)
for _, name in ipairs(pluginNames) do
    assert(severity[name], name .. ' missing from Lua.diagnostics.severity')
    assert(status[name],   name .. ' missing from Lua.diagnostics.neededFileStatus')
    assert(disable[name],  name .. ' missing from Lua.diagnostics.disable')
end
assert(assert(config['Lua.diagnostics.groupSeverity'].properties)['secret'],   'group `secret` missing (severity)')
assert(assert(config['Lua.diagnostics.groupFileStatus'].properties)['secret'], 'group `secret` missing (file status)')
