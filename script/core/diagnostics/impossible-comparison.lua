local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

protoDiagnostic.register {
    'impossible-comparison',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for a comparison of a value declared as a union of string or number literals with a literal that is not one of them (`mode == "latestt"` with `mode: "queue"|"latest"`), or of a value declared as a string, number or boolean with a literal of another kind (`s == 5` with `s: string`; Lua does not coerce in `==`): the comparison is always false (always true for `~=`). TypeScript: "This comparison appears to be unintentional because the types have no overlap".',
}

--- Whether an alias type name (`---@alias`): its expansion sits next to it in a node.
---@param uri    uri
---@param global vm.global
---@return boolean
local function isAlias(uri, global)
    for _, set in ipairs(global:getSets(uri)) do
        if set.type == 'doc.alias' then
            return true
        end
    end
    return false
end

--- The declared literals of a value, when its type is NOTHING BUT a union of declared string / number literals (`---@alias Mode "queue"|"latest"`,
--- `---@type 1|2|3`; it may also be optional). Anything else says nothing here: an inferred value (`local x = "a"` is what the variable holds now, not
--- what it is), a primitive, a class, `any`, a boolean (narrowing splits `boolean` into `true` and `false`).
---@param uri  uri
---@param node vm.node
---@return (string|number)[]?
local function declaredLiterals(uri, node)
    ---@type (string|number)[]
    local literals = {}
    for _, c in ipairs(node) do
        if c.type == 'doc.type.string' or c.type == 'doc.type.integer' then
            literals[#literals+1] = c[1] --[[@as string|number]]
        elseif c.type == 'variable' or c.type == 'local' or (c.type == 'global' and c.cate ~= 'type') then
            -- (the variables a node came from: not types)
        elseif c.type == 'nil' then
            -- (an optional value: compared with nil it is the nil comparison's business)
        elseif c.type == 'global' and c.cate == 'type' then
            ---@cast c vm.global
            if c.name ~= 'nil' and not isAlias(uri, c) then
                return nil
            end
        else
            return nil
        end
    end
    if #literals == 0 then
        return nil
    end
    return literals
end

local PRIMITIVE_KIND = {
    ['string']  = 'string',
    ['number']  = 'number',
    ['integer'] = 'number',
    ['boolean'] = 'boolean',
}

--- The primitive kinds of a value that is DECLARED as nothing but string / number / boolean (a parameter `s: string`, a field, a result of a
--- function with `@return`), possibly optional. An inferred value (`local x = 5` is what the variable holds now), a literal union, an alias, a
--- class, `any` and the like say nothing here.
---@param node vm.node
---@return table<string, true>?
local function declaredPrimitives(node)
    ---@type table<string, true>
    local kinds = {}
    local found = false
    for _, c in ipairs(node) do
        if c.type == 'variable' or c.type == 'local' or (c.type == 'global' and c.cate ~= 'type') then
            -- (the variables a node came from: not types)
        elseif c.type == 'global' and c.cate == 'type' then
            if c.name ~= 'nil' then
                local kind = PRIMITIVE_KIND[c.name]
                if not kind then
                    return nil
                end
                kinds[kind] = true
                found = true
            end
        elseif c.type ~= 'nil' then
            return nil
        end
    end
    if not found then
        return nil
    end
    return kinds
end

---@param source parser.object
---@return string?
local function literalKind(source)
    if source.type == 'string' then
        return 'string'
    elseif source.type == 'integer' or source.type == 'number' then
        return 'number'
    elseif source.type == 'boolean' then
        return 'boolean'
    end
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    ---@async
    guide.eachSourceType(state.ast, 'binary', function (src)
        local op = src.op and src.op.type
        if op ~= '==' and op ~= '~=' then
            return
        end
        local left, right = src[1], src[2]
        if not left or not right then
            return
        end
        local litSide = literalKind(right) and right
                     or literalKind(left) and left
                     or nil
        if not litSide then
            return
        end
        local other = litSide == right and left or right
        if literalKind(other) then
            -- (two literals: a constant, not a typo)
            return
        end
        delayer:delay()
        if other.type == 'getlocal' and other.node and vm.isUnknown(vm.compileNode(other.node)) then
            -- (a variable that says nothing itself, such as the key of `pairs` over a record with named fields: an earlier `k == "name"` narrows it
            -- to `string` here, which is not a declaration)
            return
        end
        local otherNode = vm.compileNode(other)
        local literals = declaredLiterals(uri, otherNode)
        if not literals then
            -- (a string / number / boolean declared as such: a literal of another kind is never equal to it; Lua does not coerce in `==`)
            local kinds = declaredPrimitives(otherNode)
            local kind = literalKind(litSide)
            if kinds and kind and not kinds[kind] then
                callback {
                    start   = src.start,
                    finish  = src.finish,
                    message = ('This comparison is always %s: the value is `%s`, never %s.'):format(
                        op == '==' and 'false' or 'true',
                        vm.getInfer(otherNode):view(uri),
                        litSide.type == 'string' and ('"%s"'):format(litSide[1]) or tostring(litSide[1])
                    ),
                }
            end
            return
        end
        if litSide.type == 'boolean' then
            return
        end
        local wanted = litSide[1]
        if wanted == 'cdata' or wanted == 'ctype' then
            -- (what `type()` answers for a LuaJIT FFI value: no Lua 5.x runtime has them in its type names)
            return
        end
        for _, literal in ipairs(literals) do
            if literal == wanted then
                return
            end
        end
        callback {
            start   = src.start,
            finish  = src.finish,
            message = ('This comparison is always %s: the value is `%s`, never `%s`.'):format(
                op == '==' and 'false' or 'true',
                vm.getInfer(otherNode):view(uri),
                litSide.type == 'string' and ('"%s"'):format(wanted) or tostring(wanted)
            ),
        }
    end)
end
