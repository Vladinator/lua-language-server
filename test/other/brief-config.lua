-- The log line of a loaded configuration is a summary: a long list (the globals of a WoW project) or a huge table is written as its size,
-- not walked by `inspect` (about a second of every start).
local provider = require 'provider.provider'

local brief = provider.briefConfig

-- small values stay as they are
assert(brief(5) == 5 and brief('x') == 'x' and brief(true) == true, 'plain values')
local small = brief { Lua = { runtime = { version = 'Lua 5.4' }, diagnostics = { globals = { 'a', 'b' } } } }
assert(small.Lua.runtime.version == 'Lua 5.4' and small.Lua.diagnostics.globals[2] == 'b', 'a small configuration is copied')

-- a long list becomes its size, a list of exactly 20 stays
---@type string[]
local long = {}
for i = 1, 5000 do long[i] = 'Global' .. i end
assert(brief(long) == '<list of 5000 items>', 'a list of thousands: ' .. tostring(brief(long)))
---@type integer[]
local twenty = {}
for i = 1, 20 do twenty[i] = i end
assert(type(brief(twenty)) == 'table' and #brief(twenty) == 20, 'a list of 20 stays')

-- a map with many keys keeps them (the settings of one section), a huge one becomes its size
---@type table<string, string>
local map = {}
for i = 1, 300 do map['key' .. i] = 'Warning' end
assert(type(brief(map)) == 'table' and brief(map).key300 == 'Warning', 'a map of 300 entries is kept')
for i = 301, 500 do map['key' .. i] = 'Warning' end
assert(brief(map) == '<table of 500 entries>', 'a map of 500 entries: ' .. tostring(brief(map)))

-- a long list inside a section does not hide the rest of it
local section = brief { diagnostics = { globals = long, disable = { 'x' } }, runtime = { version = 'Lua 5.4' } }
assert(section.diagnostics.globals == '<list of 5000 items>', 'the long list is summarised in place')
assert(section.diagnostics.disable[1] == 'x' and section.runtime.version == 'Lua 5.4', 'its neighbours are kept')

-- a table that nests deeper than the limit is cut, not walked forever (a cycle would be one)
local cyclic = {}
cyclic.me = cyclic
local out = brief(cyclic)
assert(type(out) == 'table', 'a cyclic table ends')

-- the time: five thousand globals are summarised at once
local clock = os.clock()
brief { Lua = { diagnostics = { globals = long } } }
assert(os.clock() - clock < 0.2, 'summarising a configuration with thousands of globals is quick')
