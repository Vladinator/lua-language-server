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

--- The type parameters a parameter's declared type names directly (`T`, `T?`, `T|nil`, or `T` under a type keyword a plugin registers), not inside a
--- container (`T[]`, `fun(x: T)`): those are bound through their elements.
---@param signNode vm.node
---@return string[]
local function directGenerics(signNode)
    ---@type string[]
    local names = {}
    for obj in signNode:eachObject() do
        if obj.type == 'doc.generic.name' then
            names[#names+1] = obj[1]
        end
    end
    return names
end

--- The element type of the arrays a node declares (`Frame[]`); nil when it is not declared as an array (a plain `table`, an inferred table).
---@param node vm.node
---@return vm.node?
local function elementNode(node)
    ---@type vm.node?
    local result
    for obj in node:eachObject() do
        if obj.type == 'doc.type.array' and obj.node then
            result = result or vm.createNode()
            result:merge(vm.compileNode(obj.node))
        elseif obj.type ~= 'local' and obj.type ~= 'variable' and obj.type ~= 'table' then
            return nil
        end
    end
    return result
end

--- The type parameters a parameter names as the element of an array (`T[]`): the argument binds them through the element type it declares.
---@param signNode vm.node
---@return string[]
local function arrayGenerics(signNode)
    ---@type string[]
    local names = {}
    for obj in signNode:eachObject() do
        if obj.type == 'doc.type.array' and obj.node and obj.node.type == 'doc.generic.name' then
            names[#names+1] = obj.node[1]
        end
    end
    return names
end

--- The type parameters a callback parameter names (`---@param map fun(value: number, arg: A)`), with what the function given there declares for
--- that parameter: a function that takes `y: number` there binds `A` to `number`. Only declared types bind (an unannotated parameter says nothing).
---@param uri     uri
---@param signNode vm.node
---@param argNode  vm.node
---@return { name: string, node: vm.node }[]
local function callbackGenerics(uri, signNode, argNode)
    ---@type { name: string, node: vm.node }[]
    local found = {}
    for obj in signNode:eachObject() do
        if obj.type == 'doc.type.function' then
            for position, param in ipairs(obj.args or {}) do
                local unit = param.extends
                if unit and unit.type == 'doc.type' and unit.types and #unit.types == 1 then
                    unit = unit.types[1]
                end
                if unit and unit.type == 'doc.generic.name' and not param.optional then
                    for f in argNode:eachObject() do
                        ---@type vm.node?
                        local declared
                        if f.type == 'doc.type.function' then
                            local given = f.args and f.args[position]
                            declared = given and given.extends and vm.compileNode(given.extends)
                        elseif f.type == 'function' then
                            local given = f.args and f.args[position]
                            local node = given and vm.compileNode(given)
                            declared = node and node.hasDefined and node or nil
                        end
                        local candidate = declared and candidateOf(uri, declared)
                        if candidate then
                            found[#found+1] = { name = unit[1], node = candidate }
                        end
                    end
                end
            end
        end
    end
    return found
end

--- The type parameters a parameter names as the key or the value of a table type (`table<K, V>`, `{ [K]: V }`): name -> 'key' | 'value'.
---@param signNode vm.node
---@return { name: string, slot: 'key'|'value' }[]
local function tableGenerics(signNode)
    ---@type { name: string, slot: 'key'|'value' }[]
    local found = {}
    ---@param unit parser.object?
    ---@param slot 'key'|'value'
    local function add(unit, slot)
        if unit and unit.type == 'doc.type' and unit.types and #unit.types == 1 then
            unit = unit.types[1]
        end
        if unit and unit.type == 'doc.generic.name' then
            found[#found+1] = { name = unit[1], slot = slot }
        end
    end
    for obj in signNode:eachObject() do
        if obj.type == 'doc.type.sign' and obj.node and obj.node[1] == 'table' and obj.signs then
            add(obj.signs[1], 'key')
            add(obj.signs[2], 'value')
        elseif obj.type == 'doc.type.table' and not obj.isTuple then
            for _, field in ipairs(obj.fields or {}) do
                if field.name and field.name.type == 'doc.type' then
                    add(field.name, 'key')
                    add(field.extends, 'value')
                end
            end
        end
    end
    return found
end

--- The key and the value types the table types of a node declare (`table<number, boolean>`, `{ [K]: V }`, `V[]`); nil when part of the
--- node says nothing about them (a class, `any`, an undeclared table).
---@param node vm.node
---@return vm.node? key
---@return vm.node? value
local function tableSlots(node)
    local key, value = vm.createNode(), vm.createNode()
    local count = 0
    for obj in node:eachObject() do
        if obj.type == 'doc.type.sign' and obj.node and obj.node[1] == 'table' and obj.signs and obj.signs[1] and obj.signs[2] then
            key:merge(vm.compileNode(obj.signs[1]))
            value:merge(vm.compileNode(obj.signs[2]))
            count = count + 1
        elseif obj.type == 'doc.type.table' and not obj.isTuple then
            for _, field in ipairs(obj.fields or {}) do
                if field.name.type ~= 'doc.type' then
                    return nil, nil
                end
                -- (the builtin `table<K, V>` class every table type also is: its own `K` / `V` are not a declaration)
                local k = vm.compileNode(field.name)
                local isGeneric = false
                for kobj in k:eachObject() do
                    if kobj.type == 'doc.generic.name' or kobj.type == 'generic' then
                        isGeneric = true
                    end
                end
                if not isGeneric and field.extends then
                    key:merge(k)
                    value:merge(vm.compileNode(field.extends))
                    count = count + 1
                end
            end
        elseif obj.type == 'doc.type.array' and obj.node then
            key:merge(vm.declareGlobal('type', 'integer'))
            value:merge(vm.compileNode(obj.node))
            count = count + 1
        elseif obj.type ~= 'local' and obj.type ~= 'variable' and obj.type ~= 'table' and obj.type ~= 'doc.type.sign' then
            return nil, nil
        end
    end
    if count == 0 then
        return nil, nil
    end
    return key, value
end

--- The name of the i-th parameter of a function or of a `fun(...)` type, else its position.
---@param func parser.object
---@param i    integer
---@return string
local function paramName(func, i)
    local param = (func.args or {})[i]
    if not param then
        return tostring(i)
    end
    -- (a `fun(list: T[])` argument keeps its name in `name`, the parameter of a function is the name itself)
    local name = param.name and param.name[1] or param[1]
    return tostring(name or i)
end

--- Of the signatures a call can mean (the function and its `---@overload`s) that fit it by arity, the only one that has exactly as many
--- parameters as the call has arguments (nil: none, or more than one, or no overload at all).
---@param call parser.object
---@return parser.object?
local function exactArityFunction(call)
    local matched = vm.getMatchedFunctions(call.node, call.args)
    if not matched then
        return nil
    end
    ---@type parser.object[]
    local all = {}
    local hasOverload = false
    for _, func in ipairs(matched) do
        all[#all+1] = func
        for _, doc in ipairs(func.bindDocs or {}) do
            if doc.type == 'doc.overload' and doc.overload then
                hasOverload = true
                local min, max = vm.countParamsOfFunction(doc.overload)
                local amin, amax = vm.countList(call.args)
                if amin >= min and amax <= max then
                    all[#all+1] = doc.overload
                end
            end
        end
    end
    if not hasOverload then
        return nil
    end
    ---@type parser.object?
    local found
    for _, func in ipairs(all) do
        local _, max = vm.countParamsOfFunction(func)
        if max == #call.args then
            if found then
                return nil
            end
            found = func
        end
    end
    return found
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
                    funcs[#funcs+1] = obj
                end
            end
        end
        -- several signatures fit (`table.insert(list, value)` fits `(list, pos, value?)` and `fun<T>(list: T[], value: T)`): the one
        -- that takes exactly the arguments written, when it is the only one, is the call's
        local exact = exactArityFunction(call)
        if exact then
            funcs = { exact }
        end
        if #funcs ~= 1 then
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
            -- what each type parameter of this parameter is bound to by this argument
            ---@type { name: string, node: vm.node }[]
            local entries = {}
            -- a function given for `fun(value: number, arg: A)`: what it declares for `arg` binds `A`
            for _, entry in ipairs(callbackGenerics(uri, signNode, vm.compileNode(arg))) do
                local first = bound[entry.name]
                if not first then
                    bound[entry.name] = { node = entry.node, index = i }
                end
            end
            if #names > 0 then
                local candidate = candidateOf(uri, vm.compileNode(arg))
                for _, name in ipairs(names) do
                    entries[#entries+1] = candidate and { name = name, node = candidate } or nil
                end
            else
                -- `T[]`: the element type the argument declares binds `T`
                local elementNames = arrayGenerics(signNode)
                if #elementNames > 0 then
                    local element = elementNode(vm.compileNode(arg))
                    local candidate = element and candidateOf(uri, element)
                    for _, name in ipairs(elementNames) do
                        entries[#entries+1] = candidate and { name = name, node = candidate } or nil
                    end
                else
                    -- `table<K, V>` / `{ [K]: V }`: the key and the value types the argument declares bind `K` and `V`
                    local slots = tableGenerics(signNode)
                    if #slots > 0 then
                        local key, value = tableSlots(vm.compileNode(arg))
                        for _, slot in ipairs(slots) do
                            local slotNode = slot.slot == 'key' and key or value
                            local candidate = slotNode and candidateOf(uri, slotNode)
                            entries[#entries+1] = candidate and { name = slot.name, node = candidate } or nil
                        end
                    end
                end
            end
            for _, entry in ipairs(entries) do
                local name, candidate = entry.name, entry.node
                local first = bound[name]
                if not first then
                    bound[name] = { node = candidate, index = i }
                elseif vm.canCastType(uri, first.node, candidate) then
                    -- fits
                elseif vm.canCastType(uri, candidate, first.node) then
                    -- wider than what was bound: T becomes that (`f(1, 2.5)`, `f(x, xOrNil)`)
                    first.node = candidate
                else
                    callback {
                        start   = arg.start,
                        finish  = arg.finish,
                        message = MESSAGE:format(
                            vm.getInfer(candidate):view(uri),
                            paramName(func, i),
                            name,
                            vm.getInfer(first.node):view(uri),
                            paramName(func, first.index)
                        ),
                    }
                end
            end
        end
    end)
end
