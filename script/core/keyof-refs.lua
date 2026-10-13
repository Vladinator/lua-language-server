local files = require 'files'
local vm    = require 'vm'
local guide = require 'parser.guide'

--- A string argument that names a field through a `keyof` parameter is a reference of that field:
--- `invoke(receiver, "Activate")` with `---@generic T, K: keyof T` / `---@param method K` refers to `receiver.Activate`
--- (and `obj:Do("Eat")` with `---@generic K: keyof self` to `obj.Eat`), as renaming `Activate` has to rename it too.

--- The nodes the `keyof` of the parameter at `index` ranges over for this call (the type of `T`, or the receiver for `keyof self`).
---@param uri   uri
---@param call  parser.object
---@param index integer
---@return vm.node[]
local function receiversOf(uri, call, index)
    ---@type vm.node[]
    local receivers = {}
    ---@type parser.object?
    local func
    for obj in vm.compileNode(call.node):eachObject() do
        if obj.type == 'function' then
            if func then
                return receivers
            end
            func = obj --[[@as parser.object]]
        end
    end
    local sign = func and vm.getSign(func)
    local param = func and func.args and func.args[index]
    if not func or not sign or not param then
        return receivers
    end
    ---@type parser.object?
    local typeDoc
    for _, doc in ipairs(func.bindDocs or {}) do
        if doc.type == 'doc.param' and doc.param and doc.param[1] == param[1] then
            typeDoc = doc.extends
            break
        end
    end
    if not typeDoc then
        return receivers
    end
    ---@type parser.object[]
    local keyofs = {}
    ---@param typeNode parser.object a `doc.type`
    ---@param depth    integer
    local function collect(typeNode, depth)
        if depth > 4 then
            return
        end
        for _, unit in ipairs(typeNode.types or {}) do
            if unit.type == 'doc.type.keyof' then
                keyofs[#keyofs+1] = unit
            elseif unit.type == 'doc.generic.name' then
                for _, genericDoc in ipairs(sign.docGeneric) do
                    for _, object in ipairs(genericDoc.generics) do
                        if object.generic and object.generic[1] == unit[1] and object.extends then
                            collect(object.extends, depth + 1)
                        end
                    end
                end
            end
        end
    end
    collect(typeDoc, 1)
    if #keyofs == 0 then
        return receivers
    end
    ---@type table<string, vm.node>?
    local resolved
    for _, keyof in ipairs(keyofs) do
        local name = keyof.node and keyof.node[1]
        if name == 'self' then
            if call.node.type == 'getmethod' and call.node.node then
                receivers[#receivers+1] = vm.compileNode(call.node.node)
            end
        elseif type(name) == 'string' then
            resolved = resolved or sign:resolve(uri, call.args or {})
            local bound = resolved and resolved[name]
            if bound then
                receivers[#receivers+1] = bound
            end
        end
    end
    return receivers
end

---@param args parser.object
---@param arg  parser.object
---@return integer?
local function indexIn(args, arg)
    for i, other in ipairs(args) do
        if other == arg then
            return i
        end
    end
    return nil
end

--- The string arguments that name, through a `keyof` parameter, one of the definitions of a field.
---@async
---@param suri  uri the project the search runs in
---@param key   string
---@param defs  parser.object[] the definitions of the field being searched
---@return parser.object[] the string literals
return function (suri, key, defs)
    ---@type parser.object[]
    local found = {}
    if #defs == 0 then
        return found
    end
    ---@type table<parser.object, true>
    local wanted = {}
    for _, def in ipairs(defs) do
        wanted[def] = true
    end
    local doubleQuoted = '"' .. key .. '"'
    local singleQuoted = "'" .. key .. "'"
    -- (the file itself first: a loose file is not part of any workspace)
    ---@type uri[]
    local uris = { suri }
    for _, other in ipairs(files.getAllUris(suri)) do
        if other ~= suri then
            uris[#uris+1] = other
        end
    end
    for _, uri in ipairs(uris) do
        local text = files.getText(uri)
        local state = text and (text:find(doubleQuoted, 1, true) or text:find(singleQuoted, 1, true)) and files.getState(uri)
        if state then
            guide.eachSourceType(state.ast, 'string', function (str)
                local args = str.parent
                local call = args and args.type == 'callargs' and args.parent
                if not args or str[1] ~= key or not call or call.type ~= 'call' or not call.node then
                    return
                end
                local index = indexIn(args, str)
                if not index then
                    return
                end
                for _, receiver in ipairs(receiversOf(uri, call, index)) do
                    local hit = false
                    for obj in receiver:eachObject() do
                        if obj.type == 'global' and obj.cate == 'type' then
                            ---@cast obj vm.global
                            vm.getClassFields(uri, obj, key, function (field)
                                if wanted[field --[[@as parser.object]]] then
                                    hit = true
                                end
                            end)
                        end
                    end
                    if hit then
                        found[#found+1] = str
                        return
                    end
                end
            end)
        end
    end
    return found
end
