-- A library folder inside the workspace (the settings of a workspace that lists one of its own
-- folders in `Lua.workspace.library`): its files are reached by the scan of the workspace and by the
-- scan of the library. They are loaded and counted once, not twice ("Loading workspace 4022/4022"
-- for 3508 files), and they are still there for the library's users.
local lclient = require 'lclient'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local furi    = require 'file-uri'
local ws      = require 'workspace'
local files   = require 'files'

local rootPath = LOGPATH .. '/library-inside-workspace'
local rootUri  = furi.encode(rootPath)
local libPath  = rootPath .. '/lib'

fs.create_directories(fs.path(libPath))
util.saveFile(rootPath .. '/a.lua', 'A = 1')
util.saveFile(rootPath .. '/b.lua', 'B = 2')
util.saveFile(libPath .. '/one.lua', 'ONE = 1')
util.saveFile(libPath .. '/two.lua', 'TWO = 2')

---@async
lclient():start(function (client)
    client:registerFakers()

    client:register('workspace/configuration', function ()
        return {
            {
                ['workspace.library'] = { libPath },
            },
        }
    end)

    client:initialize {
        rootPath = rootPath,
        rootUri  = rootUri,
    }
    ws.awaitReady(rootUri)

    -- (the four files, and the meta files of the standard library the workspace loads too)
    local read, max = ws.getLoadingProcess(rootUri)
    local all = #files.getAllUris(rootUri)
    assert(max == all, ('%d files in all, counted %d'):format(all, max))
    assert(read == max, ('read %d of %d'):format(read, max))

    for _, name in ipairs { '/a.lua', '/b.lua', '/lib/one.lua', '/lib/two.lua' } do
        assert(files.getState(furi.encode(rootPath .. name)), name .. ' is loaded')
    end
end)
