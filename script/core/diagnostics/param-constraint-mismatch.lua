local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Method `%s` requires `%s: %s`, but the receiver\'s type argument for `%s` is `%s`.'

protoDiagnostic.register {
    'param-constraint-mismatch',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for calls of a method marked `---@requires T: Constraint` on a receiver whose class type argument for `T` does not satisfy the constraint (`Widget<number>` where the method requires `T: Frame`). The wowlua-ls diagnostic of the same name.',
}

--- The `---@requires` docs of the definitions of the method a call names.
---@param callee parser.object a `getmethod` / `getfield`
---@return parser.object[]
local function requirementsOf(callee)
    ---@type parser.object[]
    local result = {}
    for _, def in ipairs(vm.getDefs(callee)) do
        if def.type == 'function' then
            for _, doc in ipairs(def.bindDocs or {}) do
                if doc.type == 'doc.requires' and doc.name and doc.extends then
                    result[#result+1] = doc
                end
            end
        end
    end
    return result
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    ---@async
    guide.eachSourceType(state.ast, 'call', function (call)
        delayer:delay()
        local callee = call.node
        if not callee or (callee.type ~= 'getmethod' and callee.type ~= 'getfield') then
            return
        end
        local requirements = requirementsOf(callee)
        if #requirements == 0 then
            return
        end
        local target = callee.type == 'getmethod' and callee.method or callee.field
        if not target then
            return
        end
        local methodName = guide.getKeyName(callee)
        for obj in vm.compileNode(callee.node):eachObject() do
            -- `Widget<Frame>`: the class and the types its parameters stand for
            if obj.type ~= 'doc.type.sign' or not obj.node or not obj.signs then
                goto CONTINUE
            end
            do
                local classGlobal = vm.getGlobal('type', obj.node[1])
                local arguments = classGlobal and vm.getClassGenericMap(uri, classGlobal, obj.signs)
                if not arguments then
                    goto CONTINUE
                end
                for _, doc in ipairs(requirements) do
                    local name  = doc.name[1] --[[@as string]]
                    local bound = arguments[name]
                    if bound then
                        local constraint = vm.compileNode(doc.extends)
                        if not vm.canCastType(uri, constraint, bound:copy():removeOptional()) then
                            callback {
                                start   = target.start,
                                finish  = target.finish,
                                message = MESSAGE:format(
                                    tostring(methodName), name, vm.getInfer(constraint):view(uri), name, vm.getInfer(bound):view(uri)
                                ),
                            }
                        end
                    end
                end
            end
            ::CONTINUE::
        end
    end)
end
