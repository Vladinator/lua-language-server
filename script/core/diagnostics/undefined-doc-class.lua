local files           = require 'files'
local vm              = require 'vm'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Undefined class `%s`.'

protoDiagnostic.register {
    'undefined-doc-class',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for class annotations in which an undefined class is referenced.',
}

return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    if not state.ast.docs then
        return
    end

    ---@type table<any, boolean>
    local cache = {}

    for _, doc in ipairs(state.ast.docs) do
        if doc.type == 'doc.class' then
            if not doc.extends then
                goto CONTINUE
            end
            for _, ext in ipairs(doc.extends) do
                local name = ext.type == 'doc.extends.name' and ext[1]
                if name then
                    local docs = vm.getDocSets(uri, name)
                    if cache[name] == nil then
                        cache[name] = false
                        for _, otherDoc in ipairs(docs) do
                            if otherDoc.type == 'doc.class' then
                                cache[name] = true
                                break
                            end
                        end
                    end
                    if not cache[name] then
                        callback {
                            start   = ext.start,
                            finish  = ext.finish,
                            related = cache,
                            message = MESSAGE:format(name)
                        }
                    end
                end
            end
        end
        ::CONTINUE::
    end
end
