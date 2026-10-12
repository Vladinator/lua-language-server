-- `Lua.language.fixIndent`: after an Enter that left whitespace, the server asks the client to take it away (`workspace/applyEdit`).
-- Needs the client option `fixIndents` as well; with either off nothing is asked. Run in process: the request is caught.
local config = require 'config'
local files  = require 'files'
local client = require 'client'
local proto  = require 'proto'
local fixIndent = require 'core.fix-indent'

local URI = 'file:///fix-indent-case.lua'

-- `local a = 1   ` + Enter (the editor inserted "\n  \n" at column 14, the text below is what the file is after the change)
local TEXT   = 'local a = 1   \n  \nlocal b = 2\n'
local CHANGE = { range = { start = { line = 0, character = 14 }, ['end'] = { line = 0, character = 14 } }, text = '\n  \n' }

---@param option boolean the client option `fixIndents`
---@param setting boolean `Lua.language.fixIndent`
---@return table[] the edits that were asked for
local function asked(option, setting)
    local savedInfo    = client.info
    local savedRequest = proto.request
    local savedSetting = config.get(nil, 'Lua.language.fixIndent')
    ---@type table[]
    local edits = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    ---@param method string
    ---@param params any
    proto.request = function (method, params)
        if method == 'workspace/applyEdit' then
            ---@type table[]
            local changes = params.edit.changes[URI] or {}
            for _, edit in ipairs(changes) do
                edits[#edits+1] = edit
            end
        end
    end
    client.info = { initializationOptions = { fixIndents = option }, clientInfo = { name = 'test' }, capabilities = {} }
    config.set(nil, 'Lua.language.fixIndent', setting)
    files.remove(URI)
    files.setText(URI, TEXT)
    fixIndent(URI, { CHANGE })
    files.remove(URI)
    config.set(nil, 'Lua.language.fixIndent', savedSetting)
    client.info = savedInfo
    proto.request = savedRequest
    return edits
end

local on = asked(true, true)
assert(#on == 1, 'option and setting on: the leftover spaces are taken away: ' .. #on)
assert(on[1].newText == '' and on[1].range.start.line == 0 and on[1].range.start.character == 11 and on[1].range['end'].character == 14,
    'the three spaces before the cursor go')

assert(#asked(true, false) == 0, 'setting off: nothing is asked')
assert(#asked(false, true) == 0, 'client option off: nothing is asked')
