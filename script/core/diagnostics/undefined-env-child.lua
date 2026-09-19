local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require "vm.vm"
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Undefined variable `%s` (overloaded `_ENV` ).'

protoDiagnostic.register {
    'undefined-env-child',
} {
    group    = 'global',
    severity = 'Information',
    status   = 'Any',
    description = 'Enable undefined environment variable diagnostics. It\'s raised when `_ENV` table is set to a new literal table, but the used global variable is no longer present in the global environment.',
}

---@param source parser.object
---@return boolean
local function isBindDoc(source)
    if not source.bindDocs then
        return false
    end
    for _, doc in ipairs(source.bindDocs) do
        if doc.type == 'doc.type'
        or doc.type == 'doc.class' then
            return true
        end
    end
    return false
end

return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    guide.eachSourceType(state.ast, 'getglobal', function (source)
        if not source.node then
            return
        end
        if source.node.tag == '_ENV' then
            return
        end

        if not isBindDoc(source.node) then
            return
        end

        if #vm.getDefs(source) > 0 then
            return
        end

        local key = source[1]
        callback {
            start   = source.start,
            finish  = source.finish,
            message = MESSAGE:format(key),
        }
    end)
end
