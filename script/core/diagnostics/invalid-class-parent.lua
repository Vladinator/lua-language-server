local files           = require 'files'
local guide           = require 'parser.guide'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'A class cannot extend the primitive type `%s`.'

protoDiagnostic.register {
    'invalid-class-parent',
} {
    group    = 'type-check',
    severity = 'Warning',
    -- off by default here: `---@class AddOnName : string` (an opaque, named string type) is a common idiom in addon annotations
    status   = 'None',
    description = 'Enable diagnostics for a `---@class Child : Parent` whose parent is a primitive type (`string`, `number`, `integer`, `boolean`, `nil`, `function`, `thread`): a class describes a table. `table`, `userdata` and `any` stay allowed. Off by default: `---@class Name : string` is also used on purpose, as a named string type.',
}

--- What a class cannot extend. `table` is what classes are, `userdata` is how the engine's objects are annotated, `any` and
--- `unknown` say nothing.
---@type table<string, true>
local PRIMITIVES = {
    ['string']   = true,
    ['number']   = true,
    ['integer']  = true,
    ['boolean']  = true,
    ['nil']      = true,
    ['function'] = true,
    ['thread']   = true,
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state or not state.ast.docs then
        return
    end

    guide.eachSourceType(state.ast.docs, 'doc.class', function (doc)
        for _, parent in ipairs(doc.extends or {}) do
            local name = parent.type == 'doc.extends.name' and parent[1]
            if type(name) == 'string' and PRIMITIVES[name] then
                callback {
                    start   = parent.start,
                    finish  = parent.finish,
                    message = MESSAGE:format(name),
                }
            end
        end
    end)
end
