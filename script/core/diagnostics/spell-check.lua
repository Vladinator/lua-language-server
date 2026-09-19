local files           = require 'files'
local converter       = require 'proto.converter'
local log             = require 'log'
local spell           = require 'provider.spell'
local protoDiagnostic = require 'proto.diagnostic'

protoDiagnostic.register {
    'spell-check',
} {
    group    = 'codestyle',
    severity = 'Information',
    status   = 'None',
    description = 'Enable diagnostics for typos in strings.',
}

---@async
return function(uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end
    local text = state.originText

    local status, diagnosticInfos = spell.spellCheck(uri, text)

    if not status then
        if diagnosticInfos ~= nil then
            log.error(diagnosticInfos)
        end

        return
    end

    if diagnosticInfos then
        ---@cast diagnosticInfos provider.spell.diagnosticInfo[] -- status was true above, so this can't be the error-message string
        for _, diagnosticInfo in ipairs(diagnosticInfos) do
            callback {
                start   = converter.unpackPosition(state, diagnosticInfo.range.start),
                finish  = converter.unpackPosition(state, diagnosticInfo.range["end"]),
                message = diagnosticInfo.message,
                data    = diagnosticInfo.data
            }
        end
    end
end
