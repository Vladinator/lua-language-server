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
    status   = 'Opened',
    description = 'Enable diagnostics for reading a table with a possibly-nil key through brackets (`t[k]` where `k` may be `nil`). Writing one is `need-check-nil`; a key that is `nil` for certain (`t[nil] = v`, `{ [nil] = v }`) is the runtime error "index is nil" and is reported on the write.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    ---@async
    guide.eachSourceTypes(state.ast, { 'getindex', 'setindex', 'tableindex' }, function (src)
        local index = src.index
        if not index then
            return
        end
        delayer:delay()
        local node = vm.compileNode(index)
        if vm.getInfer(index):hasType(uri, 'any') then
            return
        end
        if src.type == 'setindex' or src.type == 'tableindex' then
            -- writing: a key that MAY be nil is need-check-nil's; a key that is nil for certain (`t[nil] = v`) is always the error "index is nil"
            if vm.getInfer(index):view(uri) == 'nil' then
                callback {
                    start   = index.start,
                    finish  = index.finish,
                    message = 'The key is `nil`.',
                }
            end
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
