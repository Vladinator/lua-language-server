-- The "do you trust this location" gate that every loader of user-supplied Lua goes through:
-- `Lua.runtime.plugin` (plugin.lua) and `Lua.diagnostics.pluginsDir`
-- (core/diagnostics/custom-plugins.lua). A location is trusted when the server was started with
-- TRUST_ALL_PLUGINS, when the client vouches for it (`trustByClient`), or when the user said yes
-- once before (the answer is remembered in `<LOGPATH>/trusted`, one path per line).

local util   = require 'utility'
local client = require 'client'
local lang   = require 'language'

local m = {}

---@async
---@param path    string # the file or directory that would be loaded
---@param message string # the `lang.script` key of the question to ask
---@return boolean
function m.check(path, message)
    if TRUST_ALL_PLUGINS then
        return true
    end
    if client.getOption('trustByClient') then
        return true
    end
    local filePath = LOGPATH .. '/trusted'
    local trusted = util.loadFile(filePath)
    ---@type string[]
    local lines = {}
    if trusted then
        for line in util.eachLine(trusted) do
            lines[#lines+1] = line
            if line == path then
                return true
            end
        end
    end
    local _, index = client.awaitRequestMessage('Warning', lang.script(message, path), {
        lang.script('PLUGIN_TRUST_YES'),
        lang.script('PLUGIN_TRUST_NO'),
    })
    if not index then
        return false
    end
    lines[#lines+1] = path
    util.saveFile(filePath, table.concat(lines, '\n'))
    return true
end

return m
