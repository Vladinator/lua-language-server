local files = require 'files'
local vm    = require 'vm'

---@diagnostic disable: await-in-sync

-- A global is named by a string. `_G[1]` (an integer key) declares none; `_G.a`, `_G['b']` and the plain `c = 1` still do.

files.setText(TESTURI, [[
_G[1] = 5
_G.gnka = 1
_G['gnkb'] = 2
gnkc = 3
]])
files.compileState(TESTURI)

---@type table<string|integer, boolean>
local names = {}
for _, global in ipairs(vm.getGlobals 'variable') do
    names[global:getName()] = true
end
files.remove(TESTURI)

assert(not names['1'] and not names[1], 'a global named with the integer key of _G[1]')
assert(names['gnka'], '_G.a is a global')
assert(names['gnkb'], "_G['b'] is a global")
assert(names['gnkc'], 'a plain assignment is a global')
