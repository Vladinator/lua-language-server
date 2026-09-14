local files           = require 'files'
local define          = require 'proto.define'
local guide           = require 'parser.guide'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Only has %s variables, but you set %s values.'

protoDiagnostic.register {
    'redundant-value',
} {
    group    = 'unbalanced',
    severity = 'Warning',
    status   = 'Any',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(50000)
    guide.eachSource(state.ast, function (src) ---@async
        delayer:delay()
        if src.redundant then
            callback {
                start   = src.start,
                finish  = src.finish,
                tags    = { define.DiagnosticTag.Unnecessary },
                message = MESSAGE:format(src.redundant.max, src.redundant.passed)
            }
        end
    end)
end
