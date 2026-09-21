local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE     = 'Expected diagnostic `%s` on this line, but none was reported. Remove the comment or review the code.'
local MESSAGE_ANY = 'Expected a diagnostic on this line, but none was reported. Remove the comment or review the code.'

protoDiagnostic.register {
    'unfulfilled-expect',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'Any',
    afterAll = true,
    -- a file with `expect-*` comments is always diagnosed completely: what the other diagnostics
    -- suppressed is recorded while they run
    ---@param state parser.state
    ---@return boolean
    fullRunWhen = function (state)
        for _, doc in ipairs(state.ast.docs or {}) do
            if  doc.type == 'doc.diagnostic'
            and (doc.mode == 'expect-next-line' or doc.mode == 'expect-line') then
                return true
            end
        end
        return false
    end,
    description = 'Enable diagnostics for `---@diagnostic expect-next-line` / `expect-line` comments whose expected diagnostic did not occur, so a stale suppression cannot outlive the problem it hid.',
}

--- `---@diagnostic expect-next-line: code[, code]` (and `expect-line`) suppresses the
--- listed diagnostics on the target line like `disable-next-line` does, but must
--- actually suppress something: a stale expectation is reported here, so a fixed
--- problem cannot leave a dead suppression behind (TypeScript's `@ts-expect-error`).
--- This runs after every other diagnostic of the file (core/diagnostics/init.lua).
---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state or not state.ast.docs then
        return
    end

    for _, doc in ipairs(state.ast.docs) do
        if doc.type ~= 'doc.diagnostic'
        or (doc.mode ~= 'expect-next-line' and doc.mode ~= 'expect-line') then
            goto CONTINUE
        end
        await.delay()
        local hits = doc._hits or {}
        if doc.names then
            for _, nameUnit in ipairs(doc.names) do
                local name = nameUnit[1]
                -- a diagnostic that is switched off can never fire: not "unfulfilled"
                if  not hits[name]
                and protoDiagnostic.isEnabled
                and protoDiagnostic.isEnabled(uri, name) then
                    callback {
                        start   = nameUnit.start,
                        finish  = nameUnit.finish,
                        message = MESSAGE:format(name),
                    }
                end
            end
        elseif next(hits) == nil then
            callback {
                start   = doc.start,
                finish  = doc.finish,
                message = MESSAGE_ANY,
            }
        end
        ::CONTINUE::
    end
end
