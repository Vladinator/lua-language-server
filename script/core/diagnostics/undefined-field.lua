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
        local message = MESSAGE:format(guide.getKeyName(src))
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
    guide.eachSourceType(ast.ast, 'getfield',  checkUndefinedField)
    guide.eachSourceType(ast.ast, 'getmethod', checkUndefinedField)
    guide.eachSourceType(ast.ast, 'getindex', checkUndefinedFieldByIndexEnum)
end
