-- `## SavedVariables:` of a `.toc` file as known globals (Lua.workspace.tocSavedVariables)
---@class wow-toc.api
---@field parse      fun(text: string): table<string, true>
---@field clearCache fun()
---@type wow-toc.api
local toc    = require 'core.diagnostics.extra.wow-toc'
local config = require 'config'
local files  = require 'files'
local fs     = require 'bee.filesystem'
local core   = require 'core.diagnostics'

---@diagnostic disable: await-in-sync

-- the parser: the three directives in any case, comma / space separated, with or without spaces around the
-- `##` and the colon, other directives and comments ignored, several lines merged
do
    local vars = toc.parse('## Title: X\r\n## SavedVariables: A, B,C\n## savedvariablespercharacter:  D\n## SavedVariablesMachine: E F\n## Notes: SavedVariables: Z\nFile.lua\n')
    assert(vars.A and vars.B and vars.C and vars.D and vars.E and vars.F, 'all the listed names')
    assert(not vars.Z and not vars.X, 'not from other directives')
    assert(next(toc.parse('## Title: X\nFile.lua\n')) == nil)
    local tight = toc.parse('##SavedVariables:G,H\n##  SavedVariables : I\n# SavedVariables: J\n## SavedVariables: K\n')
    assert(tight.G and tight.H and tight.I and tight.K, 'no or extra spaces are read the same')
    assert(not tight.J, 'a single # is a comment')
end

-- the check: a `.toc` next to the file, the setting on and off, a file with no `.toc`, several flavors
local tocPath  = TESTROOT .. 'unittest.toc'
local tocPath2 = TESTROOT .. 'unittest_Classic.toc'

---@param script string
---@return string[]  the names reported by undefined-global / lowercase-global
local function reported(script)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    files.open(TESTURI)
    ---@type string[]
    local names = {}
    core(TESTURI, false, function (result)
        if result.code == 'undefined-global' or result.code == 'lowercase-global' then
            names[#names+1] = result.code .. ':' .. (result.message:match('`(.-)`') or '')
        end
    end)
    files.remove(TESTURI)
    table.sort(names)
    return names
end

---@param path string
---@param text string
local function write(path, text)
    local file = assert(io.open(path, 'wb'))
    file:write(text)
    file:close()
end

local script = 'print(MyDB, other, ClassicDB)\nmyDB2 = 1\n'
local createdDir = not fs.exists(fs.path(TESTROOT))
if createdDir then
    fs.create_directories(fs.path(TESTROOT))
end
write(tocPath, '## Title: Test\n## SavedVariables: MyDB, myDB2\nunittest.lua\n')
local ok, err = pcall(function ()
    toc.clearCache()
    config.set(nil, 'Lua.workspace.tocSavedVariables', false)
    local off = reported(script)
    assert(#off >= 3, 'setting off: all reported, got ' .. table.concat(off, ' '))
    config.set(nil, 'Lua.workspace.tocSavedVariables', true)
    toc.clearCache()
    local on = reported(script)
    assert(#on == 2 and on[1]:find('ClassicDB') and on[2]:find('other'),
        'setting on: only the undeclared ones, got ' .. table.concat(on, ' '))
    -- a second flavor file in the same folder adds its own variables
    write(tocPath2, '## SavedVariables: ClassicDB\n')
    toc.clearCache()
    local both = reported(script)
    assert(#both == 1 and both[1]:find('other'), 'two flavors: the union, got ' .. table.concat(both, ' '))
    -- without a .toc the setting changes nothing
    os.remove(tocPath)
    os.remove(tocPath2)
    toc.clearCache()
    local gone = reported(script)
    assert(#gone >= 3, 'no .toc: reported again, got ' .. table.concat(gone, ' '))
end)
config.set(nil, 'Lua.workspace.tocSavedVariables', false)
os.remove(tocPath)
os.remove(tocPath2)
if createdDir then
    fs.remove(fs.path(TESTROOT))
end
toc.clearCache()
assert(ok, err)
