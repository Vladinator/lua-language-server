local guide         = require 'parser.guide'
---@class vm
local vm            = require 'vm.vm'

--- Find a generic name referenced in a doc.type.table's fields
--- that exists in the given genericMap.
---@param tableType parser.object  doc.type.table with fields
---@param genericMap table<string, vm.node>
---@return string?  The matching generic key name
local function findGenericInTableFields(tableType, genericMap)
    for _, field in ipairs(tableType.fields) do
        if field.extends then
            ---@type string?
            local found
            guide.eachSourceType(field.extends, 'doc.generic.name', function (src)
                if genericMap[src[1]] then
                    found = src[1]
                end
            end)
            if found then
                return found
            end
        end
    end
    return nil
end

--- Search for a generic name in extends tables of a class definition.
--- For classes like `@class list<T>: {[integer]:T}`, the [integer] field
--- lives in the extends doc.type.table, not in @field annotations.
---@param uri uri
---@param classGlobal vm.global
---@param genericMap table<string, vm.node>
---@return string?  The class generic name that maps to the integer field
local function findGenericInExtendsTable(uri, classGlobal, genericMap)
    for _, set in ipairs(classGlobal:getSets(uri)) do
        if set.type ~= 'doc.class' or not set.extends then
            goto CONTINUE
        end
        for _, ext in ipairs(set.extends) do
            if ext.type == 'doc.type.table' and ext.fields then
                local key = findGenericInTableFields(ext, genericMap)
                if key then
                    return key
                end
            end
        end
        ::CONTINUE::
    end
    return nil
end

---@class vm.sign
---@field parent    parser.object
---@field signList  vm.node[]
---@field docGeneric parser.object[]
---@field paramNames table<integer, string>? the names of the parameters of a function, by position (`returns<F, index>` reads the argument of `index`)
local mt = {}
mt.__index = mt
mt.type = 'sign'

---@param node vm.node
function mt:addSign(node)
    self.signList[#self.signList+1] = node
end

---@param doc parser.object
function mt:addDocGeneric(doc)
    self.docGeneric[#self.docGeneric+1] = doc
end

---@param uri uri
---@param args parser.object
---@return table<string, vm.node>?
function mt:resolve(uri, args)
    -- `args` is `nil` for a call with no arguments at all (`f()`: the parser leaves `call.args` unset
    -- rather than an empty table). That used to return `nil` here and skip everything below, including
    -- the defaults pass -- a generic with `---@generic T = string` still came out unresolved for such a
    -- call. Treated as zero arguments instead: nothing to match against, but a default still applies.

    ---@type table<string, vm.node>
    local resolved = {}
    ---@type table<string, boolean>
    local visited = {}

    -- the type node of the parameter whose argument is being bound (`vm.propagateFlagsBound`)
    ---@type vm.node?
    local boundParam

    ---@param object vm.node|vm.node.object
    ---@param node   vm.node
    local function resolve(object, node)
        local visitedHash = ("%s|%s"):format(object, node)
        if visited[visitedHash] then
            return -- prevent circular resolve calls by only visiting each pair once
        end
        visited[visitedHash] = true
        if object.type == 'vm.node' then
            for o in object:eachObject() do
                resolve(o, node)
            end
            return
        end
        if object.type == 'doc.type' then
            resolve(vm.compileNode(object), node)
            return
        end
        if object.type == 'doc.generic.name' then
            ---@type string
            local key = object[1]
            if object.literal then
                -- 'number' -> `T`
                for n in node:eachObject() do
                    if n.type == 'string' then
                        local type = vm.declareGlobal('type', object.pattern and object.pattern:format(n[1]) or n[1], guide.getUri(n))
                        resolved[key] = vm.createNode(type, resolved[key])
                    end
                end
            else
                -- number -> T
                local sawOnlyGeneric = true
                for n in node:eachObject() do
                    if  n.type ~= 'doc.generic.name'
                    and n.type ~= 'generic' then
                        sawOnlyGeneric = false
                        if resolved[key] then
                            resolved[key]:merge(n)
                        else
                            resolved[key] = vm.createNode(n)
                        end
                    end
                end
                -- Every candidate was itself an unresolved generic name (e.g. calling a
                -- generic function like `pairs(t)` from inside another still-generic
                -- function, where `t`'s own type parameter has not been bound to anything
                -- concrete yet): bind to that generic name instead of leaving `key`
                -- unresolved. `vm.cloneObject`/`vm.isResolvedToGeneric` already know how to
                -- carry this "resolved to another generic" wrapper through instead of
                -- collapsing it to `unknown` (see the generic-method V -> T case).
                if not resolved[key] and sawOnlyGeneric then
                    for n in node:eachObject() do
                        if resolved[key] then
                            resolved[key]:merge(n)
                        else
                            resolved[key] = vm.createNode(n)
                        end
                    end
                end
                if resolved[key] then
                    -- the bound argument's flags (e.g. a taint bit) belong to whatever T stands for
                    vm.propagateFlagsBound(node, resolved[key], boundParam)
                end
                if resolved[key] and node:isOptional() then
                    resolved[key]:addOptional()
                end
            end
            return
        end
        if object.type == 'doc.type.array' then
            -- If the argument contains a doc.type.sign (generic class like
            -- list<T> extending { [integer]: V }), resolve element type
            -- exclusively through class generic map. This directly maps
            -- the array element generic (V) to the sign parameter, even
            -- when it's another generic name (T inside a method body).
            local handled = false
            local hasArrayFacet = false
            for n in node:eachObject() do
                if n.type == 'doc.type.array' then
                    hasArrayFacet = true
                end
            end
            for n in node:eachObject() do
                -- (next to an array, `table<K, V>` is not a class with an integer field: its key is whatever `K` says, and the facet with the integer keys is the
                -- array; alone it keeps binding the value type, which is what `ipairs(dict)` reports)
                if n.type == 'doc.type.sign' and n.signs and n.node and n.node[1] and not (n.node[1] == 'table' and hasArrayFacet) then
                    local classGlobal = vm.getGlobal('type', n.node[1])
                    if classGlobal then
                        local genericMap = vm.getClassGenericMap(uri, classGlobal, n.signs)
                        if genericMap and object.node and object.node.type == 'doc.generic.name' then
                            -- V[] matching list<T>: look up [integer] field,
                            -- find which class generic it references, then
                            -- map V directly to the sign's concrete parameter
                            local vKey = object.node[1] --[[@as string]]
                            -- First try @field annotations
                            vm.getClassFields(uri, classGlobal, vm.declareGlobal('type', 'integer'), function (field)
                                if field.extends then
                                    guide.eachSourceType(field.extends, 'doc.generic.name', function (src)
                                        if genericMap[src[1]] then
                                            resolved[vKey] = genericMap[src[1]]
                                            handled = true
                                        end
                                    end)
                                end
                            end)
                            -- Also search extends tables (for @class list<T>: {[integer]:T})
                            if not handled then
                                local genericKey = findGenericInExtendsTable(uri, classGlobal, genericMap)
                                if genericKey then
                                    resolved[vKey] = genericMap[genericKey]
                                    handled = true
                                end
                            end
                        end
                    end
                    if handled then break end
                end
            end
            if not handled then
                for n in node:eachObject() do
                    if n.type == 'doc.type.array' then
                        -- number[] -> T[]
                        resolve(object.node, vm.compileNode(n.node))
                    elseif n.type == 'doc.type.table' then
                        -- { [integer]: number } -> T[]
                        local tvalueNode = vm.getTableValue(uri, node, 'integer', true)
                        if tvalueNode then
                            resolve(object.node, tvalueNode)
                        end
                    elseif n.type == 'global' and n.cate == 'type' then
                        -- ---@field [integer]: number -> T[]
                        ---@cast n vm.global
                        vm.getClassFields(uri, n, vm.declareGlobal('type', 'integer'), function (field)
                            resolve(object.node, vm.compileNode(field.extends))
                        end)
                    elseif n.type == 'table' and #n >= 1 then
                        -- { x } / { ... } -> T[]
                        -- (the element expression itself: the `tableexp` wrapper of a nested literal is compiled as the type
                        -- it is expected to be, `T[]`, which has lost its elements)
                        local element = n[1]
                        resolve(object.node, vm.compileNode(element.type == 'tableexp' and element.value or element))
                    end
                end
            end
            return
        end
        if object.type == 'doc.type.table' then
            for _, ufield in ipairs(object.fields) do
                local ufieldNode = vm.compileNode(ufield.name)
                local uvalueNode = vm.compileNode(ufield.extends)
                local firstField = ufieldNode:get(1)
                local firstValue = uvalueNode:get(1)
                if not firstField or not firstValue then
                    goto CONTINUE
                end
                if firstField.type == 'doc.generic.name' and firstValue.type == 'doc.generic.name' then
                    -- { [number]: number} -> { [K]: V }
                    local tfieldNode = vm.getTableKey(uri, node, 'any', true)
                    local tvalueNode = vm.getTableValue(uri, node, 'any', true)
                    if tfieldNode then
                        resolve(firstField, tfieldNode)
                    end
                    if tvalueNode then
                        resolve(firstValue, tvalueNode)
                    end
                else
                    if ufieldNode:get(1).type == 'doc.generic.name' then
                        -- { [number]: number}|number[] -> { [K]: number }
                        local tnode = vm.getTableKey(uri, node, uvalueNode, true)
                        if tnode then
                            resolve(firstField, tnode)
                        end
                    elseif uvalueNode:get(1).type == 'doc.generic.name' then
                        -- { [number]: number}|number[] -> { [number]: V }
                        local tnode = vm.getTableValue(uri, node, ufieldNode, true)
                        if tnode then
                            resolve(firstValue, tnode)
                        end
                    end
                end
                ::CONTINUE::
            end
            return
        end
        if object.type == 'doc.type.function' then
            for i, arg in ipairs(object.args) do
                if arg.extends then
                    for n in node:eachObject() do
                        if n.type == 'function'
                        or n.type == 'doc.type.function' then
                            local farg = n.args and n.args[i]
                            if farg then
                                resolve(arg.extends, vm.compileNode(farg))
                            end
                        end
                    end
                end
            end
            for i, ret in ipairs(object.returns) do
                for n in node:eachObject() do
                    if n.type == 'function'
                    or n.type == 'doc.type.function' then
                        ---@cast n parser.object
                        local fret = vm.getReturnOfFunction(n, i)
                        if fret then
                            local retNode = vm.compileNode(fret)
                            -- `fun(): T?` given `fun(): number?`: `T` is `number` (the `?` of the parameter takes the nil; TypeScript's `T | undefined`)
                            if ret.optional and retNode:hasFalsy() then
                                retNode = retNode:copy():removeOptional():remove 'nil'
                            end
                            resolve(ret, retNode)
                        end
                    end
                end
            end
            return
        end
        if object.type == 'doc.type.sign' and object.signs then
            -- list<T> -> list<string>: match sign parameters positionally
            for n in node:eachObject() do
                if  n.type == 'doc.type.sign' and n.signs
                and n.node and object.node
                and n.node[1] == object.node[1] then
                    for i, signParam in ipairs(object.signs) do
                        if n.signs[i] then
                            resolve(vm.compileNode(signParam), vm.compileNode(n.signs[i]))
                        end
                    end
                end
            end
            return
        end
    end

    ---@param sign vm.node
    ---@return table<string, true>
    ---@return table<string, true>
    local function getSignInfo(sign)
        ---@type table<string, true>
        local knownTypes = {}
        ---@type table<string, true>
        local genericsNames   = {}
        for obj in sign:eachObject() do
            if obj.type == 'doc.generic.name' then
                genericsNames[obj[1] --[[@as string]]] = true
                goto CONTINUE
            end
            if obj.type == 'doc.type.table'
            or obj.type == 'doc.type.function'
            or obj.type == 'doc.type.array'
            or obj.type == 'doc.type.sign' then
                ---@cast obj parser.object
                ---@type boolean?
                local hasGeneric
                guide.eachSourceType(obj, 'doc.generic.name', function (src)
                    hasGeneric = true
                    genericsNames[src[1] --[[@as string]]] = true
                end)
                if hasGeneric then
                    goto CONTINUE
                end
            end
            if obj.type == 'variable'
            or obj.type == 'local'
            or obj.type == 'self' then
                goto CONTINUE
            end
            local view = vm.getInfer(obj):view(uri)
            if view then
                knownTypes[view] = true
            end
            ::CONTINUE::
        end
        return knownTypes, genericsNames
    end

    -- remove un-generic type
    ---@param argNode vm.node
    ---@param sign vm.node
    ---@param knownTypes table<string, true>
    ---@return vm.node
    local function buildArgNode(argNode, sign, knownTypes)
        local newArgNode = vm.createNode()
        local needRemoveNil = sign:hasFalsy()
        for n in argNode:eachObject() do
            if needRemoveNil then
                if n.type == 'nil' then
                    goto CONTINUE
                end
                if n.type == 'global' and n.cate == 'type' and n.name == 'nil' then
                    goto CONTINUE
                end
            end
            local view = vm.getInfer(n):view(uri)
            if knownTypes[view] then
                goto CONTINUE
            end
            newArgNode:merge(n)
            ::CONTINUE::
        end
        if not needRemoveNil and argNode:isOptional() then
            newArgNode:addOptional()
        end
        return newArgNode
    end

    ---@param genericNames table<string, true>
    ---@return boolean
    local function isAllResolved(genericNames)
        for n in pairs(genericNames) do
            if not resolved[n] then
                return false
            end
        end
        return true
    end

    --- The binding of `T` made as wide as `argNode` when the parameter is a plain `T` and the argument holds everything `T` stands for so far
    --- and more. nil: nothing to change.
    ---@param bound    vm.node
    ---@param signNode vm.node
    ---@param name     string
    ---@param argNode  vm.node
    ---@return vm.node?
    ---@param uri uri
    local function widenBinding(uri, bound, signNode, name, argNode)
        local plain = false
        for obj in signNode:eachObject() do
            -- (the parameter itself is part of its node: `variable`, `local`, `self`)
            if obj.type == 'doc.generic.name' and obj[1] == name then
                plain = true
            elseif obj.type ~= 'variable' and obj.type ~= 'local' and obj.type ~= 'self' then
                return nil
            end
        end
        if not plain or bound:isEmpty() or argNode:isEmpty() or argNode:isOptional() or bound:isOptional() then
            return nil
        end
        for obj in argNode:eachObject() do
            if obj.type == 'doc.generic.name' or obj.type == 'generic' then
                return nil
            end
        end
        if vm.isSubType(uri, bound, argNode) ~= true then
            return nil
        end
        if vm.isSubType(uri, argNode, bound) ~= false then
            -- (`Lua.type.castNumberToInteger` lets a number fit an integer, but `integer` is still the narrower of the two)
            if not (vm.getInfer(bound):view(uri) == 'integer' and vm.getInfer(argNode):view(uri) == 'number') then
                return nil
            end
        end
        local wider = vm.createNode()
        for obj in argNode:eachObject() do
            wider:merge(obj)
        end
        vm.propagateFlags(bound, wider)
        return wider
    end

    --- Is `any` among the types of the node? (what iterating or unpacking it gives is `any` too, not `unknown`)
    ---@param node vm.node
    ---@return boolean
    local function hasAny(node)
        for obj in node:eachObject() do
            if obj.type == 'global' and obj.cate == 'type' and obj.name == 'any' then
                return true
            end
        end
        return false
    end

    --- `---@param ... returns<F>`: `F` is the function whose results the argument passes on (`select(2, f())`: `f`)
    ---@param sign vm.node
    ---@param arg  parser.object
    local function bindReturnsOfCallee(sign, arg)
        if arg.type ~= 'call' or not arg.node then
            return
        end
        for obj in sign:eachObject() do
            local key = obj.type == 'doc.type.sign' and obj.node and obj.node[1] == 'returns' and obj.signs
                and vm.getSignName(obj.signs[1])
            if key and not resolved[key] then
                for callee in vm.compileNode(arg.node):eachObject() do
                    if callee.type == 'function' or callee.type == 'doc.type.function' then
                        resolved[key] = resolved[key] and resolved[key]:merge(callee) or vm.createNode(callee)
                    end
                end
            end
        end
    end

    for i, arg in ipairs(args or {}) do
        local sign = self.signList[i]
        if not sign then
            break
        end
        -- the literal numbers handed to named parameters, for `returns<F, index>`
        local paramName = self.paramNames and self.paramNames[i]
        if paramName and (arg.type == 'integer' or arg.type == 'number') then
            resolved['#' .. paramName] = vm.compileNode(arg)
        end
        bindReturnsOfCallee(sign, arg)
        local argNode = vm.compileNode(arg)
        boundParam = sign
        local knownTypes, genericNames = getSignInfo(sign)
        if not isAllResolved(genericNames) then
            local newArgNode = buildArgNode(argNode, sign, knownTypes)
            -- the rebuilt node is a fresh one: carry the argument's flags (e.g. a taint bit)
            vm.propagateFlagsBound(argNode, newArgNode, sign)
            resolve(sign, newArgNode)
        else
            -- `T` is already bound (by an earlier argument: the first one wins, as the type of `T` goes), but what this
            -- argument carries (a registered flag, see vm/flags.lua) can still come back out through `T`: keep it
            for name in pairs(genericNames) do
                if resolved[name] then
                    vm.propagateFlagsBound(argNode, resolved[name], sign)
                    -- a later argument of a plain `T` parameter that is wider than what `T` stands for makes `T` that wider type
                    -- (TypeScript: `pick(1, 2.5)` is `number`); one that does not fit stays for generic-param-mismatch
                    local widened = widenBinding(uri, resolved[name], sign, name, argNode)
                    if widened then
                        resolved[name] = widened
                    end
                end
            end
        end
        -- an argument of type `any` against `table<K, V>` / `T[]` / `{ [K]: V }`: what is inside is `any` as well
        -- (`for k, v in pairs(value)` with `value: any`), instead of the generics staying unbound and reading `unknown`
        if hasAny(argNode) then
            for name in pairs(genericNames) do
                if not resolved[name] then
                    resolved[name] = vm.createNode(vm.declareGlobal('type', 'any'))
                end
            end
        end
    end

    -- `---@generic T = string` (TypeScript's default type parameter): a generic that no argument
    -- resolved (there was none typed `T`, or it was `nil`) falls back to its declared default instead
    -- of staying unresolved (`unknown`). Not supported: a default that itself names another generic
    -- (`---@generic T, U = T`) -- it compiles as an unresolved reference, same as not having a default.
    for _, doc in ipairs(self.docGeneric) do
        for _, object in ipairs(doc.generics) do
            local name = object.generic and object.generic[1] --[[@as string?]]
            if name and not resolved[name] and object.defaultType then
                resolved[name] = vm.compileNode(object.defaultType)
            end
        end
    end

    return resolved
end

---@return vm.sign
function vm.createSign()
    local genericMgr = setmetatable({
        signList  = {},
        docGeneric = {},
    }, mt)
    return genericMgr
end

---@class parser.object
---@field public _sign vm.sign|false|nil

---@param source parser.object
---@param sign vm.sign
function vm.setSign(source, sign)
    source._sign = sign
end

---@param source parser.object
---@return vm.sign?
function vm.getSign(source)
    if source._sign ~= nil then
        return source._sign or nil
    end
    source._sign = false
    if source.type == 'function' then
        if not source.bindDocs then
            return nil
        end
        local sign = source._sign or nil
        for _, doc in ipairs(source.bindDocs) do
            if doc.type == 'doc.generic' then
                if not sign then
                    sign = vm.createSign()
                    source._sign = sign
                end
                sign:addDocGeneric(doc)
            end
        end
        if not sign then
            return nil
        end
        if source.args then
            for _, arg in ipairs(source.args) do
                local argNode = vm.compileNode(arg)
                if arg.optional then
                    argNode:addOptional()
                end
                sign:addSign(argNode)
                sign.paramNames = sign.paramNames or {}
                sign.paramNames[#sign.signList] = arg.type == 'local' and arg[1] or nil
            end
        end
    end
    if source.type == 'doc.type.function'
    or source.type == 'doc.type.table'
    or source.type == 'doc.type.array' then
        ---@type boolean?
        local hasGeneric
        -- A cloned generic name (vm.cloneObject, e.g. a function's return type re-cloned after its
        -- own generics were already resolved once) keeps `.type == 'doc.generic.name'` even though
        -- it now carries `_resolved` -- counting it here builds a fresh, wrong sign from an
        -- already-resolved shape (its own args are the resolved clones, not real generic params),
        -- re-wrapping an already-concrete return in a 'generic' node that a later `:resolve()` with
        -- unrelated args (the caller's own args, not the ones that produced this clone) can't
        -- recover -- confirmed 2026-09-27: `vm.getReturnOfFunction`'s `doc.type.function` branch hit
        -- this extracting a generic iterator's second return specifically (`fun(): K, V` called from
        -- inside another generic function; `V`, the only one this exact call shape needed to extract
        -- on its own, came back `unknown`).
        guide.eachSourceType(source, 'doc.generic.name', function (src)
            if not src._resolved then
                hasGeneric = true
            end
        end)
        if not hasGeneric then
            return nil
        end
        local sign = vm.createSign()
        source._sign = sign
        if source.type == 'doc.type.function' then
            for _, arg in ipairs(source.args) do
                if arg.extends then
                    local argNode = vm.compileNode(arg.extends)
                    if arg.optional then
                        argNode:addOptional()
                    end
                    sign:addSign(argNode)
                else
                    sign:addSign(vm.createNode())
                end
            end
        end
    end
    return source._sign or nil
end
