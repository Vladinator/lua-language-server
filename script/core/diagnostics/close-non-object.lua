local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Cannot close a value of this type. (Unless set `__close` meta method)'

protoDiagnostic.register {
    'close-non-object',
} {
    group    = 'strict',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for attempts to close a variable with a non-object.',
}

return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    guide.eachSourceType(state.ast, 'local', function (source)
        if not source.attrs then
            return
        end
        if source.attrs[1][1] ~= 'close' then
            return
        end
        if not source.value then
            callback {
                start   = source.start,
                finish  = source.finish,
                message = MESSAGE,
            }
            return
        end
        local infer = vm.getInfer(source.value)
        if  not infer:hasClass(uri)
        and not infer:hasType(uri, 'nil')
        and not infer:hasType(uri, 'table')
        and not infer:hasUnknown(uri)
        and not infer:hasAny(uri) then
            callback {
                start   = source.value.start,
                finish  = source.value.finish,
                message = MESSAGE,
            }
        end
    end)
end
