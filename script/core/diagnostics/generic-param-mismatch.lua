local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Cannot assign `%s` to parameter `%s`: `%s` was already inferred as `%s` from parameter `%s`.'

protoDiagnostic.register {
    'generic-param-mismatch',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for calls of a generic function where two arguments bound to the same type parameter (`---@param a T`, `---@param b T`) have types that do not fit together: the first argument binds `T`, a later one has to be assignable to it (or be wider, which widens `T`).',
}

--- What `arg` offers as a candidate, or nil when it says nothing about `T`: nothing known (`unknown`, `any`), only
--- `nil` (an omitted or explicitly empty argument, the parameter is allowed to take it), or still a generic itself.
---@param uri uri
---@param node vm.node
---@return vm.node?
local function candidateOf(uri, node)
    local infer = vm.getInfer(node)
    if infer:hasAny(uri) then
        return nil
    end
    local view = infer:view(uri)
    if view == 'unknown' or view == 'nil' then
        return nil
    end
    local out = node:copy()
    for obj in out:eachObject() do
        if obj.type == 'doc.generic.name' or obj.type == 'generic' then
            return nil
        end
    end
    -- (an optional argument is still a `T`: the nil part is what the parameter's own `?` or `T?` allows)
    return out:removeOptional()
end

--- The type parameters a parameter's declared type names directly (`T`, `T?`, `T|nil`, `nosecret<T>`), not inside a
--- container (`T[]`, `fun(x: T)`): those are bound through their elements.
---@param signNode vm.node
---@return string[]
local function directGenerics(signNode)
    ---@type string[]
    local names = {}
    for obj in signNode:eachObject() do
        if obj.type == 'doc.generic.name' then
            names[#names+1] = obj[1] --[[@as string]]
        end
    end
    return names
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
        if not call.args or #call.args < 2 then
            return
        end
        delayer:delay()
        -- the one signature this call can be: overload selection (arity, then argument types) leaves exactly one function.
        -- It leaves nothing for a method called with a colon (the arity there counts `self`): then the callee's only function.
        local funcs = vm.getExactMatchedFunctions(call.node, call.args)
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
        local func = funcs[1]
        -- (a method call's arguments start with `self`, and so does the parameter list of a method)
        local sign = vm.getSign(func)
        if not sign then
            return
        end

        ---@type table<string, { node: vm.node, index: integer }>
        local bound = {}
        for i, arg in ipairs(call.args) do
            local signNode = sign.signList[i]
            if not signNode then
                break
            end
            local names = directGenerics(signNode)
            if #names == 0 then
                goto CONTINUE
            end
            do
                local candidate = candidateOf(uri, vm.compileNode(arg))
                if not candidate then
                    goto CONTINUE
                end
                for _, name in ipairs(names) do
                    local first = bound[name]
                    if not first then
                        bound[name] = { node = candidate, index = i }
                    elseif vm.canCastType(uri, first.node, candidate) then
                        -- fits
                    elseif vm.canCastType(uri, candidate, first.node) then
                        -- wider than what was bound: T becomes that (`f(1, 2.5)`, `f(x, xOrNil)`)
                        first.node = candidate
                    else
                        local params = func.args or {}
                        callback {
                            start   = arg.start,
                            finish  = arg.finish,
                            message = MESSAGE:format(
                                vm.getInfer(candidate):view(uri),
                                tostring(params[i] and params[i][1] or i),
                                name,
                                vm.getInfer(first.node):view(uri),
                                tostring(params[first.index] and params[first.index][1] or first.index)
                            ),
                        }
                    end
                end
            end
            ::CONTINUE::
        end
    end)
end
