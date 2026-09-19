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

        local funcNode = vm.compileNode(source.node)
        local funcArgs = vm.countParamsOfNode(funcNode)

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
