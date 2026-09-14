local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE       = 'Annotations specify that at most %d return value(s) are required, found %d returned here instead.'
local MESSAGE_RANGE = 'Annotations specify that at most %d return value(s) are required, found %d to %d returned here instead.'

protoDiagnostic.register {
    'redundant-return-value',
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
        local returns = source.returns
        if not returns then
            return
        end
        await.delay()
        local _, max = vm.countReturnsOfSource(source)
        for _, ret in ipairs(returns) do
            local rmin, rmax = vm.countList(ret)
            if rmin > max then
                for i = max + 1, #ret - 1 do
                    callback {
                        start   = ret[i].start,
                        finish  = ret[i].finish,
                        message = MESSAGE:format(max, i),
                    }
                end
                if #ret == rmax then
                    callback {
                        start   = ret[#ret].start,
                        finish  = ret[#ret].finish,
                        message = MESSAGE:format(max, rmax),
                    }
                else
                    callback {
                        start   = ret[#ret].start,
                        finish  = ret[#ret].finish,
                        message = MESSAGE_RANGE:format(max, #ret, rmax),
                    }
                end
            end
        end
    end)
end
