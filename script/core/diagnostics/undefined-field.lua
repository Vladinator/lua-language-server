local files           = require 'files'
local vm              = require 'vm'
local guide           = require 'parser.guide'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Undefined field `%s`.'

protoDiagnostic.register {
    'undefined-field',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for cases in which an undefined field of a variable is read, also through an index that chooses between literal names (`t[flag and "a" or "b"]`).',
}

-- (the types a value can have that are not a declared shape of fields)
local notAShape = {
    ['string']   = true,
    ['number']   = true,
    ['integer']  = true,
    ['boolean']  = true,
    ['table']    = true,
    ['function'] = true,
    ['thread']   = true,
    ['userdata'] = true,
    ['lightuserdata'] = true,
    ['any']      = true,
    ['unknown']  = true,
    ['nil']      = true,
    ['_G']       = true,
    ['_ENV']     = true,
}

local skipCheckClass = {
    ['unknown']       = true,
    ['any']           = true,
    ['table']         = true,
}

---@async
return function (uri, callback)
    local ast = files.getState(uri)
    if not ast then
        return
    end

    ---@async
    ---@param src parser.object
    local function checkUndefinedField(src)
        await.delay()

        if vm.hasDef(src) then
            return
        end
        local node = src.node
        if node then
            ---@type boolean?
            local ok
            for view in vm.getInfer(node):eachView(uri) do
                if skipCheckClass[view] then
                    return
                end
                ok = true
            end
            if not ok then
                return
            end
        end
        local key = guide.getKeyName(src)
        if key == nil then
            -- `x.` typed but not finished: there is no name to report yet
            return
        end
        local message = MESSAGE:format(key)
        if     src.type == 'getfield' and src.field then
            callback {
                start   = src.field.start,
                finish  = src.field.finish,
                message = message,
            }
        elseif src.type == 'getmethod' and src.method then
            callback {
                start   = src.method.start,
                finish  = src.method.finish,
                message = message,
            }
        end
    end
    ---@async
    ---@param src parser.object
    local function checkUndefinedFieldByIndexEnum(src)
        await.delay()
        local isEnum = false
        for _, node in ipairs(vm.compileNode(src.node)) do
            local docs = node.bindDocs
            if docs then
                for _, doc in ipairs(docs) do
                    if doc.type == "doc.enum" then
                        isEnum = true
                        break
                    end
                end
            end
        end
        if not isEnum then
            return
        end
        if vm.hasDef(src) then
            return
        end
        local keyName = guide.getKeyName(src)
        if not keyName then
            return
        end
        local message = MESSAGE:format(guide.getKeyName(src))
        local index = src.index
        if not index then
            return
        end
        callback {
            start   = index.start,
            finish  = index.finish,
            message = message,
        }
    end
    --- `t[flag and "a" or "b"]`, `t[key]` with `key: "a"|"b"`: every literal the index can be must be a field (`t["b"]` alone is
    --- left to the metatable, like it always was, but a choice between names is a promise that each of them exists).
    ---@async
    ---@param src parser.object
    local function checkUndefinedLiteralIndex(src)
        await.delay()
        local index = src.index
        local node = src.node
        if not index or not node or index.type == 'string' or guide.getKeyName(src) ~= nil then
            return
        end
        -- only a value that is declared as a class: the keys of a plain table (`local t = {}`, `_G`) are filled in as the program runs
        ---@type boolean?
        local declared
        for object in vm.compileNode(node):eachObject() do
            if object.type == 'global' and object.cate == 'type' then
                if notAShape[object.name] then
                    return
                end
                declared = true
            end
        end
        if not declared then
            return
        end
        ---@type table[]
        local literals = {}
        for k in vm.compileNode(index):eachObject() do
            if (k.type == 'string' or k.type == 'doc.type.string') and type(k[1]) == 'string' and k[1] ~= '' then
                literals[#literals+1] = k
            elseif k.type == 'global' and k.cate == 'type' and k.name == 'string' then
                return
            end
        end
        for _, literal in ipairs(literals) do
            local key = literal[1] --[[@as string]]
            local found = false
            vm.compileByParentNode(node, key, function ()
                found = true
            end)
            -- (a `table<string, V>`, or a class that inherits from one, answers any string key)
            if not found
            and not vm.getTableValue(uri, vm.compileNode(node), 'string')
            and not vm.getClassIndexValue(uri, vm.compileNode(node), 'string') then
                local inside = literal.start and literal.start >= index.start and literal.finish <= index.finish
                callback {
                    start   = inside and literal.start or index.start,
                    finish  = inside and literal.finish or index.finish,
                    message = MESSAGE:format(key),
                }
            end
        end
    end
    guide.eachSourceType(ast.ast, 'getfield',  checkUndefinedField)
    guide.eachSourceType(ast.ast, 'getmethod', checkUndefinedField)
    guide.eachSourceType(ast.ast, 'getindex', checkUndefinedFieldByIndexEnum)
    guide.eachSourceType(ast.ast, 'getindex', checkUndefinedLiteralIndex)
end
