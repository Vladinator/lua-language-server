local files           = require 'files'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Unknown type conversion variable `%s`.'

protoDiagnostic.register {
    'unknown-cast-variable',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for casts of undefined variables.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    if not state.ast.docs then
        return
    end

    for _, doc in ipairs(state.ast.docs) do
        if doc.type == 'doc.cast' and doc.name then
            await.delay()
            local defs = vm.getDefs(doc.name)
            local loc = defs[1]
            if not loc then
                callback {
                    start   = doc.name.start,
                    finish  = doc.name.finish,
                    message = MESSAGE:format(doc.name[1])
                }
            end
        end
    end
end
