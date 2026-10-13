local files      = require 'files'
local vm         = require 'vm'
local hoverLabel = require 'core.hover.label'
local hoverDesc  = require 'core.hover.description'
local guide      = require 'parser.guide'
local lookback   = require 'core.look-backward'

---@class core.signature.param
---@field label [integer, integer]

---@class core.signature.list
---@field [integer] core.signature.result
---@field active? integer the index of the signature the written arguments fit best

---@class core.signature.result
---@field source? parser.object the function this signature was made from
---@field label string
---@field params core.signature.param[]
---@field index integer
---@field description any

---@param uri uri
---@param ast parser.state
---@param pos integer
---@return parser.object?
local function findNearCall(uri, ast, pos)
    local text  = files.getText(uri)
    local state = files.getState(uri)
    if not state or not text then
        return nil
    end
    ---@type parser.object?
    local nearCall
    guide.eachSourceContain(ast.ast, pos, function (src)
        if src.type == 'call'
        or src.type == 'table'
        or src.type == 'function' then
            local finishOffset = guide.positionToOffset(state, src.finish)
            -- call(),$
            if  src.finish <= pos
            and text:sub(finishOffset, finishOffset) == ')' then
                return
            end
            -- {},$
            if  src.finish <= pos
            and text:sub(finishOffset, finishOffset) == '}' then
                return
            end
            if not nearCall or nearCall.start <= src.start then
                nearCall = src
            end
        end
    end)
    if not nearCall then
        return nil
    end
    if nearCall.type ~= 'call' then
        return nil
    end
    return nearCall
end

---@async
---@param source parser.object
---@param oop boolean
---@param index? integer
---@param emptyCall? boolean no argument is written
---@return core.signature.result?
local function makeOneSignature(source, oop, index, emptyCall)
    local label = hoverLabel(source, oop, 0)
    if not label then
        return nil
    end
    -- 去掉返回值
    label = label:gsub('%s*->.+', '')
    ---@type core.signature.param[]
    local params = {}
    local i = 0
    ---@type integer?, string?
    -- both captures come from the same match call: either both nil (no match) or both set
    local argStart, argLabel = label:match '()(%b())$'
    -- not a redundant cast: suppressing just the need-check-nil here still leaves `converted`'s
    -- whole `:sub()`/`:gsub()` chain inferring `unknown` (a genuine checker limitation resolving
    -- a method chain off a `string?`), confirmed by tools/audit_casts.py's own validate.py rerun
    local converted = (argLabel --[[@as string]])
        : sub(2, -2)
        : gsub('%b<>', function (str)
            return ('_'):rep(#str)
        end)
        : gsub('%b()', function (str)
            return ('_'):rep(#str)
        end)
        : gsub('%b{}', function (str)
            return ('_'):rep(#str)
        end)
        : gsub ('%b[]', function (str)
            return ('_'):rep(#str)
        end)
        : gsub('[%(%)]', '_')

    -- string.gmatch's stub doesn't distinguish position captures `()` from
    -- string captures, so start/finish infer as string; cast at each use below
    ---@diagnostic expect-next-line: no-unknown
    for start, finish in converted:gmatch '%s*()[^,]+()' do
        i = i + 1
        params[i] = {
            ---@diagnostic expect-next-line: need-check-nil
            label = {start + argStart - 1, finish - 1 + argStart},
        }
    end
    -- 不定参数
    if index and index > i and i > 0 then
        local lastLabel = params[i].label
        local text = label:sub(lastLabel[1] + 1, lastLabel[2])
        if text:sub(1, 3) == '...' then
            index = i --[[@as integer]]
        end
    end
    if #params < (index or 0) and not emptyCall then
        return nil
    end
    return {
        label       = label,
        params      = params,
        index       = index or 1,
        description = hoverDesc(source),
    }
end

---@param call parser.object
---@param src parser.object|vm.global
---@return boolean
local function isEventNotMatch(call, src)
    if not call.args or not src.args then
        return false
    end
    ---@type string|number|boolean|nil, integer?
    local literal, index
    for i = 1, #call.args do
        literal = guide.getLiteral(call.args[i])
        if literal then
            index = i --[[@as integer]]
            break
        end
    end
    if not literal then
        return false
    end
    local event = src.args[index --[[@as integer]]]
    if not event or event.type ~= 'doc.type.arg' then
        return false
    end
    if not event.extends
    or #event.extends.types ~= 1 then
        return false
    end
    local eventLiteral = event.extends.types[1] and guide.getLiteral(event.extends.types[1])
    if eventLiteral == nil then
        -- extra checking when function param is not pure literal
        -- eg: it maybe an alias type with literal values
        local eventMap = vm.getLiterals(event.extends.types[1])
        if not eventMap then
            return false
        end
        return not eventMap[literal]
    end
    return eventLiteral ~= literal
end

---@async
---@param text string
---@param call parser.object
---@param pos integer
---@return core.signature.list
local function makeSignatures(text, call, pos)
    local func = call.node
    local oop = func.type == 'method'
             or func.type == 'getmethod'
             or func.type == 'setmethod'
    ---@type integer?
    local index
    -- (no argument written yet, the receiver of a colon call aside: a function without parameters has a signature to show too)
    local emptyCall = not call.args
    if call.args then
        ---@type parser.object[]
        local args = {}
        for _, arg in ipairs(call.args) do
            if arg.type ~= 'self' then
                args[#args+1] = arg
            end
        end
        local uri   = guide.getUri(call)
        local state = files.getState(uri)
        if state then
            for i, arg in ipairs(args) do
                local startOffset = guide.positionToOffset(state, arg.start)
                startOffset =  lookback.findTargetSymbol(text, startOffset, '(')
                            or lookback.findTargetSymbol(text, startOffset, ',')
                            or startOffset
                local startPos = guide.offsetToPosition(state, startOffset)
                if startPos > pos then
                    index = i - 1
                    break
                end
                if pos <= arg.finish then
                    index = i
                    break
                end
            end
            if not index then
                local offset     = guide.positionToOffset(state, pos)
                local backSymbol = lookback.findSymbol(text, offset)
                emptyCall = #args == 0
                if backSymbol == ','
                or backSymbol == '(' then
                    index = #args + 1
                else
                    index = #args
                end
            end
        end
    end
    ---@type core.signature.list
    local signs = {}
    local node = vm.compileNode(func)
    ---@type vm.node
    node = node.originNode or node
    ---@type table<parser.object, boolean>
    local mark = {}
    for src in node:eachObject() do
        if src.type == 'function' or src.type == 'doc.type.function' then
            if src.type == 'doc.type.function' or not vm.isVarargFunctionWithOverloads(src) then
                if  not mark[src]
                and not isEventNotMatch(call, src) then
                    mark[src] = true
                    local sign = makeOneSignature(src, oop, index, emptyCall)
                    if sign then
                        sign.source = src
                        signs[#signs+1] = sign
                    end
                end
            end
        elseif src.type == 'global' and src.cate == 'type' then
            for _, set in ipairs(src:getSets(guide.getUri(call))) do
                if set.type == 'doc.class' then
                    for _, overload in ipairs(set.calls) do
                        local f = overload.overload
                        if  not mark[f]
                        and not isEventNotMatch(call, src) then
                            mark[f] = true
                            signs[#signs+1] = makeOneSignature(f, oop, index, emptyCall)
                        end
                    end
                end
            end
        end
    end
    return signs
end

---@async
---@param uri uri
---@param pos integer
---@return core.signature.list?
return function (uri, pos)
    local state = files.getState(uri)
    local text  = files.getText(uri)
    if not state or not text then
        return nil
    end
    local offset = guide.positionToOffset(state, pos)
    pos = guide.offsetToPosition(state, lookback.skipSpace(text, offset))
    local call = findNearCall(uri, state, pos)
    if not call then
        return nil
    end
    local signs = makeSignatures(text, call, pos)
    if not signs or #signs == 0 then
        return nil
    end
    table.sort(signs, function (a, b)
        return #a.params < #b.params
    end)
    -- the overload the arguments written so far fit best is the active one (the client would take the first)
    local matched = call.node and vm.getExactMatchedFunctions(call.node, call.args or {})
    if matched and #matched > 0 then
        ---@type table<parser.object, true>
        local fits = {}
        for _, f in ipairs(matched) do
            fits[f] = true
        end
        for i, sign in ipairs(signs) do
            if sign.source and fits[sign.source] then
                signs.active = i
                break
            end
        end
    end
    return signs
end
