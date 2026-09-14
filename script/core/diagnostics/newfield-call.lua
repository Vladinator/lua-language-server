local files           = require 'files'
local guide           = require 'parser.guide'
local await           = require 'await'
local sub             = require 'core.substring'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Will be interpreted as `%s%s`. It may be necessary to add a `,` or `;`.'

protoDiagnostic.register {
    'newfield-call',
} {
    group    = 'ambiguity',
    severity = 'Warning',
    status   = 'Any',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    local text  = files.getText(uri)
    if not state or not text then
        return
    end

    ---@async
    guide.eachSourceType(state.ast, 'table', function (source)
        await.delay()
        for i = 1, #source do
            local field = source[i]
            if field.type ~= 'tableexp' then
                goto CONTINUE
            end
            local call = field.value
            if not call then
                goto CONTINUE
            end
            if call.type ~= 'call' then
                return
            end
            local func = call.node
            local args = call.args
            if args then
                local funcLine = guide.rowColOf(func.finish)
                local argsLine = guide.rowColOf(args.start)
                if argsLine > funcLine then
                    callback {
                        start   = call.start,
                        finish  = call.finish,
                        message = MESSAGE:format(
                            sub(state)(func.start + 1, func.finish),
                            sub(state)(args.start + 1, args.finish)
                        )
                    }
                end
            end
            ::CONTINUE::
        end
    end)
end
