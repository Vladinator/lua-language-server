local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'This function requires %d argument(s) but instead it is receiving %d.'

protoDiagnostic.register {
    'missing-parameter',
} {
    group    = 'unbalanced',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for function calls where the number of arguments is less than the number of annotated function parameters.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@async
    guide.eachSourceType(state.ast, 'call', function (source)
        await.delay()
        local _, callArgs = vm.countList(source.args)

        local funcArgs = vm.tryCheapCountParams(source.node)
        if not funcArgs then
            local funcNode = vm.compileNode(source.node)
            funcArgs = vm.countParamsOfNode(funcNode)
        end
        -- `---@param ... params<F>`: the `...` takes the parameters of the function F stands for, the required ones are required
        local target, varIndex = vm.getParamsProjection(uri, source)
        if target and varIndex then
            local targetMin = vm.countParamsOfFunction(target)
            funcArgs = varIndex - 1 + targetMin
        end

        if callArgs >= funcArgs then
            return
        end

        callback {
            start  = source.start,
            finish = source.finish,
            message = MESSAGE:format(funcArgs, callArgs),
        }
    end)
end
