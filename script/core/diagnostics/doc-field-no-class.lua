local files           = require 'files'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'The field must be defined after the class.'

protoDiagnostic.register {
    'doc-field-no-class',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'Any',
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
        if doc.type ~= 'doc.field' then
            goto CONTINUE
        end
        local bindGroup = doc.bindGroup
        if not bindGroup then
            goto CONTINUE
        end
        local ok
        for _, other in ipairs(bindGroup) do
            if other.type == 'doc.class' then
                ok = true
                break
            end
            if other == doc then
                break
            end
        end
        if not ok then
            callback {
                start   = doc.start,
                finish  = doc.finish,
                message = MESSAGE,
            }
        end
        ::CONTINUE::
    end
end
