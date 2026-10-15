---@class vm
local vm      = require 'vm.vm'
local guide   = require 'parser.guide'

---@class parser.object
---@field public _generic vm.generic
---@field public _resolved vm.node

---@class vm.generic
---@field type   'generic'
---@field sign   vm.sign
---@field proto  vm.object
---@field flags  table<string, boolean>?
local mt = {}
mt.__index = mt
mt.type = 'generic'

--- The name a sign of `Name<A, B>` is (`F`, `index`): the sign is the name itself or a type holding only that name.
---@param sign parser.object?
---@return string?
function vm.getSignName(sign)
    if sign and sign.type == 'doc.type' and sign.types and #sign.types == 1 then
        sign = sign.types[1]
    end
    if sign and (sign.type == 'doc.generic.name' or sign.type == 'doc.type.name') then
        return sign[1]
    end
    return nil
end

--- `fun(ctx: string, ...: params<F>)`: the arguments that stand for the `...` when `F` is bound to a function: its parameters, by name
--- and type. Nil when `arg` is not such a `...`, or `F` is not bound to a function.
---@param arg      parser.object a `doc.type.arg`
---@param resolved table<string, vm.node>
---@return parser.object[]?
local function expandParamsProjection(arg, resolved)
    if not arg.name or arg.name[1] ~= '...' or not arg.extends then
        return nil
    end
    ---@type parser.object
    local unit = arg.extends
    if unit.type == 'doc.type' and unit.types and #unit.types == 1 then
        unit = unit.types[1]
    end
    if unit.type ~= 'doc.type.sign' or not unit.node or unit.node[1] ~= 'params' or not unit.signs then
        return nil
    end
    local key = vm.getSignName(unit.signs[1])
    local fNode = key and resolved[key]
    if not fNode then
        return nil
    end
    ---@type parser.object?
    local target
    for f in fNode:eachObject() do
        if f.type == 'function' or f.type == 'doc.type.function' then
            target = f --[[@as parser.object]]
            break
        end
    end
    if not target then
        return nil
    end
    ---@type parser.object[]
    local expanded = {}
    for i, param in ipairs(target.args or {}) do
        ---@type string
        local name
        ---@type vm.node
        local typeNode
        if target.type == 'doc.type.function' then
            name     = param.name and param.name[1] or ('arg' .. i)
            typeNode = param.extends and vm.compileNode(param.extends) or vm.createNode(vm.declareGlobal('type', 'any'))
        else
            name     = param.type == '...' and '...' or (param[1] or ('arg' .. i))
            typeNode = param.type == '...' and vm.createNode(vm.declareGlobal('type', 'any')) or vm.compileNode(param)
        end
        ---@type parser.object
        local newArg = {
            type     = 'doc.type.arg',
            start    = arg.start,
            finish   = arg.finish,
            parent   = arg.parent,
            optional = param.optional == true or (target.type == 'function' and typeNode:isOptional()),
        }
        newArg.name = {
            type   = 'doc.type.arg.name',
            start  = arg.start,
            finish = arg.finish,
            parent = newArg,
            [1]    = name,
        }
        -- (written like the parser writes a type: a `doc.type` holding one unit, here a name that stands for the parameter's node)
        ---@type parser.object
        local extends = {
            type   = 'doc.type',
            start  = arg.start,
            finish = arg.finish,
            parent = newArg,
            types  = {},
        }
        ---@type parser.object
        local unit = {
            type   = 'doc.generic.name',
            start  = arg.start,
            finish = arg.finish,
            parent = extends,
            [1]    = name,
        }
        vm.setNode(unit, typeNode, true)
        unit._resolved = typeNode
        extends.types[1] = unit
        newArg.extends = extends
        expanded[#expanded+1] = newArg
    end
    return expanded
end

---@param source    vm.node.object?
---@param resolved? table<string, vm.node>
---@return vm.node.object?
local function cloneObject(source, resolved)
    if not resolved or not source then
        return source
    end
    if source.type == 'doc.generic.name' then
        local key = source[1]
        ---@type parser.object
        local newName = {
            type   = source.type,
            start  = source.start,
            finish = source.finish,
            parent = source.parent,
            [1]    = source[1],
        }
        if resolved[key] then
            vm.setNode(newName, resolved[key], true)
            newName._resolved = resolved[key]
        end
        return newName
    end
    if source.type == 'doc.type.name' then
        local key = source[1]
        if resolved[key] then
            ---@type parser.object
            local newName = {
                type   = 'doc.generic.name',
                start  = source.start,
                finish = source.finish,
                parent = source.parent,
                [1]    = source[1],
            }
            vm.setNode(newName, resolved[key], true)
            newName._resolved = resolved[key]
            return newName
        end
    end
    if source.type == 'doc.type' then
        ---@type parser.object
        local newType = {
            type     = source.type,
            start    = source.start,
            finish   = source.finish,
            parent   = source.parent,
            optional = source.optional,
            types    = {},
        }
        for i, typeUnit in ipairs(source.types) do
            local newObj     = cloneObject(typeUnit, resolved) --[[@as parser.object?]]
            newType.types[i] = newObj
        end
        return newType
    end
    if source.type == 'doc.type.arg' then
        local newArg = {
            type    = source.type,
            start   = source.start,
            finish  = source.finish,
            parent  = source.parent,
            name    = source.name,
            extends = cloneObject(source.extends, resolved)
        }
        return newArg
    end
    if source.type == 'doc.type.array' then
        local newArray = {
            type   = source.type,
            start  = source.start,
            finish = source.finish,
            parent = source.parent,
            node   = cloneObject(source.node, resolved),
        }
        return newArray
    end
    if source.type == 'doc.type.keyof' then
        local newKeyof = {
            type   = source.type,
            start  = source.start,
            finish = source.finish,
            parent = source.parent,
            node   = cloneObject(source.node, resolved),
        }
        return newKeyof
    end
    if source.type == 'doc.type.indexed' then
        local newIndexed = {
            type   = source.type,
            start  = source.start,
            finish = source.finish,
            parent = source.parent,
            node   = cloneObject(source.node, resolved),
            key    = cloneObject(source.key, resolved),
        }
        return newIndexed
    end
    if source.type == 'doc.type.intersection' then
        ---@type parser.object
        local newIntersection = {
            type   = source.type,
            start  = source.start,
            finish = source.finish,
            parent = source.parent,
            types  = {},
        }
        for i, typeUnit in ipairs(source.types) do
            newIntersection.types[i] = cloneObject(typeUnit, resolved) --[[@as parser.object]]
        end
        return newIntersection
    end
    if source.type == 'doc.type.conditional' then
        ---@type parser.object
        local newConditional = {
            type      = source.type,
            start     = source.start,
            finish    = source.finish,
            parent    = source.parent,
            check     = cloneObject(source.check, resolved) --[[@as parser.object]],
            extends   = cloneObject(source.extends, resolved) --[[@as parser.object?]],
            trueType  = cloneObject(source.trueType, resolved) --[[@as parser.object?]],
            falseType = cloneObject(source.falseType, resolved) --[[@as parser.object?]],
        }
        return newConditional
    end
    if source.type == 'doc.type.table' then
        ---@type parser.object
        local newTable = {
            type   = source.type,
            start  = source.start,
            finish = source.finish,
            parent = source.parent,
            fields = {},
        }
        for i, field in ipairs(source.fields) do
            ---@type parser.object
            local newField = {
                type    = field.type,
                start   = field.start,
                finish  = field.finish,
                parent  = newTable,
                name    = cloneObject(field.name, resolved) --[[@as parser.object]],
                extends = cloneObject(field.extends, resolved) --[[@as parser.object]],
            }
            newTable.fields[i] = newField
        end
        return newTable
    end
    if source.type == 'doc.type.function' then
        ---@type parser.object
        local newDocFunc = {
            type    = source.type,
            start   = source.start,
            finish  = source.finish,
            parent  = source.parent,
            args    = {},
            returns = {},
        }
        for _, arg in ipairs(source.args) do
            local expanded = expandParamsProjection(arg, resolved)
            if expanded then
                for _, newArg in ipairs(expanded) do
                    newArg.parent = newDocFunc
                    newDocFunc.args[#newDocFunc.args+1] = newArg
                end
            else
                local newObj = cloneObject(arg, resolved) --[[@as parser.object]]
                newObj.optional    = arg.optional
                newDocFunc.args[#newDocFunc.args+1] = newObj
            end
        end
        for i, ret in ipairs(source.returns) do
            local newObj = cloneObject(ret, resolved) --[[@as parser.object]]
            newObj.parent   = newDocFunc
            newObj.optional = ret.optional
            newDocFunc.returns[i] = newObj
        end
        return newDocFunc
    end
    if source.type == 'doc.type.sign' and source.signs then
        local needsClone = false
        -- Check if any sign parameter has a resolvable name with a concrete
        -- (non-generic) resolved type. Skip cloning when the resolved value
        -- is just another doc.generic.name (e.g. T -> T inside a method body),
        -- which would cause double-wrapping in display (list<<T>>).
        local function hasConcreteResolution(name)
            local rnode = resolved[name]
            if not rnode then
                return false
            end
            for rn in rnode:eachObject() do
                if rn.type ~= 'doc.generic.name' and rn.type ~= 'generic' then
                    return true
                end
            end
            return false
        end
        -- `returns<F, index>`: the literal argument of the parameter `index` (recorded as `#index` by `sign:resolve`)
        local isReturns = source.node and source.node[1] == 'returns'
        ---@type parser.object?
        local indexSign = isReturns and source.signs[2] or nil
        local indexName = vm.getSignName(indexSign)
        if indexName and resolved['#' .. indexName] then
            needsClone = true
        end
        for _, sign in ipairs(source.signs) do
            guide.eachSourceType(sign, 'doc.type.name', function (src)
                if hasConcreteResolution(src[1]) then
                    needsClone = true
                end
            end)
            if not needsClone then
                guide.eachSourceType(sign, 'doc.generic.name', function (src)
                    if hasConcreteResolution(src[1]) then
                        needsClone = true
                    end
                end)
            end
            if needsClone then break end
        end
        if needsClone then
            ---@type parser.object
            local newSign = {
                type        = source.type,
                start       = source.start,
                finish      = source.finish,
                parent      = source.parent,
                node        = source.node,
                signs       = {},
                extraOffset = source.extraOffset,
            }
            for i, sign in ipairs(source.signs) do
                newSign.signs[i] = cloneObject(sign, resolved) --[[@as parser.object]]
            end
            if indexName and indexSign and resolved['#' .. indexName] then
                -- (the name of a parameter, not a type: it stands for the number the call gave it)
                ---@type parser.object
                local newIndex = {
                    type   = 'doc.generic.name',
                    start  = indexSign.start,
                    finish = indexSign.finish,
                    parent = newSign,
                    [1]    = indexName,
                }
                vm.setNode(newIndex, resolved['#' .. indexName], true)
                newIndex._resolved = resolved['#' .. indexName]
                newSign.signs[2] = newIndex
            end
            return newSign
        end
    end
    return source
end

---@param node vm.node
---@param obj  vm.node.object
---@return boolean
local function nodeHolds(node, obj)
    for o in node:eachObject() do
        if o == obj then
            return true
        end
    end
    return false
end

---@param uri uri
---@param args parser.object
---@return vm.node
function mt:resolve(uri, args)
    local resolved  = self.sign:resolve(uri, args)
    local protoNode = vm.compileNode(self.proto)
    local result = vm.createNode()
    for nd in protoNode:eachObject() do
        if nd.type == 'global' or nd.type == 'variable' then
            result:merge(nd)
        else
            local clonedObject = cloneObject(nd, resolved)
            if clonedObject then
                -- When a generic resolves to another generic (e.g. V -> T
                -- inside a generic method), keep the resolved wrapper so
                -- the resolution chain is preserved and downstream filters
                -- can distinguish "resolved to generic T" from "unresolved".
                if clonedObject.type == 'doc.generic.name'
                and clonedObject._resolved
                and vm.isResolvedToGeneric(clonedObject._resolved) then
                    result:merge(clonedObject)
                else
                    local clonedNode   = vm.compileNode(clonedObject)
                    -- a projection whose `F` no argument bound stays deferred (its own node is itself): that says nothing, not its spelling
                    if clonedObject.type == 'doc.type.sign' and clonedObject.node and clonedObject.node[1] == 'returns'
                    and nodeHolds(clonedNode, clonedObject) then
                        result:merge(vm.declareGlobal('type', 'unknown'))
                    else
                        result:merge(clonedNode)
                    end
                end
            end
        end
    end
    if protoNode:isOptional() then
        result:addOptional()
    end
    vm.applyFlagsTable(self.flags, result)
    return result
end

---@param source parser.object
---@return vm.node?
function vm.getGenericResolved(source)
    if source.type ~= 'doc.generic.name' then
        return nil
    end
    return source._resolved
end

---@param source table
---@return boolean
function vm.isGenericUnsolved(source)
    if source.type == 'doc.generic.name' and not source._resolved then
        return true
    end
    return false
end

--- Check if a resolved node contains only generic name objects.
--- Used to distinguish "V resolved to generic T" (preserve wrapper)
--- from "V resolved to concrete string" (unwrap normally).
---@param node vm.node
---@return boolean
function vm.isResolvedToGeneric(node)
    for rn in node:eachObject() do
        if rn.type ~= 'doc.generic.name' then
            return false
        end
    end
    return true
end

---@param source parser.object
---@param generic vm.generic
function vm.setGeneric(source, generic)
    source._generic = generic
end

---@param source parser.object
---@return vm.generic?
function vm.getGeneric(source)
    return source._generic
end

---@param proto vm.object
---@param sign  vm.sign
---@param flags table<string, boolean>?
---@return vm.generic
function vm.createGeneric(proto, sign, flags)
    local generic = setmetatable({
        sign   = sign,
        proto  = proto,
        flags  = flags,
    }, mt)
    return generic
end

---@param source    vm.node.object?
---@param resolved? table<string, vm.node>
---@return vm.node.object?
function vm.cloneObject(source, resolved)
    return cloneObject(source, resolved)
end
