-- A workspace diagnosis that has to run again because a setting changed runs just the diagnostics
-- that read it, and takes the rest from what it cached (provider.diagnostic, `only`). The one
-- property that matters: what comes out is what a run of everything would have given, whatever
-- the setting and whatever the file.
local files  = require 'files'
local config = require 'config'
local diag   = require 'provider.diagnostic'
local util   = require 'utility'

---@diagnostic disable: await-in-sync

local samples = {
    -- one of many things to report
    [[
local unused = 1
local function notCalled() end
foo(bar)
lowercase = 1
UPPER = 2
---@deprecated
function oldApi() end
oldApi()
---@type string?
local s
print(#s)
local trailing = 1
]],
    -- comments that expect a diagnostic: `unfulfilled-expect` needs the outcome of all of them
    [[
---@diagnostic expect-next-line: undefined-global
foo()
local a ---@diagnostic expect-line: unused-local
---@diagnostic expect-next-line: need-check-nil
local b = 1
]],
    -- nothing to report
    [[
local x = 1
print(x)
]],
    -- a syntax error
    [[
local x =
foo(
]],
}

---@class diagPartial.mutation
---@field name     string
---@field key      string
---@field value    any
---@field initial? table<string, any>  settings to have before the change
---@field only?    table|false         {}: no diagnostic must be affected; false: all of them (nil: not checked)

---@type diagPartial.mutation[]
local mutations = {
    { name = 'globals: add',        key = 'Lua.diagnostics.globals',     value = { 'foo', 'bar' } },
    { name = 'globals: remove',     key = 'Lua.diagnostics.globals',     value = { 'foo' },
      initial = { ['Lua.diagnostics.globals'] = { 'foo', 'bar' } } },
    { name = 'globals: all gone',   key = 'Lua.diagnostics.globals',     value = {},
      initial = { ['Lua.diagnostics.globals'] = { 'foo', 'bar' } } },
    { name = 'globals: the deprecated one', key = 'Lua.diagnostics.globals', value = { 'oldApi' } },
    { name = 'globals: a lowercase one',    key = 'Lua.diagnostics.globals', value = { 'lowercase', 'UPPER' } },
    { name = 'globalsRegex',        key = 'Lua.diagnostics.globalsRegex', value = { '^fo' } },
    { name = 'globalsRegex: UPPER', key = 'Lua.diagnostics.globalsRegex', value = { '^%u+$' } },
    { name = 'disable: add',        key = 'Lua.diagnostics.disable',     value = { 'unused-local' } },
    { name = 'disable: several',    key = 'Lua.diagnostics.disable',     value = { 'unused-local', 'need-check-nil', 'undefined-global' } },
    { name = 'disable: remove',     key = 'Lua.diagnostics.disable',     value = { 'need-check-nil' },
      initial = { ['Lua.diagnostics.disable'] = { 'unused-local', 'need-check-nil' } } },
    { name = 'disable: none left',  key = 'Lua.diagnostics.disable',     value = {},
      initial = { ['Lua.diagnostics.disable'] = { 'unused-local', 'need-check-nil' } } },
    { name = 'severity: set',       key = 'Lua.diagnostics.severity',    value = { ['unused-local'] = 'Error', ['undefined-global'] = 'Hint' } },
    { name = 'severity: removed',   key = 'Lua.diagnostics.severity',    value = {},
      initial = { ['Lua.diagnostics.severity'] = { ['unused-local'] = 'Error' } } },
    { name = 'neededFileStatus',    key = 'Lua.diagnostics.neededFileStatus', value = { ['unused-local'] = 'None' } },
    { name = 'neededFileStatus: !', key = 'Lua.diagnostics.neededFileStatus', value = { ['lowercase-global'] = 'None!' } },
    { name = 'groupFileStatus',     key = 'Lua.diagnostics.groupFileStatus', value = { ['unused'] = 'None' } },
    { name = 'groupSeverity',       key = 'Lua.diagnostics.groupSeverity', value = { ['unused'] = 'Error' } },
    { name = 'unusedLocalExclude',  key = 'Lua.diagnostics.unusedLocalExclude', value = { 'unus*' } },
    { name = 'workspaceRate: none', key = 'Lua.diagnostics.workspaceRate', value = 50, only = {} },
    -- not known: everything
    { name = 'libraryFiles: all',   key = 'Lua.diagnostics.libraryFiles', value = 'Disable', only = false },
    { name = 'doc.privateName: all', key = 'Lua.doc.privateName',         value = { '_*' }, only = false },
    { name = 'pluginsDir: all',     key = 'Lua.diagnostics.pluginsDir',   value = 'somewhere', only = false },
}

--- The cached diagnostics of a file, in a defined order.
---@param uri uri
---@return table[]
local function snapshot(uri)
    ---@type table[]
    local list = {}
    for _, d in ipairs(diag.cache[uri] or {}) do
        list[#list+1] = d
    end
    table.sort(list, function (a, b)
        ---@type { line: integer, character: integer }
        local ra = a.range.start
        ---@type { line: integer, character: integer }
        local rb = b.range.start
        if ra.line ~= rb.line then return ra.line < rb.line end
        if ra.character ~= rb.character then return ra.character < rb.character end
        if a.code ~= b.code then return tostring(a.code) < tostring(b.code) end
        return a.message < b.message
    end)
    return list
end

---@param list table[]
---@return string
local function describe(list)
    ---@type string[]
    local out = {}
    for _, d in ipairs(list) do
        out[#out+1] = ('%d:%d %s/%s'):format(d.range.start.line, d.range.start.character, tostring(d.code), tostring(d.severity))
    end
    return table.concat(out, ', ')
end

---@param names table<string, any>?
---@return string
local function nameList(names)
    if not names then
        return 'all'
    end
    ---@type string[]
    local list = {}
    for name in pairs(names) do
        list[#list+1] = name
    end
    table.sort(list)
    return '{' .. table.concat(list, ', ') .. '}'
end

-- the settings and texts that are changed here must not start diagnoses of their own: the
-- ones that are asked for below are the ones that run
local silenced = { 'diagnosticsScope', 'refreshClient', 'refresh', 'refreshScopeDiag', 'stopScopeDiag' }
local provider = diag --[[@as table<string, any>]]
---@type table<string, any>
local saved = {}
for _, name in ipairs(silenced) do
    saved[name] = provider[name]
    provider[name] = function () end
end

---@param key string
---@param value any
local function setConfig(key, value)
    config.set(nil, key, value)
end

---@type table<string, any>
local original = {}
---@param key string
local function remember(key)
    if original[key] == nil then
        original[key] = util.deepCopy(config.get(nil, key)) or false
    end
end

---@param uri uri
---@param only? table<string, true>
local function run(uri, only)
    -- (not as part of a scope: `Lua.diagnostics.workspaceRate` would make it sleep between checks)
    diag.doDiagnostic(uri, false, nil, only)
end

---@param uri uri
local function forget(uri)
    diag.cache[uri]    = nil
    diag.complete[uri] = nil
end

local checked = 0
for si, sample in ipairs(samples) do
    for _, mutation in ipairs(mutations) do
        local title = ('sample %d, %s'):format(si, mutation.name)
        files.setText(TESTURI, sample)
        for key, value in pairs(mutation.initial or {}) do
            remember(key)
            setConfig(key, util.deepCopy(value))
        end
        remember(mutation.key)
        local oldValue = util.deepCopy(config.get(nil, mutation.key))

        -- what was cached before the change: a run of everything
        forget(TESTURI)
        run(TESTURI)
        assert(diag.complete[TESTURI], title .. ': a full run must leave a complete result')
        local base = describe(snapshot(TESTURI))

        local newValue = util.deepCopy(mutation.value)
        setConfig(mutation.key, newValue)
        local names = diag.getAffectedDiagnostics(mutation.key, newValue, oldValue)

        if mutation.only == false then
            assert(names == nil, title .. ': expected all diagnostics, got ' .. nameList(names))
        elseif mutation.only then
            assert(names and next(names) == nil, title .. ': expected no diagnostics, got ' .. nameList(names))
        end

        -- what the workspace diagnosis does now
        DIAGTIMES = {}
        run(TESTURI, names)
        ---@type table<string, number>
        local ran = DIAGTIMES
        DIAGTIMES = nil
        local got = snapshot(TESTURI)

        -- what a run of everything gives
        forget(TESTURI)
        run(TESTURI)
        local expected = snapshot(TESTURI)

        assert(util.equal(got, expected),
            ('%s (%s): a partial run gave\n  %s\nbut a full run gives\n  %s'):format(
                title, nameList(names), describe(got), describe(expected)) .. ('\n  (ran: %s, was %s, base %s)'):format(nameList(ran), util.dump(oldValue), base))

        -- and it ran nothing else (a file with `expect` comments always gets all of them)
        if names and not sample:find('expect-', 1, true) then
            for name in pairs(ran) do
                assert(names[name], ('%s: %s ran, but only %s should have'):format(title, name, nameList(names)))
            end
        end
        checked = checked + 1

        -- back to the defaults
        for key, value in pairs(original) do
            setConfig(key, util.deepCopy(value or nil))
        end
    end
end
files.remove(TESTURI)
assert(checked == #samples * #mutations)

-- a file with nothing complete cached (never diagnosed, cleared, ...) gets all of them
do
    files.setText(TESTURI, samples[1])
    forget(TESTURI)
    run(TESTURI)
    local full = snapshot(TESTURI)
    forget(TESTURI)
    run(TESTURI, { ['unused-local'] = true })
    assert(util.equal(snapshot(TESTURI), full), 'a partial run without a complete result must run everything')
    assert(diag.complete[TESTURI], 'and then the result is complete')
    -- an edit makes the cached result about the old text
    diag.complete[TESTURI] = nil
    files.setText(TESTURI, samples[3])
    forget(TESTURI)
    run(TESTURI, { ['unused-local'] = true })
    assert(#snapshot(TESTURI) == 0)
    files.remove(TESTURI)
end

-- which diagnostics a change concerns
---@param key string
---@param value any
---@param oldValue any
---@return string
local function affected(key, value, oldValue)
    return nameList(diag.getAffectedDiagnostics(key, value, oldValue))
end
assert(affected('Lua.diagnostics.globals', { 'a' }, {}) == '{deprecated, global-element, lowercase-global, undefined-global}')
assert(affected('Lua.diagnostics.disable', { 'a', 'b' }, { 'b', 'c' }) == '{a, c}')
assert(affected('Lua.diagnostics.disable', { 'a', 'b' }, { 'b', 'a' }) == '{}')
assert(affected('Lua.diagnostics.severity', { a = 'Error', b = 'Hint' }, { a = 'Error', b = 'Warning', c = 'Hint' }) == '{b, c}')
assert(affected('Lua.diagnostics.neededFileStatus', { a = 'None' }, nil) == '{a}')
assert(affected('Lua.diagnostics.neededFileStatus', nil, { a = 'None' }) == '{a}')
assert(affected('Lua.diagnostics.unusedLocalExclude', { 'x' }, {}) == '{unused-local}')
assert(affected('Lua.spell.dict', { 'x' }, {}) == '{spell-check}')
assert(affected('Lua.diagnostics.workspaceRate', 10, 100) == '{}')
assert(affected('Lua.diagnostics.enable', false, true) == 'all')
assert(affected('Lua.diagnostics.workspaceDelay', -1, 3000) == 'all')
assert(affected('Lua.diagnostics.workspaceEvent', 'None', 'OnSave') == 'all')
assert(affected('Lua.doc.privateName', { 'x' }, {}) == 'all')
assert(affected('Lua.diagnostics.whatever', 1, 2) == 'all')  -- a key nobody knows
-- `unfulfilled-expect` needs all of them
assert(affected('Lua.diagnostics.disable', { 'unfulfilled-expect' }, {}) == 'all')
-- a group is its diagnostics
do
    local names = diag.getAffectedDiagnostics('Lua.diagnostics.groupSeverity', { unused = 'Error' }, {})
    assert(names and names['unused-local'] and names['unused-function'])
    assert(not names['undefined-global'])
end

-- a plugin diagnostic that says which settings it reads is run again for them, and only for the
-- settings the server can narrow down (anything else is still all of them)
do
    local diagd = require 'proto.diagnostic'
    diagd.diagnosticDatas['fixture-reader'] = {
        severity = 'Hint', status = 'Any', reads = { 'Lua.diagnostics.globals', 'Lua.diagnostics.enable' },
    }
    local names = assert(diag.getAffectedDiagnostics('Lua.diagnostics.globals', { 'a' }, {}))
    assert(names['fixture-reader'] and names['undefined-global'])
    assert(diag.getAffectedDiagnostics('Lua.diagnostics.enable', false, true) == nil, 'not narrowed by a plugin')
    names = assert(diag.getAffectedDiagnostics('Lua.diagnostics.severity', { a = 'Error' }, {}))
    assert(not names['fixture-reader'], 'a setting it did not name')
    diagd.diagnosticDatas['fixture-reader'] = nil
end

-- what a scope still has to diagnose
do
    diag.pending = {}
    assert(diag.takeRequest('s') == nil)
    diag.addRequest('s', { a = true })
    diag.addRequest('s', { b = true })
    local request = assert(diag.takeRequest('s'))
    assert(request.all == false and request.names.a and request.names.b)
    assert(diag.takeRequest('s') == nil, 'taken')
    diag.addRequest('s', { a = true })
    diag.addRequest('s')
    request = assert(diag.takeRequest('s'))
    assert(request.all == true, 'everything wins')
    -- a pass that did not finish puts back what it took, next to what came in meanwhile
    diag.addRequest('s', { c = true })
    diag.restoreRequest('s', { all = false, names = { a = true } })
    request = assert(diag.takeRequest('s'))
    assert(request.all == false and request.names.a and request.names.c)
    diag.restoreRequest('s', { all = true, names = {} })
    assert(assert(diag.takeRequest('s')).all == true)
end

for _, name in ipairs(silenced) do
    provider[name] = saved[name]
end
