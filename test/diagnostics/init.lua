local core   = require 'core.diagnostics'
local files  = require 'files'
local config = require 'config'
local util   = require 'utility'
local catch  = require 'catch'
local diagd  = require 'proto.diagnostic'
local fs     = require 'bee.filesystem'

local status = config.get(nil, 'Lua.diagnostics.neededFileStatus')

for key in pairs(status) do
    status[key] = 'Any!'
end

-- Diagnostics that self-register from within their own file (see the
-- eager-require list in core/diagnostics/init.lua) aren't present as
-- keys in `status` above -- that table's schema is frozen by
-- config/template.lua before `require 'core.diagnostics'` on line 1 ever
-- runs, the same one-time-snapshot timing issue documented in
-- core/diagnostics/init.lua's getSeverity/getStatus/buildDiagList. Force
-- them open here too, straight from proto.diagnostic's live registry,
-- so a diagnostic whose own default status is 'None' (e.g.
-- incomplete-signature-doc) still actually runs under TEST.
for key in pairs(diagd.diagnosticDatas) do
    status[key] = 'Any!'
end

config.set('nil', 'Lua.type.castNumberToInteger', false)
config.set('nil', 'Lua.type.weakUnionCheck', false)
config.set('nil', 'Lua.type.weakNilCheck', false)

rawset(_G, 'TEST', true)

local function founded(targets, results)
    if #targets ~= #results then
        return false
    end
    for _, target in ipairs(targets) do
        for _, result in ipairs(results) do
            if target[1] == result[1] and target[2] == result[2] then
                goto NEXT
            end
        end
        do return false end
        ::NEXT::
    end
    return true
end

---@diagnostic disable: await-in-sync
---@param script string
---@param version? string
function TEST(script, version)
    if version then
        config.set(nil, 'Lua.runtime.version', version)
    end
    local newScript, catched = catch(script, '!')
    files.setText(TESTURI, newScript)
    files.open(TESTURI)
    ---@type any[]
    local origins = {}
    ---@type any[]
    local filteds = {}
    ---@type any[]
    local results = {}
    core(TESTURI, false, function (result)
        if DIAG_CARE == result.code
        or DIAG_CARE == '*' then
            results[#results+1] = { result.start, result.finish }
            filteds[#filteds+1] = result
        end
        origins[#origins+1] = result
    end)

    if results[1] then
        if not founded(catched['!'] or {}, results) then
            error(('%s\n%s'):format(util.dump(catched['!']), util.dump(results)))
        end
    else
        assert(#catched['!'] == 0)
    end

    files.remove(TESTURI)
    if version then
        config.set(nil, 'Lua.runtime.version', nil)
    end

    ---@param callback fun(diags: any[])
    return function (callback)
        callback(filteds)
    end
end

local function check(name)
    DIAG_CARE = name
    require('diagnostics.' .. name)
end

--- Extra/custom diagnostic plugins ship their tests right alongside their
--- implementation, as a `<name>.test.lua` file next to `<name>.lua` --
--- both travel together, so deleting a plugin also removes its test, with
--- no leftover reference here to update (unlike the `check 'x'` lines
--- below, one per built-in diagnostic). A test only runs if its plugin's
--- implementation file is still there to run it against.
---@param dirPath string
local function checkPluginDir(dirPath)
    local dir = fs.path(dirPath)
    if not fs.exists(dir) or not fs.is_directory(dir) then
        return
    end
    for path in fs.pairs(dir) do
        local fileName = path:filename():string()
        local name = fileName:match('^(.+)%.test%.lua$')
        if name then
            local implPath = dir / (name .. '.lua')
            if fs.exists(implPath) then
                DIAG_CARE = name
                local testFn = assert(loadfile(path:string()))
                testFn()
            end
        end
    end
end

check 'ambiguity-1'
check 'assign-type-mismatch'
check 'await-in-sync'
check 'cast-local-type'
check 'cast-type-mismatch'
check 'circle-doc-class'
check 'close-non-object'
check 'code-after-break'
check 'count-down-loop'
check 'deprecated'
check 'discard-returns'
check 'doc-field-no-class'
check 'duplicate-doc-alias'
check 'duplicate-doc-field'
check 'duplicate-doc-param'
check 'duplicate-index'
check 'duplicate-set-field'
check 'empty-block'
check 'global-element'
check 'global-in-nil-env'
check 'incomplete-signature-doc'
check 'inject-field'
check 'invisible'
check 'lowercase-global'
check 'missing-fields'
check 'missing-global-doc'
check 'missing-local-export-doc'
check 'missing-parameter'
check 'missing-return-value'
check 'missing-return'
check 'need-check-nil'
check 'unnecessary-assert'
check 'newfield-call'
check 'newline-call'
check 'not-yieldable'
check 'param-type-mismatch'
check 'redefined-local'
check 'redundant-parameter'
check 'redundant-return-value'
check 'redundant-return'
check 'redundant-value'
check 'return-type-mismatch'
check 'trailing-space'
check 'unbalanced-assignments'
check 'undefined-doc-class'
check 'undefined-doc-name'
check 'undefined-doc-param'
check 'undefined-env-child'
check 'undefined-field'
check 'undefined-global'
check 'unknown-cast-variable'
check 'unknown-diag-code'
check 'unknown-operator'
check 'unreachable-code'
check 'unused-function'
check 'unused-label'
check 'unused-local'
check 'unused-vararg'

checkPluginDir((ROOT / 'script' / 'core' / 'diagnostics' / 'extra'):string())
