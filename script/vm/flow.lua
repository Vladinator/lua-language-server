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

---@alias vm.flow.key parser.object|string

--- What a flow knows beyond its states: `castsAt`, the `---@cast` docs right before a statement or
--- condition, and `interesting`, the locals and paths something in the function can narrow or
--- assign a guarded value to. Only those are tracked: the rest is answered by nobody here (a read
--- of an untouched variable is its compiled type, which is not this analysis's business), and so
--- costs no compile at all -- compiling every parameter and local of a function up front is what
--- ran into compiles that were still open further down the stack.
---@class vm.flow.context
---@field castsAt     table<parser.object, parser.object[]>
---@field interesting table<vm.flow.key, true>
---@alias vm.flow.state table<vm.flow.key, vm.node>|false

--- Tracked things are keyed by a local's declaration node, or, for a field path rooted at a local
--- (`a.b.c`, `a[1]`), by a string: the root's id and the keys, separated by SEP. A local is
--- always present once declared; a path is present only while something narrowed or assigned it
--- (otherwise its type is the static one, see `staticNodeOf`), so a join keeps a path only when
--- both sides have it.
local SEP = ''

local blockScopes = {
    ['main'] = true, ['function'] = true, ['ifblock'] = true, ['elseifblock'] = true,
    ['elseblock'] = true, ['while'] = true, ['loop'] = true, ['in'] = true, ['repeat'] = true,
    ['do'] = true,
}

---@type table<parser.object, integer>
local declIds = setmetatable({}, { __mode = 'k' })
local nextDeclId = 0

---@param decl parser.object
---@return string
local function declKey(decl)
    local id = declIds[decl]
    if not id then
        nextDeclId = nextDeclId + 1
        id = nextDeclId
        declIds[decl] = id
    end
    return '#' .. id
end

--- The path key of a field access rooted at a local, or nil (a global, a call, a dynamic key).
---@param expr parser.object?
---@return string?
local function pathKey(expr)
    if not expr then
        return nil
    end
    local t = expr.type
    if t ~= 'getfield' and t ~= 'setfield' and t ~= 'getindex' and t ~= 'setindex' then
        return nil
    end
    local name = guide.getKeyName(expr)
    if name == nil then
        return nil
    end
    local parent = expr.node
    ---@type string?
    local base
    if parent and (parent.type == 'getlocal' or parent.type == 'setlocal') then
        if not parent.node then
            return nil
        end
        base = declKey(parent.node)
    else
        base = pathKey(parent)
    end
    if not base then
        return nil
    end
    return base .. SEP .. type(name) .. tostring(name)
end

--- Everything tracked *below* `key` (its fields), for killing them when `key` is written.
---@param state table<vm.flow.key, vm.node>
---@param key   string
local function killBelow(state, key)
    local prefix = key .. SEP
    for other in pairs(state) do
        if type(other) == 'string' and other:sub(1, #prefix) == prefix then
            state[other] = nil
        end
    end
end

--- Raised (as an error value) when the flow needs the compiled node of something whose compile is
--- still open further down the stack: that node is half built, a flow made from it would keep it
--- for good. `vm.getFlow` catches it and the caller falls back to the old walk for the request.
local CYCLE = setmetatable({}, { __tostring = function () return 'flow: compile cycle' end })

---@param source parser.object
---@return vm.node
local function compileForFlow(source)
    if vm.isCompiling(source) then
        error(CYCLE, 0)
    end
    return vm.compileNode(source)
end

--- What a field read's type is before any narrowing: the compiler keeps it when it goes on to
--- trace the read (`preTraceNode`), else the compiled node is already the static one.
---@param expr parser.object
---@return vm.node?
local function staticNodeOf(expr)
    -- (set right before the compiler asks the tracer, and compiling `expr` again from inside that
    -- request would just ask again)
    if expr.preTraceNode then
        return expr.preTraceNode
    end
    local node = compileForFlow(expr)
    return expr.preTraceNode or node
end

--- Set membership by the array itself: `vm.node:narrow` appends its fallback object without
--- registering it in the set index, so `node[obj]` alone can say "absent" for a present object.
---@param node vm.node
---@param obj  vm.node.object
---@return boolean
local function hasObject(node, obj)
    if node[obj] then
        return true
    end
    for i = 1, #node do
        if node[i] == obj then
            return true
        end
    end
    return false
end

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
        if not hasObject(b, a[i]) then
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

--- Does the node say anything about its type (a named or literal type, or nil)? The compiler's
--- nodes of an untyped variable hold only the variable itself.
---@param node vm.node
---@return boolean
local function hasTypes(node)
    return node.optional == true or node:isTyped()
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
    ---@type table<vm.flow.key, vm.node>
    local out = {}
    for decl, node in pairs(a) do
        out[decl] = node
    end
    for decl, node in pairs(b) do
        local current = out[decl]
        if not current then
            out[decl] = node
        elseif not nodeEqual(current, node) then
            local merged = current:copy():merge(node)
            if hasTypes(current) ~= hasTypes(node) then
                merged:merge(vm.declareGlobal('type', 'unknown'))
            end
            out[decl] = merged
        end
    end
    for key in pairs(out) do
        if type(key) == 'string' and (not a[key] or not b[key]) then
            out[key] = nil
        end
    end
    return out
end

---@param state table<vm.flow.key, vm.node>
---@return table<vm.flow.key, vm.node>
local function copyState(state)
    ---@type table<vm.flow.key, vm.node>
    local out = {}
    for decl, node in pairs(state) do
        out[decl] = node
    end
    return out
end

--- The node of an assignment or declaration: what the old tracer's getAssignNode says (the
--- compile of the *statement itself*, not of its right-hand side, which would drop what the
--- compiler merges in from a declared `---@type`; a field write of a never-nil value is not nil).
---@param stmt parser.object
---@return vm.node
local function assignNode(stmt)
    if vm.isCompiling(stmt) then
        error(CYCLE, 0)
    end
    return vm.getAssignNode(stmt):copy()
end

---@type fun(state: vm.flow.state, expr: parser.object?): vm.flow.state, vm.flow.state
local flow_evalCondition
---@type fun(expr: parser.object, items: parser.object[])
local addOperands
---@type fun(state: table<vm.flow.key, vm.node>, expr: parser.object?, fn: fun(node: vm.node): vm.node): vm.flow.state
local flow_narrowRef

--- Applies the `---@cast x ...` docs that sit right before an item (statement or condition), the
--- way the old tracer's fastWardCasts does. Only plain local names are handled (`---@cast a.b` is a
--- field path, not a variable).
---@param state table<vm.flow.key, vm.node>
---@param casts parser.object[]?
local function applyCasts(state, casts)
    for _, doc in ipairs(casts or {}) do
        local decl = vm.getCastTargetHead(doc)
        if decl and decl.type ~= 'global' and not doc.name[1]:find('.', 1, true) then
            ---@cast decl parser.object
            local node = state[decl]
            if node then
                node = node:copy()
                for _, cast in ipairs(doc.casts) do
                    if cast.mode == '+' then
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
                    elseif cast.extends then
                        node:clear()
                        node:merge(vm.compileNode(cast.extends))
                    end
                end
                state[decl] = node
            end
        end
    end
end

--- Applies one statement's own effect to `state`, in place (`state` must already be a private
--- copy of the state entering the statement).
---@param state table<vm.flow.key, vm.node>
---@param stmt  parser.object
---@param ctx vm.flow.context
local function applyStmt(state, stmt, ctx)
    applyCasts(state, ctx.castsAt[stmt])
    local t = stmt.type
    if t == 'local' then
        if ctx.interesting[stmt] then
            state[stmt] = assignNode(stmt)
        end
    elseif t == 'setlocal' then
        local decl = stmt.node
        if decl then
            killBelow(state, declKey(decl))
            if state[decl] then
                state[decl] = assignNode(stmt)
            end
        end
    elseif t == 'setfield' or t == 'setindex' then
        local key = pathKey(stmt)
        if key then
            killBelow(state, key)
            if ctx.interesting[key] then
                state[key] = assignNode(stmt)
            end
        end
    elseif t == 'call' and stmt.node and stmt.node.special == 'assert'
    and stmt.args and stmt.args[1] then
        -- assert(cond): what follows only runs where `cond` held. Forward-declared below.
        local yes = flow_evalCondition(state, stmt.args[1])
        if yes then
            for decl, node in pairs(yes) do
                state[decl] = node
            end
        end
    end
    if t == 'call' and stmt.node then
        -- what a registered assertion (`---@asserts`) says holds after the call
        local uri = guide.getUri(stmt)
        for _, narrowing in ipairs(vm.getFlowNarrowings(stmt, true)) do
            local after = narrowing.after
            if after then
                local narrowed = flow_narrowRef(state, narrowing.target, function (node) return after(node, uri) end)
                if narrowed then
                    for key, node in pairs(narrowed) do
                        state[key] = node
                    end
                end
            end
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
---@param state  table<vm.flow.key, vm.node>
---@param key    vm.flow.key
---@param before vm.node
---@param after  vm.node
---@return vm.flow.state
local function narrowedState(state, key, before, after)
    -- (a node that had types and has none left: `while x do ... end` on an `integer`, false edge)
    if not hasTypes(after) and hasTypes(before) then
        return false
    end
    local out = copyState(state)
    out[key] = after
    return out
end

--- What an expression refers to, when it is something this analysis tracks: a local (by its
--- declaration node) or a field path rooted at a local (by its path string).
---@param expr parser.object?
---@return vm.flow.key?
local function refKey(expr)
    if not expr then
        return nil
    end
    if expr.type == 'getlocal' then
        return expr.node
    end
    if expr.type == 'getfield' or expr.type == 'getindex' then
        return pathKey(expr)
    end
    return nil
end

--- Narrows what `expr` refers to in `state` with `fn`; `state` itself when it is nothing tracked.
--- A path nothing has narrowed yet starts from its static type.
---@param state table<vm.flow.key, vm.node>
---@param expr  parser.object?
---@param fn    fun(node: vm.node): vm.node
---@return vm.flow.state
local function narrowRef(state, expr, fn)
    local key = refKey(expr)
    if not expr or not key then
        return state
    end
    ---@type vm.node?
    local current = state[key]
    if not current and type(key) == 'string' then
        current = staticNodeOf(expr)
    end
    if not current then
        return state
    end
    return narrowedState(state, key, current, fn(current))
end

---@param a vm.flow.state
---@param b vm.flow.state
---@return vm.flow.state
local function joinTwo(a, b)
    return stateJoin(a, b)
end

--- The states along the true and false edges of the branch condition `expr`, given the state
--- `state` entering it. Compositional: `not`, `and`, `or` and parentheses combine the answers of
--- their operands (`a and b`: `b` is only evaluated where `a` held, the false state is the join of
--- "`a` failed" and "`a` held, `b` failed"), so any nesting works without a special case. An
--- expression this analysis does not understand narrows nothing: both edges get `state`.
--- The `---@cast` docs of the flow being run (set around its transfer functions and queries).
---@type table<parser.object, parser.object[]>
local activeCasts = {}

--- `state` with the casts written right before `operand` applied.
---@param state   vm.flow.state
---@param operand parser.object
---@return vm.flow.state
local function withCasts(state, operand)
    local casts = activeCasts[operand]
    if not state or not casts then
        return state
    end
    local out = copyState(state)
    applyCasts(out, casts)
    return out
end

---@param state vm.flow.state
---@param expr  parser.object?
---@return vm.flow.state trueState
---@return vm.flow.state falseState
local function evalCondition(state, expr)
    if not state then
        return false, false
    end
    if not expr then
        return state, state
    end
    local t = expr.type
    if t == 'paren' then
        return evalCondition(state, expr.exp)
    end
    -- a constant condition has one way out (`while true do ... break ... end` is left by its breaks)
    if t == 'nil' or (t == 'boolean' and expr[1] == false) then
        return false, state
    end
    if t == 'number' or t == 'integer' or t == 'string' or (t == 'boolean' and expr[1] == true) then
        return state, false
    end
    if refKey(expr) then
        return narrowRef(state, expr, function (node) return node:copy():setTruthy() end),
               narrowRef(state, expr, function (node) return node:copy():setFalsy() end)
    end
    if t == 'call' and expr.node then
        -- a registered guard (`isString(x)`, a `---@guard` function, a secret check): the rules say
        -- how each argument is narrowed where the call is truthy and where it is not
        local uri = guide.getUri(expr)
        ---@type vm.flow.state, vm.flow.state
        local yes, no = state, state
        for _, narrowing in ipairs(vm.getFlowNarrowings(expr)) do
            local whenTrue, whenFalse = narrowing.whenTrue, narrowing.whenFalse
            if whenTrue and yes then
                yes = narrowRef(yes, narrowing.target, function (node) return whenTrue(node, uri) end)
            end
            if whenFalse and no then
                no = narrowRef(no, narrowing.target, function (node) return whenFalse(node, uri) end)
            end
        end
        return yes, no
    end
    if t == 'unary' and expr.op and expr.op.type == 'not' then
        local yes, no = evalCondition(state, expr[1])
        return no, yes
    end
    if t == 'binary' and expr.op then
        local op = expr.op.type
        local left, right = expr[1], expr[2]
        if op == 'and' then
            local leftYes, leftNo = evalCondition(state, left)
            local rightYes, rightNo = evalCondition(withCasts(leftYes, right), right)
            return rightYes, joinTwo(leftNo, rightNo)
        end
        if op == 'or' then
            local leftYes, leftNo = evalCondition(state, left)
            local rightYes, rightNo = evalCondition(withCasts(leftNo, right), right)
            return joinTwo(leftYes, rightYes), rightNo
        end
        if (op == '==' or op == '~=') and left and right then
            if left.type == 'nil' then
                left, right = right, left
            end
            ---@type vm.flow.state, vm.flow.state
            local yes, no = state, state
            local uri = guide.getUri(expr)
            if refKey(left) and right.type == 'nil' then
                yes = narrowRef(state, left, function ()
                    return vm.createNode(vm.declareGlobal('type', 'nil'))
                end)
                no = narrowRef(state, left, function (node) return node:copy():removeOptional() end)
            elseif left.type == 'call' and right.type == 'string'
            and left.node and left.node.special == 'type'
            and refKey(left.args and left.args[1]) then
                -- if type(x) == 'string' then
                local name = right[1] --[[@as string]]
                local arg = left.args[1]
                yes = narrowRef(state, arg, function (node) return node:copy():narrow(uri, name) end)
                no  = narrowRef(state, arg, function (node) return node:copy():remove(name) end)
            elseif refKey(left) then
                -- if x == 'literal' then (the checker is anything with a literal type name)
                local name = vm.getNodeName(right)
                if name then
                    local checkerNode = vm.compileNode(right)
                    yes = narrowRef(state, left, function (node) return node:copy():narrow(uri, name) end)
                    no  = narrowRef(state, left, function (node)
                        local out = node:copy()
                        out:removeNode(checkerNode)
                        return out
                    end)
                end
            end
            if left.type == 'getfield' and left.field and refKey(left.node)
            and right[1] ~= nil and vm.getNodeName(right) then
                -- if x.kind == 'literal' then: `x` is the member of a union that can have it
                local fieldName = left.field[1] --[[@as string]]
                local checker = right
                ---@type vm.node?
                local base = refKey(left.node) and (function ()
                    local key = refKey(left.node)
                    return key and state[key] or staticNodeOf(left.node)
                end)()
                if base then
                    local keepMatching, dropMatching = vm.getLiteralFieldNarrowers(uri, base, fieldName, checker)
                    if keepMatching and dropMatching then
                        if yes then
                            yes = narrowRef(yes, left.node, keepMatching)
                        end
                        if no then
                            no = narrowRef(no, left.node, dropMatching)
                        end
                    end
                end
            end
            if op == '~=' then
                yes, no = no, yes
            end
            return yes, no
        end
    end
    return state, state
end

flow_evalCondition = evalCondition

--- The right operands of the `and` / `or` inside a condition, as items a `---@cast` can attach to.
---@param expr  parser.object
---@param items parser.object[]
function addOperands(expr, items)
    if expr.type == 'paren' then
        if expr.exp then
            addOperands(expr.exp, items)
        end
    elseif expr.type == 'unary' then
        if expr[1] then
            addOperands(expr[1], items)
        end
    elseif expr.type == 'binary' and expr.op and (expr.op.type == 'and' or expr.op.type == 'or') then
        if expr[1] then
            addOperands(expr[1], items)
        end
        if expr[2] then
            items[#items+1] = expr[2]
            addOperands(expr[2], items)
        end
    end
end
flow_narrowRef = narrowRef

---@class vm.flow
---@field cfg        vm.cfg
---@field result     vm.dataflow.result
---@field stmtBlock  table<parser.object, vm.cfg.block>   statement -> the block it sits in
---@field condBlock  table<parser.object, vm.cfg.block>   branch condition -> the block testing it
---@field exprBlock  table<parser.object, vm.cfg.block>   loop-header expression -> the block running it
---@field ctx        vm.flow.context
local flow = {}
flow.__index = flow

--- Is the local `decl` declared in `func` or in a function nested in it? (Not decided by range:
--- `local function f` spans its own body, but `f` belongs to the enclosing function.)
---@param decl parser.object
---@param func parser.object
---@return boolean
local function isInside(decl, func)
    ---@type parser.object?
    local fn = guide.getParentFunction(decl)
    while fn do
        if fn == func then
            return true
        end
        fn = guide.getParentFunction(fn)
    end
    return false
end

---@type table<parser.object, vm.flow>
local flowCache = setmetatable({}, { __mode = 'k' })
---@type table?
local flowEpoch

--- `vm.buildFlow`, remembered per function node (an enclosing function's flow answers for every
--- closure created in it). nil when the build met a compile cycle (see below).
---@param main parser.object
---@return vm.flow?
function vm.getFlow(main)
    -- a flow holds compiled nodes: it lives exactly as long as the node cache it was built from
    if flowEpoch ~= vm.nodeCache then
        flowEpoch = vm.nodeCache
        flowCache = setmetatable({}, { __mode = 'k' })
    end
    local cached = flowCache[main]
    if not cached then
        -- A build compiles statements, and one of them can be a compile that is still open further
        -- down the stack (compiling `for k in pairs(t)` asks for `t`, whose flow asks for `k`):
        -- what such a read returns is half built and must not be kept. The flow is then dropped,
        -- and the caller falls back to the old walk for this one request.
        local watch <close> = vm.watchCompileCycles()
        local ok, built = pcall(vm.buildFlow, main)
        if not ok then
            if built == CYCLE then
                return nil
            end
            error(built, 0)
        end
        if watch.hit then
            return nil
        end
        cached = built
        flowCache[main] = cached
    end
    return cached
end

---@type table<parser.object, true>
local building = setmetatable({}, { __mode = 'k' })

--- The flow answer for `vm.traceNode(source)`, or nil when it has none (a global, a path not rooted
--- at a local, an unreachable read, a read inside a function whose flow is being built right now:
--- that one is asked by the flow's own compiles, and the old tracer answers it). Behind
--- `LLS_FLOW=1` until the old tracer is retired; see TRACER-REDESIGN.md, Phase 6.
---@param source parser.object
---@return vm.node?
function vm.traceNodeByFlow(source)
    if source.type ~= 'getlocal' and refKey(source) == nil then
        return nil
    end
    local func = guide.getParentFunction(source) or guide.getRoot(source)
    -- Only a request that is not itself inside another compile may build a flow: a build compiles
    -- statements, and doing that from deep inside an open compile met half-built nodes that stayed
    -- (loop variables typed `unknown` for good). The price is that a read first compiled from
    -- inside another compile is answered by the old walk, whatever the flow would say. Known
    -- limitation of the hybrid, see TRACER-REDESIGN.md.
    if building[func] or vm.compileDepth() > 1 then
        return nil
    end
    local ok, result = pcall(function ()
        local flow = vm.getFlow(func)
        return flow and flow:getNode(source)
    end)
    if not ok then
        if result ~= CYCLE then
            log.error('flow analysis failed: ' .. tostring(result))
        end
        return nil
    end
    -- (an answer with no type in it is a half-built input, not a result: the old walk decides)
    if not result or not hasTypes(result) then
        return nil
    end
    return result:copy()
end

---@param main parser.object a 'main' or 'function' node
---@return vm.flow
function vm.buildFlow(main)
    building[main] = true
    local ok, result = pcall(vm.buildFlowUnguarded, main)
    building[main] = nil
    if not ok then
        error(result, 0)
    end
    return result
end

---@param main parser.object a 'main' or 'function' node
---@return vm.flow
function vm.buildFlowUnguarded(main)
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

    -- Each `---@cast` attaches to the first item (statement or condition) after it in this
    -- function; one written inside an item (in a nested function) is not ours.
    ---@type parser.object[]
    local items = {}
    for _, block in ipairs(cfg.blocks) do
        for _, stmt in ipairs(block.stmts) do
            items[#items+1] = stmt
        end
        if block.condition then
            items[#items+1] = block.condition
            addOperands(block.condition, items)
        end
    end
    table.sort(items, function (a, b) return a.start < b.start end)
    ---@type table<parser.object, parser.object[]>
    local castsAt = {}
    for _, doc in ipairs(guide.getRoot(main).docs or {}) do
        if doc.type == 'doc.cast' and doc.name and doc.start >= main.start and doc.finish <= main.finish then
            ---@type parser.object?, parser.object?
            local before, after
            for _, item in ipairs(items) do
                if item.start < doc.start then
                    before = item
                elseif item.start >= doc.finish then
                    after = item
                    break
                end
            end
            -- a cast ends with its block: what follows the block is not under it
            ---@type parser.object?
            local scope
            guide.eachSourceContain(main, doc.start, function (src)
                if blockScopes[src.type] and (not scope or src.start > scope.start) then
                    scope = src
                end
            end)
            if scope and after and after.start >= scope.finish then
                after = nil
            end
            -- (inside a condition, the next item is an operand of it: `n and ---@cast n T` then the rest)
            if after and (not before or before.finish <= doc.finish
            or (after.start >= before.start and after.finish <= before.finish)) then
                castsAt[after] = castsAt[after] or {}
                table.insert(castsAt[after], doc)
            end
        end
    end

    -- What is worth tracking: whatever a branch condition, an assertion-like call or a cast names.
    ---@type table<vm.flow.key, true>
    local interesting = {}
    ---@param expr parser.object?
    local function noteRef(expr)
        local key = refKey(expr)
        if key then
            interesting[key] = true
        end
        -- (`x.kind == 'lit'` narrows `x` too, and a path starts from its root's compile)
        if expr and (expr.type == 'getfield' or expr.type == 'getindex') then
            noteRef(expr.node)
        end
    end
    --- Mirrors what evalCondition can narrow: a reference tested for truthiness, against nil or a
    --- literal, `type(ref)`, and the targets of registered guard calls.
    ---@param expr parser.object?
    local function noteCondition(expr)
        if not expr then
            return
        end
        local kind = expr.type
        if kind == 'paren' then
            noteCondition(expr.exp)
        elseif kind == 'unary' then
            noteCondition(expr[1])
        elseif kind == 'binary' and expr.op then
            local op = expr.op.type
            if op == 'and' or op == 'or' then
                noteCondition(expr[1])
                noteCondition(expr[2])
            elseif op == '==' or op == '~=' then
                for i = 1, 2 do
                    local side = expr[i]
                    if side and side.type == 'call' and side.node and side.node.special == 'type' then
                        noteRef(side.args and side.args[1])
                    else
                        noteRef(side)
                    end
                end
            end
        elseif kind == 'call' then
            for _, narrowing in ipairs(vm.getFlowNarrowings(expr)) do
                noteRef(narrowing.target)
            end
        else
            noteRef(expr)
        end
    end
    ---@param root parser.object
    local function noteRefs(root)
        -- (an assertion-like statement call: its narrowings, or `assert(cond)`)
        if root.node and root.node.special == 'assert' then
            noteCondition(root.args and root.args[1])
        else
            noteCondition(root)
        end
    end
    for _, block in ipairs(cfg.blocks) do
        if block.condition then
            noteCondition(block.condition)
        end
        for _, stmt in ipairs(block.stmts) do
            if stmt.type == 'call' and stmt.node
            and (stmt.node.special == 'assert' or #vm.getFlowNarrowings(stmt, true) > 0) then
                noteRefs(stmt)
            end
        end
    end
    for _, docs in pairs(castsAt) do
        for _, doc in ipairs(docs) do
            local head = vm.getCastTargetHead(doc)
            if head and head.type ~= 'global' then
                ---@cast head parser.object
                interesting[head] = true
            end
        end
    end
    ---@type vm.flow.context
    local ctx = { castsAt = castsAt, interesting = interesting }

    -- Locals that no block statement declares (a function's parameters, `for` loop variables) hold
    -- their compiled type from the start; nothing in this analysis reassigns them but `setlocal`.
    ---@type table<vm.flow.key, vm.node>
    local seeded = {}
    for _, declType in ipairs { 'local', 'self' } do
        guide.eachSourceType(main, declType, function (loc)
            if stmtBlock[loc] or not interesting[loc] then
                return
            end
            if (guide.getParentFunction(loc) or main) ~= main then
                return
            end
            seeded[loc] = compileForFlow(loc):copy()
        end)
    end

    -- An upvalue (declared outside this function) enters with the state its enclosing function
    -- has at the point this function is created (narrowing that holds there holds inside: the
    -- old tracer behaves the same way), or, without such an answer, with its declaration's
    -- compiled type. Narrowing inside this function applies on top. Uses in functions nested
    -- in this one are seeded too, so that this flow can in turn answer for them.
    ---@type parser.object?
    local parentFunction = guide.getParentFunction(main)
    ---@type table<vm.flow.key, vm.node>|false|nil
    local parentState
    if parentFunction and next(interesting) ~= nil then
        local parentFlow = vm.getFlow(parentFunction)
        parentState = parentFlow and parentFlow:stateAt(main) or false
        -- field paths the enclosing function has narrowed or assigned (`m.queue = {}` above the
        -- closure) hold inside it too
        for key, node in pairs(parentState or {}) do
            if type(key) == 'string' then
                seeded[key] = node
            end
        end
    end
    for _, readType in ipairs { 'getlocal', 'setlocal' } do
        guide.eachSourceType(main, readType, function (ref)
            local decl = ref.node
            if not decl or seeded[decl] or stmtBlock[decl] or not interesting[decl] then
                return
            end
            if main.type == 'main' or isInside(decl, main) then
                return
            end
            local outer = parentState and parentState[decl]
            seeded[decl] = outer or compileForFlow(decl):copy()
        end)
    end

    ---@type vm.dataflow.spec
    local spec = {
        bottom  = function () return false end,
        initial = function () return seeded end,
        join    = stateJoin,
        equal   = stateEqual,
        transfer = function (block, stateIn)
            if not stateIn then
                -- became unreachable after having been reached (a narrowing on the way here now
                -- leaves nothing): nothing flows out of it on any edge any more
                return false, { ['true'] = false, ['false'] = false }
            end
            local savedCasts = activeCasts
            activeCasts = ctx.castsAt
            local state = copyState(stateIn)
            for _, stmt in ipairs(block.stmts) do
                applyStmt(state, stmt, ctx)
            end
            if block.condition then
                applyCasts(state, ctx.castsAt[block.condition])
                local yes, no = evalCondition(state, block.condition)
                activeCasts = savedCasts
                return state, { ['true'] = yes, ['false'] = no }
            end
            activeCasts = savedCasts
            return state
        end,
    }

    return setmetatable({
        cfg       = cfg,
        result    = vm.runDataflow(cfg, spec),
        stmtBlock = stmtBlock,
        condBlock = condBlock,
        exprBlock = exprBlock,
        ctx       = ctx,
    }, flow)
end

--- The narrowed node of a read of a local, or nil when this analysis has no answer for it (a read
--- in another function, one in code the CFG never reached, a variable it does not track).
---@param read parser.object a `getlocal`
---@return vm.node?
function flow:getNode(read)
    local key = refKey(read)
    if not key then
        return nil
    end
    local state = self:stateAt(read)
    local node = state and state[key]
    if not node and state and type(key) == 'string' and self.ctx.interesting[key] then
        return staticNodeOf(read)
    end
    return node
end

--- Every tracked local's node at the point where `node` (any expression or statement of this
--- function) is evaluated; nil when the analysis has no answer there.
---@param node parser.object
---@return table<vm.flow.key, vm.node>?
function flow:stateAt(node)
    ---@type vm.cfg.block?, parser.object?, parser.object?
    local block, owner, condition
    ---@type parser.object?
    local cursor = node
    -- the `and`/`or` nodes between the read and its statement or condition that it is the
    -- *right* operand of: it only runs where the left operand held (`and`) or failed (`or`)
    ---@type parser.object[]
    local guards = {}
    while cursor do
        if self.stmtBlock[cursor] then
            block, owner = self.stmtBlock[cursor], cursor
            break
        end
        if self.condBlock[cursor] then
            block = self.condBlock[cursor]
            condition = cursor
            break
        end
        if self.exprBlock[cursor] then
            block = self.exprBlock[cursor]
            break
        end
        local parent = cursor.parent
        if parent and parent.type == 'binary' and parent[2] == cursor
        and parent.op and (parent.op.type == 'and' or parent.op.type == 'or') then
            guards[#guards+1] = parent
        end
        cursor = parent
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
        applyStmt(state, stmt, self.ctx)
    end
    if condition then
        applyCasts(state, self.ctx.castsAt[condition])
    elseif owner then
        applyCasts(state, self.ctx.castsAt[owner])
    end
    ---@type vm.flow.state
    local at = state
    for i = #guards, 1, -1 do
        local guard = guards[i]
        local savedCasts = activeCasts
        activeCasts = self.ctx.castsAt
        local yes, no = evalCondition(at, guard[1])
        activeCasts = savedCasts
        at = guard.op.type == 'and' and yes or no
        if not at then
            return nil
        end
        local casts = self.ctx.castsAt[guard[2]]
        if casts then
            at = copyState(at)
            applyCasts(at, casts)
        end
    end
    return at or nil
end
