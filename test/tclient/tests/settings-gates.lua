-- The switches of the editor features: `Lua.hover.enable`, `Lua.completion.enable`, `Lua.signatureHelp.enable`, `Lua.codeLens.enable`.
-- Each answers while it is on and says nothing while it is off; a request the client sends anyway must not fail.
local lclient = require 'lclient'
local ws      = require 'workspace'
local config  = require 'config'
local furi    = require 'file-uri'

local uri = furi.encode('gates/test.lua')

local TEXT = table.concat({
    '---@param a integer',
    '---@param b string',
    'local function target(a, b) end',
    'local value = 1',
    'target(value, "x")',
    'target(',
    'val',
    '',
}, string.char(10))

---@async
lclient():start(function (client)
    client:registerFakers()
    client:initialize()
    ws.awaitReady()

    client:notify('textDocument/didOpen', {
        textDocument = { uri = uri, languageId = 'lua', version = 1, text = TEXT },
    })

    --- The result of a request with a setting on and off.
    ---@async
    ---@param key    string
    ---@param method string
    ---@param params table
    ---@return any on
    ---@return any off
    local function both(key, method, params)
        config.set(uri, key, true)
        local on = client:awaitRequest(method, params)
        config.set(uri, key, false)
        local off = client:awaitRequest(method, params)
        return on, off
    end

    local position = { textDocument = { uri = uri }, position = { line = 4, character = 8 } }

    -- hover
    local hoverOn, hoverOff = both('Lua.hover.enable', 'textDocument/hover', position)
    assert(hoverOn and hoverOn.contents, 'hover answers while it is on')
    assert(hoverOff == nil, 'hover says nothing while it is off')
    config.set(uri, 'Lua.hover.enable', true)

    -- completion (after `val`: the local `value`)
    local completeParams = { textDocument = { uri = uri }, position = { line = 6, character = 3 } }
    local completeOn, completeOff = both('Lua.completion.enable', 'textDocument/completion', completeParams)
    ---@param result any
    ---@return table<string, boolean>
    local function labels(result)
        ---@type table[]
        local items = result and (result.items or result) or {}
        ---@type table<string, boolean>
        local found = {}
        for _, item in ipairs(items) do
            found[item.label] = true
        end
        return found
    end
    assert(labels(completeOn).value, 'completion offers the local while it is on')
    assert(next(labels(completeOff)) == nil, 'completion offers nothing while it is off')
    config.set(uri, 'Lua.completion.enable', true)

    -- signature help (inside the call `target(` on line 6)
    local signatureParams = { textDocument = { uri = uri }, position = { line = 5, character = 7 } }
    local signatureOn, signatureOff = both('Lua.signatureHelp.enable', 'textDocument/signatureHelp', signatureParams)
    assert(signatureOn and signatureOn.signatures and #signatureOn.signatures > 0, 'signature help answers while it is on')
    assert(signatureOff == nil or not signatureOff.signatures or #signatureOff.signatures == 0, 'signature help says nothing while it is off')
    config.set(uri, 'Lua.signatureHelp.enable', true)

    -- code lens (off by default): the reference counts of a definition
    local lensParams = { textDocument = { uri = uri } }
    assert(config.get(uri, 'Lua.codeLens.enable') == false, 'code lens is off by default')
    local lensOn, lensOff = both('Lua.codeLens.enable', 'textDocument/codeLens', lensParams)
    assert(lensOn and #lensOn > 0, 'code lens answers while it is on')
    assert(lensOff == nil or #lensOff == 0, 'code lens says nothing while it is off')
    config.set(uri, 'Lua.codeLens.enable', false)

    client:notify('textDocument/didClose', { textDocument = { uri = uri } })
end)
