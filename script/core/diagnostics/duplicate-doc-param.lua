local files           = require 'files'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Duplicate params `%s`.'

protoDiagnostic.register {
    'duplicate-doc-param',
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
        if doc.type ~= 'doc.param' then
            goto CONTINUE
        end
        local name = doc.param[1]
        local bindGroup = doc.bindGroup
        if not bindGroup then
            goto CONTINUE
        end
        ---@cast bindGroup parser.object[]
        for _, other in ipairs(bindGroup) do
            if  other ~= doc
            and other.type == 'doc.param'
            and other.param[1] == name then
                callback {
                    start   = doc.param.start,
                    finish  = doc.param.finish,
                    message = MESSAGE:format(name)
                }
                goto CONTINUE
            end
        end
        ::CONTINUE::
    end
end
