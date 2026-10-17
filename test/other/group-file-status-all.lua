-- `Lua.diagnostics.groupFileStatus` takes the name `*`: the status of every diagnostic that no group setting speaks for.
-- (`{ "*": "Any" }` is how a project checks every file, not only the open ones.)
local config = require 'config'
require 'core.diagnostics'
local diagd  = require 'proto.diagnostic'
local files  = require 'files'

local uri = 'file:///group-file-status-all-unopened.lua'
files.remove(uri)
files.setText(uri, 'local x = 1\n')
assert(not files.isOpen(uri), 'the file is not open')

-- the settings changed here must not start diagnoses of their own (they would run on the shared state of the other tests)
local provider = require 'provider.diagnostic' --[[@as table<string, any>]]
---@type table<string, any>
local silencedFunctions = {}
for _, name in ipairs { 'diagnosticsScope', 'refreshClient', 'refresh', 'refreshScopeDiag', 'stopScopeDiag' } do
    silencedFunctions[name] = provider[name]
    provider[name] = function () end
end

local KEY = 'Lua.diagnostics.groupFileStatus'
local NEEDED = 'Lua.diagnostics.neededFileStatus'
local saved = config.get(nil, KEY)
local savedNeeded = config.get(nil, NEEDED)

-- test/diagnostics writes `Any!` into the live table of the default of every diagnostic and keeps it for the rest of the run: take it
-- out while this test reads the defaults, and put it back at the end
local live = config.get(nil, NEEDED) --[[@as table<string, string>]]
---@type table<string, string>
local polluted = {}
for key, value in pairs(live) do
    polluted[key] = value
    live[key] = nil
end

-- a diagnostic that is `Opened` by default and belongs to the `type-check` group, one from another group, and one that is off by default
local TYPED = 'param-type-mismatch'
local OTHER = 'unused-local'
local OFF   = 'spell-check'
assert(require 'proto.define'.DiagnosticDefaultNeededFileStatus[OFF] == 'None', OFF .. ' is off by default')

---@param status table<string, string>?
---@param needed table<string, string>?
---@return boolean typed
---@return boolean other
---@return boolean off the diagnostic that is off by default
local function enabled(status, needed)
    config.set(nil, KEY, status or {})
    config.set(nil, NEEDED, needed or {})
    return diagd.isEnabled(uri, TYPED, false), diagd.isEnabled(uri, OTHER, false), diagd.isEnabled(uri, OFF, false)
end

do
    local typed, other, off = enabled(nil)
    assert(typed == false and other == false and off == false, 'by default both wait for the file to be opened, the third is off')

    -- a diagnostic that is off by default stays off under `*` = Any / Opened (in both tables), a listed one can still be switched on
    typed, other, off = enabled { ['*'] = 'Any' }
    assert(off == false, '`*` = Any does not switch on what is off by default')
    typed, other, off = enabled(nil, { ['*'] = 'Any' })
    assert(off == false, '... nor in neededFileStatus')
    typed, other, off = enabled(nil, { ['*'] = 'Any', [OFF] = 'Any' })
    assert(off, 'a diagnostic the table lists with Any is on')

    typed, other = enabled { ['*'] = 'Any' }
    assert(typed and other, '`*` = Any: every diagnostic runs on an unopened file')

    typed, other = enabled { ['*'] = 'Fallback' }
    assert(typed == false and other == false, '`*` = Fallback leaves the single settings alone')

    typed, other = enabled { ['*'] = 'None' }
    assert(typed == false and other == false, '`*` = None: off')

    -- a group that speaks for its own diagnostics wins over `*`
    typed, other = enabled { ['*'] = 'Any', ['type-check'] = 'None' }
    assert(typed == false and other, 'a group set to None keeps its diagnostics off, the others follow `*`')
    typed, other = enabled { ['*'] = 'None', ['type-check'] = 'Any' }
    assert(typed and other == false, 'a group set to Any works with `*` = None')

    -- a single setting with `!` wins over everything
    typed, other = enabled({ ['*'] = 'Any' }, { [TYPED] = 'Opened!' })
    assert(typed == false and other, 'a name with `!` beats `*`')
    typed, other = enabled({ ['*'] = 'None' }, { [TYPED] = 'Any!' })
    assert(typed and other == false, '`Any!` beats `*` = None')

    -- the same name in `neededFileStatus` (the first place a user looks for it)
    typed, other = enabled(nil, { ['*'] = 'Any' })
    assert(typed and other, '`*` = Any in neededFileStatus')
    typed, other = enabled(nil, { ['*'] = 'Any', [TYPED] = 'Opened' })
    assert(typed == false and other, 'a name the table lists keeps its own value, `*` is for the rest')
    typed, other = enabled(nil, { ['*'] = 'None', [OTHER] = 'Any' })
    assert(typed == false and other, '`*` = None turns the unlisted ones off, a listed one keeps its value')
    typed, other = enabled(nil, { ['*'] = 'Any', [TYPED] = 'Opened!' })
    assert(typed == false and other, 'a name with `!` keeps its value there too')
    -- (a listed alias of the name counts as listing the name; the alias is made up for this test)
    diagd.registerAlias('zz-status-alias-test', TYPED)
    typed, other = enabled(nil, { ['*'] = 'Any', ['zz-status-alias-test'] = 'Opened' })
    assert(typed == false and other, 'an alias the table lists keeps the value for its name')
    typed, other = enabled({ ['type-check'] = 'None' }, { ['*'] = 'Any' })
    assert(typed == false and other, 'a group setting still wins over `*` in neededFileStatus')
    typed, other = enabled({ ['*'] = 'None' }, { ['*'] = 'Any' })
    assert(typed == false and other == false, 'when both are set, groupFileStatus`s `*` is the one used')
    -- (compared with a table that lists a name nobody uses: a non-empty table is read together with what earlier tests left in the defaults)
    local typed0, other0 = enabled(nil, { ['zz-no-such-diagnostic'] = 'Any' })
    typed, other = enabled(nil, { ['*'] = 'Fallback' })
    assert(typed == typed0 and other == other0, '`*` = Fallback in neededFileStatus changes nothing')
end

config.set(nil, KEY, saved)
config.set(nil, NEEDED, savedNeeded)
for key, value in pairs(polluted) do
    live[key] = value
end
for name, original in pairs(silencedFunctions) do
    provider[name] = original
end
files.remove(uri)
