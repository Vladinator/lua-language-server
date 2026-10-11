---@class vm
local vm    = require 'vm.vm'
local guide = require 'parser.guide'
local util  = require 'utility'
local files = require 'files'
local scope = require 'workspace.scope'

---@class parser.object
---@field package _varargFunction?      boolean
---@field package _onlyOverloadFunction? boolean

---@param arg parser.object
---@return parser.object?
local function getDocParam(arg)
    ---@type parser.object[]?
    local bindDocs = arg.bindDocs
    if not bindDocs then
        return nil
    end
    for _, doc in ipairs(bindDocs) do
        if doc.type == 'doc.param'
        and doc.param[1] == arg[1] then
            return doc
        end
    end
    return nil
end

---@param func parser.object
---@return integer min
---@return number  max
---@return integer def
function vm.countParamsOfFunction(func)
    local min = 0
    local max = 0
    local def = 0
    if func.type == 'function' then
        if func.args then
            max = #func.args
            def = max
            for i = #func.args, 1, -1 do
                local arg = func.args[i]
                if arg.type == '...' then
                    max = math.huge
                elseif arg.type == 'self'
                and    i == 1 then
                    min = i
                    break
                elseif getDocParam(arg)
                and    not vm.compileNode(arg):isNullable() then
                    min = i
                    break
                end
            end
        end
    end
    if func.type == 'doc.type.function' then
        if func.args then
            max = #func.args
            def = max
            for i = #func.args, 1, -1 do
                local arg = func.args[i]
                if arg.name and arg.name[1] =='...' then
                    max = math.huge
                elseif not vm.compileNode(arg):isNullable() then
                    min = i
                    break
                end
            end
        end
    end
    return min, max, def
end

---@param source parser.object
---@return integer min
---@return number  max
---@return integer def
function vm.countParamsOfSource(source)
    local min = 0
    local max = 0
    local def = 0
    ---@type table<parser.object, boolean>
    local overloads = {}
    ---@type parser.object[]?
    local bindDocs = source.bindDocs
    if bindDocs then
        for _, doc in ipairs(bindDocs) do
            if doc.type == 'doc.overload' then
                overloads[doc.overload] = true
            end
        end
    end
    ---@type boolean?
    local hasDocFunction
    for nd in vm.compileNode(source):eachObject() do
        if nd.type == 'doc.type.function' and not overloads[nd] then
            hasDocFunction = true
            ---@cast nd parser.object
            local dmin, dmax, ddef = vm.countParamsOfFunction(nd)
            if dmin > min then
                min = dmin
            end
            if dmax > max then
                max = dmax
            end
            if ddef > def then
                def = ddef
            end
        end
    end
    if not hasDocFunction then
        local dmin, dmax, ddef = vm.countParamsOfFunction(source)
        if dmin > min then
            min = dmin
        end
        if dmax > max then
            max = dmax
        end
        if ddef > def then
            def = ddef
        end
    end
    return min, max, def
end

--- A cheap, structural shortcut for `vm.countParamsOfNode(vm.compileNode(calleeNode))`'s most
--- common case: a callee that is a single local/global with exactly one set, a plain `function`
--- value, and no doc comments anywhere (no `---@overload`, no `---@param` widening, no generics).
--- Its parameter count is then exactly what's written in its own argument list --
--- `vm.countParamsOfFunction`'s no-doc branch already answers that without ever calling
--- `vm.compileNode` (it only does for a documented param, to check nullability) -- so this skips
--- the callee's full, general type resolution (return types, unions, generic instantiation, all
--- irrelevant to a param count) for a shape common enough to matter: in this fork's own `script/`,
--- a large fraction of `vm.compileNode(call.node)`'s cost on a call-heavy file comes from the
--- engine's cyclic-compile bookkeeping (`taintedBy`/second-pass recompute) on plain, mutually
--- recursive local/global function declarations -- exactly this shape.
---@param calleeNode parser.object  the callee expression of a call (`call.node`)
---@return integer? min
---@return number?  max
---@return integer? def
function vm.tryCheapCountParams(calleeNode)
    if calleeNode.type ~= 'getlocal' and calleeNode.type ~= 'getglobal' then
        return nil
    end
    local sets = vm.getVariableSets(calleeNode)
    if not sets or #sets ~= 1 then
        return nil
    end
    local set = sets[1]
    if set.bindDocs then
        return nil
    end
    local value = set.value
    if not value or value.type ~= 'function' or value.bindDocs then
        return nil
    end
    return vm.countParamsOfFunction(value)
end

---@param node vm.node
---@return integer min
---@return number  max
---@return integer def
function vm.countParamsOfNode(node)
    ---@type integer?, number?, integer?
    local min, max, def
    for n in node:eachObject() do
        if n.type == 'function'
        or n.type == 'doc.type.function' then
            ---@cast n parser.object
            local fmin, fmax, fdef = vm.countParamsOfFunction(n)
            if not min or fmin < min then
                min = fmin
            end
            if not max or fmax > max then
                max = fmax
            end
            if not def or fdef > def then
                def = fdef
            end
        end
    end
    return min or 0, max or math.huge, def or 0
end

---@param func parser.object
---@param onlyDoc? boolean
---@param mark? table<parser.object, boolean>
---@return integer min
---@return number  max
---@return integer def
function vm.countReturnsOfFunction(func, onlyDoc, mark)
    if func.type == 'function' then
        ---@type integer?, number?, integer?
        local min, max, def
        ---@type boolean?
        local hasDocReturn
        if func.bindDocs then
            ---@type parser.object?
            local lastReturn
            ---@type integer
            local n = 0
            ---@type integer?, number?, integer?
            local dmin, dmax, ddef
            for _, doc in ipairs(func.bindDocs) do
                if doc.type == 'doc.return' then
                    hasDocReturn = true
                    for _, ret in ipairs(doc.returns) do
                        n = n + 1
                        lastReturn = ret
                        dmax = n
                        ddef = n
                        if  (not ret.name or ret.name[1] ~= '...')
                        and not vm.compileNode(ret):isNullable() then
                            dmin = n
                        end
                    end
                end
            end
            if lastReturn then
                if lastReturn.name and lastReturn.name[1] == '...' then
                    dmax = math.huge
                end
            end
            if dmin and (not min or (dmin < min)) then
                min = dmin
            end
            if dmax and (not max or (dmax > max)) then
                max = dmax
            end
            if ddef and (not def or (ddef > def)) then
                def = ddef
            end
        end
        if not onlyDoc and not hasDocReturn and func.returns then
            for _, ret in ipairs(func.returns) do
                local dmin, dmax, ddef = vm.countList(ret, mark)
                if not min or dmin < min then
                    min = dmin
                end
                if not max or dmax > max then
                    max = dmax
                end
                if not def or ddef > def then
                    def = ddef
                end
            end
        end
        return min or 0, max or math.huge, def or 0
    end
    if func.type == 'doc.type.function' then
        return vm.countList(func.returns)
    end
    error('not a function')
end

---@param source parser.object
---@return integer min
---@return number  max
---@return integer def
function vm.countReturnsOfSource(source)
    ---@type table<parser.object, boolean>
    local overloads = {}
    ---@type boolean?
    local hasDocFunction
    ---@type integer?, number?, integer?
    local min, max, def
    ---@type parser.object[]?
    local bindDocs = source.bindDocs
    if bindDocs then
        for _, doc in ipairs(bindDocs) do
            if doc.type == 'doc.overload' then
                overloads[doc.overload] = true
                local dmin, dmax, ddef = vm.countReturnsOfFunction(doc.overload)
                if not min or dmin < min then
                    min = dmin
                end
                if not max or dmax > max then
                    max = dmax
                end
                if not def or ddef > def then
                    def = ddef
                end
            end
        end
    end
    for nd in vm.compileNode(source):eachObject() do
        if nd.type == 'doc.type.function' and not overloads[nd] then
            ---@cast nd parser.object
            hasDocFunction = true
            local dmin, dmax, ddef = vm.countReturnsOfFunction(nd)
            if not min or dmin < min then
                min = dmin
            end
            if not max or dmax > max then
                max = dmax
            end
            if not def or ddef > def then
                def = ddef
            end
        end
    end
    if not hasDocFunction then
        local dmin, dmax, ddef = vm.countReturnsOfFunction(source, true)
        if not min or dmin < min then
            min = dmin
        end
        if not max or dmax > max then
            max = dmax
        end
        if not def or ddef > def then
            def = ddef
        end
    end
    -- every path above that can finish the function also sets min/max/def
    return min --[[@as integer]], max --[[@as number]], def --[[@as integer]]
end

---@param func parser.object
---@param args parser.object[]?
---@param mark? table<parser.object, boolean>
---@return integer min
---@return number  max
---@return integer def
function vm.countReturnsOfCall(func, args, mark)
    local funcs = vm.getMatchedFunctions(func, args, mark)
    if not funcs then
        return 0, math.huge, 0
    end
    ---@type integer?, number?, integer?
    local min, max, def
    for _, f in ipairs(funcs) do
        local rmin, rmax, rdef = vm.countReturnsOfFunction(f, false, mark)
        if not min or rmin < min then
            min = rmin
        end
        if not max or rmax > max then
            max = rmax
        end
        if not def or rdef > def then
            def = rdef
        end
    end
    return min or 0, max or math.huge, def or 0
end

---@param list parser.object[]?
---@param mark? table<parser.object, boolean>
---@return integer min
---@return number  max
---@return integer def
function vm.countList(list, mark)
    if not list then
        return 0, 0, 0
    end
    local lastArg = list[#list]
    if not lastArg then
        return 0, 0, 0
    end
    ---@type integer, number, integer
    local min, max, def = #list, #list, #list
    if lastArg.type == '...'
    or lastArg.type == 'varargs'
    or (lastArg.type == 'doc.type' and lastArg.name and lastArg.name[1] == '...') then
        max = math.huge
    elseif lastArg.type == 'call' then
        if not mark then
            mark = {}
        end
        if mark[lastArg] then
            min = min - 1
            max = math.huge
        else
            mark[lastArg] = true
            local rmin, rmax, rdef = vm.countReturnsOfCall(lastArg.node, lastArg.args, mark)
            return min - 1 + rmin, max - 1 + rmax, def - 1 + rdef
        end
    end
    for i = min, 1, -1 do
        local arg = list[i]
        if  arg.type == 'doc.type'
        and ((arg.name and arg.name[1] == '...')
            or vm.compileNode(arg):isNullable()) then
            min = i - 1
        else
            break
        end
    end
    return min, max, def
end

---@param uri uri
---@param args parser.object[]
---@param params parser.object[]?
---@return boolean
local function isAllParamMatched(uri, args, params)
    if not params then
        return false
    end
    for i = 1, #args do
        if not params[i] then
            break
        end
        local argNode = vm.compileNode(args[i])
        local defNode = vm.compileNode(params[i])
        -- a parameter declared as exactly `nil` (`---@overload fun(a: T, b: nil)`) takes only a nil argument. canCastType
        -- lets anything into a `nil` slot (the leniency for `local x = nil`), which kept such an overload next to the
        -- signature that really matches and made its `T?` return win a union with the right one
        if vm.getInfer(defNode):viewIfUnknownOrNil(uri) == 'nil'
        and not (argNode:isNullable() or vm.isSubType(uri, argNode, 'nil')) then
            return false
        end
        if not vm.canCastType(uri, defNode, argNode) then
            return false
        end
    end
    return true
end

---@param uri uri
---@param args parser.object[]
---@param func parser.object
---@return number
local function calcFunctionMatchScore(uri, args, func)
    if vm.isVarargFunctionWithOverloads(func)
    or vm.isFunctionWithOnlyOverloads(func)
    or not isAllParamMatched(uri, args, func.args)
    then
        return -1
    end
    local matchScore = 0
    for i = 1, math.min(#args, #func.args) do
        local arg, param = args[i], func.args[i]
        local defLiterals, literalsCount = vm.getLiterals(param)
        if defLiterals then
            for n in vm.compileNode(arg):eachObject() do
                -- if param's literals map contains arg's literal, this is narrower than a subtype match
                if defLiterals[guide.getLiteral(n)] then
                    -- the more the literals defined in the param, the less bonus score will be added
                    -- this favors matching overload param with exact literal value, over alias/enum that has many literal values
                    matchScore = matchScore + 1/literalsCount
                    break
                end
            end
        end
    end
    return matchScore
end

---@param func parser.object
---@param args? parser.object[]
---@return parser.object[]?
function vm.getExactMatchedFunctions(func, args)
    local funcs = vm.getMatchedFunctions(func, args)
    if not args or not funcs then
        return funcs
    end
    if #funcs == 1 then
        return funcs
    end
    local uri = guide.getUri(func)
    ---@type number[]
    local matchScores = {}
    for i, n in ipairs(funcs) do
        matchScores[i] = calcFunctionMatchScore(uri, args, n)
    end

    local maxMatchScore = math.max(table.unpack(matchScores))
    if maxMatchScore == -1 then
        -- all should be removed
        return nil
    end

    local minMatchScore = math.min(table.unpack(matchScores))
    if minMatchScore == maxMatchScore then
        -- all should be kept
        return funcs
    end

    -- remove functions that have matchScore < maxMatchScore
    ---@type integer[]
    local needRemove = {}
    for i, matchScore in ipairs(matchScores) do
        if matchScore < maxMatchScore then
            needRemove[#needRemove + 1] = i
        end
    end
    util.tableMultiRemove(funcs, needRemove)
    return funcs
end

---@param func parser.object
---@param args? parser.object[]
---@param mark? table<parser.object, boolean>
---@return parser.object[]?
function vm.getMatchedFunctions(func, args, mark)
    ---@type parser.object[]
    local funcs = {}
    local node = vm.compileNode(func)
    for n in node:eachObject() do
        if n.type == 'function'
        or n.type == 'doc.type.function' then
            ---@cast n parser.object
            funcs[#funcs+1] = n
        end
    end

    local amin, amax = vm.countList(args, mark)

    ---@type parser.object[]
    local matched = {}
    for _, n in ipairs(funcs) do
        local min, max = vm.countParamsOfFunction(n)
        if amin >= min and amax <= max then
            matched[#matched+1] = n
        end
    end

    if #matched == 0 then
        return nil
    else
        return matched
    end
end

---@param func parser.object
---@return boolean
function vm.isVarargFunctionWithOverloads(func)
    if func.type ~= 'function' then
        return false
    end
    if not func.args then
        return false
    end
    if func._varargFunction ~= nil then
        return func._varargFunction
    end
    if func.args[1] and func.args[1].type == 'self' then
        if not func.args[2] or func.args[2].type ~= '...' then
            func._varargFunction = false
            return false
        end
    else
        if not func.args[1] or func.args[1].type ~= '...' then
            func._varargFunction = false
            return false
        end
    end
    if not func.bindDocs then
        func._varargFunction = false
        return false
    end
    for _, doc in ipairs(func.bindDocs) do
        if doc.type == 'doc.overload' then
            func._varargFunction = true
            return true
        end
    end
    func._varargFunction = false
    return false
end

---@param func parser.object
---@return boolean
function vm.isFunctionWithOnlyOverloads(func)
    if func.type ~= 'function' then
        return false
    end
    if func._onlyOverloadFunction ~= nil then
        return func._onlyOverloadFunction
    end

    if not func.bindDocs then
        func._onlyOverloadFunction = false
        return false
    end
    local hasOverload = false
    for _, doc in ipairs(func.bindDocs) do
        if doc.type == 'doc.overload' then
            hasOverload = true
        elseif doc.type == 'doc.param'
        or doc.type == 'doc.return'
        then
            -- has specified @param or @return, thus not only @overload
            func._onlyOverloadFunction = false
            return false
        end
    end
    func._onlyOverloadFunction = hasOverload
    return true
end

---@param func parser.object
---@return boolean
function vm.isEmptyFunction(func)
    if #func > 0 then
        return false
    end
    local startRow  = guide.rowColOf(func.start)
    local finishRow = guide.rowColOf(func.finish)
    return finishRow - startRow <= 1
end

--- `---@param ... params<F>` (wowlua-ls): the name of the type parameter `F`, for a function that has it.
---@param func parser.object
---@return string?
local function paramsProjectionOf(func)
    for _, doc in ipairs(func.bindDocs or {}) do
        if doc.type == 'doc.param' and doc.param and doc.param[1] == '...' and doc.extends then
            for _, unit in ipairs(doc.extends.types or {}) do
                if unit.type == 'doc.type.sign' and unit.node and unit.node[1] == 'params' and unit.signs and unit.signs[1] then
                    ---@type string?
                    local name
                    -- (`doc.generic.name`: a type parameter of the function; `doc.type.name`: a name the function does not declare, a
                    -- type parameter of the class it belongs to)
                    guide.eachSourceTypes(unit.signs[1], { 'doc.generic.name', 'doc.type.name' }, function (src)
                        name = name or src[1] --[[@as string]]
                    end)
                    if name then
                        return name
                    end
                end
            end
        end
    end
    return nil
end

--- Does any file of the workspace write `params<`? Almost none does: the three diagnostics that ask `vm.getParamsProjection` about every call
--- then skip all of it. Computed once per scope (dropped with the rest of `vm.getCache` when a file changes).
---@param suri uri
---@return boolean
local function workspaceUsesParamsProjection(suri)
    local cache = vm.getCache('paramsProjection.any') --[[@as table<string, boolean>]]
    local scopeName = scope.getScope(suri):getName()
    local found = cache[scopeName]
    if found == nil then
        found = false
        for other in files.eachFile(suri) do
            local text = files.getText(other)
            if text and text:find('params<', 1, true) then
                found = true
                break
            end
        end
        cache[scopeName] = found
    end
    return found
end

--- A call of a function whose `...` is `params<F>`: the arguments from the `...` on are the parameters of the function `F` was bound to by an
--- earlier argument (`call(spawn, "orc", 3)`). Returns that function and the position of the `...` in the parameters of the called one;
--- nil when the called function has no such `...`, `F` is not bound, or it can stand for several functions.
---@async
---@param uri  uri
---@param call parser.object
---@return parser.object? target the function `F` stands for (a `function` or a `doc.type.function`)
---@return integer?       varIndex the position of the `...` in the called function's own parameters
function vm.getParamsProjection(uri, call)
    local args = call.args
    if not args or not workspaceUsesParamsProjection(uri) then
        return nil
    end
    -- asked by three diagnostics for every call of the file: once is enough (dropped with the rest of `vm.getCache` when a file changes)
    local cache = vm.getCache('paramsProjection') --[[@as table<parser.object, {[1]: parser.object?, [2]: integer?}>]]
    local cached = cache[call]
    if cached then
        return cached[1], cached[2]
    end
    local target, varIndex = vm.findParamsProjection(uri, call)
    cache[call] = { target, varIndex }
    return target, varIndex
end

--- `F` as a type parameter of the CLASS the called method belongs to (`GenericRegistry<F>` with `---@param ... params<F>` on its `Call`):
--- what the receiver says it stands for (`---@type GenericRegistry<fun(name: string, count: number)>`), the same route `returns<F>` takes.
---@param uri  uri
---@param call parser.object
---@param func parser.object the method the call resolved to
---@param name string        the name of the type parameter
---@return vm.node?
local function boundByReceiver(uri, call, func, name)
    local callNode = call.node
    if not callNode or (callNode.type ~= 'getmethod' and callNode.type ~= 'getfield') or not callNode.node then
        return nil
    end
    for receiver in vm.compileNode(callNode.node):eachObject() do
        if receiver.type == 'doc.type.sign' or (receiver.type == 'global' and receiver.cate == 'type') then
            ---@cast receiver parser.object|vm.global
            local map = vm.getReceiverGenericMap(uri, receiver, func)
            if map and map[name] then
                return map[name]
            end
        end
    end
    return nil
end

---@async
---@param uri  uri
---@param call parser.object
---@return parser.object?
---@return integer?
function vm.findParamsProjection(uri, call)
    local args = call.args or {}
    local funcs = vm.getExactMatchedFunctions(call.node, args)
    if not funcs or #funcs ~= 1 or funcs[1].type ~= 'function' then
        return nil
    end
    local func = funcs[1]
    local name = paramsProjectionOf(func)
    if not name then
        return nil
    end
    -- bound by an earlier argument (a type parameter of the function), or by the receiver (a type parameter of the class)
    local sign = vm.getSign(func)
    local resolved = sign and sign:resolve(uri, args)
    local bound = resolved and resolved[name] or boundByReceiver(uri, call, func, name)
    if not bound then
        return nil
    end
    ---@type parser.object?
    local target
    for obj in bound:eachObject() do
        if obj.type == 'function' or obj.type == 'doc.type.function' then
            if target then
                return nil
            end
            ---@cast obj parser.object
            target = obj
        end
    end
    if not target then
        return nil
    end
    ---@type integer?
    local varIndex
    for i, param in ipairs(func.args or {}) do
        if param.type == '...' then
            varIndex = i
        end
    end
    if not varIndex then
        return nil
    end
    return target, varIndex
end
