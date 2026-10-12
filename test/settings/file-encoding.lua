-- `Lua.runtime.fileEncoding`: how the text of a file that is read from disk is decoded (a file the editor sends is already text).
-- The setting is read when a file is stored, so each case sets it, stores bytes, and reads the text back.
local config = require 'config'
local files  = require 'files'

local URI = 'file:///file-encoding-case.lua'

--- UTF-16 bytes of an ASCII text.
---@param text   string
---@param little boolean
---@return string
local function utf16(text, little)
    ---@type string[]
    local out = {}
    for i = 1, #text do
        local c = text:sub(i, i)
        out[#out+1] = little and (c .. '\0') or ('\0' .. c)
    end
    return table.concat(out)
end

---@param encoding string
---@param bytes    string
---@return string?
local function decoded(encoding, bytes)
    config.set(nil, 'Lua.runtime.fileEncoding', encoding)
    files.remove(URI)
    files.setText(URI, bytes)
    local text = files.getText(URI)
    files.remove(URI)
    return text
end

local saved = config.get(nil, 'Lua.runtime.fileEncoding')

assert(decoded('utf8', 'local x = 1') == 'local x = 1', 'utf8: the bytes are the text')
assert(decoded('utf16le', utf16('local x = 1', true)) == 'local x = 1', 'utf16le: two bytes per character, low byte first')
assert(decoded('utf16be', utf16('local x = 1', false)) == 'local x = 1', 'utf16be: two bytes per character, high byte first')
-- the wrong encoding does not give the text back
assert(decoded('utf8', utf16('local x = 1', true)) ~= 'local x = 1', 'utf16 bytes read as utf8 are not the text')
assert(decoded('utf16le', utf16('local x = 1', false)) ~= 'local x = 1', 'utf16be bytes read as utf16le are not the text')

config.set(nil, 'Lua.runtime.fileEncoding', saved)
