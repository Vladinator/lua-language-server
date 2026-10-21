-- Text that is not valid UTF-8 (a file in another encoding, or damage) must never make the
-- column arithmetic throw: the utf16 codecs replace what they cannot read.
local encoder = require 'encoder'

-- a well formed character followed by a stray continuation byte used to raise
-- "invalid UTF-8 code" (utf8.codes checks what follows a character)
assert(encoder.len('utf16', 'a\x80b') == 3)
assert(encoder.len('utf16', '\xC3\xA9\x80') == 2)          -- é, then a stray byte
assert(encoder.len('utf16', 'x\xE2\x82\xAC\xBFy') == 4)    -- €, stray continuation, y
assert(math.type(encoder.offset('utf16', 'a\x80b', 3)) == 'integer')   -- lands after the 3 byte replacement character
assert(encoder.len('utf16', '\xFF\xFE') == 2)
assert(encoder.len('utf16', '\xF0\x9F\x98\x80') == 2)      -- one astral character is two UTF-16 units
assert(encoder.len('utf16', '') == 0)

-- every spelling of the little-endian UTF-16 counts the same (`len` compared `utf16` twice and knew no `utf16le`: found by impossible-comparison)
assert(encoder.len('utf16le', 'abc') == 3)
assert(encoder.len('utf16le', '\xC3\xA9') == 1)
assert(encoder.len('utf16le', '\xF0\x9F\x98\x80') == 2)
assert(encoder.len('utf16le', 'a\x80b') == encoder.len('utf16', 'a\x80b'))
assert(encoder.len('utf16be', 'abc') == 3)
assert(encoder.len('utf8', '\xC3\xA9') == 1)
