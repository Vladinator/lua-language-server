local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

protoDiagnostic.register {
    'redundant-or',
} {
    group    = 'redundant',
    severity = 'Hint',
    status   = 'None',
    description = 'Enable diagnostics for `a or b` where `a` is always truthy: `b` is never evaluated.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    ---@async
    guide.eachSourceType(state.ast, 'binary', function (src)
        if not src.op or src.op.type ~= 'or' then
            return
        end
        local left, right = src[1], src[2]
        if not left or not right then
            return
        end
        delayer:delay()
        if vm.compileNode(left):alwaysTruthy() then
            callback {
                start   = right.start,
                finish  = right.finish,
                message = 'The left side of `or` is always truthy: this is never evaluated.',
            }
        end
    end)
end
