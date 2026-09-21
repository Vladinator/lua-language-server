---@class vm
local vm        = require 'vm.vm'
local guide     = require 'parser.guide'
local util      = require 'utility'

---@class parser.object
---@field package _tracer? vm.tracer
---@field package _casts?  parser.object[]

---@alias tracer.mode 'local' | 'global'

vm.registerCallNarrowing {
    match = function (calleeNode)
        return calleeNode.special == 'assert'
    end,
    narrow = function (tracer, action, topNode, outNode)
        if not action.args or not action.args[1] then
            return topNode, outNode
        end
        for i = 2, #action.args do
            tracer:lookIntoChild(action.args[i], topNode, topNode:copy())
        end
        topNode = tracer:lookIntoChild(action.args[1], topNode:copy(), topNode:copy())
        return topNode, outNode
    end,
}

---@class vm.tracer
---@field mode      tracer.mode
---@field name      string
---@field source    parser.object | vm.variable
---@field assigns   (parser.object | vm.variable)[]
---@field assignMap table<parser.object|vm.variable, true>
---@field getMap    table<parser.object, true>
---@field careMap   table<parser.object, true>
---@field mark      table<parser.object, true>
---@field casts     parser.object[]
---@field nodes     table<parser.object, vm.node|false>
---@field trackBreaks table<parser.object, true>   loops with a constant true condition, left only by their `break`s
---@field breakNodes  table<parser.object, vm.node[]>  the node the variable has at each `break` reached so far
---@field main      parser.object
---@field uri       uri
---@field castIndex integer?
---@field walkFrame? vm.compileFrame  set while a walk of this tracer is running (vm.beginWalk)
---@field fieldFallbackDone? boolean
local mt = {}
mt.__index = mt
mt.fastCalc    = true

---@return parser.object[]
function mt:getCasts()
    local root = guide.getRoot(self.main)
    if not root._casts then
        ---@type parser.object[]
        local casts = {}
        root._casts = casts
        local docs = root.docs
        for _, doc in ipairs(docs) do
            if doc.type == 'doc.cast' and doc.name then
                casts[#casts+1] = doc
            end
        end
    end
    return root._casts
end

---@param obj parser.object
function mt:collectAssign(obj)
    while true do
        local block = guide.getParentBlock(obj)
        if not block then
            return
        end
        obj = block
        if self.assignMap[obj] then
            return
        end
        if obj == self.main then
            return
        end
        self.assignMap[obj] = true
        self.assigns[#self.assigns+1] = obj
    end
end

--- A loop condition that is always true: the loop is left by its `break`s, or never.
---@param filter parser.object?
---@return boolean
local function isConstantTrue(filter)
    if not filter then
        return false
    end
    if filter.type == 'boolean' then
        return filter[1] == true
    end
    return filter.type == 'integer'
        or filter.type == 'number'
        or filter.type == 'string'
end

---@param obj parser.object
function mt:collectCare(obj)
    while true do
        if self.careMap[obj] then
            return
        end
        if obj == self.main then
            return
        end
        if not obj then
            return
        end
        self.careMap[obj] = true

        -- what the variable is after `while true do ... end` is what it is at the `break`s, so
        -- the walks have to go through them
        if obj.type == 'while' and obj.breaks then
            self.trackBreaks[obj] = true
            for _, brk in ipairs(obj.breaks) do
                self:collectCare(brk)
            end
        end

        if self.fastCalc then
            if obj.type == 'if'
            or obj.type == 'while'
            or obj.type == 'binary' then
                self.fastCalc = false
            end
            if obj.type == 'call' and obj.node then
                if obj.node.special == 'assert'
                or obj.node.special == 'type'
                or vm.matchCallNarrowing(obj.node) then
                    self.fastCalc = false
                end
            end
        end

        obj = obj.parent
    end
end

function mt:collectLocal()
    local startPos  = self.source.base.start
    local finishPos = 0

    local variable = self.source

    if  variable.base.type ~= 'local'
    and variable.base.type ~= 'self' then
        self.assigns[#self.assigns+1] = variable
        self.assignMap[self.source] = true
    end

    ---@type parser.object[]
    local sets = variable.sets
    for _, set in ipairs(sets) do
        self.assigns[#self.assigns+1] = set
        self.assignMap[set] = true
        self:collectCare(set)
        if set.finish > finishPos then
            finishPos = set.finish
        end
    end

    ---@type parser.object[]
    local gets = variable.gets
    for _, get in ipairs(gets) do
        self:collectCare(get)
        self.getMap[get] = true
        if get.finish > finishPos then
            finishPos = get.finish
        end
    end

    ---@type parser.object[]
    local casts = self:getCasts()
    for _, cast in ipairs(casts) do
        if  cast.name[1] == self.name
        and cast.start  > startPos
        and cast.finish < finishPos
        and vm.getCastTargetHead(cast) == variable.base then
            self.casts[#self.casts+1] = cast
        end
    end

    if #self.casts > 0 then
        self.fastCalc = false
    end
end

function mt:collectGlobal()
    self.assigns[#self.assigns+1] = self.source
    self.assignMap[self.source] = true

    local uri    = guide.getUri(self.source)
    local globalVar = self.source['global']
    local link   = globalVar.links[uri]

    for _, set in ipairs(link.sets) do
        self.assigns[#self.assigns+1] = set
        self.assignMap[set] = true
        self:collectCare(set)
    end

    for _, get in ipairs(link.gets) do
        self:collectCare(get)
        self.getMap[get] = true
    end

    ---@type parser.object[]
    local casts = self:getCasts()
    for _, cast in ipairs(casts) do
        if cast.name[1] == self.name then
            local castTarget = vm.getCastTargetHead(cast)
            if castTarget and castTarget.type == 'global' then
                self.casts[#self.casts+1] = cast
            end
        end
    end

    if #self.casts > 0 then
        self.fastCalc = false
    end
end

---@param start  integer
---@param finish integer
---@return parser.object?
function mt:getLastAssign(start, finish)
    ---@type parser.object?
    local lastAssign
    for _, assign in ipairs(self.assigns) do
        ---@type parser.object
        local obj
        if assign.type == 'variable' then
            ---@cast assign vm.variable
            obj = assign.base
        else
            ---@cast assign parser.object
            obj = assign
        end
        if obj.start < start then
            goto CONTINUE
        end
        if (obj.effect or obj.range or obj.start) >= finish then
            break
        end
        local objBlock = guide.getTopBlock(obj)
        if not objBlock then
            break
        end
        if  objBlock.start  <= finish
        and objBlock.finish >= finish then
            lastAssign = obj
        end
        ::CONTINUE::
    end
    return lastAssign
end

---@param pos integer
function mt:resetCastsIndex(pos)
    for i = 1, #self.casts do
        local cast = self.casts[i]
        if cast.start > pos then
            self.castIndex = i
            return
        end
    end
    self.castIndex = nil
end

---@param pos integer
---@param node vm.node
---@return vm.node
function mt:fastWardCasts(pos, node)
    if not self.castIndex then
        return node
    end
    local castIndex = self.castIndex
    for i = castIndex, #self.casts do
        local action = self.casts[i]
        if action.start > pos then
            return node
        end
        node = node:copy()
        for _, cast in ipairs(action.casts) do
            if     cast.mode == '+' then
                if cast.optional then
                    node:addOptional()
                end
                if cast.extends then
                    node:merge(vm.compileNode(cast.extends))
                end
            elseif cast.mode == '-' then
                if cast.optional then
                    node:removeOptional()
                end
                if cast.extends then
                    node:removeNode(vm.compileNode(cast.extends))
                end
            else
                if cast.extends then
                    node:clear()
                    node:merge(vm.compileNode(cast.extends))
                end
            end
        end
    end
    self.castIndex = castIndex + 1
    return node
end

--- How a type says its field `fieldName` relates to `literal`, for the discriminated unions
--- (`{ kind: 'circle', r: number } | { kind: 'square', side: number }`, or classes with a
--- `---@field kind 'circle'`):
---   'match'  the field is declared with exactly that literal
---   'union'  ... with that literal among others (`'a' | 'b'`): the type stays where the literal is one of them
---   'other'  ... with other literals only
---   nil      not decided by this field (missing, or declared with a type that is not a literal)
--- The type is a class, or a table type written inline.
--- @param uri uri
--- @param obj vm.node.object
--- @param fieldName string
--- @param literal parser.object
--- @return 'match'|'union'|'other'|nil
local function judgeByLiteralField(uri, obj, fieldName, literal)
    ---@param types parser.object[]
    ---@return 'match'|'union'|'other'|nil
    local function judge(types)
        local literals = 0
        local hit      = false
        for _, t in ipairs(types) do
            if guide.isLiteral(t) and t[1] ~= nil then
                literals = literals + 1
                if t[1] == literal[1] then
                    hit = true
                end
            end
        end
        if literals == 0 then
            return nil
        end
        if not hit then
            return 'other'
        end
        return #types > 1 and 'union' or 'match'
    end

    if obj.type == 'doc.type.table' then
        ---@cast obj parser.object
        for _, f in ipairs(obj.fields or {}) do
            local key = f.name
            if key and key.type ~= 'doc.type' and key[1] == fieldName and f.extends then
                return judge(f.extends.types)
            end
        end
    elseif obj.type == 'global' and obj.cate == 'type' then
        ---@cast obj vm.global
        for _, set in ipairs(obj:getSets(uri)) do
            if set.type == 'doc.class' then
                for _, f in ipairs(set.fields) do
                    -- (the parser drops a `---@field` without a type, so `extends` is always set here; the
                    -- field is optional on parser.object because most node types have none)
                    if f.field and f.field[1] == fieldName and f.extends then
                        local verdict = judge(f.extends.types)
                        if verdict then
                            return verdict
                        end
                    end
                end
            end
        end
    end
    return nil
end

--- The types of `node` without one.
---@param node vm.node
---@param obj  vm.node.object
local function removeType(node, obj)
    if obj.type == 'global' and obj.cate == 'type' then
        ---@cast obj vm.global
        node:remove(obj.name)
    else
        ---@cast obj -vm.global
        node:removeObject(obj)
    end
end

vm.registerEqualityNarrowing {
    -- if x == y then
    match = function (tracer, handler, checker)
        return tracer.getMap[handler] == true
    end,
    narrow = function (tracer, action, topNode, outNode, handler, checker)
        topNode = tracer:lookIntoChild(handler, topNode, outNode)
        local checkerNode = vm.compileNode(checker)
        local checkerName = vm.getNodeName(checker)
        if checkerName then
            topNode = topNode:copy()
            if action.op.type == '==' then
                topNode:narrow(tracer.uri, checkerName)
                if outNode then
                    outNode:removeNode(checkerNode)
                end
            else
                topNode:removeNode(checkerNode)
                if outNode then
                    outNode:narrow(tracer.uri, checkerName)
                end
            end
        end
        return topNode, outNode
    end,
}

vm.registerEqualityNarrowing {
    -- if x.kind == 'literal' then (narrow a union by a field that every member declares with a literal
    -- type: classes, and table types written inline)
    match = function (tracer, handler, checker)
        return handler.type == 'getfield'
           and handler.node.type == 'getlocal'
    end,
    narrow = function (tracer, action, topNode, outNode, handler, checker)
        if not handler.field
        or checker[1] == nil
        or not tracer.getMap[handler.node] then
            return topNode, outNode
        end
        local fieldName = handler.field[1] --[[@as string]]
        ---@type table<vm.node.object, 'match'|'union'|'other'|false>
        local verdicts = {}
        ---@param obj vm.node.object
        ---@return 'match'|'union'|'other'|false
        local function verdictOf(obj)
            local verdict = verdicts[obj]
            if verdict == nil then
                verdict = judgeByLiteralField(tracer.uri, obj, fieldName, checker) or false
                verdicts[obj] = verdict
            end
            return verdict
        end
        local anyMatch = false
        for obj in topNode:eachObject() do
            local verdict = verdictOf(obj)
            if verdict == 'match' or verdict == 'union' then
                anyMatch = true
            end
        end
        if not anyMatch then
            return topNode, outNode
        end
        -- the branch where the field is that literal: only the types that can have it
        ---@param node vm.node
        ---@return vm.node
        local function keepMatching(node)
            local result = node:copy()
            for i = 1, #node do
                local obj = node[i] --[[@as vm.node.object]]
                local verdict = verdictOf(obj)
                if verdict ~= 'match' and verdict ~= 'union' then
                    removeType(result, obj)
                end
            end
            result:removeOptional()
            return result
        end
        -- the other branch: the types that have only that literal are gone (`'a' | 'b'` may still be `'b'`)
        ---@param node vm.node
        ---@return vm.node
        local function dropMatching(node)
            local result = node:copy()
            for i = 1, #node do
                local obj = node[i] --[[@as vm.node.object]]
                if verdictOf(obj) == 'match' then
                    removeType(result, obj)
                end
            end
            return result
        end
        if action.op.type == '==' then
            topNode = keepMatching(topNode)
            if outNode then
                outNode = dropMatching(outNode)
            end
        else
            topNode = dropMatching(topNode)
            if outNode then
                outNode = keepMatching(outNode)
            end
        end
        return topNode, outNode
    end,
}

vm.registerEqualityNarrowing {
    -- if type(x) == 'string' then
    match = function (tracer, handler, checker)
        return handler.type == 'call'
           and checker.type == 'string'
           and handler.node.special == 'type'
           and handler.args
           and handler.args[1]
           and tracer.getMap[handler.args[1]] == true
    end,
    narrow = function (tracer, action, topNode, outNode, handler, checker)
        tracer:lookIntoChild(handler, topNode)
        topNode = topNode:copy()
        if action.op.type == '==' then
            topNode:narrow(tracer.uri, checker[1])
            if outNode then
                outNode:remove(checker[1])
            end
        else
            topNode:remove(checker[1])
            if outNode then
                outNode:narrow(tracer.uri, checker[1])
            end
        end
        return topNode, outNode
    end,
}

vm.registerEqualityNarrowing {
    -- local tp = type(x); if tp == 'string' then
    match = function (tracer, handler, checker)
        if not (handler.type == 'getlocal' and checker.type == 'string') then
            return false
        end
        local nodeValue = vm.getObjectValue(handler.node)
        if not (nodeValue and nodeValue.type == 'select' and nodeValue.sindex == 1) then
            return false
        end
        local call = nodeValue.vararg
        return call ~= nil
           and call.type == 'call'
           and call.node.special == 'type'
           and call.args ~= nil
           and tracer.getMap[call.args[1]] == true
    end,
    narrow = function (tracer, action, topNode, outNode, handler, checker)
        if action.op.type == '==' then
            topNode:narrow(tracer.uri, checker[1])
            if outNode then
                outNode:remove(checker[1])
            end
        else
            topNode:remove(checker[1])
            if outNode then
                outNode:narrow(tracer.uri, checker[1])
            end
        end
        return topNode, outNode
    end,
}

--- Record what a read is narrowed to. When the compile of that very read is what started
--- this walk (`path = path:string()`: compiling the `path` on the right runs the walk, and
--- the walk needs the assignment, whose value is that same call), its cached node is still
--- empty, so the assignment could not be resolved and everything the walk derived after
--- it (`path` after the `if`) was computed from nothing and kept. Hand the narrowed type to
--- the waiting compile right away so that the cycle sees the real thing.
---@param tracer vm.tracer
---@param action parser.object
---@param node   vm.node
local function setReadNode(tracer, action, node)
    tracer.nodes[action] = node
    if vm.isCompiling(action) then
        local waiting = vm.getNode(action)
        if waiting then
            waiting:merge(node)
        end
    end
end

local lookIntoChild = util.switch()
    : case 'getlocal'
    : case 'getglobal'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        if tracer.getMap[action] then
            setReadNode(tracer, action, topNode)
            if outNode then
                topNode = topNode:copy():setTruthy()
                outNode = outNode:copy():setFalsy()
            end
        end
        return topNode, outNode
    end)
    : case 'repeat'
    : case 'loop'
    : case 'for'
    : case 'do'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        if action.type == 'loop' then
            tracer:lookIntoChild(action.init, topNode)
            tracer:lookIntoChild(action.max, topNode)
        end
        if action[1] then
            tracer:lookIntoBlock(action, action.bstart, topNode:copy())
            local lastAssign = tracer:getLastAssign(action.start, action.finish)
            if lastAssign then
                tracer:getNode(lastAssign)
            end
            local actionNode = tracer.nodes[action]
            if actionNode then
                topNode = actionNode:copy()
            end
        end
        if action.type == 'repeat' then
            tracer:lookIntoChild(action.filter, topNode)
        end
        return topNode, outNode
    end)
    : case 'in'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        tracer:lookIntoChild(action.exps, topNode)
        if action[1] then
            tracer:lookIntoBlock(action, action.bstart, topNode:copy())
            local lastAssign = tracer:getLastAssign(action.start, action.finish)
            if lastAssign then
                tracer:getNode(lastAssign)
            end
            local actionNode = tracer.nodes[action]
            if actionNode then
                topNode = actionNode:copy()
            end
        end
        return topNode, outNode
    end)
    : case 'break'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        ---@type parser.object?
        local loop = action.parent
        while loop
        and loop.type ~= 'while'
        and loop.type ~= 'loop'
        and loop.type ~= 'in'
        and loop.type ~= 'for'
        and loop.type ~= 'repeat'
        and loop.type ~= 'function' do
            loop = loop.parent
        end
        if loop and tracer.trackBreaks[loop] then
            local nodes = tracer.breakNodes[loop]
            if not nodes then
                nodes = {}
                tracer.breakNodes[loop] = nodes
            end
            nodes[#nodes+1] = topNode:copy()
        end
        return topNode, outNode
    end)
    : case 'while'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        ---@type vm.node, vm.node
        local blockNode, mainNode
        if action.filter then
            blockNode, mainNode = tracer:lookIntoChild(action.filter, topNode:copy(), topNode:copy())
        else
            blockNode = topNode:copy()
            mainNode  = topNode:copy()
        end
        if action[1] then
            tracer:lookIntoBlock(action, action.bstart, blockNode:copy())
            local lastAssign = tracer:getLastAssign(action.start, action.finish)
            if lastAssign then
                tracer:getNode(lastAssign)
            end
            local actionNode = tracer.nodes[action]
            if actionNode then
                topNode = mainNode:merge(actionNode)
            end
            if tracer.trackBreaks[action] and isConstantTrue(action.filter) then
                topNode = tracer:getBreakExit(action, topNode) or topNode
            end
        end
        if action.filter then
            -- look into filter again
            guide.eachSource(action.filter, function (src)
                tracer.mark[src] = nil
            end)
            blockNode, topNode = tracer:lookIntoChild(action.filter, topNode:copy(), topNode:copy())
            if tracer.trackBreaks[action] and not isConstantTrue(action.filter) then
                -- a loop that has a condition is also left through its `break`s, in the state the
                -- variable has there (`while x do break end`: `x` is not falsy after it)
                for _, breakNode in ipairs(tracer.breakNodes[action] or {}) do
                    topNode:merge(breakNode)
                end
            end
        end
        return topNode, outNode
    end)
    : case 'if'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        ---@type boolean?
        local hasElse
        local mainNode = topNode:copy()
        ---@type vm.node[]
        local blockNodes = {}
        for _, subBlock in ipairs(action) do
            tracer:resetCastsIndex(subBlock.start)
            local blockNode = mainNode:copy()
            if subBlock.filter then
                blockNode, mainNode = tracer:lookIntoChild(subBlock.filter, blockNode, mainNode)
            else
                hasElse = true
                mainNode:clear()
            end
            ---@type boolean?
            local mergedNode
            if subBlock[1] then
                tracer:lookIntoBlock(subBlock, subBlock.bstart, blockNode:copy())
                local neverReturn = subBlock.hasReturn
                                or  subBlock.hasGoTo
                                or  subBlock.hasBreak
                                or  vm.blockExits(subBlock)
                if neverReturn then
                    mergedNode = true
                else
                    local lastAssign = tracer:getLastAssign(subBlock.start, subBlock.finish)
                    if lastAssign then
                        tracer:getNode(lastAssign)
                    end
                    if tracer.nodes[subBlock] then
                        blockNodes[#blockNodes+1] = tracer.nodes[subBlock]
                        mergedNode = true
                    end
                end
            end
            if not mergedNode then
                blockNodes[#blockNodes+1] = blockNode
            end
        end
        if not hasElse and not topNode:hasKnownType() then
            mainNode:merge(vm.declareGlobal('type', 'unknown'))
        end
        for _, blockNode in ipairs(blockNodes) do
            mainNode:merge(blockNode)
        end
        topNode = mainNode
        return topNode, outNode
    end)
    : case 'getfield'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        tracer:lookIntoChild(action.node, topNode)
        tracer:lookIntoChild(action.field, topNode)
        if tracer.getMap[action] then
            setReadNode(tracer, action, topNode)
            if outNode then
                topNode = topNode:copy():setTruthy()
                outNode = outNode:copy():setFalsy()
            end
        end
        return topNode, outNode
    end)
    : case 'getmethod'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        tracer:lookIntoChild(action.node, topNode)
        tracer:lookIntoChild(action.method, topNode)
        if tracer.getMap[action] then
            setReadNode(tracer, action, topNode)
            if outNode then
                topNode = topNode:copy():setTruthy()
                outNode = outNode:copy():setFalsy()
            end
        end
        return topNode, outNode
    end)
    : case 'getindex'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        tracer:lookIntoChild(action.node, topNode)
        tracer:lookIntoChild(action.index, topNode)
        if tracer.getMap[action] then
            setReadNode(tracer, action, topNode)
            if outNode then
                topNode = topNode:copy():setTruthy()
                outNode = outNode:copy():setFalsy()
            end
        end
        return topNode, outNode
    end)
    : case 'setfield'
    : case 'setmethod'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        tracer:lookIntoChild(action.node, topNode)
        tracer:lookIntoChild(action.value, topNode)
        return topNode, outNode
    end)
    : case 'setglobal'
    : case 'setlocal'
    : case 'tablefield'
    : case 'tableexp'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        tracer:lookIntoChild(action.value, topNode)
        return topNode, outNode
    end)
    : case 'setindex'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        tracer:lookIntoChild(action.node, topNode)
        tracer:lookIntoChild(action.index, topNode)
        tracer:lookIntoChild(action.value, topNode)
        return topNode, outNode
    end)
    : case 'tableindex'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        tracer:lookIntoChild(action.index, topNode)
        tracer:lookIntoChild(action.value, topNode)
        return topNode, outNode
    end)
    : case 'local'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        tracer:lookIntoChild(action.value, topNode)
        -- special treat for `local tp = type(x)`
        if  action.value
        and action.ref
        and action.value.type == 'select' then
            local index = action.value.sindex
            local call  = action.value.vararg
            if  index == 1
            and call.type == 'call'
            and call.node
            and call.node.special == 'type'
            and call.args then
                local getVar = call.args[1]
                if  getVar
                and tracer.getMap[getVar] then
                    for _, ref in ipairs(action.ref) do
                        tracer:collectCare(ref)
                    end
                end
            end
        end
        return topNode, outNode
    end)
    : case 'return'
    : case 'table'
    : case 'callargs'
    : case 'list'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        for _, ret in ipairs(action) do
            tracer:lookIntoChild(ret, topNode:copy())
        end
        return topNode, outNode
    end)
    : case 'select'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        tracer:lookIntoChild(action.vararg, topNode)
        return topNode, outNode
    end)
    : case 'function'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        tracer:lookIntoBlock(action, action.bstart, topNode:copy())
        return topNode, outNode
    end)
    : case 'paren'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node
    : call(function (tracer, action, topNode, outNode)
        topNode, outNode = tracer:lookIntoChild(action.exp, topNode, outNode)
        return topNode, outNode
    end)
    : case 'call'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        topNode, outNode = vm.runCallNarrowing(tracer, action, topNode, outNode)
        tracer:lookIntoChild(action.node, topNode)
        tracer:lookIntoChild(action.args, topNode)
        return topNode, outNode
    end)
    : case 'binary'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        if not action[1] or not action[2] then
            tracer:lookIntoChild(action[1], topNode)
            tracer:lookIntoChild(action[2], topNode)
            return topNode, outNode
        end
        if     action.op.type == 'and' then
            outNode = outNode or topNode:copy()
            local topNode1, outNode1 = tracer:lookIntoChild(action[1], topNode, outNode)
            local topNode2, outNode2 = tracer:lookIntoChild(action[2], topNode1, topNode1:copy())
            topNode = topNode2
            if vm.compileNode(action[2]):alwaysTruthy() then
                outNode = outNode1
            else
                outNode = vm.createNode(outNode1, outNode2)
            end
        elseif action.op.type == 'or' then
            outNode = outNode or topNode:copy()
            local topNode1, outNode1 = tracer:lookIntoChild(action[1], topNode, outNode)
            local topNode2, outNode2 = tracer:lookIntoChild(action[2], outNode1, outNode1:copy())
            topNode = vm.createNode(topNode1, topNode2)
            outNode = outNode2:copy()
        elseif action.op.type == '=='
        or     action.op.type == '~=' then
            ---@type parser.object?, parser.object?
            local handler, checker
            for i = 1, 2 do
                if guide.isLiteral(action[i]) then
                    checker = action[i]
                    handler = action[3-i] -- Copilot tells me use `3-i` instead of `i%2+1`
                end
            end
            if not handler then
                tracer:lookIntoChild(action[1], topNode)
                tracer:lookIntoChild(action[2], topNode)
                return topNode, outNode
            end
            topNode, outNode = vm.runEqualityNarrowing(tracer, action, topNode, outNode, handler, checker)
        end
        tracer:lookIntoChild(action[1], topNode)
        tracer:lookIntoChild(action[2], topNode)
        return topNode, outNode
    end)
    : case 'unary'
    ---@param tracer   vm.tracer
    ---@param action   parser.object
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    : call(function (tracer, action, topNode, outNode)
        if not action[1] then
            tracer:lookIntoChild(action[1], topNode)
            return topNode, outNode
        end
        if action.op.type == 'not' then
            outNode = outNode or topNode:copy()
            outNode, topNode = tracer:lookIntoChild(action[1], topNode, outNode)
            outNode = outNode:copy()
        end
        tracer:lookIntoChild(action[1], topNode)
        return topNode, outNode
    end)

---@param action   parser.object
---@param topNode  vm.node
---@param outNode? vm.node
---@return vm.node topNode
---@return vm.node outNode
function mt:lookIntoChild(action, topNode, outNode)
    if not self.careMap[action]
    or self.mark[action] then
        return topNode, outNode or topNode
    end
    self.mark[action] = true
    topNode = self:fastWardCasts(action.start, topNode)
    ---@type vm.node, vm.node?
    local newTopNode, newOutNode = lookIntoChild(action.type, self, action, topNode, outNode)
    topNode = newTopNode
    outNode = newOutNode
    return topNode, outNode or topNode
end

---@param block   parser.object
---@param start   integer
---@param node    vm.node
---@param effect? integer  when walking on from an assignment: its `effect`, to step over the statement itself
function mt:lookIntoBlock(block, start, node, effect)
    self:resetCastsIndex(start)
    for _, action in ipairs(block) do
        if (action.effect or action.start) < start then
            goto CONTINUE
        end
        -- The assignment's own statement is not "after" it: `id = f(id)` reads `id` before the
        -- assignment takes effect. Its target ends before its value, so the position test above
        -- lets it through, and the reads in the value used to get the assigned type instead of
        -- the earlier one, but only when this walk happened to run before the one from the
        -- previous assignment (which stops at the assignment).
        if effect and effect ~= math.maxinteger and action.effect == effect then
            goto CONTINUE
        end
        if self.careMap[action] then
            node = self:lookIntoChild(action, node)
            if action.type == 'do'
            or action.type == 'loop'
            or action.type == 'in'
            or action.type == 'repeat' then
                return
            end
        end
        if action.finish > start and self.assignMap[action] then
            return
        end
        ::CONTINUE::
    end
    self.nodes[block] = node
    if block.type == 'repeat' then
        self:lookIntoChild(block.filter, node)
    end
    if block.type == 'do'
    or block.type == 'loop'
    or block.type == 'in'
    or block.type == 'repeat' then
        self:lookIntoBlock(block.parent, block.finish, node)
    end
end

--- Constructors that can never evaluate to nil, and don't need compiling to
--- know it. Anything else (a local, a call, ...) is left alone: compiling an
--- arbitrary value from inside the tracer can start tracing that value's own
--- variable while it is already being compiled, which turned unrelated reads
--- into `unknown` in the self-check (parser/guide.lua's `myCache`).
local neverNilTypes = {
    ['table']    = true,
    ['string']   = true,
    ['integer']  = true,
    ['number']   = true,
    ['function'] = true,
}

--- Whether an assigned value is syntactically known to be non-nil: a
--- constructor above, `true`, or `a or b` (either side, through parens). `a or
--- b` is decided syntactically rather than from the value's node because inside
--- a loop the read of `a` in `t.x = t.x or {}` is circular with the tracer that
--- is asking, so the node comes back empty.
---@param value parser.object
---@return boolean
local function neverNil(value)
    local tp = value.type
    if neverNilTypes[tp] then
        return true
    end
    if tp == 'boolean' then
        return value[1] == true
    end
    if tp == 'paren' and value.exp then
        return neverNil(value.exp)
    end
    if tp == 'binary' and value.op.type == 'or' then
        return (value[2] ~= nil and neverNil(value[2]))
            or (value[1] ~= nil and neverNil(value[1]))
    end
    return false
end

--- The node of an assignment. A field assignment's own compiled node is the
--- union of every type the field is declared with (`---@field x? T`
--- contributes the `?`), not just what was assigned. When the assigned value
--- can't be nil, the field can't be nil right after the write either --
--- otherwise `t.x = {}` (or `if not t.x then t.x = {} end`) never narrows
--- `t.x` afterwards.
---@param source parser.object
---@return vm.node
local function getAssignNode(source)
    local node = vm.compileNode(source)
    if  node:hasFalsy()
    and source.value
    and (source.type == 'setfield'
    or   source.type == 'setindex'
    or   source.type == 'setmethod')
    and neverNil(source.value) then
        node = node:copy():removeOptional()
    end
    return node
end

--- Whether the loop's block makes the variable non-nil before its first `break` on every path:
--- `if not x then x = {} end` (or `x == nil`) as a statement of the block, the assignment in it a
--- value that is never nil, and no assignment between it and the last `break` that could give nil
--- (one after the last `break` is followed by the guard again before any `break`).
---@param loop      parser.object
---@param assigns   parser.object[] the assignments of the variable in the loop
---@param firstBreak integer
---@param lastBreak  integer
---@return boolean
function mt:hasGuardedInit(loop, assigns, firstBreak, lastBreak)
    for _, stmt in ipairs(loop) do
        if stmt.type ~= 'if' or stmt.finish >= firstBreak or #stmt ~= 1 then
            goto continue
        end
        do
            local block = stmt[1]
            local cond  = block.filter
            ---@type parser.object?
            local operand
            if cond and cond.type == 'unary' and cond.op.type == 'not' then
                operand = cond[1]
            elseif cond and cond.type == 'binary' and cond.op.type == '==' and cond[1] and cond[2] then
                if cond[2].type == 'nil' then
                    operand = cond[1]
                elseif cond[1].type == 'nil' then
                    operand = cond[2]
                end
            end
            if not operand or not self.getMap[operand] then
                goto continue
            end
            if block.hasReturn or block.hasBreak or block.hasGoTo or vm.blockExits(block) then
                goto continue
            end
            local initialises = false
            for _, assign in ipairs(assigns) do
                if assign.parent == block and assign.value and neverNil(assign.value) then
                    initialises = true
                end
            end
            if not initialises then
                goto continue
            end
            for _, assign in ipairs(assigns) do
                if  assign.start >= stmt.start
                and assign.start <  lastBreak
                and not (assign.value and neverNil(assign.value)) then
                    goto continue
                end
            end
            return true
        end
        ::continue::
    end
    return false
end

--- The node the variable has after `while true do ... end`. The loop is left only through its
--- `break`s, so it is what it is at each of them, when that does not depend on how the loop was
--- entered or came around: the loop's own block assigns the variable before the first `break`
--- (then it is the union of the nodes at the breaks), or makes it non-nil there (a guarded
--- initialisation: then it is what `approx`, entry merged with the end of the body, is without nil).
--- A `goto` only counts when it lands after the last `break`, inside the loop. Otherwise `nil`,
--- and the caller keeps the approximation.
---@param loop   parser.object
---@param approx vm.node
---@return vm.node?
function mt:getBreakExit(loop, approx)
    local breaks = loop.breaks
    if not breaks then
        return
    end
    ---@type parser.object[]
    local assigns = {}
    for _, assign in ipairs(self.assigns) do
        if assign.type ~= 'variable' then
            ---@cast assign parser.object
            if assign.start >= loop.start and assign.finish <= loop.finish then
                assigns[#assigns+1] = assign
            end
        end
    end
    -- (the breaks are in source order)
    local firstBreak = breaks[1].start
    local lastBreak  = breaks[#breaks].finish
    ---@type table<string, parser.object>
    local labels = {}
    guide.eachSourceType(loop, 'label', function (label)
        labels[label[1] --[[@as string]]] = label
    end)
    local gotosAreSafe = true
    guide.eachSourceType(loop, 'goto', function (jump)
        local label = labels[jump[1] --[[@as string]]]
        if not label or label.start <= lastBreak or label.start < jump.start then
            gotosAreSafe = false
        end
    end)
    if not gotosAreSafe then
        return
    end
    local guarded = false
    for _, assign in ipairs(assigns) do
        if assign.parent == loop and assign.finish < firstBreak then
            guarded = true
            break
        end
    end
    -- an assignment whose value reads the variable (`line = line .. char`) is circular with the
    -- walk that asks for it: what comes back is empty, and what the reads in the loop got from
    -- it stays wrong, so those loops keep the approximation; unless the value is a constructor
    -- or `x or <constructor>` (`l = l or {}`), which is what it is whatever the read says
    for _, assign in ipairs(assigns) do
        local value = assign.value
        if value and not neverNil(value) then
            for get in pairs(self.getMap) do
                if get.start >= value.start and get.finish <= value.finish then
                    guarded = false
                end
            end
        end
    end
    if not guarded then
        if self:hasGuardedInit(loop, assigns, firstBreak, lastBreak) then
            return approx:copy():removeOptional()
        end
        return
    end
    -- every walk that can reach a `break` has to have run
    for _, assign in ipairs(assigns) do
        self:getNode(assign)
    end
    local nodes = self.breakNodes[loop]
    if not nodes or #nodes ~= #breaks then
        return
    end
    local exit = nodes[1]:copy()
    for i = 2, #nodes do
        exit:merge(nodes[i])
    end
    return exit
end

---@param source parser.object
function mt:calcNode(source)
    if self.getMap[source] then
        local lastAssign = self:getLastAssign(0, source.finish)
        if not lastAssign then
            return
        end
        if self.fastCalc then
            if vm.isCompiling(lastAssign) then
                vm.walkSkipped(self)
            else
                self.nodes[source] = getAssignNode(lastAssign)
            end
            return
        end
        self:calcNode(lastAssign)
        return
    end
    if self.assignMap[source] then
        local node = getAssignNode(source)
        -- An assignment that is still being compiled (`n = n + 1`: compiling it asked for the read
        -- of `n` whose walk got here) only has its half-built node. Everything a walk derives from
        -- that (the reads after the assignment, the exit of the loop around it) would be kept
        -- for good, and be wrong: the request that is compiling the assignment walks on from it
        -- again once it is done, but `mark` keeps that walk from visiting those reads a second time.
        if vm.isCompiling(source) then
            vm.walkSkipped(self)
            return
        end
        self.nodes[source] = node
        local parentBlock = guide.getParentBlock(source)
        if parentBlock then
            self:lookIntoBlock(parentBlock, source.finish, node, (source.type == 'setlocal' or source.type == 'setfield' or source.type == 'setindex') and source.effect or nil)
        end
        return
    end
end

---@param source parser.object
---@return vm.node?
function mt:getNode(source)
    local cache = self.nodes[source]
    if cache ~= nil then
        return cache or nil
    end
    if source == self.main then
        self.nodes[source] = false
        return nil
    end
    self.nodes[source] = false
    self:calcNode(source)
    return self.nodes[source] or nil
end

--- A field path (`t1.s`) whose value only ever came from the table
--- constructor that built `t1` (never an explicit `t1.s = ...`
--- assignment anywhere) has an empty `variable.sets` -- collectLocal
--- above has nothing to anchor a backward search on, so calcNode's
--- getLastAssign always comes up empty and narrowing (an enclosing
--- `if`/guard) never gets a chance to run at all. This walks the block
--- forward exactly once, starting right after the base variable's own
--- declaration and seeded with the field's already-resolved static
--- type (computed structurally by vm/compiler.lua before it ever calls
--- vm.traceNode), so every tracked occurrence in that walk still gets
--- narrowed the normal way -- this only supplies the missing starting
--- point, not a different narrowing mechanism.
---@param source   parser.object
---@param variable vm.variable
---@return vm.node?
function mt:getFallbackFieldNode(source, variable)
    if self.fieldFallbackDone then
        return self.nodes[source] or nil
    end
    self.fieldFallbackDone = true
    if not variable:getParent() then
        -- not a field path (t1.s) at all -- a plain local/self always
        -- has at least one real `set` (its own declaration), so it
        -- never needs this fallback.
        return nil
    end
    -- Note: an explicit reassignment elsewhere in the same scope
    -- (self.assigns non-empty) does NOT disqualify this fallback -- only
    -- one *before* this read would (and getNode's own getLastAssign
    -- search, tried before this fallback runs, already handles that
    -- case). A later reassignment is irrelevant to this read, and the
    -- forward walk below stops at it naturally via lookIntoBlock's own
    -- assignMap check, so it can never leak into what this read sees.
    local initialNode = vm.compileNode(source)
    if not initialNode or initialNode:isEmpty() then
        return nil
    end
    local parentBlock = guide.getParentBlock(variable.base)
    if not parentBlock then
        return nil
    end
    self:lookIntoBlock(parentBlock, variable.base.finish, initialNode:copy())
    return self.nodes[source] or nil
end

---@class vm.node
---@field package _tracer vm.tracer

---@param mode tracer.mode
---@param source parser.object | vm.variable
---@param name string
---@return vm.tracer?
local function createTracer(mode, source, name)
    local node = vm.compileNode(source)
    local tracer = node._tracer
    if tracer then
        return tracer
    end
    ---@type parser.object?
    local main
    if source.type == 'variable' then
        ---@cast source vm.variable
        main = guide.getParentBlock(source.base)
    else
        ---@cast source parser.object
        main = guide.getParentBlock(source)
    end
    if not main then
        return nil
    end
    tracer = setmetatable({
        source    = source,
        mode      = mode,
        name      = name,
        assigns   = {},
        assignMap = {},
        getMap    = {},
        careMap   = {},
        mark      = {},
        casts     = {},
        nodes     = {},
        trackBreaks = {},
        breakNodes  = {},
        main      = main,
        uri       = guide.getUri(main),
    }, mt)
    node._tracer = tracer

    if tracer.mode == 'local' then
        tracer:collectLocal()
    else
        tracer:collectGlobal()
    end

    return tracer
end

---@param source parser.object
---@return vm.node?
function vm.traceNode(source)
    ---@type tracer.mode?, (parser.object|vm.variable)?, string?
    local mode, base, name
    if vm.getGlobalNode(source) then
        base = vm.getGlobalBase(source)
        if not base then
            return nil
        end
        mode = 'global'
        name = base['global']:getCodeName()
    else
        base = vm.getVariable(source)
        if not base then
            return nil
        end
        name = base:getCodeName()
        mode = 'local'
    end
    -- The tracer keeps its own results, which the compile bookkeeping in vm/compiler.lua
    -- cannot drop. If the walk consumed the half-built node of a compile that is still
    -- open further down the stack (compiling the assignment `path = path:string()` asks
    -- for `path`, whose walk asks for the assignment again), what the tracer cached from
    -- that is wrong, so the tracer is dropped and the next request rebuilds it. A
    -- request that was already using a tracer that a nested request dropped like that
    -- asks again with a fresh one, once that compile has finished.
    ---@type vm.node?
    local node
    for _ = 1, 2 do
        local tracer = createTracer(mode, base, name)
        if not tracer then
            return nil
        end
        -- the walk of this tracer may already be running further down the stack (see
        -- vm.beginWalk): then we are a nested request for a read it has not reached yet
        local running = tracer.walkFrame
        local walk <close> = not running and vm.beginWalk(tracer) or nil
        local watch <close> = vm.watchCompileCycles()
        node = tracer:getNode(source)
        if not node and mode == 'local' then
            ---@cast base vm.variable
            node = tracer:getFallbackFieldNode(source, base)
        end
        -- whatever comes back from a walk that is still running is provisional: the reads it
        -- has not reached are empty, and the ones it has may still change (an assignment
        -- further on decides them)
        if running then
            vm.consumeWalk(running)
        end
        local owner = vm.getNode(base)
        if not owner then
            break
        end
        if watch.hit then
            if owner._tracer == tracer then
                owner._tracer = nil
            end
            break
        end
        if owner._tracer == tracer then
            break
        end
    end
    return node
end
