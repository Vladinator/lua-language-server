local files           = require 'files'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Undefined param `%s`.'

protoDiagnostic.register {
    'undefined-doc-param',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for cases in which a parameter annotation is given without declaring the parameter in the function definition.',
}

return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    if not state.ast.docs then
        return
    end

    for _, doc in ipairs(state.ast.docs) do
        if doc.type == 'doc.param'
        and not doc.bindSource then
            callback {
                start   = doc.param.start,
                finish  = doc.param.finish,
                message = MESSAGE:format(doc.param[1])
            }
        end
    end
end
