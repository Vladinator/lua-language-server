local files           = require 'files'
local config          = require 'config'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Cannot assign `%s` to parameter `%s`.'

protoDiagnostic.register {
    'param-type-mismatch',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for function calls where the type of a provided parameter does not match the type of the annotated function definition.',
}

---@param defNode  vm.node
---@param classGenericMap table<string, vm.node>?
local function expandGenerics(defNode, classGenericMap)
    ---@type parser.object[]
    local generics = {}
    for dn in defNode:eachObject() do
        if dn.type == 'doc.generic.name' then
            ---@cast dn parser.object
            generics[#generics+1] = dn
        end
    end

    for _, generic in ipairs(generics) do
        defNode:removeObject(generic)
    end

    for _, generic in ipairs(generics) do
        -- First check if this generic is a class generic that can be resolved
        local genericName = generic[1]
        if classGenericMap and genericName and classGenericMap[genericName] then
            defNode:merge(classGenericMap[genericName])
        else
            -- Fall back to constraint or unknown
            local limits = generic.generic and generic.generic.extends
            if limits then
                -- (`---@generic K: keyof self`: `self` is the receiver of this call, not the class that declares the method)
                if classGenericMap and classGenericMap.self then
                    limits = vm.cloneObject(limits, { self = classGenericMap.self }) --[[@as parser.object]]
                end
                defNode:merge(vm.compileNode(limits))
            else
                local unknownType = vm.declareGlobal('type', 'unknown')
                defNode:merge(unknownType)
            end
        end
    end
end

---@param uri uri
---@param source parser.object
---@return table<string, vm.node>?
---@param funcNode vm.node what the call resolves to
local function getReceiverGenericMap(uri, source, funcNode)
    local callNode = source.node
    if not callNode then
        return nil
    end
    -- Only resolve generics for method calls (obj:method()), not static calls (Class.method())
    if callNode.type ~= 'getmethod' then
        return nil
    end
    local receiver = callNode.node
    if not receiver then
        return nil
    end
    -- the method the call resolves to: which class declares it decides which type arguments it is read with
    ---@type parser.object?
    local method
    for f in funcNode:eachObject() do
        if f.type == 'function' then
            method = f
            break
        end
    end
    local receiverNode = vm.compileNode(receiver)
    ---@type table<string, vm.node>
    local result = { self = receiverNode }
    for rn in receiverNode:eachObject() do
        -- `Box<number>`, or a class that inherits from one (`---@class NumberBox: Box<number>`)
        if rn.type == 'doc.type.sign' or (rn.type == 'global' and rn.cate == 'type') then
            local map = vm.getReceiverGenericMap(uri, rn, method)
            if map then
                for name, node in pairs(map) do
                    result[name] = node
                end
                break
            end
        end
    end
    return result
end

--- The parameter an argument at position `i` goes to: its own, or the `...` of the function when the position is past the declared
--- ones (`---@param ... number` is a type for every extra argument, as a rest parameter is in TypeScript).
---@param func parser.object
---@param i    integer
---@return parser.object?
local function paramAt(func, i)
    local args = func.args
    if not args then
        return nil
    end
    local param = args[i]
    if param then
        return param
    end
    local last = args[#args]
    -- (a `fun(...: number)` type names it in `.name`)
    if last and (last[1] == '...' or (last.name and last.name[1] == '...')) then
        return last
    end
    return nil
end

--- A callback type the generic function names as a parameter (`fun(key: K): V`), with the type parameters the call bound put in: what the
--- argument given for it is compared with. The other parts of the parameter type are left alone.
---@param uri      uri
---@param call     parser.object
---@param func     parser.object the function the call resolves to
---@param paramNode vm.node
---@return vm.node
local function withBoundCallbacks(uri, call, func, paramNode)
    local sign = func.type == 'function' and vm.getSign(func)
    if not sign then
        return paramNode
    end
    ---@type table<string, vm.node>?
    local resolved
    local result = vm.createNode()
    for obj in paramNode:eachObject() do
        ---@type boolean?
        local open
        if obj.type == 'doc.type.function' then
            guide.eachSourceType(obj, 'doc.generic.name', function (src)
                if not src._resolved then
                    open = true
                end
            end)
        end
        if open then
            resolved = resolved or sign:resolve(uri, call.args)
            local cloned = vm.cloneObject(obj, resolved)
            result:merge(cloned and vm.compileNode(cloned) or obj)
        else
            result:merge(obj)
        end
    end
    if paramNode:isOptional() then
        result:addOptional()
    end
    return result
end

---@param uri      uri
---@param call     parser.object
---@param funcNode vm.node
---@param i integer
---@param classGenericMap table<string, vm.node>?
---@return vm.node?
local function getDefNode(uri, call, funcNode, i, classGenericMap)
    local defNode = vm.createNode()
    for src in funcNode:eachObject() do
        if src.type == 'function'
        or src.type == 'doc.type.function' then
            local param = paramAt(src, i)
            if param then
                local paramNode = withBoundCallbacks(uri, call, src, vm.compileNode(param))
                -- Check for global type references that match class generic params
                if classGenericMap then
                    local newNode = vm.createNode()
                    for pn in paramNode:eachObject() do
                        if pn.type == 'global' and pn.cate == 'type' and classGenericMap[pn.name] then
                            -- Replace the global type reference with the resolved type
                            newNode:merge(classGenericMap[pn.name])
                        else
                            newNode:merge(pn)
                        end
                    end
                    -- (a parameter written `x?` stays optional)
                    if paramNode:isOptional() then
                        newNode:addOptional()
                    end
                    defNode:merge(newNode)
                else
                    defNode:merge(paramNode)
                end
                if param[1] == '...' then
                    defNode:addOptional()
                end
            end
        elseif src.type == 'table' then
            -- called through the `__call` of its metatable: the table is the first argument
            for _, func in ipairs(vm.getMetamethodFunctions('call', src)) do
                local param = paramAt(func, i + 1)
                if param then
                    defNode:merge(vm.compileNode(param))
                    if param[1] == '...' then
                        defNode:addOptional()
                    end
                end
            end
        end
    end
    if defNode:isEmpty() then
        return nil
    end

    expandGenerics(defNode, classGenericMap)

    return defNode
end

--- A call of a function whose `...` is `params<F>` (wowlua-ls): each argument from the `...` on has to fit the matching parameter of the
--- function `F` was bound to (`call(spawn, "orc", 3)`: `spawn`'s).
---@async
---@param uri      uri
---@param call     parser.object
---@param callback fun(result: table)
local function checkParamsProjection(uri, call, callback)
    local target, varIndex = vm.getParamsProjection(uri, call)
    if not target or not varIndex then
        return
    end
    local args = call.args or {}
    for k = varIndex, #args do
        local param = target.args and target.args[k - varIndex + 1]
        local arg   = args[k]
        if not param or arg.type == 'varargs' then
            return
        end
        -- (a `...` of F, or a type parameter of F's own signature, has no type to check against here: nothing is claimed)
        local expected = vm.compileNode(param)
        local given    = vm.compileNode(arg)
        local errs = {}
        if not expected:isEmpty() and not vm.canCastType(uri, expected, given, errs) then
            callback {
                start   = arg.start,
                finish  = arg.finish,
                message = MESSAGE:format(vm.getInfer(given):view(uri), vm.getInfer(expected):view(uri))
                    .. '\n' .. vm.viewTypeErrorMessage(uri, errs),
            }
        end
    end
end

---@param funcNode vm.node
---@param i integer
---@return vm.node
local function getRawDefNode(funcNode, i)
    local defNode = vm.createNode()
    for f in funcNode:eachObject() do
        if f.type == 'function'
        or f.type == 'doc.type.function' then
            local param = paramAt(f, i)
            if param then
                defNode:merge(vm.compileNode(param))
            end
        elseif f.type == 'table' then
            for _, func in ipairs(vm.getMetamethodFunctions('call', f)) do
                local param = paramAt(func, i + 1)
                if param then
                    defNode:merge(vm.compileNode(param))
                end
            end
        end
    end
    return defNode
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@async
    guide.eachSourceType(state.ast, 'call', function (source)
        if not source.args then
            return
        end
        await.delay()
        checkParamsProjection(uri, source, callback)
        local funcNode = vm.compileNode(source.node)
        -- Get the class generic map for method calls on generic class instances
        local classGenericMap = getReceiverGenericMap(uri, source, funcNode)
        for i, arg in ipairs(source.args) do
            ---@type vm.node
            local refNode = vm.compileNode(arg)
            if not refNode then
                goto CONTINUE
            end
            local defNode = getDefNode(uri, source, funcNode, i, classGenericMap)
            if not defNode then
                goto CONTINUE
            end
            if arg.type == 'self'
            or ((arg.type == 'getfield' or arg.type == 'getindex') and not config.get(uri, 'Lua.type.checkFieldNilArguments')) then
                -- (the original LuaLS could not narrow a field, so it took the falsy values out of a field read before the check;
                -- `Lua.type.checkFieldNilArguments` keeps them: a field is narrowed here like a variable)
                refNode = refNode:copy():setTruthy()
            end
            ---@type typecheck.err[]
            local errs = {}
            local fits = vm.canCastType(uri, defNode, refNode, errs)
            -- `Lua.type.checkFieldNilArguments` asks for the nil of a field read even under `Lua.type.weakUnionCheck` (which takes a union for
            -- fitting as soon as one member does, nil included): the nil is checked on its own unless `Lua.type.weakNilCheck` ignores it
            if fits and (arg.type == 'getfield' or arg.type == 'getindex')
            and config.get(uri, 'Lua.type.checkFieldNilArguments')
            and not config.get(uri, 'Lua.type.weakNilCheck')
            and refNode:isOptional()
            and vm.isSubType(uri, 'nil', defNode) == false then
                fits = false
                errs[#errs+1] = 'TYPE_ERROR_OPTIONAL_DISMATCH'
                errs[#errs+1] = defNode
            end
            if not fits then
                local rawDefNode = getRawDefNode(funcNode, i)
                assert(errs)
                callback {
                    start   = arg.start,
                    finish  = arg.finish,
                    message = MESSAGE:format(
                        vm.getInfer(refNode):view(uri),
                        vm.getInfer(rawDefNode):view(uri)
                    ) .. '\n' .. vm.viewTypeErrorMessage(uri, errs),
                }
            end
            ::CONTINUE::
        end
    end)
end
