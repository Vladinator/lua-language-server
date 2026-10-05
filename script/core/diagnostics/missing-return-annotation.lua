local files           = require 'files'
local guide           = require 'parser.guide'
local await           = require 'await'
local reachable       = require 'core.diagnostics.helper.reachable-function'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Missing @return annotation: the function returns a value.'

protoDiagnostic.register {
    'missing-return-annotation',
} {
    group    = 'luadoc',
    severity = 'Hint',
    status   = 'None',
    description = 'Enable diagnostics for a function that other files can reach (a global, a function of a global table, of an exported table) whose body returns a value but has no `---@return`. Local functions and file-private tables are not looked at (the wowlua-ls diagnostic of the same name).',
}

--- Does the function document its return values or its whole type?
---@param source parser.object
---@return boolean
local function isDocumented(source)
    -- (a `---@type` binds to the variable that holds the function, `---@return` / `---@overload` to the function)
    for _, holder in ipairs { source, source.parent } do
        for _, doc in ipairs(holder.bindDocs or {}) do
            if doc.type == 'doc.return' or doc.type == 'doc.type' or doc.type == 'doc.overload' then
                return true
            end
        end
    end
    return false
end

--- Does a `return` of this function (not of one nested in it) carry a value?
---@param source parser.object
---@return boolean
local function returnsAValue(source)
    for _, ret in ipairs(source.returns or {}) do
        if ret[1] ~= nil then
            return true
        end
    end
    return false
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@async
    guide.eachSourceType(state.ast, 'function', function (source)
        await.delay()
        if reachable.isReachable(source) and returnsAValue(source) and not isDocumented(source) then
            callback {
                start   = source.start,
                finish  = source.start + #'function',
                message = MESSAGE,
            }
        end
    end)
end
