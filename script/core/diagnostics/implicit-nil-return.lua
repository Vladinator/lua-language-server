local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

protoDiagnostic.register {
    'implicit-nil-return',
} {
    group    = 'conventions',
    severity = 'Hint',
    status   = 'None',
    description = 'Enable diagnostics for a bare `return` in a function whose first `@return` is optional (`T?`): write `return nil` to say it on purpose.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    ---@async
    guide.eachSourceType(state.ast, 'return', function (src)
        if #src > 0 then
            return
        end
        local func = guide.getParentFunction(src)
        if not func or func.type ~= 'function' or not func.bindDocs then
            return
        end
        for _, doc in ipairs(func.bindDocs) do
            if doc.type == 'doc.return' then
                for _, rtn in ipairs(doc.returns) do
                    if rtn.returnIndex == 1 then
                        delayer:delay()
                        local node = vm.compileNode(rtn)
                        -- (`@return nil` alone is not optional: a bare return says the same)
                        if node:hasNil() and not node:alwaysFalsy() then
                            callback {
                                start   = src.start,
                                finish  = src.finish,
                                message = 'Bare `return` in a function whose `@return` is optional: write `return nil`.',
                            }
                        end
                        return
                    end
                end
            end
        end
    end)
end
