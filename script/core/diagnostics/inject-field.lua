local files           = require 'files'
local vm              = require 'vm'
local guide           = require 'parser.guide'
local await           = require 'await'
local hname           = require 'core.hover.name'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE           = 'Fields cannot be injected into the reference of `%s` for `%s`. %s'
local FIX_CLASS_MESSAGE = 'To do so, use `---@class` for `%s`.'
local FIX_TABLE_MESSAGE = 'To allow injection, add `%s` to the definition.'

protoDiagnostic.register {
    'inject-field',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Injecting a field into an object',
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
    local function checkInjectField(src)
        await.delay()

        local node = src.node
        if not node then
            return
        end
        ---@type boolean?
        local ok
        for view in vm.getInfer(node):eachView(uri) do
            if skipCheckClass[view] or vm.hasUndeclaredAncestry(uri, view) then
                return
            end
            ok = true
        end
        if not ok then
            return
        end
        -- a class that inherits from `table<string, V>` takes any string key
        if (src.type == 'setfield' or src.type == 'setindex') and vm.getClassIndexValue(uri, vm.compileNode(node), 'string') then
            return
        end

        -- a variable that a narrowing cut down to one member of a union (`if not x.specs then x.specs = {} end`: only the member without
        -- `specs` can be here) may still be declared with the field by another member of what the variable can hold: the code builds that member
        local keyName = guide.getKeyName(src)
        if src.type == 'setindex' and type(keyName) ~= 'string' then
            -- (`t[k] = v` with a key that is not a string literal: `index-key-mismatch` and the key type say what is wrong)
            return
        end
        if keyName and (src.type == 'setfield' or src.type == 'setindex') and node.type == 'getlocal' and node.node then
            ---@type boolean?
            local declared
            vm.compileByParentNode(node.node, keyName, function (def)
                if def.type == 'doc.field' or def.type == 'doc.type.field' then
                    declared = true
                end
            end)
            if declared then
                return
            end
        end

        ---@type boolean?
        local isExact
        local class = vm.getDefinedClass(uri, node)
        if class then
            for _, doc in ipairs(class:getSets(uri)) do
                if vm.docHasAttr(doc, 'exact') then
                    isExact = true
                    break
                end
            end
            if not isExact then
                return
            end
            if  src.type == 'setmethod'
            and not guide.getSelfNode(node) then
                return
            end
        end

        for _, def in ipairs(vm.getDefs(src)) do
            local dnode = def.node
            if dnode
            and not isExact
            and vm.getDefinedClass(uri, dnode) then
                return
            end
            if def.type == 'doc.type.field' then
                return
            end
            if def.type == 'doc.field' then
                return
            end
            if def.type == 'tablefield' and not isExact then
                return
            end
        end

        local howToFix = ''
        if not isExact then
            howToFix = FIX_CLASS_MESSAGE:format(hname(node))
            for _, ndef in ipairs(vm.getDefs(node)) do
                if ndef.type == 'doc.type.table' then
                    howToFix = FIX_TABLE_MESSAGE:format('[any]: any')
                    break
                end
            end
        end

        local message = MESSAGE:format(
            vm.getInfer(node):view(uri),
            guide.getKeyName(src),
            howToFix
        )
        if     src.type == 'setfield' and src.field then
            callback {
                start   = src.field.start,
                finish  = src.field.finish,
                message = message,
            }
        elseif src.type == 'setindex' and src.index then
            callback {
                start   = src.index.start,
                finish  = src.index.finish,
                message = message,
            }
        elseif src.type == 'setmethod' and src.method then
            callback {
                start   = src.method.start,
                finish  = src.method.finish,
                message = message,
            }
        end
    end
    guide.eachSourceType(ast.ast, 'setfield',  checkInjectField)
    guide.eachSourceType(ast.ast, 'setindex',  checkInjectField)
    guide.eachSourceType(ast.ast, 'setmethod', checkInjectField)

    ---@async
    ---@param src parser.object
    local function checkExtraTableField(src)
        await.delay()

        if not src.bindSource then
            return
        end
        if not vm.docHasAttr(src, 'exact') then
            return
        end
        local value = src.bindSource.value
        if not value or value.type ~= 'table' then
            return
        end
        for _, field in ipairs(value) do
            local defs = vm.getDefs(field)
            for _, def in ipairs(defs) do
                if def.type == 'doc.field' then
                    goto nextField
                end
            end
            local message = MESSAGE:format(
                vm.getInfer(src):view(uri),
                guide.getKeyName(field),
                ''
            )
            callback {
                start   = field.start,
                finish  = field.finish,
                message = message,
            }
            ::nextField::
        end
    end

    guide.eachSourceType(ast.ast, 'doc.class', checkExtraTableField)
end
