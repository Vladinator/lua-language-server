local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Type `%s` does not satisfy the constraint `%s` of type parameter `%s`.'
local KEYOF   = 'Argument `%s` does not match `%s`, the keys of the other argument.'
local MEMBER  = 'Type `%s` does not satisfy the constraint `%s` of type parameter `%s`: `%s` does not fit.'
local ARGUMENT = 'Type `%s` does not satisfy the constraint `%s` of type parameter `%s` of `%s`.'

protoDiagnostic.register {
    'generic-constraint-mismatch',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for the type arguments of a class or an alias that do not satisfy the constraint of their type parameter (`Widget<number>` where `---@class Widget<T: Frame>`), and for calls of a generic function where an argument does not fit a `keyof` of another argument: the type bound to a type parameter does not satisfy a constraint that names another type parameter (`---@generic K: keyof T`), or the argument of a parameter typed `keyof T` (`---@param key keyof T`, `---@param ... keyof T`: every extra argument) is not a key of `T`. A constraint on its own (`---@generic T: Base`) is already reported by `param-type-mismatch`. The wowlua-ls diagnostic of the same name.',
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

--- The `---@param` doc of a parameter, by its name (`...` for the variadic one).
---@param func parser.object
---@param name string|integer
---@return parser.object?
local function paramDoc(func, name)
    for _, doc in ipairs(func.bindDocs or {}) do
        if doc.type == 'doc.param' and doc.param and doc.param[1] == name then
            return doc
        end
    end
    return nil
end

--- Does the type contain a `keyof`?
---@param typeDoc parser.object
---@return boolean
local function hasKeyof(typeDoc)
    local found = false
    guide.eachSource(typeDoc, function (src)
        if src.type == 'doc.type.keyof' then
            found = true
        end
    end)
    return found
end

--- A parameter typed `keyof T` (`---@param key keyof T`, `---@param ... keyof T`: every extra argument) takes the argument
--- against the keys of the type `T` was bound to by another argument.
---@async
---@param uri      uri
---@param call     parser.object
---@param func     parser.object
---@param resolved table<string, vm.node>
---@param callback fun(result: table)
local function checkKeyofParams(uri, call, func, resolved, callback)
    local params = func.args or {}
    -- (a call with a colon has the receiver as its first argument, as the parameter list of the method has `self`)
    local last = params[#params]
    for i, arg in ipairs(call.args or {}) do
        local param = params[i]
        if not param and last and last.type == '...' then
            param = last
        end
        local doc = param and paramDoc(func, param[1])
        local typeDoc = doc and doc.extends
        if not typeDoc or not hasKeyof(typeDoc) then
            goto CONTINUE
        end
        do
            local expected = vm.compileNode(vm.cloneObject(typeDoc, resolved) --[[@as parser.object]])
            local given    = vm.compileNode(arg)
            local givenView = arg.type == 'string' and ('"%s"'):format(arg[1]) or vm.getInfer(given):view(uri)
            if givenView == 'unknown' or givenView == 'nil' or vm.getInfer(given):hasAny(uri) then
                goto CONTINUE
            end
            if vm.canCastType(uri, expected, given) then
                goto CONTINUE
            end
            callback {
                start   = arg.start,
                finish  = arg.finish,
                message = KEYOF:format(givenView, vm.getInfer(expected):view(uri)),
            }
        end
        ::CONTINUE::
    end
end

--- Does the type name something that is not defined (`undefined-doc-name` reports that already)?
---@param typeDoc parser.object
---@return boolean
local function namesUndefinedType(typeDoc)
    local found = false
    guide.eachSourceType(typeDoc, 'doc.type.name', function (src)
        local typeGlobal = vm.getGlobal('type', src[1] --[[@as string]])
        if not typeGlobal or #typeGlobal:getSets(guide.getUri(src)) == 0 then
            found = true
        end
    end)
    return found
end

--- `Widget<number>` where the class says `---@class Widget<T: Frame>` (an alias too: `---@alias Pair<K: string, V>`): each type argument has
--- to satisfy the constraint of its type parameter. (An argument that is a type parameter of the function around it, or a constraint that names
--- another type parameter, compiles to something that casts: nothing is reported for them.)
---@async
---@param uri      uri
---@param state    parser.state
---@param callback fun(result: table)
local function checkTypeArguments(uri, state, callback)
    guide.eachSourceType(state.ast, 'doc.type.sign', function (usage)
        if not usage.node or not usage.signs then
            return
        end
        local typeGlobal = vm.getGlobal('type', usage.node[1] --[[@as string]])
        if not typeGlobal then
            return
        end
        ---@type parser.object[]?
        local declared
        for _, set in ipairs(typeGlobal:getSets(uri)) do
            if (set.type == 'doc.class' or set.type == 'doc.alias') and set.signs then
                declared = set.signs
                break
            end
        end
        for i, sign in ipairs(declared or {}) do
            local arg = usage.signs[i]
            if arg and sign.extends and not namesUndefinedType(arg) then
                local given = vm.compileNode(arg)
                local view  = vm.getInfer(given):view(uri)
                do
                    local constraint = vm.compileNode(sign.extends)
                    if not vm.canCastType(uri, constraint, given:copy():removeOptional()) then
                        callback {
                            start   = arg.start,
                            finish  = arg.finish,
                            message = ARGUMENT:format(view, vm.getInfer(constraint):view(uri), tostring(sign[1]), tostring(usage.node[1])),
                        }
                    end
                end
            end
        end
    end)
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    checkTypeArguments(uri, state, callback)

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
        checkKeyofParams(uri, call, funcs[1], resolved, callback)
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
