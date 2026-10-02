-- The types `require` and `dofile` give: the first return is what the target file returns, the second
-- return of `require` is the loader data (`unknown` from Lua 5.3, `nil` before), a missing target is
-- unknown. These branches of vm/compiler.lua were executed by no test.
local files  = require 'files'
local guide  = require 'parser.guide'
local vm     = require 'vm'
local config = require 'config'
local furi   = require 'file-uri'

local modUri = furi.encode(TESTROOT .. 'requiredofile_mod.lua')

--- The view of each local of `script`, by name, with `version` as the runtime version.
---@param script  string
---@param version string
---@return table<string, string>
local function viewsOf(script, version)
    config.set(nil, 'Lua.runtime.version', version)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    files.compileState(TESTURI)
    local state = assert(files.getState(TESTURI))
    ---@type table<string, string>
    local views = {}
    guide.eachSource(state.ast, function (src)
        if src.type == 'local' then
            views[tostring(src[1])] = vm.getInfer(src):view(TESTURI)
        end
    end)
    files.remove(TESTURI)
    config.set(nil, 'Lua.runtime.version', nil)
    return views
end

files.setText(modUri, 'return 1, "x"\n')
files.compileState(modUri)

local script = table.concat({
    "local a, b = dofile('requiredofile_mod.lua')",
    "local m, extra, third = require 'requiredofile_mod'",
    "local missing = dofile('requiredofile_nothing.lua')",
    "local none = require 'requiredofile_nothing'",
}, string.char(10)) .. string.char(10)

do
    local views = viewsOf(script, 'Lua 5.4')
    assert(views.a == 'integer' and views.b == 'string', 'dofile: the file\'s returns, in order')
    assert(views.m == 'integer', 'require: the first return')
    assert(views.extra == 'unknown', 'require: loader data is unknown from 5.3 on: ' .. views.extra)
    assert(views.third == 'nil', 'require: nothing after that')
    assert(views.missing == 'unknown', 'dofile of a file that is not there')
end

do
    local views = viewsOf(script, 'Lua 5.1')
    assert(views.m == 'integer')
    assert(views.extra == 'nil', 'before 5.3 require returns one value: ' .. views.extra)
    assert(views.third == 'nil')
end

files.remove(modUri)
