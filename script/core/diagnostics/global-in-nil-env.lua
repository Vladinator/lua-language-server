local files           = require 'files'
local guide           = require 'parser.guide'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Invalid global (`_ENV` is `nil`).'

protoDiagnostic.register {
    'global-in-nil-env',
} {
    group    = 'global',
    severity = 'Warning',
    status   = 'Any',
}

return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local function check(source)
        local node = source.node
        if not node then
            return
        end
        if node.tag == '_ENV' then
            return
        end
        if guide.isParam(node) then
            return
        end

        if not node.value or node.value.type == 'nil' then
            callback {
                start   = source.start,
                finish  = source.finish,
                uri     = uri,
                message = MESSAGE,
                related = {
                    {
                        start  = node.start,
                        finish = node.finish,
                        uri    = uri,
                    }
                }
            }
        end
    end

    guide.eachSourceType(state.ast, 'getglobal', check)
    guide.eachSourceType(state.ast, 'setglobal', check)
end
