-- The generic hooks and registries the plugins use, tested with fake names and without any plugin (so they still
-- hold with the whole `extra/` folder removed): the diagnostic alias registry, `vm.registerGlobalProvider`,
-- `vm.registerMainVarargProvider`, the folder lookup cache of the scopes, the config version that the type-check
-- cache follows, and the dialect lists of the doc tags.
local config  = require 'config'
local files   = require 'files'
local core    = require 'core.diagnostics'
local diagd   = require 'proto.diagnostic'
local docTags = require 'parser.docTags'
local scope   = require 'workspace.scope'
local guide   = require 'parser.guide'
local vm      = require 'vm'

---@diagnostic disable: await-in-sync

--- The `code: message` of what the diagnostics report for `script` (open file, every diagnostic of `codes`).
---@param script string
---@param codes  table<string, true>
---@return string[]
local function reported(script, codes)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    files.open(TESTURI)
    ---@type string[]
    local found = {}
    core(TESTURI, false, function (result)
        if codes[result.code or ''] then
            found[#found+1] = (result.code or '') .. ': ' .. result.message
        end
    end)
    files.remove(TESTURI)
    table.sort(found)
    return found
end

-- ## diagnostic aliases ------------------------------------------------------------------------------------------

diagd.registerAlias('zz-test-alias', 'unused-local')
assert(diagd.resolveAlias('zz-test-alias') == 'unused-local')
assert(diagd.resolveAlias('unused-local') == 'unused-local', 'a canonical name stays itself')
assert(diagd.resolveAlias('no-such-diagnostic') == 'no-such-diagnostic', 'an unknown name stays itself')
local aliases = diagd.aliasesOf('unused-local')
assert(#aliases >= 1 and aliases[1] ~= nil, 'the alias is listed under its canonical name')
local listed = false
for _, name in ipairs(aliases) do
    listed = listed or name == 'zz-test-alias'
end
assert(listed)
assert(#diagd.aliasesOf('param-type-mismatch') >= 0 and diagd.aliasesOf('no-such-diagnostic')[1] == nil)
-- the names a settings table takes as key and the names `---@diagnostic` knows
---@type table<string, true>
local keyNames = {}
for _, name in ipairs(diagd.getDiagAndAliasNames()) do
    keyNames[name] = true
end
assert(keyNames['zz-test-alias'] and keyNames['unused-local'], 'alias and canonical are valid keys')
assert(diagd.getDiagAndErrNameMap()['zz-test-alias'], 'a known name for unknown-diag-code')
assert(not diagd.getDiagAndErrNameMap()['zz-test-alias-typo'])

local UNUSED = { ['unused-local'] = true, ['unknown-diag-code'] = true }
local unusedScript = 'local unusedVariable = 1\n'
assert(#reported(unusedScript, UNUSED) == 1, 'unused-local reports without a suppression')
assert(#reported('---@diagnostic disable-next-line: zz-test-alias\n' .. unusedScript, UNUSED) == 0,
    'the alias in a comment silences the canonical diagnostic and is no unknown code')
assert(#reported('---@diagnostic disable-next-line: zz-test-alias-typo\n' .. unusedScript, UNUSED) == 2,
    'a near miss is an unknown code and silences nothing')
local disable = config.get(nil, 'Lua.diagnostics.disable')
config.set(nil, 'Lua.diagnostics.disable', { 'zz-test-alias' })
assert(#reported(unusedScript, UNUSED) == 0, 'the alias in diagnostics.disable')
config.set(nil, 'Lua.diagnostics.disable', disable)
assert(#reported(unusedScript, UNUSED) == 1, 'enabled again')

-- ## known globals of a plugin -----------------------------------------------------------------------------------

local providerOn = false
vm.registerGlobalProvider(function (_uri, name)
    return providerOn and (name == 'ZzProvidedGlobal' or name == 'zzProvidedLower')
end)
local GLOBALS = { ['undefined-global'] = true, ['lowercase-global'] = true, ['global-element'] = true }
local globalScript = 'print(ZzProvidedGlobal, ZzOther)\nzzProvidedLower = 1\n'
providerOn = false
local without = reported(globalScript, GLOBALS)
local mentionsProvided = false
for _, line in ipairs(without) do
    mentionsProvided = mentionsProvided or line:find('ZzProvidedGlobal', 1, true) ~= nil
end
assert(mentionsProvided and #without >= 3, 'no provider answer: both provided names and the other one are reported, got ' .. table.concat(without, ' | '))
providerOn = true
local withProvider = reported(globalScript, GLOBALS)
for _, line in ipairs(withProvider) do
    assert(not line:find('ZzProvidedGlobal', 1, true) and not line:find('zzProvidedLower', 1, true), 'a provided global is known: ' .. line)
end
local stillOther = false
for _, line in ipairs(withProvider) do
    stillOther = stillOther or line:find('ZzOther', 1, true) ~= nil
end
assert(stillOther, 'a name the provider does not know is still undefined')
providerOn = false
assert(vm.isProvidedGlobal(TESTURI, 'ZzProvidedGlobal') == false)

-- ## the arguments of a file -------------------------------------------------------------------------------------

local varargsOn = false
vm.registerMainVarargProvider(function (_uri, index)
    if not varargsOn then
        return nil
    end
    -- (a quoted name is a string literal type)
    return index == 1 and 'string' or index == 2 and 'table' or index == 3 and '"Zz"' or nil
end)

---@param script string
---@return table<string, string>
local function typesOf(script)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    local state = assert(files.getState(TESTURI))
    ---@type table<string, string>
    local result = {}
    guide.eachSourceType(state.ast, 'local', function (source)
        local name = source[1]
        if type(name) == 'string' then
            result[name] = vm.getInfer(source):view(TESTURI)
        end
    end)
    files.remove(TESTURI)
    return result
end

local varargScript = 'local a, b, c = ...\nlocal function f(...)\n    local inner = ...\n    return inner\nend\nreturn a, b, c, f\n'
varargsOn = false
local off = typesOf(varargScript)
assert(off.a == 'unknown' and off.b == 'unknown', 'no provider answer: unknown as before')
varargsOn = true
local on = typesOf(varargScript)
assert(on.a == 'string' and on.b == 'table', 'positions 1 and 2: ' .. tostring(on.a) .. ' ' .. tostring(on.b))
assert(on.c == '"Zz"', 'a quoted name is a literal: ' .. tostring(on.c))
local fourth = typesOf('local a, b, c, d = ...\nreturn a, b, c, d\n')
assert(fourth.d == 'unknown', 'a position nobody answers stays unknown')
assert(on.inner == 'unknown', "a function's own `...` is not the file's")
local selected = typesOf('local ns = select(2, ...)\nreturn ns\n')
assert(selected.ns == 'table', '`select(2, ...)`, the usual way to take the second one: ' .. tostring(selected.ns))
varargsOn = false

-- ## folder lookup cache -----------------------------------------------------------------------------------------

do
    local outerUri = 'file:///zz-scope-test/outer'
    local innerUri = 'file:///zz-scope-test/outer/inner'
    local outer = scope.createFolder(outerUri, 'outer')
    local inner = scope.createFolder(innerUri, 'inner')
    local inInner = innerUri .. '/a.lua'
    local inOuter = outerUri .. '/b.lua'
    local outside = 'file:///zz-scope-test/elsewhere/c.lua'
    local ok, err = pcall(function ()
        assert(scope.getFolder(inInner) == inner, 'the longest folder wins')
        assert(scope.getFolder(inOuter) == outer)
        assert(scope.getFolder(outside) == nil)
        assert(scope.getFolder(inInner) == inner and scope.getFolder(outside) == nil, 'asked again (cached)')
        -- a folder created later is seen at once, also for an answer that was cached as "none"
        local late = scope.createFolder('file:///zz-scope-test/elsewhere', 'late')
        assert(scope.getFolder(outside) == late, 'a new folder invalidates the cache')
        late:remove()
        assert(scope.getFolder(outside) == nil, 'a removed folder invalidates the cache')
        inner:remove()
        assert(scope.getFolder(inInner) == outer, 'after the inner folder is gone the outer one owns the uri')
        ---@type any
        local noUri = nil
        assert(scope.getFolder(noUri) == nil, 'no uri, no folder')
    end)
    outer:remove()
    inner:remove()
    assert(ok, err)
    assert(scope.getFolder(inOuter) == nil)
end

-- ## config version, and the type-check settings that follow it --------------------------------------------------

do
    local before = config.version
    local old = config.get(nil, 'Lua.type.weakNilCheck')
    config.set(nil, 'Lua.type.weakNilCheck', not old)
    assert(config.version > before, 'a change bumps the version at once (the watch events come later)')
    config.set(nil, 'Lua.type.weakNilCheck', old)
    local same = config.version
    config.set(nil, 'Lua.type.weakNilCheck', old)
    assert(config.version == same, 'setting the same value again changes nothing')
end

do
    -- the argument check reads weakNilCheck through a cache: the answer must follow the setting in the same tick
    local MISMATCH = { ['param-type-mismatch'] = true }
    local script = '---@param x number\nlocal function f(x) end\n---@type number?\nlocal n\nf(n)\n'
    local old = config.get(nil, 'Lua.type.weakNilCheck')
    local oldUnion = config.get(nil, 'Lua.type.weakUnionCheck')
    config.set(nil, 'Lua.type.weakUnionCheck', false)
    local ok, err = pcall(function ()
        config.set(nil, 'Lua.type.weakNilCheck', false)
        local strict = #reported(script, MISMATCH)
        config.set(nil, 'Lua.type.weakNilCheck', true)
        local weak = #reported(script, MISMATCH)
        config.set(nil, 'Lua.type.weakNilCheck', false)
        local strictAgain = #reported(script, MISMATCH)
        assert(strict == 1 and weak == 0 and strictAgain == 1,
            ('weakNilCheck false / true / false: %d / %d / %d (1 / 0 / 1 expected)'):format(strict, weak, strictAgain))
    end)
    config.set(nil, 'Lua.type.weakNilCheck', old)
    config.set(nil, 'Lua.type.weakUnionCheck', oldUnion)
    assert(ok, err)
end

-- ## dialects of the doc tags ------------------------------------------------------------------------------------

do
    local default = docTags.getTagFlavors('zz-test-tag-nobody-declared')
    assert(#default == 1 and default[1] == 'luals', 'a tag that does not say is `luals` only')
    docTags.setTagFlavors('zz-test-tag', { 'luals', 'wowluals' })
    local set = docTags.getTagFlavors('zz-test-tag')
    assert(#set == 2 and set[1] == 'luals' and set[2] == 'wowluals')
    local keyword = docTags.getKeywordFlavors('zz-test-keyword-nobody-declared')
    assert(#keyword == 1 and keyword[1] == 'luals')
    docTags.setKeywordFlavors('zz-test-keyword', { 'wowluals' })
    assert(docTags.getKeywordFlavors('zz-test-keyword')[1] == 'wowluals')
end

-- ## built-in text rewrites --------------------------------------------------------------------------------------

do
    local plugin = require 'plugin'
    local rewriteOn = false
    -- the text `ZZ_BUILTIN_SOURCE` becomes the declaration of a local, while the hook is on
    plugin.registerBuiltin {
        OnSetText = function (_uri, text)
            if not rewriteOn then
                return nil
            end
            local first, last = text:find('ZZ_BUILTIN_SOURCE', 1, true)
            if not first then
                return nil
            end
            return { { start = first, finish = last, text = 'local zzFromBuiltin = 1' } }
        end,
    }
    local UNDEFINED = { ['undefined-global'] = true }
    local script = 'ZZ_BUILTIN_SOURCE\nprint(zzFromBuiltin)\n'
    rewriteOn = false
    -- (without the rewrite the first line is not even a statement: only count what is said about the global)
    local plain = reported(script, UNDEFINED)
    local mentions = 0
    for _, line in ipairs(plain) do
        if line:find('zzFromBuiltin', 1, true) then
            mentions = mentions + 1
        end
    end
    assert(mentions == 1, 'off: the name is undefined, got ' .. table.concat(plain, ' | '))
    rewriteOn = true
    local rewritten = reported(script, UNDEFINED)
    for _, line in ipairs(rewritten) do
        assert(not line:find('zzFromBuiltin', 1, true), 'on: the local the rewrite declared is known: ' .. line)
    end
    -- the dispatch contract: a built-in interface that has nothing to say is no answer, one that answers is
    rewriteOn = false
    assert(plugin.dispatch('OnSetText', TESTURI, 'ZZ_BUILTIN_SOURCE') == false, 'built-ins with nothing to say: nobody answered')
    rewriteOn = true
    local suc, diffs = plugin.dispatch('OnSetText', TESTURI, 'ZZ_BUILTIN_SOURCE')
    assert(suc == true and type(diffs) == 'table' and #diffs == 1, 'a built-in answer is returned')
    rewriteOn = false
end
