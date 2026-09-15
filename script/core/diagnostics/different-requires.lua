local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local rpath           = require 'workspace.require-path'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'The same file is required with different names.'

protoDiagnostic.register {
    'different-requires',
} {
    group    = 'ambiguity',
    severity = 'Warning',
    status   = 'Any',
}

return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end
    local cache = vm.getCache 'different-requires' --[[@as table<uri, {source: parser.object, require: string}>]]
    guide.eachSpecialOf(state.ast, 'require', function (source)
        local call = source.parent
        if not call or call.type ~= 'call' then
            return
        end
        local arg1 = call.args and call.args[1]
        if not arg1 or arg1.type ~= 'string' then
            return
        end
        local literal = arg1[1]
        local results = rpath.findUrisByRequireName(uri, literal)
        if not results or #results ~= 1 then
            return
        end
        local result = results[1]
        if not files.isLua(result) then
            return
        end
        local other = cache[result]
        if not other then
            cache[result] = {
                source  = arg1,
                require = literal,
            }
            return
        end
        if other.require ~= literal then
            callback {
                start   = arg1.start,
                finish  = arg1.finish,
                related = {
                    {
                        start  = other.source.start,
                        finish = other.source.finish,
                        uri    = guide.getUri(other.source),
                    }
                },
                message = MESSAGE,
            }
        end
    end)
end
