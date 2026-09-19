local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Cannot infer type.'

protoDiagnostic.register {
    'no-unknown',
} {
    group    = 'strong',
    severity = 'Warning',
    status   = 'None',
    description = 'Enable diagnostics for cases in which the type cannot be inferred.',
}

local types = {
    'local',
    'setlocal',
    'setglobal',
    'getglobal',
    'setfield',
    'setindex',
    'tablefield',
    'tableindex',
}

---@async
return function (uri, callback)
    local ast = files.getState(uri)
    if not ast then
        return
    end

    ---@async
    guide.eachSourceTypes(ast.ast, types, function (source)
        await.delay()
        if vm.getInfer(source):view(uri) == 'unknown' then
            callback {
                start   = source.start,
                finish  = source.finish,
                message = MESSAGE,
            }
        end
    end)
end
