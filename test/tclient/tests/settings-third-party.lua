-- `Lua.workspace.userThirdParty` and `Lua.workspace.checkThirdParty`: a folder of third-party library descriptions
-- (`<name>/config.json` with `words` / `files`, and `<name>/library`) is scanned against the files of the workspace; when
-- one matches, `checkThirdParty` decides what happens: `Apply` / `ApplyInMemory` add the library to `Lua.workspace.library`,
-- `Disable` does nothing. The check runs with the workspace, so every case is a client of its own.
local lclient = require 'lclient'
local ws      = require 'workspace'
local config  = require 'config'
local furi    = require 'file-uri'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local await   = require 'await'

local BASE = fs.path(LOGPATH) / 'settings-third-party'
pcall((fs --[[@as any]]).remove_all, BASE)
local nl = string.char(10)
local BACKSLASH = string.char(92)

--- Make a workspace with one file and a folder of third-party descriptions with one library.
---@param name     string unique per case
---@param source   string the text of the workspace file
---@param filename string the name of the workspace file
---@param cfgJson  string the config.json of the library
---@return string root uri of the workspace
---@return string thirdDir the folder to give to `userThirdParty`
---@return string libraryDir the `library` folder that must be added
local function makeCase(name, source, filename, cfgJson)
    local dir      = BASE / name / 'workspace'
    local thirdDir = BASE / name / 'third'
    local libDir   = thirdDir / 'zebralib' / 'library'
    fs.create_directories(dir)
    fs.create_directories(libDir)
    util.saveFile((dir / filename):string(), source .. nl)
    util.saveFile((thirdDir / 'zebralib' / 'config.json'):string(), cfgJson)
    util.saveFile((libDir / 'zebra.lua'):string(), '---@meta' .. nl .. 'ZebraLib = {}' .. nl)
    local root = assert(furi.encode(dir:string()))
    return root, thirdDir:string(), (thirdDir / 'zebralib' / 'library'):string()
end

--- Start a client with these settings and say whether the library ended up in `Lua.workspace.library`.
---@param root     string
---@param settings table<string, any>
---@param library  string
---@return boolean
local function added(root, settings, library)
    local found = false
    ---@async
    lclient():start(function (client)
        client:registerFakers()
        client:register('workspace/configuration', function ()
            return { settings }
        end)
        client:initialize { rootUri = root }
        ws.awaitReady(root)
        await.sleep(3)
        for _, path in ipairs(config.get(root, 'Lua.workspace.library') --[[@as string[] ]]) do
            if path:gsub(BACKSLASH, '/') == library:gsub(BACKSLASH, '/') then
                found = true
            end
        end
    end)
    return found
end

--- The settings of a case: the description folder and what to do on a match.
---@param thirdDir string
---@param check    string
---@return table<string, any>
local function settingsOf(thirdDir, check)
    return {
        ['workspace.useGitIgnore']     = false,
        ['workspace.userThirdParty']   = { thirdDir },
        ['workspace.checkThirdParty']  = check,
    }
end

-- a word of the file matches: ApplyInMemory adds the library
do
    local root, third, library = makeCase('words-apply', 'local x = zebra3rd.run()', 'main.lua',
        '{ "words": [ "zebra3rd%.%w+" ] }')
    assert(added(root, settingsOf(third, 'ApplyInMemory'), library), 'a matching word adds the library')
end

-- the same match with Disable adds nothing
do
    local root, third, library = makeCase('words-disable', 'local x = zebra3rd.run()', 'main.lua',
        '{ "words": [ "zebra3rd%.%w+" ] }')
    assert(not added(root, settingsOf(third, 'Disable'), library), 'Disable: nothing is added')
end

-- no word of the file matches: nothing is added
do
    local root, third, library = makeCase('words-nomatch', 'local x = something.else()', 'main.lua',
        '{ "words": [ "zebra3rd%.%w+" ] }')
    assert(not added(root, settingsOf(third, 'ApplyInMemory'), library), 'no match: nothing is added')
end

-- the name of a file matches (`files`)
do
    local root, third, library = makeCase('files-apply', 'local x = 1', 'zebra3rdfile.lua',
        '{ "files": [ "zebra3rdfile%.lua" ] }')
    assert(added(root, settingsOf(third, 'ApplyInMemory'), library), 'a matching file name adds the library')
end

-- without `userThirdParty` the description folder is not read
do
    local root, third, library = makeCase('no-user-dir', 'local x = zebra3rd.run()', 'main.lua',
        '{ "words": [ "zebra3rd%.%w+" ] }')
    local settings = settingsOf(third, 'ApplyInMemory')
    settings['workspace.userThirdParty'] = {}
    assert(not added(root, settings, library), 'no description folder: nothing is added')
end

pcall((fs --[[@as any]]).remove_all, BASE)
