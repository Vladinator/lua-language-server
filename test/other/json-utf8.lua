-- The JSON the server writes (messages to the client, the --check report) is always valid UTF-8: a string that quotes a file saved as Latin-1 or CP1252
-- (old addons are full of them) has every byte that is not part of a character replaced by U+FFFD. Valid strings are untouched.
local json = require 'json'
require 'json-beautify'

local REPLACEMENT = string.char(0xEF, 0xBF, 0xBD)
local e_acute     = string.char(0xE9)                      -- Latin-1 'e acute': a lead byte of a three-byte sequence, alone
local thousand    = string.char(0xE5, 0x8D, 0x83)          -- a valid three-byte character

---@param s string
---@return string
local function encoded(s)
    local out = json.encode({ value = s })
    assert(out, 'encode failed')
    assert(utf8.len(out), 'the JSON is not valid UTF-8')
    return out
end

local function wrapped(s)
    return '{"value":"' .. s .. '"}'
end

-- valid strings stay as they are
assert(encoded('plain') == wrapped('plain'))
assert(encoded(thousand) == wrapped(thousand))
assert(encoded('a' .. thousand .. 'b') == wrapped('a' .. thousand .. 'b'))
assert(encoded('') == wrapped(''))
local BS = string.char(92)
assert(encoded('quote" and ' .. BS .. ' and tab' .. string.char(9)) == wrapped('quote' .. BS .. '" and ' .. BS .. BS .. ' and tab' .. BS .. 't'))

-- invalid bytes become U+FFFD, one per byte that belongs to no character
assert(encoded('caf' .. e_acute) == wrapped('caf' .. REPLACEMENT))
assert(encoded('caf' .. e_acute .. ' cr' .. string.char(0xE8) .. 'me') == wrapped('caf' .. REPLACEMENT .. ' cr' .. REPLACEMENT .. 'me'))
assert(encoded(string.char(0xFF, 0xFE)) == wrapped(REPLACEMENT .. REPLACEMENT))
assert(encoded('a' .. string.char(0x80) .. 'b') == wrapped('a' .. REPLACEMENT .. 'b'))                 -- a stray continuation byte
assert(encoded(thousand .. string.char(0xE5, 0x8D)) == wrapped(thousand .. REPLACEMENT .. REPLACEMENT)) -- a character cut short
assert(encoded(string.char(0xC0, 0xAF)) == wrapped(REPLACEMENT .. REPLACEMENT))                         -- an overlong form

-- the beautified form (the --check report) too
local beautify = json.beautify
assert(beautify, 'json-beautify.lua adds json.beautify')
local pretty = beautify({ message = 'Duplicate index `caf' .. e_acute .. '`.' })
assert(utf8.len(pretty), 'the beautified JSON is not valid UTF-8')
assert(pretty:find(REPLACEMENT, 1, true))
