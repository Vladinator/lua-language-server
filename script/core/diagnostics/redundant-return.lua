local files           = require 'files'
local guide           = require 'parser.guide'
local define          = require 'proto.define'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Redundant return.'

protoDiagnostic.register {
    'redundant-return',
} {
    group    = 'unused',
    severity = 'Hint',
    status   = 'Opened',
}

-- reports 'return' without any return values at the end of functions
return function (uri, callback)
    local ast = files.getState(uri)
    if not ast then
        return
    end

    guide.eachSourceType(ast.ast, 'return', function (source)
        if not source.parent or source.parent.type ~= "function" then
            return
        end
        if #source > 0 then
            return
        end
        callback {
            start   = source.start,
            finish  = source.finish,
            tags    = { define.DiagnosticTag.Unnecessary },
            message = MESSAGE,
        }
    end)
end
