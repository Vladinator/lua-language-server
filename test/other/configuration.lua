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

-- every diagnostic that a plugin brings (whichever are there: core/diagnostics/extra/), and
-- `unfulfilled-expect`, which registers itself too
local diagd = require 'proto.diagnostic'
local pluginNames = require 'extra_diagnostics'()
pluginNames[#pluginNames+1] = 'unfulfilled-expect'

local severity = assert(config['Lua.diagnostics.severity'].properties)
local status   = assert(config['Lua.diagnostics.neededFileStatus'].properties)
local disable  = toSet(assert(config['Lua.diagnostics.disable'].items).enum)
for _, name in ipairs(pluginNames) do
    assert(severity[name], name .. ' missing from Lua.diagnostics.severity')
    assert(status[name],   name .. ' missing from Lua.diagnostics.neededFileStatus')
    assert(disable[name],  name .. ' missing from Lua.diagnostics.disable')
end
-- and the groups they put themselves in
for _, name in ipairs(pluginNames) do
    for _, group in ipairs(diagd.getGroups(name)) do
        assert(assert(config['Lua.diagnostics.groupSeverity'].properties)[group],   ('group `%s` missing (severity)'):format(group))
        assert(assert(config['Lua.diagnostics.groupFileStatus'].properties)[group], ('group `%s` missing (file status)'):format(group))
    end
end
