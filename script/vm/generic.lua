---@class vm
local vm      = require 'vm.vm'
local guide   = require 'parser.guide'

---@class parser.object
---@field public _generic vm.generic
---@field public _resolved vm.node

---@class vm.generic
---@field sign   vm.sign
---@field proto  vm.object
---@field flags  table<string, boolean>?
local mt = {}
mt.__index = mt
mt.type = 'generic'

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
        for i, arg in ipairs(source.args) do
            local newObj = cloneObject(arg, resolved) --[[@as parser.object]]
            newObj.optional    = arg.optional
            newDocFunc.args[i] = newObj
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
                type   = source.type,
                start  = source.start,
                finish = source.finish,
                parent = source.parent,
                node   = source.node,
                signs  = {},
            }
            for i, sign in ipairs(source.signs) do
                newSign.signs[i] = cloneObject(sign, resolved) --[[@as parser.object]]
            end
            return newSign
        end
    end
    return source
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
                    result:merge(clonedNode)
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
