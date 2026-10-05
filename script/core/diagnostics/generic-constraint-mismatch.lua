local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Type `%s` does not satisfy the constraint `%s` of type parameter `%s`.'
local MEMBER  = 'Type `%s` does not satisfy the constraint `%s` of type parameter `%s`: `%s` does not fit.'

protoDiagnostic.register {
    'generic-constraint-mismatch',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for calls of a generic function where the type bound to a type parameter does not satisfy a constraint that names another type parameter (`---@generic K: keyof T`). A constraint on its own (`---@generic T: Base`) is already reported by `param-type-mismatch`. The argument that binds the type parameter is reported (the wowlua-ls diagnostic of the same name).',
}

--- Does the constraint name a type parameter (`keyof T`)? One that does not is checked by `param-type-mismatch` already (as `<T:Base>`).
---@param constraint parser.object
---@return boolean
local function namesTypeParameter(constraint)
    local found = false
    guide.eachSource(constraint, function (src)
        if src.type == 'doc.generic.name' then
            found = true
        end
    end)
    return found
end

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
                if not name or not object.extends or not resolved[name] or not namesTypeParameter(object.extends) then
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
                    -- a union names the member that does not fit
                    ---@type string[]
                    local failing = {}
                    local count = 0
                    for member in bound:copy():removeOptional():eachObject() do
                        count = count + 1
                        local single = vm.createNode(member)
                        if not vm.canCastType(uri, constraint, single) then
                            failing[#failing+1] = vm.getInfer(single):view(uri)
                        end
                    end
                    local constraintView = vm.getInfer(constraint):view(uri)
                    callback {
                        start   = target.start,
                        finish  = target.finish,
                        message = count > 1 and #failing > 0 and #failing < count and failing[1] ~= view
                            and MEMBER:format(view, constraintView, name, table.concat(failing, '`, `'))
                            or MESSAGE:format(view, constraintView, name),
                    }
                end
                ::CONTINUE::
            end
        end
    end)
end
