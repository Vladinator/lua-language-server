-- `Lua.window.progressBar` and `Lua.window.statusBar`: whether the server asks the client for progress bars and whether it shows its
-- status bar item. A client that has the status bar option gets `$/status/show` and `$/status/hide` as the setting changes.
local lclient = require 'lclient'
local ws      = require 'workspace'
local config  = require 'config'
local furi    = require 'file-uri'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local await   = require 'await'
local progress = require 'progress'
local client_  = require 'client'

local DIR = fs.path(LOGPATH) / 'settings-window'
pcall((fs --[[@as any]]).remove_all, DIR)
fs.create_directories(DIR)
local nl = string.char(10)
for i = 1, 30 do
    util.saveFile((DIR / ('f' .. i .. '.lua')):string(), 'local x = ' .. i .. nl .. 'print(x)' .. nl)
end
local root = assert(furi.encode(DIR:string()))

-- progress bars: asked for while the setting is on, never while it is off
---@param progressBar boolean
---@return integer how many progress tokens the server asked the client to create
local function progressRequests(progressBar)
    local created = 0
    ---@async
    lclient():start(function (client)
        client:registerFakers()
        client:register('workspace/configuration', function ()
            return { { ['window.progressBar'] = progressBar, ['workspace.useGitIgnore'] = false } }
        end)
        client:register('window/workDoneProgress/create', function ()
            created = created + 1
            return nil
        end)
        client:initialize { rootUri = root }
        ws.awaitReady(root)
        await.sleep(1)
        -- (a progress of our own, shown at once: the ones of the server itself depend on how long its work takes)
        local before = created
        local prog = progress.create(root, 'settings-window test', 0)
        prog:setMessage('working')
        await.sleep(0.5)
        prog:remove()
        created = created - before
    end)
    return created
end

local withBar    = progressRequests(true)
local withoutBar = progressRequests(false)
assert(withBar > 0, 'the progress bar is asked for while the setting is on')
assert(withoutBar == 0, 'no progress bar is asked for while it is off: ' .. withoutBar)

-- status bar: shown while on, hidden when switched off, shown again when switched back on
do
    ---@type string[]
    local events = {}
    ---@async
    lclient():start(function (client)
        client:registerFakers()
        client:register('$/status/show', function ()
            events[#events+1] = 'show'
            return nil
        end)
        client:register('$/status/hide', function ()
            events[#events+1] = 'hide'
            return nil
        end)
        client:initialize { rootUri = root }
        ws.awaitReady(root)
        -- (the client option is read where the server keeps what the client sent; the test client has no way to add one)
        client_.info.initializationOptions.statusBar = true
        await.sleep(1)
        config.set(nil, 'Lua.window.statusBar', false)
        await.sleep(1)
        config.set(nil, 'Lua.window.statusBar', true)
        await.sleep(1)
        -- off for the workspace only: the bar is hidden although the global setting says on
        config.set(root, 'Lua.window.statusBar', false)
        await.sleep(1)
    end)
    local joined = table.concat(events, ',')
    -- off (global) hides, on again shows, off for the workspace only hides again although the global setting says on
    assert(joined:find('hide,show,hide$'), 'the status bar follows the setting: ' .. joined)
end

pcall((fs --[[@as any]]).remove_all, DIR)
