-- `---@secret-guard <param> <kind>` (declared in secret-access.lua) that does not read like that, or
-- names something that is not a parameter of the function it is bound to: the parser leaves such a tag
-- bare, and a bare tag does nothing, so without this report a guard that looks protective would silently
-- be none. Same shape as invalid-guard.lua for `---@guard`; deleting this file removes only the report.
-- Its tests are next to it.

local files           = require 'files'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

protoDiagnostic.register {
    'invalid-secret-guard',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for a `---@secret-guard <parameter> <is-secret|accessible|any-secret>` that is not of that form, is not above a function, or names something that is not a parameter of that function.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state or not state.ast.docs then
        return
    end
    for _, doc in ipairs(state.ast.docs) do
        if doc.type ~= 'doc.secret-guard' then
            goto CONTINUE
        end
        await.delay()
        if not doc.param or not doc.kind then
            callback {
                start   = doc.start,
                finish  = doc.finish,
                message = 'Expected `<parameter> <is-secret|accessible|any-secret>`, with the parameter of the function (`...` for a vararg).',
            }
            goto CONTINUE
        end
        ---@type parser.object?
        local source = doc.bindSource
        ---@type parser.object?
        local func = source and (source.type == 'function' and source
            or (source.value and source.value.type == 'function' and source.value)
            or nil) or nil
        if not func then
            callback {
                start   = doc.start,
                finish  = doc.finish,
                message = 'This tag has to be above a function.',
            }
            goto CONTINUE
        end
        local found = false
        for _, arg in ipairs(func.args or {}) do
            if arg[1] == doc.param[1] then
                found = true
                break
            end
        end
        if not found then
            callback {
                start   = doc.param.start,
                finish  = doc.param.finish,
                message = ('`%s` is not a parameter of this function.'):format(doc.param[1]),
            }
        end
        ::CONTINUE::
    end
end
