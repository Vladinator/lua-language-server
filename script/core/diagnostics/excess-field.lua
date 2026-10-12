local vm              = require 'vm'
local files           = require 'files'
local guide           = require 'parser.guide'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'The field `%s` does not exist in type `%s`.'

protoDiagnostic.register {
    'excess-field',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'A table constructor given to a class has a field the class does not declare (the excess property check of TypeScript).',
}

--- The names a class declares: `---@field`s, inherited ones and the fields assigned to it in code.
---@param def parser.object
---@return table<string|integer, true>
local function getDeclaredKeys(def)
    ---@type table<parser.object, table<string|integer, true>>
    local cache = vm.getCache('excess-field.keys', true)
    local cached = cache[def]
    if cached then
        return cached
    end
    ---@type table<string|integer, true>
    local keys = {}
    for _, field in ipairs(vm.getFields(def)) do
        local key = vm.getKeyName(field)
        if key then
            keys[key] = true
        end
    end
    cache[def] = keys
    return keys
end

--- Does the class, or a class it inherits from, extend a class nothing defines? Its fields are unknown then (the API annotations of the
--- game are not loaded, a library is missing): a key that looks undeclared may belong to the parent.
---@param uri  uri
---@param class parser.object a `doc.class`
---@param seen table<parser.object, true>
---@return boolean
local function hasUnknownAncestor(uri, class, seen)
    if seen[class] then
        return false
    end
    seen[class] = true
    for _, ext in ipairs(class.extends or {}) do
        local name = ext.type == 'doc.extends.name' and ext[1]
        if name then
            ---@type boolean?
            local known
            for _, doc in ipairs(vm.getDocSets(uri, name)) do
                if doc.type == 'doc.class' then
                    known = true
                    if hasUnknownAncestor(uri, doc, seen) then
                        return true
                    end
                end
            end
            if not known then
                return true
            end
        end
    end
    return false
end

--- `return { ... }` in a function with `---@return Class`: the declared type of that return value.
---@param src parser.object a table constructor
---@return parser.object?
local function declaredReturnOf(src)
    local ret = src.parent
    if not ret or ret.type ~= 'return' then
        return nil
    end
    ---@type integer?
    local index
    for i, value in ipairs(ret) do
        if value == src then
            index = i
            break
        end
    end
    local func = guide.getParentFunction(src)
    if not index or not func or func.type ~= 'function' then
        return nil
    end
    for _, doc in ipairs(func.bindDocs or {}) do
        if doc.type == 'doc.return' then
            for _, rtn in ipairs(doc.returns) do
                if rtn.returnIndex == index then
                    return rtn
                end
            end
        end
    end
    return nil
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@async
    ---@param src parser.object
    guide.eachSourceType(state.ast, 'table', function (src)
        await.delay()

        vm.removeNode(src)
        local defs = vm.getDefs(src)
        local returned = declaredReturnOf(src)
        if returned then
            defs = {}
            for _, unit in ipairs(returned.types or { returned }) do
                -- (`Line|nil`: nil is no class of the table that is returned)
                if not (unit.type == 'doc.type.name' and unit[1] == 'nil') then
                    for _, def in ipairs(vm.getDefs(unit)) do
                        defs[#defs+1] = def
                    end
                end
            end
        end
        ---@type parser.object[]
        local classes = {}
        for _, def in ipairs(defs) do
            if def.type == 'doc.class' then
                if def.bindSource and guide.isInRange(def.bindSource, src.start) then
                    return
                end
                -- a class of an API stub is rarely complete (the fields the game adds at run time), only the classes of the project are checked
                local classUri = guide.getUri(def)
                if files.isLibrary(classUri) or vm.isMetaFile(classUri) then
                    return
                end
                classes[#classes+1] = def
            elseif def.type == 'doc.type.array'
            or     def.type == 'doc.type.table' then
                return
            end
        end
        if #classes == 0 then
            return
        end
        for _, class in ipairs(classes) do
            if hasUnknownAncestor(uri, class, {}) then
                return
            end
        end
        ---@type string[]
        local names = {}
        for _, class in ipairs(classes) do
            names[#names+1] = class.class[1]
        end
        local name = table.concat(names, '|')
        if vm.getClassIndexValue(uri, vm.compileNode(classes[1]), 'string') then
            return
        end

        for _, field in ipairs(src) do
            local keyNode = field.type == 'tablefield' and field.field
            if keyNode then
                local key = vm.getKeyName(field)
                if key and type(key) == 'string' then
                    ---@type boolean?
                    local declared
                    for _, class in ipairs(classes) do
                        if getDeclaredKeys(class)[key] then
                            declared = true
                            break
                        end
                    end
                    if not declared then
                        callback {
                            start   = keyNode.start,
                            finish  = keyNode.finish,
                            message = MESSAGE:format(key, name),
                        }
                    end
                end
            end
        end
    end)
end
