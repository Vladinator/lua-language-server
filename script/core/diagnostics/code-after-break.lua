local files           = require 'files'
local guide           = require 'parser.guide'
local define          = require 'proto.define'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Unable to execute code after `break`.'

protoDiagnostic.register {
    'code-after-break',
} {
    group    = 'unused',
    severity = 'Hint',
    status   = 'Opened',
    description = 'Enable diagnostics for code placed after a break statement in a loop.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@type table<parser.object, boolean>
    local mark = {}
    ---@async
    guide.eachSourceType(state.ast, 'break', function (source)
        local list = source.parent
        if mark[list] then
            return
        end
        mark[list] = true
        await.delay()
        for i = #list, 1, -1 do
            local src = list[i]
            if src == source then
                if i == #list then
                    return
                end
                callback {
                    start   = list[i+1].start,
                    finish  = list[#list].range or list[#list].finish,
                    tags    = { define.DiagnosticTag.Unnecessary },
                    message = MESSAGE,
                }
            end
        end
    end)
end
