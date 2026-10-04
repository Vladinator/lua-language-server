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

--- what `local function zzFlaggedFn` returns is flagged (a plugin tagging a function: the value of every call carries it)
vm.registerGenesisRule('function.return', function (source, node)
    local func = source.parent
    local holder = func and func.parent
    if holder and holder.type == 'local' and type(holder[1]) == 'string' and holder[1]:find('^zzFlaggedFn') then
        node:setFlag(FLAG)
    end
end)
--- ... and a local named `zzFlagged...` is flagged by its declaration, which stays true whatever is assigned to it
vm.registerFlagDeriver(FLAG, function (source)
    return source.type == 'local' and type(source[1]) == 'string' and source[1]:find('^zzFlagged') ~= nil
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
    '',
    'local function zzFlaggedFn() return 1 end',
    -- a value that carries the flag, then values that do not: the variable follows what it holds NOW
    'local inheritedA = zzFlaggedFn()',
    'inheritedA = 1',
    'local r_literalInt = inheritedA',
    'local inheritedB = zzFlaggedFn()',
    'inheritedB = "s"',
    'local r_literalStr = inheritedB',
    'local inheritedC = zzFlaggedFn()',
    'inheritedC = plain',
    'local r_variable = inheritedC',
    'local inheritedD = zzFlaggedFn()',
    'if plain > 1 then inheritedD = 1 else inheritedD = 2 end',
    'local r_branches = inheritedD',
    'local inheritedE = 1',
    'inheritedE = zzFlaggedFn()',
    'local r_flaggedLater = inheritedE',
    'local inheritedF = zzFlaggedFn()',
    'local r_untouched = inheritedF',
    -- a declaration that is flagged by itself stays flagged
    'local zzFlaggedDeclared = 1',
    'zzFlaggedDeclared = 2',
    'local r_declared = zzFlaggedDeclared',
}, string.char(10)) .. string.char(10)

local expected = {
    r_first    = true,   -- first argument
    r_second   = true,   -- a later argument of the same `T`: the type stays the first one's, the flag still arrives
    r_none     = false,
    r_same     = true,
    r_clean    = false,
    r_literalInt = false,
    r_literalStr = false,
    r_variable   = false,
    r_branches   = false,
    r_flaggedLater = true,
    r_untouched  = true,
    r_declared   = true,   -- the declaration itself is flagged: an assignment does not clear that
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
assert(seen == 12, 'every case was looked at: ' .. seen)

-- the type of `T` is the first candidate's, whatever the later arguments are (TypeScript's inference of one candidate)
guide.eachSourceType(state.ast, 'local', function (source)
    if source[1] == 'r_second' then
        assert(vm.getInfer(source):view(TESTURI) == 'integer', 'T keeps the type of the first argument')
    end
end)
files.remove(TESTURI)
