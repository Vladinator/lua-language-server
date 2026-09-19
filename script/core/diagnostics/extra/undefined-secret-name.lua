-- Companion of need-check-secret.lua: `---@secret a, b` / `---@secret-unwrap a, b`
-- must name locals of the statement the tag is bound to; a name that matches
-- nothing (a typo, or a local that was renamed) silently does nothing, so report it.

local files           = require 'files'
local guide           = require 'parser.guide'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'No local named `%s` in the statement this tag applies to.'

protoDiagnostic.register {
    'undefined-secret-name',
} {
    group    = 'secret',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for a name in `---@secret a, b` / `---@secret-unwrap a, b` that is not a local of the statement the tag applies to.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state or not state.ast.docs then
        return
    end

    ---@type table<parser.object, table<string, true>> tag doc -> names of the locals it is bound to
    local bound = {}
    guide.eachSourceType(state.ast, 'local', function (source)
        if not source.bindDocs then
            return
        end
        for _, doc in ipairs(source.bindDocs) do
            if (doc.type == 'doc.secret' or doc.type == 'doc.secret-unwrap') and doc.names then
                ---@type table<string, true>
                local names = bound[doc] or {}
                bound[doc] = names
                names[source[1] --[[@as string]]] = true
            end
        end
    end)

    for _, doc in ipairs(state.ast.docs) do
        if (doc.type == 'doc.secret' or doc.type == 'doc.secret-unwrap') and doc.names then
            local locals = bound[doc] or {}
            for _, name in ipairs(doc.names) do
                if not locals[name[1]] then
                    callback {
                        start   = name.start,
                        finish  = name.finish,
                        message = MESSAGE:format(name[1]),
                    }
                end
            end
        end
    end
end
