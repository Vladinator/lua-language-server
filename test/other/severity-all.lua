-- `Lua.diagnostics.severity` and `Lua.diagnostics.groupSeverity` take the name `*`: the severity of every diagnostic that no group setting
-- speaks for (`severity`: that the table does not list). `{ "*": "Hint" }` quietens everything.
local config = require 'config'
require 'core.diagnostics'
local diagd  = require 'proto.diagnostic'
local files  = require 'files'

-- the settings changed here must not start diagnoses of their own (they would run on the shared state of the other tests)
local provider = require 'provider.diagnostic' --[[@as table<string, any>]]
---@type table<string, any>
local silencedFunctions = {}
for _, name in ipairs { 'diagnosticsScope', 'refreshClient', 'refresh', 'refreshScopeDiag', 'stopScopeDiag' } do
    silencedFunctions[name] = provider[name]
    provider[name] = function () end
end

local uri = 'file:///severity-all-unopened.lua'
files.remove(uri)
files.setText(uri, 'local x = 1\n')

local SEV, GROUP = 'Lua.diagnostics.severity', 'Lua.diagnostics.groupSeverity'
local savedSeverity, savedGroup = config.get(nil, SEV), config.get(nil, GROUP)

local TYPED = 'param-type-mismatch'   -- Warning by default, group `type-check`
local OTHER = 'unused-local'          -- Hint by default, group `unused`

---@param severity? table<string, string>
---@param group?    table<string, string>
---@return string typed
---@return string other
local function severities(severity, group)
    config.set(nil, SEV, severity or {})
    config.set(nil, GROUP, group or {})
    return diagd.getSeverity(uri, TYPED), diagd.getSeverity(uri, OTHER)
end

local typed, other = severities()
assert(typed == 'Warning' and other == 'Hint', 'the defaults: ' .. typed .. ' / ' .. other)

typed, other = severities({ ['*'] = 'Error' })
assert(typed == 'Error' and other == 'Error', '`*` in severity is the severity of the names it does not list')
typed, other = severities({ ['*'] = 'Error', [OTHER] = 'Hint' })
assert(typed == 'Error' and other == 'Hint', 'a listed name keeps its own value')
typed, other = severities({ ['*'] = 'Fallback' })
assert(typed == 'Warning' and other == 'Hint', '`*` = Fallback changes nothing')
typed, other = severities({ ['*'] = 'Hint!' })
assert(typed == 'Hint' and other == 'Hint', 'a `!` on the value of `*` is read as the plain value')

typed, other = severities(nil, { ['*'] = 'Information' })
assert(typed == 'Information' and other == 'Information', '`*` in groupSeverity')
typed, other = severities(nil, { ['*'] = 'Information', ['type-check'] = 'Error' })
assert(typed == 'Error' and other == 'Information', 'a group that speaks for its diagnostics wins over `*`')
typed, other = severities({ ['*'] = 'Error' }, { ['type-check'] = 'Hint' })
assert(typed == 'Hint' and other == 'Error', 'a group beats `*` in severity, which stays for the other diagnostics')
typed, other = severities({ [TYPED] = 'Error!' }, { ['*'] = 'Hint' })
assert(typed == 'Error' and other == 'Hint', 'a name with `!` beats `*` in groupSeverity')
typed, other = severities({ ['*'] = 'Error' }, { ['*'] = 'Hint' })
assert(typed == 'Hint' and other == 'Hint', 'when both are set, groupSeverity`s `*` is the one used')

-- (a listed alias of the name counts as listing the name; the alias is made up for this test)
diagd.registerAlias('zz-severity-alias-test', TYPED)
typed, other = severities({ ['*'] = 'Error', ['zz-severity-alias-test'] = 'Hint' })
assert(typed == 'Hint' and other == 'Error', 'an alias the table lists keeps the value for its name')

config.set(nil, SEV, savedSeverity)
config.set(nil, GROUP, savedGroup)
for name, original in pairs(silencedFunctions) do
    provider[name] = original
end
files.remove(uri)
