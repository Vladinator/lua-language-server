local files           = require 'files'
local guide           = require 'parser.guide'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = '`not` binds tighter than `%s`: this is `(not x) %s y`. Add brackets: `not (x %s y)` or `(not x) %s y`.'

protoDiagnostic.register {
    'not-precedence',
} {
    group    = 'ambiguity',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for a comparison whose left side is a bare `not x`: `not x == y` is `(not x) == y`, not `not (x == y)`. Brackets say which one is meant.',
}

local comparisons = {
    ['=='] = true,
    ['~='] = true,
    ['<']  = true,
    ['<='] = true,
    ['>']  = true,
    ['>='] = true,
}

---@param source? parser.object
---@return boolean?
local function isNot(source)
    return source
       and source.type == 'unary'
       and source.op
       and source.op.type == 'not'
end

return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    guide.eachSourceType(state.ast, 'binary', function (source)
        local op = source.op and source.op.type
        if not op or not comparisons[op] then
            return
        end
        -- a bracketed `(not x)` is a `paren`, not a `unary`: it is the explicit form and is left alone
        if not isNot(source[1]) then
            return
        end
        -- `not a == not b` asks whether a and b are both nil-ish or both not: deliberate for (in)equality, never for an ordering
        if (op == '==' or op == '~=') and isNot(source[2]) then
            return
        end
        callback {
            start   = source.start,
            finish  = source.finish,
            message = MESSAGE:format(op, op, op, op),
        }
    end)
end
