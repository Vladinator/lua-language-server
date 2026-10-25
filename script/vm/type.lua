---@class vm
local vm        = require 'vm.vm'
local guide     = require 'parser.guide'
local config    = require 'config.config'
local scope     = require 'workspace.scope'
local util      = require 'utility'
local lang      = require 'language'

---@class vm.ANY
vm.ANY = {'<VM.ANY>'}
---@class vm.ANYDOC
vm.ANYDOC = {'<VM.ANYDOC>'}

---@alias typecheck.err vm.node.object|string|vm.node

--- A doc or source node, not a global type, a variable or a generic: the `.type` of a `vm.node.object` does not narrow it by itself.
---@guard obj is parser.object
---@param obj vm.node.object
---@return boolean
local function isNode(obj)
    return obj.type ~= 'global' and obj.type ~= 'variable' and obj.type ~= 'generic'
end

---@param object vm.node.object
---@return string?
function vm.getNodeName(object)
    if object.type == 'global' and object.cate == 'type' then
        ---@cast object vm.global
        return object.name
    end
    if object.type == 'nil'
    or object.type == 'boolean'
    or object.type == 'number'
    or object.type == 'string'
    or object.type == 'table'
    or object.type == 'function'
    or object.type == 'integer' then
        return object.type
    end
    if object.type == 'doc.type.boolean' then
        return 'boolean'
    end
    if object.type == 'doc.type.integer' then
        return 'integer'
    end
    if object.type == 'doc.type.function' then
        return 'function'
    end
    if object.type == 'doc.type.table' then
        return 'table'
    end
    if object.type == 'doc.type.array' then
        return 'table'
    end
    if object.type == 'doc.type.string' then
        return 'string'
    end
    if object.type == 'doc.field.name' then
        return 'string'
    end
    return nil
end

---@param parentName string
---@param child      vm.node.object
---@param uri        uri
---@param mark       table<string, boolean>
---@param errs?      typecheck.err[]
---@return boolean?
local function checkParentEnum(parentName, child, uri, mark, errs)
    local parentClass = vm.getGlobal('type', parentName)
    if not parentClass then
        return nil
    end
    ---@type parser.object[]?
    local enums
    for _, set in ipairs(parentClass:getSets(uri)) do
        if set.type == 'doc.enum' then
            local denums = vm.getEnums(set)
            if denums then
                if enums then
                    enums = util.arrayMerge(enums, denums)
                else
                    enums = util.arrayMerge({}, denums)
                end
            end
        end
    end
    if not enums then
        return nil
    end
    if child.type == 'global' then
        for _, enum in ipairs(enums) do
            if vm.isSubType(uri, child, vm.compileNode(enum), mark) then
                return true
            end
        end
        if errs then
            errs[#errs+1] = 'TYPE_ERROR_ENUM_GLOBAL_DISMATCH'
            errs[#errs+1] = child
            errs[#errs+1] = parentClass
        end
        return false
    elseif child.type == 'generic' then
        if errs then
            errs[#errs+1] = 'TYPE_ERROR_ENUM_GENERIC_UNSUPPORTED'
            errs[#errs+1] = child
        end
        return false
    else
        local childName = vm.getNodeName(child)
        if childName == 'number'
        or childName == 'integer'
        or childName == 'boolean'
        or childName == 'string' then
            for _, enum in ipairs(enums) do
                ---@type vm.node
                local enumNode = vm.compileNode(enum)
                for nd in enumNode:eachObject() do
                    if childName == vm.getNodeName(nd) and nd[1] == child[1] then
                        return true
                    end
                end
            end
            if errs then
                errs[#errs+1] = 'TYPE_ERROR_ENUM_LITERAL_DISMATCH'
                errs[#errs+1] = child[1]
                errs[#errs+1] = parentClass
            end
            return false
        elseif childName == 'function'
        or     childName == 'table' then
            for _, enum in ipairs(enums) do
                ---@type vm.node
                local enumNode = vm.compileNode(enum)
                for nd in enumNode:eachObject() do
                    if child == nd then
                        return true
                    end
                end
            end
            if errs then
                errs[#errs+1] = 'TYPE_ERROR_ENUM_OBJECT_DISMATCH'
                errs[#errs+1] = child
                errs[#errs+1] = parentClass
            end
            return false
        end
        if errs then
            errs[#errs+1] = 'TYPE_ERROR_ENUM_NO_OBJECT'
            errs[#errs+1] = child
        end
        return false
    end
end

---@param childName  string
---@param parent     vm.node.object
---@param uri        uri
---@param mark       table<string, boolean>
---@param errs?      typecheck.err[]
---@return boolean?
local function checkChildEnum(childName, parent, uri, mark, errs)
    if mark[childName] then
        return
    end
    local childClass = vm.getGlobal('type', childName)
    if not childClass then
        return nil
    end
    ---@type parser.object[]?
    local enums
    for _, set in ipairs(childClass:getSets(uri)) do
        if set.type == 'doc.enum' then
            enums = vm.getEnums(set)
            break
        end
    end
    if not enums then
        return nil
    end
    mark[childName] = true
    for _, enum in ipairs(enums) do
        if not vm.isSubType(uri, vm.compileNode(enum), parent, mark, errs) then
            mark[childName] = nil
            return false
        end
    end
    mark[childName] = nil
    return true
end

---@param parent vm.node.object
---@param child  vm.node.object
---@param mark   table<string, boolean>
---@param errs?  typecheck.err[]
---@return boolean
local function checkValue(parent, child, mark, errs)
    if parent.type == 'doc.type.integer' then
        if child.type == 'integer'
        or child.type == 'doc.type.integer'
        or child.type == 'number' then
            if parent[1] ~= child[1] then
                if errs then
                    errs[#errs+1] = 'TYPE_ERROR_INTEGER_DISMATCH'
                    errs[#errs+1] = child[1]
                    errs[#errs+1] = parent[1]
                end
                return false
            end
        end
        return true
    end

    if parent.type == 'doc.type.string'
    or parent.type == 'doc.field.name' then
        if child.type == 'string'
        or child.type == 'doc.type.string'
        or child.type == 'doc.field.name' then
            if parent[1] ~= child[1] then
                if errs then
                    errs[#errs+1] = 'TYPE_ERROR_STRING_DISMATCH'
                    errs[#errs+1] = child[1]
                    errs[#errs+1] = parent[1]
                end
                return false
            end
        end
        return true
    end

    if parent.type == 'doc.type.boolean' then
        if child.type == 'boolean'
        or child.type == 'doc.type.boolean' then
            if parent[1] ~= child[1] then
                if errs then
                    errs[#errs+1] = 'TYPE_ERROR_BOOLEAN_DISMATCH'
                    errs[#errs+1] = child[1]
                    errs[#errs+1] = parent[1]
                end
                return false
            end
        end
        return true
    end

    if parent.type == 'doc.type.table' then
        if child.type == 'doc.type.table' then
            if child == parent then
                return true
            end
            local uri = guide.getUri(parent)
            local tnode = vm.compileNode(child)
            for _, pfield in ipairs(parent.fields) do
                local knode = vm.compileNode(pfield.name)
                local cvalues = vm.getTableValue(uri, tnode, knode, true)
                if not cvalues then
                    if pfield.optional then
                        goto continue
                    end
                    if errs then
                        errs[#errs+1] = 'TYPE_ERROR_TABLE_NO_FIELD'
                        errs[#errs+1] = pfield.name
                    end
                    return false
                end
                local pvalues = vm.compileNode(pfield.extends)
                if vm.isSubType(uri, cvalues, pvalues, mark, errs) == false then
                    if errs then
                        errs[#errs+1] = 'TYPE_ERROR_TABLE_FIELD_DISMATCH'
                        errs[#errs+1] = pfield.name
                        errs[#errs+1] = cvalues
                        errs[#errs+1] = pvalues
                    end
                    return false
                end
                ::continue::
            end
        end
        return true
    end

    -- `string[]` from a `number[]` (not from a literal, which is checked by its fields): the element types have to fit, as in TypeScript
    if parent.type == 'doc.type.array' and child.type == 'doc.type.array' then
        if child == parent then
            return true
        end
        local uri = guide.getUri(parent)
        local childElement  = vm.compileNode(child.node)
        local parentElement = vm.compileNode(parent.node)
        if vm.isSubType(uri, childElement, parentElement, mark, errs) == false then
            if errs then
                errs[#errs+1] = 'TYPE_ERROR_ARRAY_ELEMENT_DISMATCH'
                errs[#errs+1] = childElement
                errs[#errs+1] = parentElement
            end
            return false
        end
    end

    return true
end

--- The type names the language itself has, with or without a `---@class` in the meta files.
local builtinTypeNames = {
    ['nil'] = true, ['boolean'] = true, ['string'] = true, ['number'] = true, ['integer'] = true, ['table'] = true,
    ['function'] = true, ['thread'] = true, ['userdata'] = true, ['lightuserdata'] = true, ['any'] = true, ['unknown'] = true,
    ['never'] = true, ['true'] = true, ['false'] = true, ['_G'] = true, ['_ENV'] = true, ['...'] = true, ['self'] = true,
}

--- A type name that nothing declares (`---@param x NoSuchType`, the library that declares it is not loaded): `undefined-doc-name` says so
--- once, and the type is unknown to the checks that compare with it, which then say nothing more about it.
---@param name string
---@param suri uri
---@return boolean
local function isUndefinedType(name, suri)
    if builtinTypeNames[name] or not name:match '^[%a_][%w_.%-]*$' or vm.isUtilityTypeName(name) then
        return false
    end
    local globalVar = vm.getGlobal('type', name)
    return not globalVar or #globalVar:getSets(suri) == 0
end

--- Is `name` a type nothing declares, or a class with an ancestor nothing declares (`---@class Real : Ghost`)? Nothing is known of what
--- such a type has, so the checks of fields and calls on a value of it say nothing (`undefined-doc-name` / `undefined-doc-class` do).
---@param suri uri
---@param name string
---@return boolean
function vm.hasUndeclaredAncestry(suri, name)
    ---@type table<string, true>
    local seen = {}
    ---@param current string
    ---@return boolean
    local function walk(current)
        if seen[current] then
            return false
        end
        seen[current] = true
        if isUndefinedType(current, suri) then
            return true
        end
        local globalVar = vm.getGlobal('type', current)
        if not globalVar then
            return false
        end
        for _, set in ipairs(globalVar:getSets(suri)) do
            if set.type == 'doc.class' and set.extends then
                for _, ext in ipairs(set.extends) do
                    if ext.type == 'doc.extends.name' and type(ext[1]) == 'string' and walk(ext[1]) then
                        return true
                    end
                end
            end
        end
        return false
    end
    return walk(name)
end

---@param name string
---@param suri uri
---@return boolean
local function isAlias(name, suri)
    local globalVar = vm.getGlobal('type', name)
    if not globalVar then
        return false
    end
    for _, set in ipairs(globalVar:getSets(suri)) do
        if set.type == 'doc.alias' then
            return true
        end
    end
    return false
end

---@param parent vm.global
---@param child  parser.object
---@param uri    uri
---@param mark   table<string, boolean>
---@param errs?  typecheck.err[]
---@return boolean
local function checkTableShape(parent, child, uri, mark, errs)
    local set = parent:getSets(uri)
    ---@type string[]
    local missedKeys = {}
    ---@type boolean?
    local failedCheck
    ---@type table<string|integer, vm.node>?
    local myKeys
    for _, def in ipairs(set) do
        if not def.fields or #def.fields == 0 then
            goto continue
        end
        if not myKeys then
            myKeys = {}
            for _, field in ipairs(child) do
                local key = vm.getKeyName(field) or field.tindex
                if key then
                    myKeys[key] = vm.compileNode(field)
                end
            end
        end

        for _, field in ipairs(def.fields) do
            ---@type string|integer?
            local key = vm.getKeyName(field)
            if not key then
                local fieldnode = vm.compileNode(field.field)[1]
                if fieldnode and fieldnode.type == 'doc.type.integer' then
                    key = vm.getKeyName(fieldnode)
                end
            end
            if not key then
                goto continue
            end

            ---@type boolean?
            local ok
            local nodeField = vm.compileNode(field)
            if myKeys[key] then
                ok = vm.isSubType(uri, myKeys[key], nodeField, mark, errs)
                if ok == false then
                    if errs then
                        errs[#errs+1] = 'TYPE_ERROR_PARENT_ALL_DISMATCH' -- error display can be greatly improved
                        errs[#errs+1] = myKeys[key]
                        errs[#errs+1] = nodeField
                    end
                    failedCheck = true
                end
            elseif not nodeField:isNullable() then
                if type(key) == "number" then
                    missedKeys[#missedKeys+1] = ('`[%s]`'):format(key)
                else
                    missedKeys[#missedKeys+1] = ('`%s`'):format(key)
                end
                failedCheck = true
            end
        end
        ::continue::
    end
    if errs and #missedKeys > 0 then
        errs[#errs+1] = 'DIAG_MISSING_FIELDS'
        errs[#errs+1] = parent
        errs[#errs+1] = table.concat(missedKeys, ', ')
    end
    if failedCheck then
        return false
    end

    return true
end

---@class vm.type.checkConfig
---@field weakUnionCheck   boolean
---@field weakNilCheck     boolean
---@field maxUnionVariants integer

--- `vm.isSubType` reads `Lua.type.weakUnionCheck`/`weakNilCheck`/`maxUnionVariants` from
--- `config.get` on nearly every one of its own recursive calls -- a single top-level
--- `vm.canCastType` on a concrete value against a concrete field type can recurse through
--- `isSubType` several times over (once to unwrap the value's node, once to unwrap the field
--- type's, an optional-nil check, ...), each asking `config.get` (a per-call scope/workspace-folder
--- resolution, not a plain table read) for the same 3 keys again. These 3 settings cannot change
--- mid-comparison (nothing in this recursion edits config), so they are fetched once per top-level
--- call and cached on `mark` -- already threaded, unchanged, through every recursive call of one
--- `isSubType`/`canCastType` invocation -- keyed by the `mark` table's own identity so a caller
--- that passes no `mark` (a fresh `{}` each time) still gets its own, uncontaminated cache.
---@type table<table, vm.type.checkConfig>
local typeCheckConfigCache = setmetatable({}, { __mode = 'k' })

--- The same 3 values per uri, valid while no configuration value and no workspace folder changed (`isSubType` is
--- called for nearly every checked type, each time with a fresh `mark`).
---@type table<uri|false, vm.type.checkConfig>
local typeCheckConfigByUri = {}
local typeCheckConfigVersion = -1
---@type table<uri, scope|false>?
local typeCheckConfigFolders

---@param uri  uri
---@param mark table<string, boolean>
---@return vm.type.checkConfig
local function getTypeCheckConfig(uri, mark)
    local cfg = typeCheckConfigCache[mark]
    if not cfg then
        if typeCheckConfigVersion ~= config.version or typeCheckConfigFolders ~= scope.folderCache then
            typeCheckConfigByUri = {}
            typeCheckConfigVersion = config.version
            typeCheckConfigFolders = scope.folderCache
        end
        cfg = typeCheckConfigByUri[uri or false]
        if not cfg then
            cfg = {
                weakUnionCheck   = config.get(uri, 'Lua.type.weakUnionCheck') or false,
                weakNilCheck     = config.get(uri, 'Lua.type.weakNilCheck') or false,
                maxUnionVariants = config.get(uri, 'Lua.type.maxUnionVariants') or 0,
            }
            typeCheckConfigByUri[uri or false] = cfg
        end
        typeCheckConfigCache[mark] = cfg
    end
    return cfg
end

--- The opaque aliases (`---@alias (opaque) PlayerID number`) a node stands for, nil when it has none. The alias global travels in the node next
--- to the aliased types, which is what makes the alias nominal: two opaque aliases of the same inner type are different types.
---@param uri  uri
---@param node vm.node
---@return table<vm.global, true>?
local function opaqueAliasesOf(uri, node)
    ---@type table<vm.global, true>?
    local found
    for obj in node:eachObject() do
        if obj.type == 'global' and obj.cate == 'type' then
            ---@cast obj vm.global
            for _, set in ipairs(obj:getSets(uri)) do
                if set.type == 'doc.alias' and vm.docHasAttr(set, 'opaque') then
                    found = found or {}
                    found[obj] = true
                    break
                end
            end
        end
    end
    return found
end

--- Does a function written with a body give nothing at all: no `return` with a value, no `@return`, and it does not end in a call that never returns?
---@param func parser.object
---@return boolean
local function givesNothing(func)
    if func.returns then
        return false
    end
    for _, doc in ipairs(func.bindDocs or {}) do
        if doc.type == 'doc.return' then
            return false
        end
    end
    return not vm.blockExits(func) and vm.countReturnsOfSource(func) == 0
end

--- Does a promised return type ask for a value: not optional, not `any`, `unknown`, `nil` or `never`, and not a type parameter?
---@param promised parser.object|vm.generic
---@return boolean
local function promisesValue(promised)
    local node = vm.compileNode(promised)
    if node:isOptional() then
        return false
    end
    local any = false
    for obj in node:eachObject() do
        if obj.type == 'global' and obj.cate == 'type' and (obj.name == 'any' or obj.name == 'unknown' or obj.name == 'nil' or obj.name == 'never')
        or obj.type == 'nil' or obj.type == 'doc.generic.name' or obj.type == 'generic' or obj.type == 'variable' or obj.type == 'local' then
            return false
        end
        any = true
    end
    return any
end

--- A function (or `fun(...)`) given where `fun(...)` is asked for: it must not need more arguments than the type provides, what the
--- type provides has to fit the parameters that are declared, and what it gives has to fit what the type promises (TypeScript's
--- rule). Only what is written counts: an unannotated parameter or return says nothing, and a generic type or function is not judged.
---@param uri    uri
---@param child  parser.object
---@param parent parser.object
---@return boolean
local function functionTypeMismatch(uri, child, parent)
    -- (the parent is a `fun(...)` type, or a function with its annotations: a method a class declares, that another one overrides)
    if (parent.type ~= 'doc.type.function' and parent.type ~= 'function')
    or (child.type ~= 'function' and child.type ~= 'doc.type.function') then
        return false
    end
    local parentIsFunction = parent.type == 'function'
    if parentIsFunction then
        if vm.getSign(parent) then
            return false
        end
        for _, doc in ipairs(parent.bindDocs or {}) do
            if doc.type == 'doc.overload' then
                return false
            end
        end
    end
    -- (a type parameter a call has bound is its type now; one still open says nothing)
    ---@type boolean?
    local open
    for _, side in ipairs { parent, child } do
        guide.eachSourceType(side, 'doc.generic.name', function (src)
            if not src._resolved then
                open = true
            end
        end)
    end
    if open or parent.signs or (child.type == 'function' and vm.getSign(child)) then
        return false
    end
    ---@type parser.object[]
    local provided = {}
    for _, arg in ipairs(parent.args or {}) do
        -- (two methods both have the implicit `self` first: it is not a parameter to compare; against a `fun(self: T, ...)` it is the
        -- parameter the type names)
        if not (parentIsFunction and arg.type == 'self') then
            provided[#provided+1] = arg
        end
    end
    ---@type parser.object[]
    local taken = {}
    for _, arg in ipairs(child.args or {}) do
        if not (parentIsFunction and arg.type == 'self') then
            taken[#taken+1] = arg
        end
    end
    -- (a `fun(self: T, ...)` field that redeclares a method: its `self` is the implicit one of the method)
    if parentIsFunction and child.type == 'doc.type.function' and taken[1] and taken[1].name and taken[1].name[1] == 'self' then
        local parentHasSelf = false
        for _, arg in ipairs(parent.args or {}) do
            if arg.type == 'self' then
                parentHasSelf = true
            end
        end
        if parentHasSelf then
            table.remove(taken, 1)
        end
    end
    -- (a plain function written for a method slot, `obj.Show = function(self, ...) end`, the hooking idiom: the method is called with the object first, so
    -- the first parameter of the function is the object, not a parameter the method type provides)
    if parentIsFunction and child.type == 'function' and taken[1] then
        local parentHasSelf, childHasSelf = false, false
        for _, arg in ipairs(parent.args or {}) do
            if arg.type == 'self' then
                parentHasSelf = true
            end
        end
        for _, arg in ipairs(child.args or {}) do
            if arg.type == 'self' then
                childHasSelf = true
            end
        end
        if parentHasSelf and not childHasSelf then
            table.remove(taken, 1)
        end
    end
    local providesAny = false
    for _, arg in ipairs(provided) do
        if arg.type == '...' or (arg.name and arg.name[1] == '...') then
            providesAny = true
        end
    end
    if not providesAny then
        local required = 0
        for _, arg in ipairs(taken) do
            if arg.type ~= '...' and not (arg.name and arg.name[1] == '...') and not arg.optional
            and not (child.type == 'function' and vm.compileNode(arg):isOptional()) then
                required = required + 1
            end
        end
        if required > #provided then
            return true
        end
    end
    for i = 1, math.min(#taken, #provided) do
        if provided[i].type == '...' or (provided[i].name and provided[i].name[1] == '...') then
            break
        end
        ---@type vm.node?
        local wantNode
        if parentIsFunction then
            local providedNode = vm.compileNode(provided[i])
            wantNode = providedNode.hasDefined and providedNode or nil
        else
            wantNode = provided[i].extends and vm.compileNode(provided[i].extends)
        end
        ---@type vm.node?
        local takes
        if child.type == 'doc.type.function' then
            takes = taken[i].extends and vm.compileNode(taken[i].extends)
        else
            local argNode = vm.compileNode(taken[i])
            takes = argNode.hasDefined and argNode or nil
        end
        -- (bivariant, as TypeScript's methods: a callback may take a narrower type than the one it is called with, the
        -- other way round is fine too; only two types that have nothing in common are a mismatch)
        if wantNode and takes then
            if vm.isSubType(uri, wantNode, takes) == false and vm.isSubType(uri, takes, wantNode) == false then
                return true
            end
        end
    end
    ---@type (parser.object|vm.generic)?
    local promised
    if parentIsFunction then
        for _, doc in ipairs(parent.bindDocs or {}) do
            if doc.type == 'doc.return' then
                promised = vm.getReturnOfFunction(parent, 1)
            end
        end
    else
        promised = parent.returns and parent.returns[1]
    end
    -- (a named function that gives nothing, where a value is promised: `takesCallback(print)`)
    if promised and child.type == 'function' and givesNothing(child) and promisesValue(promised) then
        return true
    end
    if promised and not (child.type == 'function' and not child.returns) then
        ---@type (parser.object|vm.generic)?
        local given
        if child.type == 'doc.type.function' then
            given = child.returns and child.returns[1]
        else
            given = vm.getReturnOfFunction(child, 1)
            local written = false
            for _, doc in ipairs(child.bindDocs or {}) do
                if doc.type == 'doc.return' then
                    written = true
                end
            end
            -- (an inferred return counts only when every part of it is a type that is known)
            if given and not written then
                for obj in vm.compileNode(given):eachObject() do
                    if obj.type == 'global' and obj.cate == 'type' and (obj.name == 'any' or obj.name == 'unknown')
                    or obj.type == 'doc.generic.name' or obj.type == 'generic' or obj.type == 'variable' or obj.type == 'local' then
                        given = nil
                        break
                    end
                end
            end
        end
        -- (a `nil` among what it gives is not what makes it unfit: a function that gives nothing when it fails fits)
        if given and vm.isSubType(uri, vm.compileNode(given):copy():removeOptional():remove 'nil', vm.compileNode(promised)) == false then
            return true
        end
    end
    return false
end

vm.functionTypeMismatch = functionTypeMismatch

--- Does the class have the fields of the inline shape (`{a: number, b?: string}`, or the shape an intersection `A & B` makes)? A field it lacks
--- must be nullable in the shape, one it has must fit. A class with a string index (`[string]: V`) can have any field: it fits.
---@param uri   uri
---@param class vm.global
---@param shape parser.object a `doc.type.table`
---@return boolean
local function classFitsShape(uri, class, shape)
    if vm.getClassIndexValue(uri, vm.createNode(class), 'string') then
        return true
    end
    for _, field in ipairs(shape.fields or {}) do
        local key = vm.getKeyName(field)
        if type(key) == 'string' then
            local wanted = vm.compileNode(field)
            ---@type vm.node?
            local found
            vm.getClassFields(uri, class, key, function (src)
                found = found or vm.createNode()
                found:merge(vm.compileNode(src))
            end)
            if not found then
                if not wanted:isNullable() then
                    return false
                end
            elseif vm.isSubType(uri, found, wanted) == false then
                return false
            end
        end
    end
    return true
end

---@param uri uri
---@param child  vm.node|string|vm.node.object
---@param parent vm.node|string|vm.node.object
---@param mark?  table<string, boolean>
---@param errs? typecheck.err[]
---@return boolean|nil
local function isSubTypeOfNames(uri, child, parent, mark, errs)
    mark = mark or {}

    if type(child) == 'string' then
        local globalVar = vm.getGlobal('type', child)
        if not globalVar then
            return nil
        end
        child = globalVar
    elseif child.type == 'vm.node' then
        -- opaque aliases are nominal: a value of one is not accepted where another is expected (plain values and literals are, and the
        -- alias flows out to its inner type)
        if parent.type == 'vm.node' then
            ---@cast parent vm.node
            local parentOpaque = opaqueAliasesOf(uri, parent)
            local childOpaque = parentOpaque and opaqueAliasesOf(uri, child --[[@as vm.node]])
            if parentOpaque and childOpaque then
                local shared = false
                for alias in pairs(childOpaque) do
                    if parentOpaque[alias] then
                        shared = true
                        break
                    end
                end
                if not shared then
                    return false
                end
            end
        end
        local typeCfg = getTypeCheckConfig(uri, mark)
        if typeCfg.weakUnionCheck then
            local hasKnownType = 0
            local maxUnionVariants = typeCfg.maxUnionVariants
            local i = 0
            for n in child:eachObject() do
                i = i + 1
                if maxUnionVariants > 0 and i > maxUnionVariants then
                    break
                end
                if vm.getNodeName(n) then
                    ---@type boolean?
                    local res = vm.isSubType(uri, n, parent, mark, errs)
                    if res == true then
                        return true
                    elseif res == false then
                        hasKnownType = hasKnownType + 1
                    end
                end
            end
            if hasKnownType > 0 then
                if  errs
                and hasKnownType > 1
                and #vm.getInfer(child):getSubViews(uri) > 1 then
                    errs[#errs+1] = 'TYPE_ERROR_CHILD_ALL_DISMATCH'
                    errs[#errs+1] = child
                    errs[#errs+1] = parent
                end
                return false
            end
            return true
        else
            local weakNil = typeCfg.weakNilCheck
            ---@type boolean?
            local skipTable
            local maxUnionVariants = typeCfg.maxUnionVariants
            local i = 0
            for n in child:eachObject() do
                i = i + 1
                if maxUnionVariants > 0 and i > maxUnionVariants then
                    break
                end
                if skipTable == nil and n.type == "table" and parent.type == "vm.node" then -- skip table type check if child has class
                    for _, c in ipairs(child) do
                        if c.type == 'global' and c.cate == 'type' then
                            for _, set in ipairs(c:getSets(uri)) do
                                if set.type == 'doc.class' then
                                    skipTable = true
                                    break
                                end
                            end
                        end
                        if skipTable then
                            break
                        end
                    end
                    if not skipTable then
                        skipTable = false
                    end
                end
                local nodeName = vm.getNodeName(n)
                if  nodeName
                and not (nodeName == 'nil' and weakNil) and not (skipTable and n.type == 'table')
                and vm.isSubType(uri, n, parent, mark, errs) == false then
                    if errs then
                        errs[#errs+1] = 'TYPE_ERROR_UNION_DISMATCH'
                        errs[#errs+1] = n
                        errs[#errs+1] = parent
                    end
                    return false
                end
            end
            if not weakNil and child:isOptional() then
                if vm.isSubType(uri, 'nil', parent, mark, errs) == false then
                    if errs then
                        errs[#errs+1] = 'TYPE_ERROR_OPTIONAL_DISMATCH'
                        errs[#errs+1] = parent
                    end
                    return false
                end
            end
            return true
        end
    end

    local childName = vm.getNodeName(child)
    if childName == 'any'
    or childName == 'unknown' then
        return true
    end

    if not childName
    or isAlias(childName, uri) then
        return nil
    end
    if child.type == 'global' and child.cate == 'type' and isUndefinedType(childName, uri) then
        return true
    end

    if type(parent) == 'string' then
        local globalVar = vm.getGlobal('type', parent)
        if not globalVar then
            return false
        end
        parent = globalVar
    elseif parent.type == 'vm.node' then
        local hasKnownType = 0
        local maxUnionVariants = getTypeCheckConfig(uri, mark).maxUnionVariants
        local i = 0
        for n in parent:eachObject() do
            i = i + 1
            if maxUnionVariants > 0 and i > maxUnionVariants then
                break
            end
            if vm.getNodeName(n) then
                ---@type boolean?
                local res = vm.isSubType(uri, child, n, mark, errs)
                if res == true then
                    return true
                elseif res == false then
                    hasKnownType = hasKnownType + 1
                end
            end
            if n.type == 'doc.generic.name' then
                return true
            end
        end
        if parent:isOptional() then
            if vm.isSubType(uri, child, 'nil', mark, errs) == true then
                return true
            end
        end
        if hasKnownType > 0 then
            if  errs
            and hasKnownType > 1
            and #vm.getInfer(parent):getSubViews(uri) > 1 then
                errs[#errs+1] = 'TYPE_ERROR_PARENT_ALL_DISMATCH'
                errs[#errs+1] = child
                errs[#errs+1] = parent
            end
            return false
        end
        return true
    end


    local parentName = vm.getNodeName(parent)
    if parentName == 'any'
    or parentName == 'unknown' then
        return true
    end

    if not parentName
    or isAlias(parentName, uri) then
        return nil
    end
    if parent.type == 'global' and parent.cate == 'type' and isUndefinedType(parentName, uri) then
        return true
    end

    -- nothing has the type `never` but `never` (a table would pass as a class without fields)
    if parentName == 'never' and childName ~= 'never' then
        return false
    end

    if childName == parentName then
        if not checkValue(parent, child, mark, errs) then
            return false
        end
        if parentName == 'function'
        and isNode(child) and isNode(parent)
        and functionTypeMismatch(uri, child, parent) then
            if errs then
                errs[#errs+1] = 'TYPE_ERROR_DISMATCH'
                errs[#errs+1] = child
                errs[#errs+1] = parent
            end
            return false
        end
        return true
    end

    if parentName == 'number' and childName == 'integer' then
        return true
    end

    if parentName == 'integer' and childName == 'number' then
        if config.get(uri, 'Lua.type.castNumberToInteger') then
            return true
        end
        if  child.type == 'number'
        and child[1]
        and not math.tointeger(child[1]) then
            if errs then
                errs[#errs+1] = 'TYPE_ERROR_NUMBER_LITERAL_TO_INTEGER'
                errs[#errs+1] = child[1]
            end
            return false
        end
        if  child.type == 'global'
        and child.cate == 'type' then
            if errs then
                errs[#errs+1] = 'TYPE_ERROR_NUMBER_TYPE_TO_INTEGER'
            end
            return false
        end
        return true
    end

    local result = checkParentEnum(parentName, child, uri, mark, errs)
    if result ~= nil then
        return result
    end

    result = checkChildEnum(childName, parent, uri, mark, errs)
    if result ~= nil then
        return result
    end

    if parentName == 'table' and not guide.isBasicType(childName) then
        -- (a class given where an inline shape is asked for: it has to have the fields of the shape)
        if isNode(parent) and parent.type == 'doc.type.table' and child.type == 'global' and child.cate == 'type'
        and not classFitsShape(uri, child --[[@as vm.global]], parent) then
            if errs then
                errs[#errs+1] = 'TYPE_ERROR_DISMATCH'
                errs[#errs+1] = child
                errs[#errs+1] = parent
            end
            return false
        end
        return true
    end
    if childName == 'table' and not guide.isBasicType(parentName) then
        if config.get(uri, 'Lua.type.checkTableShape') then
            ---@cast parent vm.global
            ---@cast child parser.object
            return checkTableShape(parent, child, uri, mark, errs)
        else
            return true
        end
    end

    -- the key of every `mark` write below; only used where `childName` is known to be set
    -- (a setindex with an unresolved key is what came out `unknown` in the editor's order)
    local markKey = childName
    -- check class parent
    if childName and not mark[markKey] then
        mark[markKey] = true
        local isBasicType = guide.isBasicType(childName)
        local childClass = vm.getGlobal('type', childName)
        if childClass then
            for _, set in ipairs(childClass:getSets(uri)) do
                if set.type == 'doc.class' and set.extends then
                    for _, ext in ipairs(set.extends) do
                        -- A parent given with arguments (`---@class A : B<string>`) is
                        -- parsed into `doc.type.sign`, keeping the name one level down.
                        -- Without looking inside, such a parent is skipped entirely and
                        -- the class is not recognized as its child.
                        ---@type string?
                        local extName
                        if ext.type == 'doc.extends.name' then
                            extName = ext[1]
                        elseif ext.type == 'doc.type.sign'
                        and    ext.node
                        and    ext.node.type == 'doc.extends.name' then
                            extName = ext.node[1]
                        end
                        if  extName
                        and (not isBasicType or guide.isBasicType(extName))
                        and vm.isSubType(uri, extName, parent, mark, errs) == true then
                            mark[markKey] = nil
                            return true
                        end
                    end
                end
            end
        end
        mark[markKey] = nil
    end

    --[[
    ---@class A: string

    ---@type A
    local x = '' --> `string` set to `A`
    ]]
    if  guide.isBasicType(childName)
    and not mark[markKey] then
        mark[markKey] = true
        if vm.isSubType(uri, parentName, childName, mark) then
            mark[markKey] = nil
            return true
        end
        mark[markKey] = nil
    end

    if errs then
        errs[#errs+1] = 'TYPE_ERROR_DISMATCH'
        errs[#errs+1] = child
        errs[#errs+1] = parent
    end
    return false
end

--- `Box<number>` for `Box<boolean>`: the type arguments of a generic class. The class of the child, or one it inherits from, has to
--- have arguments that are assignable to the ones the parameter names (covariant, as TypeScript's arrays are). Only a clear `false` counts, so
--- a class with no argument given, `any` and an argument that is a type parameter say nothing; a parent that also allows another class
--- is not judged by the arguments.
---@param uri       uri
---@param childSign parser.object one instance of a generic class
---@param parent    vm.node
---@param errs?     typecheck.err[]
---@return boolean
local function signMismatch(uri, childSign, parent, errs)
    local chain = vm.getClassGenericChain(uri, childSign)
    ---@type parser.object[]
    local related = {}
    ---@type string[]
    local classNames = {}
    for obj in parent:eachObject() do
        if isNode(obj) and obj.type == 'doc.type.sign' and obj.signs and obj.node then
            local found = false
            for _, entry in ipairs(chain) do
                if entry.class == obj.node[1] and entry.arguments then
                    found = true
                end
            end
            if not found then
                return false
            end
            related[#related+1] = obj
        elseif obj.type == 'global' and obj.cate == 'type' then
            ---@cast obj vm.global
            if not guide.isBasicType(obj.name) then
                classNames[#classNames+1] = obj.name
            end
        end
    end
    if #related == 0 then
        return false
    end
    -- (the class of a sign is part of the node too: only another class makes the parent wider)
    for _, other in ipairs(classNames) do
        local named = false
        for _, sign in ipairs(related) do
            if sign.node[1] == other then
                named = true
            end
        end
        if not named then
            return false
        end
    end
    for _, parentSign in ipairs(related) do
        local parentName = parentSign.node[1] --[[@as string]]
        local parentClass = vm.getGlobal('type', parentName)
        ---@type table<string, vm.node>?
        local arguments
        for _, entry in ipairs(chain) do
            if entry.class == parentName then
                arguments = entry.arguments
            end
        end
        if not parentClass or not arguments then
            return false
        end
        local mismatch = false
        for _, set in ipairs(parentClass:getSets(uri)) do
            if set.type == 'doc.class' and set.signs then
                for i, signName in ipairs(set.signs) do
                    local childArgument  = arguments[signName[1] --[[@as string]]]
                    local parentArgument = parentSign.signs[i]
                    if childArgument and parentArgument
                    and vm.isSubType(uri, childArgument, vm.compileNode(parentArgument)) == false then
                        mismatch = true
                    end
                end
                break
            end
        end
        if not mismatch then
            return false
        end
    end
    if errs then
        errs[#errs+1] = 'TYPE_ERROR_DISMATCH'
        errs[#errs+1] = childSign
        errs[#errs+1] = related[1]
    end
    return true
end

--- Does any instance of a generic class in `child` (a union of `Box<boolean> | Box<number>` has two) fail to fit `parent`?
---@param uri    uri
---@param child  vm.node
---@param parent vm.node
---@param errs?  typecheck.err[]
---@return boolean
local function typeArgumentsMismatch(uri, child, parent, errs)
    for obj in child:eachObject() do
        if isNode(obj) and obj.type == 'doc.type.sign' and obj.signs and obj.node
        and signMismatch(uri, obj, parent, errs) then
            return true
        end
    end
    return false
end

--- The kind of key a dictionary type has: `literals` (a union of string literals, `keys` lists them), `string`, `integer` (`integer` and
--- `number` keys: the table can be an array), `mixed` (a union of kinds: `table<string|integer, V>` is a table that is both an array and a
--- dictionary, nothing can be said about it) or `other`.
---@param node vm.node
---@return string kind
---@return table<string, true>? keys
local function dictionaryKeyKind(node)
    ---@type table<string, true>
    local keys = {}
    local count = 0
    ---@type table<string, true>
    local kinds = {}
    for obj in node:eachObject() do
        if (obj.type == 'doc.type.string' or obj.type == 'string') and obj[1] ~= nil then
            keys[tostring(obj[1])] = true
            count = count + 1
            kinds.literals = true
        else
            local name = vm.getNodeName(obj)
            if name == 'string' then
                kinds.string = true
            elseif name == 'integer' or name == 'number' then
                kinds.integer = true
            elseif obj.type ~= 'local' and obj.type ~= 'variable' then
                return 'other', nil
            end
        end
    end
    if node:isOptional() or next(kinds) == nil then
        return 'other', nil
    end
    ---@type string
    local kind = next(kinds) --[[@as string]]
    if next(kinds, kind) then
        -- (a string-keyed hash and its string literals are one kind of key)
        if kinds.literals and kinds.string and not kinds.integer then
            return 'string', nil
        end
        return 'mixed', nil
    end
    return kind, kind == 'literals' and keys or nil
end

--- The required fields (neither optional nor nullable) a class has, its parents' included, by key.
---@param uri   uri
---@param class vm.global
---@return table<string, vm.node>
local function getRequiredFieldsOf(uri, class)
    ---@type table<string, vm.node>
    local required = {}
    for _, set in ipairs(class:getSets(uri)) do
        if set.type == 'doc.class' then
            for _, field in ipairs(vm.getFields(set) or {}) do
                if field.type == 'doc.field' and not field.optional then
                    local node = vm.compileNode(field)
                    local key = vm.getKeyName(field)
                    if key and type(key) == 'string' and not node:isNullable() then
                        required[key] = node
                    end
                end
            end
        end
    end
    return required
end

--- Does the dictionary `table<K, V>` (`dictionary`, a `doc.type.sign`) fit one member of the parent: an array `E[]` or a class? true: it
--- does, false: it does not, nil: nothing says (the parent is something else, or the key is not known).
---@param uri           uri
---@param dictionary    parser.object
---@param member        vm.node.object
---@param childHasArray boolean the child also has an array member (a string-keyed hash next to one is tolerated)
---@return boolean?
local function dictionaryFits(uri, dictionary, member, childHasArray)
    local keyNode   = vm.compileNode(dictionary.signs[1])
    local valueNode = vm.compileNode(dictionary.signs[2])
    local kind, keys = dictionaryKeyKind(keyNode)
    if kind == 'other' or kind == 'mixed' then
        return nil
    end
    if member.type == 'doc.type.array' then
        if kind == 'integer' then
            return vm.isSubType(uri, valueNode, vm.compileNode(member.node)) ~= false
        elseif kind == 'string' or kind == 'literals' then
            return childHasArray
        end
        return false
    end
    if member.type == 'global' and member.cate == 'type' then
        ---@cast member vm.global
        local required = getRequiredFieldsOf(uri, member)
        if kind ~= 'literals' then
            return next(required) == nil
        end
        for key, fieldNode in pairs(required) do
            if not (keys and keys[key]) or vm.isSubType(uri, valueNode, fieldNode) == false then
                return false
            end
        end
        return true
    end
    return nil
end

--- A dictionary `table<K, V>` given where an array or a class is asked for. Judged only when the parent is nothing but arrays and classes
--- (and `nil`), and only a clear `false` for every member of the parent counts.
---@param uri    uri
---@param child  vm.node
---@param parent vm.node
---@param errs?  typecheck.err[]
---@return boolean
local function dictionaryMismatch(uri, child, parent, errs)
    ---@type parser.object[]
    local dictionaries = {}
    local childHasArray = false
    for obj in child:eachObject() do
        if isNode(obj) and obj.type == 'doc.type.sign' and obj.node and obj.node[1] == 'table' and obj.signs and #obj.signs == 2 then
            dictionaries[#dictionaries+1] = obj
        elseif obj.type == 'doc.type.array' then
            childHasArray = true
        end
    end
    if #dictionaries == 0 then
        return false
    end
    ---@type vm.node.object[]
    local members = {}
    for obj in parent:eachObject() do
        if obj.type == 'doc.type.array' then
            members[#members+1] = obj
        elseif obj.type == 'global' and obj.cate == 'type' then
            ---@cast obj vm.global
            if guide.isBasicType(obj.name) then
                return false
            end
            members[#members+1] = obj
        elseif obj.type ~= 'local' and obj.type ~= 'variable' and obj.type ~= 'self' then
            return false
        end
    end
    if #members == 0 then
        return false
    end
    for _, dictionary in ipairs(dictionaries) do
        local fits = false
        local unknown = false
        for _, member in ipairs(members) do
            local result = dictionaryFits(uri, dictionary, member, childHasArray)
            if result == true then
                fits = true
            elseif result == nil then
                unknown = true
            end
        end
        if not fits and not unknown then
            if errs then
                errs[#errs+1] = 'TYPE_ERROR_DISMATCH'
                errs[#errs+1] = dictionary
                errs[#errs+1] = members[1]
            end
            return true
        end
    end
    return false
end

---@param uri uri
---@param child  vm.node|string|vm.node.object
---@param parent vm.node|string|vm.node.object
---@param mark?  table<string, boolean>
---@param errs? typecheck.err[]
---@return boolean|nil
function vm.isSubType(uri, child, parent, mark, errs)
    local result = isSubTypeOfNames(uri, child, parent, mark, errs)
    if result == true
    and type(child) == 'table' and type(parent) == 'table'
    and child.type == 'vm.node' and parent.type == 'vm.node'
    and (typeArgumentsMismatch(uri, child --[[@as vm.node]], parent --[[@as vm.node]], errs)
      or dictionaryMismatch(uri, child --[[@as vm.node]], parent --[[@as vm.node]], errs)) then
        return false
    end
    return result
end

---@param node string|vm.node|vm.object
---@return boolean
function vm.isUnknown(node)
    if type(node) == 'string' then
        return node == 'unknown'
    end
    if node.type == 'vm.node' then
        return not node:hasKnownType()
    end
    return false
end

--- The `table<K, V>` types a class inherits from (`---@class Dict : table<string, number>`), through any chain of parents: the class indexes
--- like that table. A class with type parameters is left alone (its table parent is a generic).
---@param uri   uri
---@param tnode vm.node
---@return parser.object[]
local function collectClassTables(uri, tnode)
    ---@type parser.object[]
    local found = {}
    ---@type table<vm.global, true>
    local seen = {}
    ---@param class vm.global
    local function walk(class)
        if seen[class] then
            return
        end
        seen[class] = true
        for _, set in ipairs(class:getSets(uri)) do
            if set.type == 'doc.class' and set.extends and not set.signs then
                for _, ext in ipairs(set.extends) do
                    if ext.type == 'doc.type.table' then
                        if not vm.getGeneric(ext) then
                            found[#found+1] = ext
                        end
                    elseif ext.type == 'doc.type.sign' and ext.node and ext.node[1] == 'table' then
                        -- `table<K, V>`: the meta class of `table` resolves it to the table type `{ [K]: V }`
                        for obj in vm.compileNode(ext):eachObject() do
                            if isNode(obj) and obj.type == 'doc.type.table' then
                                found[#found+1] = obj
                            end
                        end
                    elseif ext.type == 'doc.extends.name' then
                        local parent = vm.getGlobal('type', ext[1])
                        if parent then
                            walk(parent)
                        end
                    end
                end
            end
        end
    end
    for tn in tnode:eachObject() do
        if tn.type == 'global' and tn.cate == 'type' then
            ---@cast tn vm.global
            walk(tn)
        end
    end
    return found
end

--- The key types a class declares for its own indexing: the `---@field [K] V` lines of the class and of the classes it inherits from, and
--- the K of an inherited `table<K, V>`. nil when it declares none. `named` tells that the class also has named fields (a string can
--- then be a field name as well, whatever K says).
---@param uri   uri
---@param tnode vm.node
---@return vm.node?
---@return boolean named
function vm.getClassIndexKeys(uri, tnode)
    local keys = vm.createNode()
    local count = 0
    local named = false
    ---@type table<vm.global, true>
    local seen = {}
    -- what the type parameters of a class stand for where the type is written with arguments (`Map<string, number>`)
    ---@type table<vm.global, table<string, vm.node>>
    local bindings = {}
    for tn in tnode:eachObject() do
        if tn.type == 'doc.type.sign' and tn.node and tn.node[1] ~= 'table' and tn.signs then
            local class = vm.getGlobal('type', tn.node[1] --[[@as string]])
            local map = class and vm.getClassGenericMap(uri, class, tn.signs)
            if class and map then
                bindings[class] = map
            end
        end
    end
    ---@param class vm.global
    local function walk(class)
        if seen[class] then
            return
        end
        seen[class] = true
        for _, set in ipairs(class:getSets(uri)) do
            if set.type == 'doc.class' then
                for _, ext in ipairs(set.extends or {}) do
                    if ext.type == 'doc.extends.name' then
                        local parent = vm.getGlobal('type', ext[1])
                        if parent then
                            walk(parent)
                        end
                    end
                end
                for _, field in ipairs(set.fields) do
                    if field.field and field.field.type == 'doc.type' then
                        local keyNode = vm.compileNode(field.field)
                        local bound = bindings[class]
                        if bound then
                            -- `---@field [K] V` of `Map<K, V>` written `Map<string, number>`: the key is what `K` stands for
                            local resolved = vm.createNode()
                            for obj in keyNode:eachObject() do
                                local replaced = obj.type == 'doc.generic.name' and bound[obj[1] --[[@as string]]]
                                if replaced then
                                    resolved:merge(replaced)
                                else
                                    resolved:merge(vm.createNode(obj))
                                end
                            end
                            keyNode = resolved
                        end
                        keys:merge(keyNode)
                        count = count + 1
                    elseif field.field then
                        named = true
                    end
                end
            end
        end
    end
    for tn in tnode:eachObject() do
        if tn.type == 'global' and tn.cate == 'type' then
            ---@cast tn vm.global
            walk(tn)
        elseif tn.type == 'doc.type.sign' and tn.node and tn.node[1] ~= 'table' then
            local class = vm.getGlobal('type', tn.node[1] --[[@as string]])
            if class then
                walk(class)
            end
        end
    end
    for _, tbl in ipairs(collectClassTables(uri, tnode)) do
        for _, field in ipairs(tbl.fields or {}) do
            if field.name.type ~= 'doc.field.name' then
                keys:merge(vm.compileNode(field.name))
                count = count + 1
            end
        end
    end
    if count == 0 then
        return nil, named
    end
    return keys, named
end

--- The value type of indexing a class that inherits from `table<K, V>` with a key of the type `knode` (nil: the class has no such parent, or
--- the key does not fit K).
---@param uri   uri
---@param tnode vm.node
---@param knode vm.node|string
---@return vm.node?
function vm.getClassIndexValue(uri, tnode, knode)
    local tables = collectClassTables(uri, tnode)
    if #tables == 0 then
        return nil
    end
    local tableNode = vm.createNode()
    for _, tbl in ipairs(tables) do
        tableNode:merge(tbl)
    end
    return vm.getTableValue(uri, tableNode, knode)
end

---@param uri uri
---@param tnode vm.node
---@param knode vm.node|string
---@param inversion? boolean
---@return vm.node?
function vm.getTableValue(uri, tnode, knode, inversion)
    local result = vm.createNode()
    local inferSize = config.get(uri, "Lua.type.inferTableSize")
    for tn in tnode:eachObject() do
        if tn.type == 'doc.type.table' then
            for _, field in ipairs(tn.fields) do
                if field.extends then
                    if inversion then
                        if vm.isSubType(uri, vm.compileNode(field.name), knode) then
                            result:merge(vm.compileNode(field.extends))
                        end
                    else
                        if vm.isSubType(uri, knode, vm.compileNode(field.name)) then
                            result:merge(vm.compileNode(field.extends))
                        end
                    end
                end
            end
        end
        if tn.type == 'doc.type.array' then
            result:merge(vm.compileNode(tn.node))
        end
        if tn.type == 'table' then
            if vm.isUnknown(knode) then
                goto CONTINUE
            end
            for _, field in ipairs(tn) do
                if  field.type == 'tableindex'
                and field.value then
                    result:merge(vm.compileNode(field.value))
                end
                if  field.type == 'tablefield'
                and field.value then
                    if inversion then
                        if vm.isSubType(uri, 'string', knode) then
                            result:merge(vm.compileNode(field.value))
                        end
                    else
                        if vm.isSubType(uri, knode, 'string') then
                            result:merge(vm.compileNode(field.value))
                        end
                    end
                end
                if  field.type == 'tableexp'
                and field.value
                and field.tindex <= inferSize then
                    if inversion then
                        if vm.isSubType(uri, 'integer', knode) then
                            result:merge(vm.compileNode(field.value))
                        end
                    else
                        if vm.isSubType(uri, knode, 'integer') then
                            result:merge(vm.compileNode(field.value))
                        end
                    end
                end
                if field.type == 'varargs' then
                    result:merge(vm.compileNode(field))
                end
            end
        end
        ::CONTINUE::
    end
    local viaClass = vm.getClassIndexValue(uri, tnode, knode)
    if viaClass then
        result:merge(viaClass)
    end
    if result:isEmpty() then
        return nil
    end
    return result
end

---@param uri uri
---@param tnode vm.node
---@param vnode vm.node|string|vm.object
---@param reverse? boolean
---@return vm.node?
function vm.getTableKey(uri, tnode, vnode, reverse)
    local result = vm.createNode()
    for tn in tnode:eachObject() do
        if tn.type == 'doc.type.table' then
            -- `{ numSpecs: number, [number]: number }`: next to an index signature the named fields are keys too (`string`), else the loop key of
            -- `pairs` would be `number` and `k ~= "numSpecs"` an impossible comparison. A table with named fields only keeps saying nothing here.
            local hasSignature = false
            for _, field in ipairs(tn.fields) do
                if field.name.type ~= 'doc.field.name' then
                    hasSignature = true
                    break
                end
            end
            for _, field in ipairs(tn.fields) do
                local named = field.name.type == 'doc.field.name'
                if  field.extends
                and (not named or hasSignature) then
                    local keyNode = named and vm.declareGlobal('type', 'string') or vm.compileNode(field.name)
                    if reverse then
                        if vm.isSubType(uri, vm.compileNode(field.extends), vnode) then
                            result:merge(keyNode)
                        end
                    else
                        if vm.isSubType(uri, vnode, vm.compileNode(field.extends)) then
                            result:merge(keyNode)
                        end
                    end
                end
            end
        end
        if tn.type == 'doc.type.array' then
            result:merge(vm.declareGlobal('type', 'integer'))
        end
        if tn.type == 'table' then
            if vm.isUnknown(tnode) then
                goto CONTINUE
            end
            for _, field in ipairs(tn) do
                if field.type == 'tableindex' then
                    if field.index then
                        result:merge(vm.compileNode(field.index))
                    end
                end
                if field.type == 'tablefield' then
                    result:merge(vm.declareGlobal('type', 'string'))
                end
                if field.type == 'tableexp' or field.type == 'varargs' then
                    result:merge(vm.declareGlobal('type', 'integer'))
                end
            end
        end
        ::CONTINUE::
    end
    if result:isEmpty() then
        return nil
    end
    return result
end

---@param uri uri
---@param defNode vm.node
---@param refNode vm.node
---@param errs typecheck.err[]?
---@return boolean
function vm.canCastType(uri, defNode, refNode, errs)
    local defInfer = vm.getInfer(defNode)
    local refInfer = vm.getInfer(refNode)

    if defInfer:hasAny(uri) then
        return true
    end
    if refInfer:hasAny(uri) then
        return true
    end
    -- (fast path: on a table literal with thousands of trivial one-member-type entries, calling
    -- `:view(uri)` here just to compare it against a literal string paid for the sort+concat a
    -- real view string needs, for a boolean answer -- see TODO.md's assign-type-mismatch profiling
    -- entry. `viewIfUnknownOrNil` reproduces exactly what `:view(uri) == 'unknown'`/`'nil'` would
    -- answer without that cost; differentially validated against `:view()` itself, 0 disagreements
    -- over the repo self-check and 3 real corpora, before landing here.)
    local defFast = defInfer:viewIfUnknownOrNil(uri)
    if defFast == 'unknown' or defFast == 'nil' then
        return true
    end
    if refInfer:viewIfUnknownOrNil(uri) == 'unknown' then
        return true
    end

    if vm.isSubType(uri, refNode, 'nil') then
        -- allow `local x = {};x = nil`,
        -- but not allow `local x ---@type table;x = nil`
        if  defInfer:hasType(uri, 'table')
        and not defNode:hasType 'table' then
            return true
        end
    end

    if vm.isSubType(uri, refNode, 'number') then
        -- allow `local x = 0;x = 1.0`,
        -- but not allow `local x ---@type integer;x = 1.0`
        if  defInfer:hasType(uri, 'integer')
        and not defNode:hasType 'integer' then
            return true
        end
    end

    if vm.isSubType(uri, refNode, defNode, {}, errs) then
        return true
    end


    return false
end

---@type table<string, string[]>
local ErrorMessageMap = {
    TYPE_ERROR_ENUM_GLOBAL_DISMATCH       = {'child', 'parent'},
    TYPE_ERROR_ENUM_GENERIC_UNSUPPORTED   = {'child'},
    TYPE_ERROR_ENUM_LITERAL_DISMATCH      = {'child', 'parent'},
    TYPE_ERROR_ENUM_OBJECT_DISMATCH       = {'child', 'parent'},
    TYPE_ERROR_ENUM_NO_OBJECT             = {'child'},
    TYPE_ERROR_INTEGER_DISMATCH           = {'child', 'parent'},
    TYPE_ERROR_STRING_DISMATCH            = {'child', 'parent'},
    TYPE_ERROR_BOOLEAN_DISMATCH           = {'child', 'parent'},
    TYPE_ERROR_TABLE_NO_FIELD             = {'key'},
    TYPE_ERROR_TABLE_FIELD_DISMATCH       = {'key', 'child', 'parent'},
    TYPE_ERROR_ARRAY_ELEMENT_DISMATCH     = {'child', 'parent'},
    TYPE_ERROR_CHILD_ALL_DISMATCH         = {'child', 'parent'},
    TYPE_ERROR_PARENT_ALL_DISMATCH        = {'child', 'parent'},
    TYPE_ERROR_UNION_DISMATCH             = {'child', 'parent'},
    TYPE_ERROR_OPTIONAL_DISMATCH          = {'parent'},
    TYPE_ERROR_NUMBER_LITERAL_TO_INTEGER  = {'child'},
    TYPE_ERROR_NUMBER_TYPE_TO_INTEGER     = {},
    TYPE_ERROR_DISMATCH                   = {'child', 'parent'},
    DIAG_MISSING_FIELDS                   = {"1", "2"},
}

---@param uri uri
---@param errs typecheck.err[]
---@return string
function vm.viewTypeErrorMessage(uri, errs)
    ---@type string[]
    local lines = {}
    ---@type table<string, boolean>
    local mark  = {}
    local index = 1
    while true do
        local name = errs[index] --[[@as string?]]  -- (the list is a name, then the values of its message)
        if not name then
            break
        end
        index = index + 1
        ---@type string[]
        local params = ErrorMessageMap[name]
        ---@type table<string, string?>
        local lparams = {}
        for _, paramName in ipairs(params) do
            local value = errs[index]
            if type(value) == 'string'
            or type(value) == 'number'
            or type(value) == 'boolean' then
                lparams[paramName] = util.viewLiteral(value)
            elseif value.type == 'global' then
                ---@cast value vm.global
                lparams[paramName] = value.name
            elseif value.type == 'vm.node' then
                ---@cast value vm.node
                lparams[paramName] = vm.getInfer(value):view(uri)
            elseif value.type == 'table' then
                lparams[paramName] = 'table'
            elseif value.type == 'generic' then
                lparams[paramName] = vm.getInfer(value):view(uri)
            elseif value.type == 'variable' then
            else
                if paramName == 'key' then
                    lparams[paramName] = vm.viewKey(value, uri)
                else
                    lparams[paramName] = vm.getInfer(value):view(uri)
                                      or vm.getInfer(value):view(uri)
                end
            end
            index = index + 1
        end
        local line = lang.script(name, lparams)
        if not mark[line] then
            mark[line] = true
            lines[#lines+1] = '- ' .. line
        end
    end
    util.revertArray(lines)
    if #lines > 15 then
        lines[13] = ('...(+%d)'):format(#lines - 15)
        table.move(lines, #lines - 2, #lines, 14)
        return table.concat(lines, '\n', 1, 16)
    else
        return table.concat(lines, '\n')
    end
end

---@param name string
---@param uri uri
---@return parser.object[]?
function vm.getOverloadsByTypeName(name, uri)
    local globalVar = vm.getGlobal('type', name)
    if not globalVar then
        return nil
    end
    ---@type parser.object[]?
    local results
    for _, set in ipairs(globalVar:getSets(uri)) do
        for _, doc in ipairs(set.bindGroup) do
            if doc.type == 'doc.overload' then
                if not results then
                    results = {}
                end
                results[#results+1] = doc.overload
            end
        end
    end
    return results
end
