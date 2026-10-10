-- A parameter type that carries a flag registered with `vm.registerBindAbsorbedFlag` binds the generic to the argument WITHOUT that flag
-- (`fn(v: secret<T>)`: wowlua-ls' "secret unwrap through a generic"); a plain `T` keeps it. The flag here is a fake one that only this test
-- registers, so the test passes with the whole extra/ folder removed (check_plugin_isolation.py --run).
local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'
require 'docfixture'

-- (`parser.object.fixtureType` is declared by generic-flags.lua)

local FLAG = 'zz-absorb-test-flag'

vm.registerPropagatingFlag(FLAG)
vm.registerBindAbsorbedFlag(FLAG)
--- a local named `zzFlagged...` carries the flag
vm.registerGenesisRule('local', function (source, node)
    local name = source[1]
    if type(name) == 'string' and name:find('^zzFlagged') then
        node:setFlag(FLAG)
    end
end)
--- a type written with the fixture's type keyword is flagged
vm.registerGenesisRule('doc.type', function (source, node)
    if source.fixtureType then
        node:setFlag(FLAG)
    end
end)

local script = table.concat({
    '---@generic T',
    '---@param v fixturetype T',
    '---@return T',
    'local function absorb(v) return v end',
    '',
    '---@generic T',
    '---@param v T',
    '---@return T',
    'local function keep(v) return v end',
    '',
    '---@generic T',
    '---@param plain T',
    '---@param v fixturetype T',
    '---@return T',
    'local function second(plain, v) return plain end',
    '',
    '---@generic T',
    '---@param v fixturetype T',
    '---@param plain T',
    '---@return T',
    'local function firstAbsorbs(v, plain) return plain end',
    '',
    'local zzFlaggedValue = 1',
    'local plain = 2',
    '',
    'local r_absorb      = absorb(zzFlaggedValue)',
    'local r_keep        = keep(zzFlaggedValue)',
    'local r_chain       = absorb(keep(zzFlaggedValue))',
    'local r_plainAbsorb = absorb(plain)',
    'local r_second      = second(zzFlaggedValue, 1)',
    'local r_secondFlag  = second(1, zzFlaggedValue)',
    'local r_firstAbs    = firstAbsorbs(zzFlaggedValue, plain)',
    'local r_firstBoth   = firstAbsorbs(plain, zzFlaggedValue)',
}, string.char(10)) .. string.char(10)

local expected = {
    r_absorb      = false,  -- the parameter absorbs the flag
    r_keep        = true,   -- a plain `T` keeps it
    r_chain       = false,  -- absorbed after being carried
    r_plainAbsorb = false,
    r_second      = true,   -- the first parameter is plain: its argument's flag comes out through `T`
    r_secondFlag  = false,  -- the later argument goes to the absorbing parameter
    r_firstAbs    = false,  -- the flagged argument goes to the absorbing parameter
    r_firstBoth   = true,   -- the plain parameter takes the flagged argument
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
assert(seen == 8, 'every case was looked at: ' .. seen)
files.remove(TESTURI)
