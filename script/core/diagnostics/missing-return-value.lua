local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE       = 'Annotations specify that at least %d return value(s) are required, found %d returned here instead.'
local MESSAGE_RANGE = 'Annotations specify that at least %d return value(s) are required, found %d to %d returned here instead.'

protoDiagnostic.register {
    'missing-return-value',
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

    ---@async
    guide.eachSourceType(state.ast, 'function', function (source)
        await.delay()
        local returns = source.returns
        if not returns then
            return
        end
        local min = vm.countReturnsOfSource(source)
        if min == 0 then
            return
        end
        for _, ret in ipairs(returns) do
            local rmin, rmax = vm.countList(ret)
            if rmax < min then
                if rmin == rmax then
                    callback {
                        start   = ret.start,
                        finish  = ret.start + #'return',
                        message = MESSAGE:format(min, rmax),
                    }
                else
                    callback {
                        start   = ret.start,
                        finish  = ret.start + #'return',
                        message = MESSAGE_RANGE:format(min, rmin, rmax),
                    }
                end
            end
        end
    end)
end
