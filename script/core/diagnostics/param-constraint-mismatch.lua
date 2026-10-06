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
    description = 'Enable diagnostics for calls of a method marked `---@requires T: Constraint` on a receiver whose class type argument for `T` does not satisfy the constraint (`Widget<number>` where the method requires `T: Frame`). The receiver may also inherit the method from a parent class (`---@class Numbers: Widget<number>`). The wowlua-ls diagnostic of the same name.',
}

---@class constraint.requirement
---@field doc    parser.object the `doc.requires`
---@field owners table<string, true> the classes the method is declared on

--- The `---@requires` docs of the definitions of the method a call names, with the classes each definition belongs to.
---@param callee parser.object a `getmethod` / `getfield`
---@return constraint.requirement[]
local function requirementsOf(callee)
    ---@type constraint.requirement[]
    local result = {}
    for _, def in ipairs(vm.getDefs(callee)) do
        if def.type ~= 'function' then
            goto CONTINUE
        end
        do
            ---@type table<string, true>?
            local owners
            for _, doc in ipairs(def.bindDocs or {}) do
                if doc.type == 'doc.requires' and doc.name and doc.extends then
                    owners = owners or vm.getMethodOwners(def)
                    result[#result+1] = { doc = doc, owners = owners }
                end
            end
        end
        ::CONTINUE::
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
            -- `Widget<Frame>` (the class and the types its parameters stand for) or a class that inherits from one
            ---@cast obj parser.object|vm.global
            local chain = vm.getClassGenericChain(uri, obj)
            for _, requirement in ipairs(requirements) do
                local doc  = requirement.doc
                local name = doc.name[1] --[[@as string]]
                -- the class the method is declared on (the one entry of the chain), with the arguments the receiver gives it
                for _, entry in ipairs(chain) do
                    local bound = entry.arguments and entry.arguments[name]
                    if bound and requirement.owners[entry.class] then
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
        end
    end)
end
