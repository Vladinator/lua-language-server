-- A setting that appears for the first time in a later configuration (a `.luarc.json` that is created while the server runs, a client that sends only the
-- settings the user changed) is a change like any other: the watchers hear of it, so what depends on it (the diagnostics, the workspace) is refreshed.
-- A client that sends every setting never showed the gap, because there the key was always there already.
local lclient = require 'lclient'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local furi    = require 'file-uri'
local ws      = require 'workspace'
local config  = require 'config'
local await   = require 'await'

local rootPath = LOGPATH .. '/config-new-key'
local rootUri  = furi.encode(rootPath)

fs.create_directories(fs.path(rootPath))
util.saveFile(rootPath .. '/a.lua', 'local x = 1\n')

---@async
lclient():start(function (client)
    client:registerFakers()
    client:initialize {
        rootPath = rootPath,
        rootUri  = rootUri,
    }
    ws.awaitReady(rootUri)

    local scp = ws.getFirstScope()
    ---@type { key: string, value: any, old: any }[]
    local events = {}
    local recording = true
    config.watch(function (_, key, value, oldValue)
        if recording and key == 'Lua.diagnostics.disable' then
            events[#events+1] = { key = key, value = value, old = oldValue }
        end
    end)

    local function names(list)
        return table.concat(list or {}, ',')
    end

    -- nothing set so far (the fake client sends no settings): the first value that differs from the default is heard
    config.update(scp, {})
    await.sleep(0.2)
    events = {}
    config.update(scp, { Lua = { diagnostics = { disable = { 'unused-local' } } } })
    await.sleep(0.2)
    assert(#events == 1, ('a new setting: one event, got %d'):format(#events))
    assert(names(events[1].value) == 'unused-local' and names(events[1].old) == '', ('the event carries the new value and the default as the old one, got %s / %s'):format(names(events[1].value), tostring(events[1].old and #events[1].old)))

    -- the same again: nothing changed
    events = {}
    config.update(scp, { Lua = { diagnostics = { disable = { 'unused-local' } } } })
    await.sleep(0.2)
    assert(#events == 0, ('the same setting again: no event, got %d'):format(#events))

    -- a setting that goes away is heard as before
    config.update(scp, {})
    await.sleep(0.2)
    assert(#events == 1 and names(events[1].value) == '' and names(events[1].old) == 'unused-local', 'a setting that goes away: one event')

    -- a new setting that is the default is not a change
    events = {}
    config.update(scp, { Lua = { diagnostics = { disable = {} } } })
    await.sleep(0.2)
    assert(#events == 0, ('a new setting equal to the default: no event, got %d'):format(#events))

    recording = false
    config.update(scp, {})
end)
