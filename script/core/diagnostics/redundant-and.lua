local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

protoDiagnostic.register {
    'redundant-and',
} {
    group    = 'redundant',
    severity = 'Hint',
    status   = 'None',
    description = 'Enable diagnostics for `a and b` where `a` is always falsy (`b` is never evaluated) or always truthy (the `and` changes nothing).',
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
        if not src.op or src.op.type ~= 'and' then
            return
        end
        local left, right = src[1], src[2]
        if not left or not right then
            return
        end
        delayer:delay()
        local node = vm.compileNode(left)
        if node:alwaysFalsy() then
            callback {
                start   = right.start,
                finish  = right.finish,
                message = 'The left side of `and` is always falsy: this is never evaluated.',
            }
        elseif node:alwaysTruthy() then
            callback {
                start   = left.start,
                finish  = left.finish,
                message = 'This is always truthy: the `and` evaluates to its right side.',
            }
        end
    end)
end
