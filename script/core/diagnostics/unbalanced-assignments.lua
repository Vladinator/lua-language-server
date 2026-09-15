local files           = require 'files'
local guide           = require 'parser.guide'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'The value is assigned as `nil` because the number of values is not enough. In Lua, `x, y = 1 ` is equivalent to `x, y = 1, nil` .'

protoDiagnostic.register {
    'unbalanced-assignments',
} {
    group    = 'unbalanced',
    severity = 'Warning',
    status   = 'Any',
}

local types = {
    'local',
    'setlocal',
    'setglobal',
    'setfield',
    'setindex' ,
}

---@async
return function (uri, callback)
    local ast = files.getState(uri)
    if not ast then
        return
    end

    ---@type parser.object?
    local last

    ---@param source parser.object
    local function checkSet(source)
        if source.value then
            last = source
        else
            if not last then
                return
            end
            if  last.start       <= source.start
            and last.value.start >= source.finish then
                callback {
                    start   = source.start,
                    finish  = source.finish,
                    message = MESSAGE
                }
            else
                last = nil
            end
        end
    end

    local delayer = await.newThrottledDelayer(1000)
    ---@async
    guide.eachSourceTypes(ast.ast, types, function (source)
        delayer:delay()
        checkSet(source)
    end)
end
