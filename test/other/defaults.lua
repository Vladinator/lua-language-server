-- The defaults this fork chose on purpose (it is never merged back, so it does not keep the original LuaLS ones). A revert of one of
-- them changes what every user sees, so it must be a decision, not an accident.
local template   = require 'config.template'
local diagnostic = require 'proto.diagnostic'

local function default(key)
    local unit = assert(template[key], 'unknown setting: ' .. key)
    return unit.default
end

assert(default 'Lua.type.checkFieldNilArguments' == true, 'a nil field passed as an argument is checked by default')
assert(default 'Lua.type.castNumberToInteger' == true, 'a number fits an integer by default (the original LuaLS, kept on purpose)')
assert(default 'Lua.type.weakUnionCheck' == false, 'a union fits only when every member does')
assert(default 'Lua.type.weakNilCheck' == false, 'nil is checked')
assert(default 'Lua.workspace.preloadFileSize' == 2000, 'a source file of two megabytes is still read (the original 500 skipped real addon files of 850 KB)')
assert(diagnostic.getDefaultStatus()['nil-index'] == 'Opened', 'a possibly-nil key is reported by default')
