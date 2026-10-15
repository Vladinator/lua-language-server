local lclient = require 'lclient'
local ws      = require 'workspace'

-- the item that fits the parameter the cursor is at is sent with `preselect`, the others are not
---@async
lclient():start(function (client)
    client:registerFakers()
    client:initialize()

    client:notify('textDocument/didOpen', {
        textDocument = {
            uri = 'file://preselect.lua',
            languageId = 'lua',
            version = 0,
            text = [[
---@param s string
local function takes(s) end
local vara = 1
local varb = "x"
takes(var)
]]
        }
    })

    ws.awaitReady()

    local completions = client:awaitRequest('textDocument/completion', {
        textDocument = { uri = 'file://preselect.lua' },
        position = { line = 4, character = 9 },
    })

    ---@type table<string, boolean?>
    local preselected = {}
    for _, item in ipairs(completions.items --[[@as {label: string, preselect: boolean?}[] ]]) do
        preselected[item.label] = item.preselect
    end
    assert(preselected['varb'] == true, 'the string variable is preselected')
    assert(preselected['vara'] == nil, 'the number variable is not')
end)
