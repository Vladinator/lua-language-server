---@class vm
local vm    = require 'vm.vm'
local guide = require 'parser.guide'

--- Phase 3 of the tracer redesign (see `TRACER-REDESIGN.md`): a real, reusable, multi-variable
--- flow analysis built on `vm.buildCFG` (Phase 1) and `vm.runDataflow` (Phase 2). Still standalone:
--- nothing here is wired into `vm.traceNode` or the compiler; `test/other/flow-differential.lua`
--- is what compares its answers against the old tracer's.
---
--- State entering/leaving a block is a map from a local's declaration node to its `vm.node` at
--- that point; `false` (not an empty map) is the lattice bottom, meaning "this block is never
--- reached" -- an empty map is a legitimate *reached* state (a function with no locals yet), and
--- the engine has to be able to tell the two apart or it stops propagating at the entry block.
---
--- Supported so far: local declarations, plain reassignment, and narrowing of a *direct* reference
--- to a tracked local used as a whole branch condition (`if x`, `if not x`, `if x == nil`,
--- `if x ~= nil`, and the same for `while`). Everything else (calls such as `assert(x)`/`type(x)`,
--- `and`/`or` inside a condition, field paths, globals, upvalues written from a nested function,
--- `goto`-driven state) is treated as having no effect on the state -- exactly what
--- `test/other/flow-differential.lua` measures against the old tracer, so the next thing to port is
--- chosen from data, not guessed.

---@alias vm.flow.state table<parser.object, vm.node>|false

---@param a vm.node
---@param b vm.node
---@return boolean
local function nodeEqual(a, b)
    if a == b then
        return true
    end
    if (a.optional == true) ~= (b.optional == true) then
        return false
    end
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if not b[a[i]] then
            return false
        end
    end
    local aFlags, bFlags = a.flags, b.flags
    if aFlags then
        for name, value in pairs(aFlags) do
            if (value == true) ~= (bFlags ~= nil and bFlags[name] == true) then
                return false
            end
        end
    end
    if bFlags then
        for name, value in pairs(bFlags) do
            if value == true and not (aFlags ~= nil and aFlags[name] == true) then
                return false
            end
        end
    end
    return true
end

---@param a vm.flow.state
---@param b vm.flow.state
---@return boolean
local function stateEqual(a, b)
    if a == b then
        return true
    end
    if not a or not b then
        return false
    end
    for decl, node in pairs(a) do
        local other = b[decl]
        if not other or not nodeEqual(node, other) then
            return false
        end
    end
    for decl in pairs(b) do
        if not a[decl] then
            return false
        end
    end
    return true
end

---@param a vm.flow.state
---@param b vm.flow.state
---@return vm.flow.state
local function stateJoin(a, b)
    if not a then
        return b
    end
    if not b then
        return a
    end
    ---@type table<parser.object, vm.node>
    local out = {}
    for decl, node in pairs(a) do
        out[decl] = node
    end
    for decl, node in pairs(b) do
        local current = out[decl]
        if not current then
            out[decl] = node
        elseif not nodeEqual(current, node) then
            out[decl] = current:copy():merge(node)
        end
    end
    return out
end

---@param state table<parser.object, vm.node>
---@return table<parser.object, vm.node>
local function copyState(state)
    ---@type table<parser.object, vm.node>
    local out = {}
    for decl, node in pairs(state) do
        out[decl] = node
    end
    return out
end

--- The node of an assignment or declaration, the way vm/tracer.lua's own getAssignNode reads it:
--- the compile of the *statement itself*, not of its right-hand side (that would drop what the
--- compiler merges in from a declared `---@type`). The field-only tweak in tracer.lua's version
--- has no counterpart here, this only handles plain locals.
---@param stmt parser.object
---@return vm.node
local function assignNode(stmt)
    return vm.compileNode(stmt):copy()
end

--- Applies one statement's own effect to `state`, in place (`state` must already be a private
--- copy of the state entering the statement).
---@param state table<parser.object, vm.node>
---@param stmt  parser.object
local function applyStmt(state, stmt)
    local t = stmt.type
    if t == 'local' then
        state[stmt] = assignNode(stmt)
    elseif t == 'setlocal' then
        local decl = stmt.node
        if decl and state[decl] then
            state[decl] = assignNode(stmt)
        end
    end
end

--- The state along a branch edge that narrows `decl` from `before` to `after`. Narrowing a
--- variable down to *nothing* (`if x == nil` on a variable that is already only nil, on its false
--- edge) means no value can take this edge: the state is bottom, not "reached with an empty
--- variable". That is what makes provably-dead paths contribute nothing to a join -- reachability
--- comes out of the value lattice itself instead of a separate pass. Only emptiness *produced by
--- the narrowing* counts: a variable that was already empty before it (a type the compiler could
--- not resolve) says nothing about reachability.
---@param state  table<parser.object, vm.node>
---@param decl   parser.object
---@param before vm.node
---@param after  vm.node
---@return vm.flow.state
local function narrowedState(state, decl, before, after)
    if after:isEmpty() and not after:isOptional() and not before:isEmpty() then
        return false
    end
    local out = copyState(state)
    out[decl] = after
    return out
end

---@alias vm.flow.shape 'truthy'|'nileq'

--- What a branch condition tests, when it is a direct reference to a local: the local's
--- declaration node, how it is tested, and whether the test is inverted (`not x`, `x ~= nil`).
---@param cond parser.object?
---@return parser.object? decl
---@return vm.flow.shape? shape
---@return boolean inverted
local function conditionShape(cond)
    if not cond then
        return nil, nil, false
    end
    if cond.type == 'getlocal' then
        return cond.node, 'truthy', false
    end
    if cond.type == 'unary' and cond.op and cond.op.type == 'not'
    and cond[1] and cond[1].type == 'getlocal' then
        return cond[1].node, 'truthy', true
    end
    if cond.type == 'binary' and cond.op
    and (cond.op.type == '==' or cond.op.type == '~=') then
        local left, right = cond[1], cond[2]
        if left and right then
            if left.type == 'getlocal' and right.type == 'nil' then
                return left.node, 'nileq', cond.op.type == '~='
            end
            if right.type == 'getlocal' and left.type == 'nil' then
                return right.node, 'nileq', cond.op.type == '~='
            end
        end
    end
    return nil, nil, false
end

---@class vm.flow
---@field cfg        vm.cfg
---@field result     vm.dataflow.result
---@field stmtBlock  table<parser.object, vm.cfg.block>   statement -> the block it sits in
---@field condBlock  table<parser.object, vm.cfg.block>   branch condition -> the block testing it
---@field exprBlock  table<parser.object, vm.cfg.block>   loop-header expression -> the block running it
local flow = {}
flow.__index = flow

---@param main parser.object a 'main' or 'function' node
---@return vm.flow
function vm.buildFlow(main)
    local cfg = vm.buildCFG(main)

    ---@type table<parser.object, vm.cfg.block>
    local stmtBlock = {}
    ---@type table<parser.object, vm.cfg.block>
    local condBlock = {}
    ---@type table<parser.object, vm.cfg.block>
    local exprBlock = {}
    for _, block in ipairs(cfg.blocks) do
        for _, stmt in ipairs(block.stmts) do
            stmtBlock[stmt] = block
        end
        if block.condition then
            condBlock[block.condition] = block
        end
        for _, expr in ipairs(block.exprs or {}) do
            exprBlock[expr] = block
        end
    end

    -- Locals that no block statement declares (a function's parameters, `for` loop variables) hold
    -- their compiled type from the start; nothing in this analysis reassigns them but `setlocal`.
    ---@type table<parser.object, vm.node>
    local seeded = {}
    for _, declType in ipairs { 'local', 'self' } do
        guide.eachSourceType(main, declType, function (loc)
            if stmtBlock[loc] then
                return
            end
            if (guide.getParentFunction(loc) or main) ~= main then
                return
            end
            seeded[loc] = vm.compileNode(loc):copy()
        end)
    end

    ---@type vm.dataflow.spec
    local spec = {
        bottom  = function () return false end,
        initial = function () return seeded end,
        join    = stateJoin,
        equal   = stateEqual,
        transfer = function (block, stateIn)
            ---@cast stateIn table<parser.object, vm.node>
            local state = copyState(stateIn)
            for _, stmt in ipairs(block.stmts) do
                applyStmt(state, stmt)
            end
            local decl, shape, inverted = conditionShape(block.condition)
            ---@type vm.node?
            local current
            if decl then
                current = state[decl]
            end
            if decl and current and shape then
                ---@type vm.node, vm.node
                local trueNode, falseNode
                if shape == 'truthy' then
                    trueNode  = current:copy():setTruthy()
                    falseNode = current:copy():setFalsy()
                else
                    trueNode  = vm.createNode(vm.declareGlobal('type', 'nil'))
                    falseNode = current:copy():removeOptional()
                end
                if inverted then
                    trueNode, falseNode = falseNode, trueNode
                end
                return state, {
                    ['true']  = narrowedState(state, decl, current, trueNode),
                    ['false'] = narrowedState(state, decl, current, falseNode),
                }
            end
            return state
        end,
    }

    return setmetatable({
        cfg       = cfg,
        result    = vm.runDataflow(cfg, spec),
        stmtBlock = stmtBlock,
        condBlock = condBlock,
        exprBlock = exprBlock,
    }, flow)
end

--- The narrowed node of a read of a local, or nil when this analysis has no answer for it (a read
--- in another function, one in code the CFG never reached, a variable it does not track).
---@param read parser.object a `getlocal`
---@return vm.node?
function flow:getNode(read)
    local decl = read.node
    if not decl then
        return nil
    end
    ---@type vm.cfg.block?, parser.object?
    local block, owner
    ---@type parser.object?
    local cursor = read
    while cursor do
        if self.stmtBlock[cursor] then
            block, owner = self.stmtBlock[cursor], cursor
            break
        end
        if self.condBlock[cursor] then
            block = self.condBlock[cursor]
            break
        end
        if self.exprBlock[cursor] then
            block = self.exprBlock[cursor]
            break
        end
        cursor = cursor.parent
    end
    if not block then
        return nil
    end
    local stateIn = self.result.stateIn[block]
    if not stateIn then
        return nil
    end
    local state = copyState(stateIn)
    for _, stmt in ipairs(block.stmts) do
        if stmt == owner then
            break
        end
        applyStmt(state, stmt)
    end
    return state[decl]
end
