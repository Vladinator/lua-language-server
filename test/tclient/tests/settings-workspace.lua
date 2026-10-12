-- Which files the workspace loads: `Lua.workspace.ignoreDir`, `Lua.workspace.useGitIgnore`, `Lua.workspace.maxPreload`.
-- The settings are read when the workspace is loaded, so every case is a client of its own on the same folder on disk.
local lclient = require 'lclient'
local ws      = require 'workspace'
local files   = require 'files'
local furi    = require 'file-uri'
local fs      = require 'bee.filesystem'
local util    = require 'utility'

local DIR = fs.path(LOGPATH) / 'settings-workspace'
pcall((fs --[[@as any]]).remove_all, DIR)
fs.create_directories(DIR / 'skip')
fs.create_directories(DIR / 'deep' / 'keep')
local root = assert(furi.encode(DIR:string()))
local NAMES = {
    'keep.lua',
    'skip/ignored.lua',
    'by_git.lua',
    'deep/keep/inner.lua',
}
for _, name in ipairs(NAMES) do
    util.saveFile((DIR / name):string(), 'X = 1' .. string.char(10))
end
util.saveFile((DIR / '.gitignore'):string(), 'by_git.lua' .. string.char(10))

--- Start a client on the folder with these settings and say which of the files it loaded.
---@param settings table
---@return table<string, boolean>
local function loaded(settings)
    ---@type table<string, boolean>
    local found = {}
    ---@async
    lclient():start(function (client)
        client:registerFakers()
        client:register('workspace/configuration', function ()
            return { settings }
        end)
        client:initialize { rootUri = root }
        ws.awaitReady(root)
        for _, name in ipairs(NAMES) do
            found[name] = files.exists(root .. '/' .. name)
        end
    end)
    return found
end

---@param found table<string, boolean>
---@return integer
local function count(found)
    local n = 0
    for _, yes in pairs(found) do
        if yes then
            n = n + 1
        end
    end
    return n
end

-- nothing ignored: the git ignore file is on by default
local all = loaded { ['workspace.useGitIgnore'] = true, ['workspace.ignoreDir'] = {} }
assert(all['keep.lua'] and all['skip/ignored.lua'] and all['deep/keep/inner.lua'], 'plain files are loaded')
assert(not all['by_git.lua'], 'a file that .gitignore lists is not loaded (useGitIgnore on)')

-- useGitIgnore off: that file comes back
local noGit = loaded { ['workspace.useGitIgnore'] = false, ['workspace.ignoreDir'] = {} }
assert(noGit['by_git.lua'], 'a file that .gitignore lists is loaded again (useGitIgnore off)')

-- ignoreDir: a folder, and the same name deeper down is left alone by an anchored pattern
local ignored = loaded { ['workspace.useGitIgnore'] = true, ['workspace.ignoreDir'] = { '/skip' } }
assert(not ignored['skip/ignored.lua'], 'the folder in ignoreDir is not loaded')
assert(ignored['keep.lua'] and ignored['deep/keep/inner.lua'], 'the rest is loaded')
local unanchored = loaded { ['workspace.useGitIgnore'] = true, ['workspace.ignoreDir'] = { 'keep' } }
assert(not unanchored['deep/keep/inner.lua'], 'a folder name matches at any depth')

-- ignoreSubmodules: the folders a `.gitmodules` lists are skipped (on by default); off, they load
util.saveFile((DIR / '.gitmodules'):string(), '[submodule "vendor"]' .. string.char(10) .. '	path = submod' .. string.char(10))
fs.create_directories(DIR / 'submod')
util.saveFile((DIR / 'submod' / 'in.lua'):string(), 'X = 1' .. string.char(10))
NAMES[#NAMES+1] = 'submod/in.lua'
local withSubmodules = loaded { ['workspace.useGitIgnore'] = false, ['workspace.ignoreDir'] = {}, ['workspace.ignoreSubmodules'] = true }
assert(not withSubmodules['submod/in.lua'], 'ignoreSubmodules on: the submodule folder is not loaded')
assert(withSubmodules['keep.lua'], 'ignoreSubmodules on: the rest is')
local keepSubmodules = loaded { ['workspace.useGitIgnore'] = false, ['workspace.ignoreDir'] = {}, ['workspace.ignoreSubmodules'] = false }
assert(keepSubmodules['submod/in.lua'], 'ignoreSubmodules off: the submodule folder is loaded')

-- dofileRoots: the folders `dofile('name.lua')` is looked up in, outside the workspace too; their files are loaded
local DOF = fs.path(LOGPATH) / 'settings-workspace-dofile'
pcall((fs --[[@as any]]).remove_all, DOF)
fs.create_directories(DOF)
util.saveFile((DOF / 'rooted.lua'):string(), 'Y = 1' .. string.char(10))
---@param roots string[]
---@return boolean loaded
---@return integer found
local function dofileFrom(roots)
    local isLoaded, found = false, 0
    ---@async
    lclient():start(function (client)
        client:registerFakers()
        client:register('workspace/configuration', function ()
            return { { ['workspace.useGitIgnore'] = false, ['workspace.ignoreDir'] = {}, ['workspace.dofileRoots'] = roots } }
        end)
        client:initialize { rootUri = root }
        ws.awaitReady(root)
        isLoaded = files.exists(assert(furi.encode((DOF / 'rooted.lua'):string())))
        found = #ws.findUrisByDofile('rooted.lua', root .. '/keep.lua')
    end)
    return isLoaded, found
end
local rootLoaded, rootFound = dofileFrom { DOF:string() }
assert(rootLoaded and rootFound == 1, 'dofileRoots set: the file of the folder is loaded and dofile finds it: ' .. tostring(rootLoaded) .. ' ' .. rootFound)
local noRootLoaded, noRootFound = dofileFrom {}
assert(not noRootLoaded and noRootFound == 0, 'dofileRoots empty: neither: ' .. tostring(noRootLoaded) .. ' ' .. noRootFound)
pcall((fs --[[@as any]]).remove_all, DOF)

-- maxPreload: no more files than that are read when the workspace opens
local limited = loaded { ['workspace.useGitIgnore'] = false, ['workspace.ignoreDir'] = {}, ['workspace.maxPreload'] = 1 }
assert(count(limited) < count(noGit), 'maxPreload = 1 loads fewer files than the default: ' .. count(limited) .. ' of ' .. count(noGit))

pcall((fs --[[@as any]]).remove_all, DIR)
