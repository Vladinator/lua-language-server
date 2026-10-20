local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

protoDiagnostic.register {
    'index-key-mismatch',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for indexing a table whose key type is declared (`table<number, V>`, `V[]`, `{ [K]: V }`) with a key of an incompatible type (`t[flag]` with `flag: boolean`).',
}

--- Whether a key type still holds a generic parameter nobody bound (the `K` of the builtin `table<K, V>` class that every table type
--- also is): it is not a declaration of this table, the one with the real key comes with it.
---@param node vm.node
---@return boolean
local function hasGeneric(node)
    for obj in node:eachObject() do
        if obj.type == 'doc.generic.name' or obj.type == 'generic' then
            return true
        end
    end
    return false
end

--- The key types the table types of the receiver declare, or nil when some part of the receiver says nothing about its keys (a class,
--- `any`, no declaration at all): then nothing is reported. The variable, the local, the `table<K, V>` sign and the table literal the
--- node also holds are the same value seen from other sides.
---@param uri   uri
---@param tnode vm.node
---@return vm.node?
local function declaredKeys(uri, tnode)
    local keys = vm.createNode()
    local count = 0
    for tn in tnode:eachObject() do
        if tn.type == 'doc.type.table' then
            for _, field in ipairs(tn.fields) do
                if field.name.type == 'doc.field.name' then
                    -- (a named field of an inline type: `undefined-field` says what is wrong with a stray key)
                    return nil
                end
                local keyNode = vm.compileNode(field.name)
                if not hasGeneric(keyNode) then
                    keys:merge(keyNode)
                    count = count + 1
                end
            end
        elseif tn.type == 'doc.type.sign' then
            -- (read from the sign itself: of a union of two `table<K, V>` only one is expanded into a table object)
            if tn.node and tn.node[1] == 'table' and tn.signs and tn.signs[1] then
                local keyNode = vm.compileNode(tn.signs[1])
                if not hasGeneric(keyNode) then
                    keys:merge(keyNode)
                    count = count + 1
                end
            end
        elseif tn.type == 'doc.type.array' then
            keys:merge(vm.declareGlobal('type', 'integer'))
            count = count + 1
        elseif tn.type == 'global' and tn.cate == 'type' then
            ---@cast tn vm.global
            local isAlias = false
            for _, set in ipairs(tn:getSets(uri)) do
                if set.type == 'doc.alias' then
                    isAlias = true
                end
            end
            if not isAlias then
                -- (a class, `table`, `any`, ...: it says nothing about the keys, or not only that)
                return nil
            end
        elseif tn.type ~= 'variable'
        and    tn.type ~= 'local'
        and    tn.type ~= 'table' then
            return nil
        end
    end
    if count == 0 then
        return nil
    end
    if keys:hasName('integer') then
        -- (a float with an integer value is the same key: `t[i / 2]`)
        keys:merge(vm.declareGlobal('type', 'number'))
    end
    return keys
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    ---@async
    guide.eachSourceTypes(state.ast, { 'getindex', 'setindex' }, function (src)
        local index = src.index
        if not index or not src.node then
            return
        end
        delayer:delay()
        local keys = declaredKeys(uri, vm.compileNode(src.node))
        if not keys then
            return
        end
        local given = vm.compileNode(index)
        if given:hasNil() and src.type == 'getindex' then
            -- (`nil-index` says that one)
            return
        end
        local errs = {}
        if vm.canCastType(uri, keys, given, errs) then
            return
        end
        callback {
            start   = index.start,
            finish  = index.finish,
            message = ('Cannot use `%s` as a key of a table indexed by `%s`.'):format(
                vm.getInfer(given):view(uri),
                vm.getInfer(keys):view(uri)
            ) .. '\n' .. vm.viewTypeErrorMessage(uri, errs),
        }
    end)
end
