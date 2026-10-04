-- Generic resolution carries the registered node flags (vm/flags.lua) of the arguments into what `T` stands for, without
-- knowing what any flag means. The flag here is a fake one that only this test registers, so the test passes with the
-- whole extra/ folder removed (check_plugin_isolation.py --run).
--
-- * `T` is bound by the FIRST argument that mentions it (the type of `T`, TypeScript's first candidate), but a flag on a
--   later argument still comes out through `T`;
-- * nothing is flagged where nothing was.
local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'

local FLAG = 'zz-generic-test-flag'

--- a local named `zzFlagged...` carries the flag, like a plugin tagging a declaration
vm.registerPropagatingFlag(FLAG)
vm.registerGenesisRule('local', function (source, node)
    local name = source[1]
    if type(name) == 'string' and name:find('^zzFlagged') then
        node:setFlag(FLAG)
    end
end)

local script = table.concat({
    '---@generic T',
    '---@param first T',
    '---@param second T',
    '---@return T',
    'local function pick(first, second) return first end',
    '',
    '---@generic T',
    '---@param value T',
    '---@return T',
    'local function same(value) return value end',
    '',
    'local zzFlaggedValue = 1',
    'local plain = 2',
    '',
    'local r_first  = pick(zzFlaggedValue, 1)',
    'local r_second = pick(1, zzFlaggedValue)',
    'local r_none   = pick(1, plain)',
    'local r_same   = same(zzFlaggedValue)',
    'local r_clean  = same(plain)',
}, string.char(10)) .. string.char(10)

local expected = {
    r_first    = true,   -- first argument
    r_second   = true,   -- a later argument of the same `T`: the type stays the first one's, the flag still arrives
    r_none     = false,
    r_same     = true,
    r_clean    = false,
}

files.setText(TESTURI, script)
local state = assert(files.getState(TESTURI))
local seen = 0
guide.eachSourceType(state.ast, 'local', function (source)
    local name = source[1]
    if type(name) == 'string' and expected[name] ~= nil then
        seen = seen + 1
        local flagged = vm.compileNode(source):hasFlag(FLAG)
        assert(flagged == expected[name],
            ('%s: flag %s, expected %s'):format(name, tostring(flagged), tostring(expected[name])))
    end
end)
assert(seen == 5, 'every case was looked at: ' .. seen)

-- the type of `T` is the first candidate's, whatever the later arguments are (TypeScript's inference of one candidate)
guide.eachSourceType(state.ast, 'local', function (source)
    if source[1] == 'r_second' then
        assert(vm.getInfer(source):view(TESTURI) == 'integer', 'T keeps the type of the first argument')
    end
end)
files.remove(TESTURI)
