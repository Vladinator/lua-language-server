-- A table setting (`Lua.diagnostics.neededFileStatus`, `severity`, `groupFileStatus`, ...) keeps the entries that are fine when one entry is not: a name that is no diagnostic
-- (a typo, a name of another version, a diagnostic of a plugin that loads later) or a value that is no status. The whole table used to be dropped, silently: every other entry
-- stopped applying. (Found 2026-10-26 by a matrix project whose `.luarc.json` listed a name this server does not know.)
local config = require 'config'
require 'core.diagnostics'

local NEEDED   = 'Lua.diagnostics.neededFileStatus'
local SEVERITY = 'Lua.diagnostics.severity'
local GROUP    = 'Lua.diagnostics.groupFileStatus'

-- the settings changed here must not start diagnoses of their own
local provider = require 'provider.diagnostic' --[[@as table<string, any>]]
---@type table<string, any>
local silenced = {}
for _, name in ipairs { 'diagnosticsScope', 'refreshClient', 'refresh', 'refreshScopeDiag', 'stopScopeDiag' } do
    silenced[name] = provider[name]
    provider[name] = function () end
end

local saved = { [NEEDED] = config.get(nil, NEEDED), [SEVERITY] = config.get(nil, SEVERITY), [GROUP] = config.get(nil, GROUP) }

--- Sets `key` and gives back what the server holds for it.
---@param key   string
---@param value table
---@return table<string, string>
local function load(key, value)
    config.set(nil, key, value)
    return config.get(nil, key) --[[@as table<string, string>]]
end

do
    local got = load(NEEDED, { ['no-such-diagnostic'] = 'Any', ['global-element'] = 'Any!', ['unused-local'] = 'Opened' })
    assert(got['global-element'] == 'Any!', 'a valid entry survives an unknown name next to it')
    assert(got['unused-local'] == 'Opened', 'so does the second one')
end

do
    local got = load(NEEDED, { ['unused-local'] = 'Sometimes', ['global-element'] = 'Any' })
    assert(got['global-element'] == 'Any', 'a valid entry survives an invalid value next to it')
    assert(got['unused-local'] ~= 'Sometimes', 'the invalid value itself is not kept')
end

do
    local got = load(SEVERITY, { ['no-such-diagnostic'] = 'Error', ['unused-local'] = 'Error' })
    assert(got['unused-local'] == 'Error', 'severity: the known name keeps its level')
    got = load(SEVERITY, { ['unused-local'] = 'Loud' })
    assert(got['unused-local'] ~= 'Loud', 'severity: an invalid level is not kept')
end

do
    local got = load(GROUP, { ['no-such-group'] = 'Any', ['conventions'] = 'Any' })
    assert(got['conventions'] == 'Any', 'groupFileStatus: the known group survives an unknown one')
end

-- a table that is completely valid is unchanged
do
    local got = load(NEEDED, { ['global-element'] = 'Any', ['unused-local'] = 'None' })
    assert(got['global-element'] == 'Any' and got['unused-local'] == 'None', 'a valid table is loaded as it is')
end

for key, value in pairs(saved) do
    config.set(nil, key, value)
end
for name, fn in pairs(silenced) do
    provider[name] = fn
end
