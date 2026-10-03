local files           = require 'files'
local guide           = require 'parser.guide'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Redefined local `%s`.'

-- wowlua-ls splits this into `redefined-local` (same scope) and `shadowed-local` (outer scope); here one
-- diagnostic covers both, so its `shadowed-local` is accepted as another name for it
protoDiagnostic.registerAlias('shadowed-local', 'redefined-local')

protoDiagnostic.register {
    'redefined-local',
} {
    group    = 'redefined',
    severity = 'Hint',
    status   = 'Opened',
    description = 'Enable redefined local variable diagnostics.',
}

---@async
return function (uri, callback)
    local ast = files.getState(uri)
    if not ast then
        return
    end

    ---@async
    guide.eachSourceType(ast.ast, 'local', function (source)
        local name = source[1]
        if name == '_'
        or name == ast.ENVMode then
            return
        end
        await.delay()
        local exist = guide.getLocal(source, name, source.start-1)
        if exist then
            callback {
                start   = source.start,
                finish  = source.finish,
                message = MESSAGE:format(name),
                related = {
                    {
                        start  = exist.start,
                        finish = exist.finish,
                        uri    = uri,
                    }
                },
            }
        end
    end)
end
