local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

protoDiagnostic.register {
    'nil-index',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'None',
    description = 'Enable diagnostics for reading a table with a possibly-nil key through brackets (`t[k]` where `k` may be `nil`). Writing one is `need-check-nil`.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    ---@async
    guide.eachSourceType(state.ast, 'getindex', function (src)
        local index = src.index
        if not index then
            return
        end
        delayer:delay()
        local node = vm.compileNode(index)
        if vm.getInfer(index):hasType(uri, 'any') then
            return
        end
        if node:hasNil() then
            callback {
                start   = index.start,
                finish  = index.finish,
                message = 'The key may be `nil`.',
            }
        end
    end)
end
