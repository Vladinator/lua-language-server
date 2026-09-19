local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'The return values of this function cannot be discarded.'

protoDiagnostic.register {
    'discard-returns',
} {
    group    = 'strict',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for calls of functions annotated with `---@nodiscard` where the return values are ignored.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end
    ---@async
    guide.eachSourceType(state.ast, 'call', function (source)
        if not guide.isBlockType(source.parent) then
            return
        end
        if source.parent.filter == source then
            return
        end
        await.delay()
        if vm.isNoDiscard(source.node, true) then
            callback {
                start   = source.start,
                finish  = source.finish,
                message = MESSAGE,
            }
        end
    end)
end
