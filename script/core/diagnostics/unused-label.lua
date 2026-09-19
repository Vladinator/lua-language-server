local files           = require 'files'
local guide           = require 'parser.guide'
local define          = require 'proto.define'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Unused label `%s`.'

protoDiagnostic.register {
    'unused-label',
} {
    group    = 'unused',
    severity = 'Hint',
    status   = 'Opened',
    description = 'Enable unused label diagnostics.',
}

return function (uri, callback)
    local ast = files.getState(uri)
    if not ast then
        return
    end

    guide.eachSourceType(ast.ast, 'label', function (source)
        if not source.ref then
            callback {
                start   = source.start,
                finish  = source.finish,
                tags    = { define.DiagnosticTag.Unnecessary },
                message = MESSAGE:format(source[1]),
            }
        end
    end)
end
