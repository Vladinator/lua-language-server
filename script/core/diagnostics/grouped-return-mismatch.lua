local protoDiagnostic = require 'proto.diagnostic'

protoDiagnostic.register {
    'grouped-return-mismatch',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for return values that each fit their own slot but together match none of the cases of a tuple-union return annotation (`---@return (A, B) | (C, D)`).',
}

-- the check is part of return-type-mismatch.lua, which serves both diagnostics (it is told which one runs)
return require 'core.diagnostics.return-type-mismatch'
