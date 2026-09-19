local files   = require 'files'
local diag    = require 'proto.diagnostic'

local MESSAGE = 'Unknown diagnostic code `%s`.'

diag.register {
    'unknown-diag-code',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics in cases in which an unknown diagnostics code is entered.',
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
        if doc.type == 'doc.diagnostic' then
            if doc.names then
                for _, nameUnit in ipairs(doc.names) do
                    local code = nameUnit[1]
                    if not diag.getDiagAndErrNameMap()[code] then
                        callback {
                            start   = nameUnit.start,
                            finish  = nameUnit.finish,
                            message = MESSAGE:format(code),
                        }
                    end
                end
            end
        end
    end
end
