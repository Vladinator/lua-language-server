local files           = require 'files'
local guide           = require 'parser.guide'
local await           = require 'await'
local reachable       = require 'core.diagnostics.helper.reachable-function'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Missing @param annotation for parameter `%s`.'

protoDiagnostic.register {
    'missing-param-annotation',
} {
    group    = 'luadoc',
    severity = 'Hint',
    status   = 'None',
    description = 'Enable diagnostics for a function that other files can reach (a global, a function of a global table, of an exported table) with a parameter that has no `---@param`. Local functions and file-private tables are not looked at (the wowlua-ls diagnostic of the same name).',
}

---@param source parser.object
---@param name   string|integer
---@return boolean
local function hasParamDoc(source, name)
    for _, doc in ipairs(source.bindDocs or {}) do
        if doc.type == 'doc.param' and doc.param[1] == name then
            return true
        end
    end
    return false
end

--- A function typed as a whole (`---@type fun(a: number)`, `---@overload`) documents its parameters in that type.
---@param source parser.object
---@return boolean
local function isTypedAsAWhole(source)
    -- (a `---@type` binds to the variable that holds the function, `---@overload` to the function)
    for _, holder in ipairs { source, source.parent } do
        for _, doc in ipairs(holder.bindDocs or {}) do
            if doc.type == 'doc.type' or doc.type == 'doc.overload' then
                return true
            end
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
        if not source.args or not reachable.isReachable(source) or isTypedAsAWhole(source) then
            return
        end
        for _, arg in ipairs(source.args) do
            local name = arg[1]
            if name ~= nil and name ~= 'self' and name ~= '_' and not hasParamDoc(source, name) then
                callback {
                    start   = arg.start,
                    finish  = arg.finish,
                    message = MESSAGE:format(tostring(name)),
                }
            end
        end
    end)
end
