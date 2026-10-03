local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local protoDiagnostic = require 'proto.diagnostic'

protoDiagnostic.register {
    'nil-table-key',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for a table type whose key type includes `nil` (`table<string?, V>`): `nil` is not a valid table key.',
}

return function (uri, callback)
    local state = files.getState(uri)
    if not state or not state.ast.docs then
        return
    end

    guide.eachSource(state.ast.docs, function (source)
        if source.type ~= 'doc.type.sign' then
            return
        end
        local name = source.node and source.node[1]
        if name ~= 'table' then
            return
        end
        local key = source.signs and source.signs[1]
        if not key then
            return
        end
        if vm.compileNode(key):hasNil() then
            callback {
                start   = key.start,
                finish  = key.finish,
                message = 'The key type includes `nil`, which is not a valid table key.',
            }
        end
    end)
end
