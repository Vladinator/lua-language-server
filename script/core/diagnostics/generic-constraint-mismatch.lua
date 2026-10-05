local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Type `%s` does not satisfy the constraint `%s` of type parameter `%s`.'

protoDiagnostic.register {
    'generic-constraint-mismatch',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for calls of a generic function where the type bound to a type parameter does not satisfy its constraint (`---@generic T: Base`, `---@generic K: keyof T`). The argument that binds the type parameter is reported (the wowlua-ls diagnostic of the same name).',
}

--- The type parameters a parameter's declared type names directly (`T`, `T?`, `T|nil`), not inside a container.
---@param signNode vm.node
---@param name     string
---@return boolean
local function namesDirectly(signNode, name)
    for obj in signNode:eachObject() do
        if obj.type == 'doc.generic.name' and obj[1] == name then
            return true
        end
    end
    return false
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
        -- the one function this call can be (see `generic-param-mismatch`)
        local funcs = vm.getExactMatchedFunctions(call.node, call.args or {})
        if not funcs or #funcs == 0 then
            funcs = {}
            for obj in vm.compileNode(call.node):eachObject() do
                if obj.type == 'function' or obj.type == 'doc.type.function' then
                    ---@cast obj parser.object
                    funcs[#funcs+1] = obj
                end
            end
        end
        if #funcs ~= 1 or funcs[1].type ~= 'function' then
            return
        end
        local sign = vm.getSign(funcs[1])
        if not sign or #sign.docGeneric == 0 then
            return
        end

        local resolved = sign:resolve(uri, call.args or {})
        if not resolved then
            return
        end
        for _, doc in ipairs(sign.docGeneric) do
            for _, object in ipairs(doc.generics) do
                local name = object.generic and object.generic[1] --[[@as string?]]
                if not name or not object.extends or not resolved[name] then
                    goto CONTINUE
                end
                do
                    local bound = resolved[name]
                    local view = vm.getInfer(bound):view(uri)
                    local constraint = vm.compileNode(vm.cloneObject(object.extends, resolved) --[[@as parser.object]])
                    if vm.canCastType(uri, constraint, bound:copy():removeOptional()) then
                        goto CONTINUE
                    end
                    local target = call
                    for i, arg in ipairs(call.args or {}) do
                        local signNode = sign.signList[i]
                        if signNode and namesDirectly(signNode, name) then
                            target = arg
                            break
                        end
                    end
                    callback {
                        start   = target.start,
                        finish  = target.finish,
                        message = MESSAGE:format(view, vm.getInfer(constraint):view(uri), name),
                    }
                end
                ::CONTINUE::
            end
        end
    end)
end
