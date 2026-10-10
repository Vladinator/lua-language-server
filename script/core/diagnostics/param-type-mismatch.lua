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
            ---@cast f parser.object
            method = f
            break
        end
    end
    local receiverNode = vm.compileNode(receiver)
    for rn in receiverNode:eachObject() do
        -- `Box<number>`, or a class that inherits from one (`---@class NumberBox: Box<number>`)
        if rn.type == 'doc.type.sign' or (rn.type == 'global' and rn.cate == 'type') then
            ---@cast rn parser.object|vm.global
            local map = vm.getReceiverGenericMap(uri, rn, method)
            if map then
                return map
            end
        end
    end
    return nil
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

---@param funcNode vm.node
---@param i integer
---@param classGenericMap table<string, vm.node>?
---@return vm.node?
local function getDefNode(funcNode, i, classGenericMap)
    local defNode = vm.createNode()
    for src in funcNode:eachObject() do
        if src.type == 'function'
        or src.type == 'doc.type.function' then
            ---@cast src parser.object
            local param = paramAt(src, i)
            if param then
                local paramNode = vm.compileNode(param)
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
                    defNode:merge(newNode)
                else
                    defNode:merge(paramNode)
                end
                if param[1] == '...' then
                    defNode:addOptional()
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
            ---@cast f parser.object
            local param = paramAt(f, i)
            if param then
                defNode:merge(vm.compileNode(param))
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
            local defNode = getDefNode(funcNode, i, classGenericMap)
            if not defNode then
                goto CONTINUE
            end
            if arg.type == 'self'
            or ((arg.type == 'getfield' or arg.type == 'getindex') and not config.get(uri, 'Lua.type.checkFieldNilArguments')) then
                -- (the original LuaLS could not narrow a field, so it took the falsy values out of a field read before the check;
                -- `Lua.type.checkFieldNilArguments` keeps them: a field is narrowed here like a variable)
                refNode = refNode:copy():setTruthy()
            end
            local errs = {}
            if not vm.canCastType(uri, defNode, refNode, errs) then
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
