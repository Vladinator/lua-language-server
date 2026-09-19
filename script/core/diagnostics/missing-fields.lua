local vm              = require 'vm'
local files           = require 'files'
local guide           = require 'parser.guide'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Missing required fields in type `%s`: %s'

--- The definitions of one class that a table constructor is checked against.
---@class missing-fields.defs
---@field [integer] parser.object
---@field isPartial? boolean

protoDiagnostic.register {
    'missing-fields',
} {
    group    = 'unbalanced',
    severity = 'Warning',
    status   = 'Any',
}

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

        vm.removeNode(src) -- the node is not updated correctly, reason still unknown
        local defs = vm.getDefs(src)
        ---@type table<string, missing-fields.defs>
        local sortedDefs = {}
        for _, def in ipairs(defs) do
            if def.type == 'doc.class' then
                -- `---@class (incremental) X`: objects of X are built field by
                -- field, so a table constructor is never expected to be complete
                if vm.docHasAttr(def, 'incremental') then
                    return
                end
                if def.bindSource and guide.isInRange(def.bindSource, src.start) then
                    return
                end
                local className = def.class[1] --[[@as string]]
                if not sortedDefs[className] then
                    sortedDefs[className] = {}
                    -- check if this class is a `partial` class
                    -- a partial class will not check missing inherited fields
                    local class = vm.getGlobal('type', className)
                    ---@cast class -nil
                    for _, set in ipairs(class:getSets(uri)) do
                        if  set.type == 'doc.class'
                        and vm.docHasAttr(set, 'partial')
                        then
                            sortedDefs[className].isPartial = true
                            break
                        end
                    end
                end
                local samedefs = sortedDefs[className]
                samedefs[#samedefs+1] = def
            end
            if def.type == 'doc.type.array'
            or def.type == 'doc.type.table' then
                return
            end
        end

        ---@type table<string|integer, boolean>?
        local myKeys
        ---@type string[]
        local warnings = {}
        for className, samedefs in pairs(sortedDefs) do
            ---@type string[]
            local missedKeys = {}
            for _, def in ipairs(samedefs --[[@as parser.object[] ]]) do
                local fields = samedefs.isPartial and def.fields or vm.getFields(def)
                if not fields or #fields == 0 then
                    goto continue
                end

                if not myKeys then
                    myKeys = {}
                    for _, field in ipairs(src) do
                        local key = vm.getKeyName(field) or field.tindex
                        if key then
                            myKeys[key] = true
                        end
                    end
                end

                for _, field in ipairs(fields) do
                    if  not field.optional
                    and field.type == "doc.field"
                    and not vm.compileNode(field):isNullable() then
                        local key = vm.getKeyName(field)
                        if not key then
                            local fieldnode = vm.compileNode(field.field)[1]
                            if fieldnode and fieldnode.type == 'doc.type.integer' then
                                ---@cast fieldnode parser.object
                                key = vm.getKeyName(fieldnode)
                            end
                        end

                        if key and not myKeys[key] then
                            if type(key) == "number" then
                                missedKeys[#missedKeys+1] = ('`[%s]`'):format(key)
                            else
                                missedKeys[#missedKeys+1] = ('`%s`'):format(key)
                            end
                        end
                    end
                end
                ::continue::

                if not samedefs.isPartial then
                    -- if not partial class, then all fields in this class have already been checked
                    -- because in the above uses `vm.getFields` to get all fields
                    break
                end
            end

            if #missedKeys == 0 then
                return
            end

            warnings[#warnings+1] = MESSAGE:format(className, table.concat(missedKeys, ', '))
        end

        if #warnings == 0 then
            return
        end
        callback {
            start   = src.start,
            finish  = src.finish,
            message = table.concat(warnings, '\n')
        }
    end)
end
