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
