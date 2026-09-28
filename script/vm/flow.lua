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
---@alias vm.flow.state table<vm.flow.key, vm.node>|false

--- Tracked things are keyed by a local's declaration node, or, for a field path rooted at a local
--- (`a.b.c`, `a[1]`), by a string: the root's id and the keys, separated by SEP. A local is
--- always present once declared; a path is present only while something narrowed or assigned it
--- (otherwise its type is the static one, see `staticNodeOf`), so a join keeps a path only when
--- both sides have it.
local SEP = ''

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

--- What a field read's type is before any narrowing: the compiler keeps it when it goes on to
--- trace the read (`preTraceNode`), else the compiled node is already the static one.
---@param expr parser.object
---@return vm.node?
local function staticNodeOf(expr)
    local node = vm.compileNode(expr)
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
            out[decl] = current:copy():merge(node)
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
    return vm.getAssignNode(stmt):copy()
end

---@type fun(state: vm.flow.state, expr: parser.object?): vm.flow.state, vm.flow.state
local flow_evalCondition
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
---@param castsAt table<parser.object, parser.object[]>
local function applyStmt(state, stmt, castsAt)
    applyCasts(state, castsAt[stmt])
    local t = stmt.type
    if t == 'local' then
        state[stmt] = assignNode(stmt)
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
            state[key] = assignNode(stmt)
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
        for _, narrowing in ipairs(vm.getFlowNarrowings(stmt)) do
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
    if after:isEmpty() and not after:isOptional() and not before:isEmpty() then
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
            local rightYes, rightNo = evalCondition(leftYes, right)
            return rightYes, joinTwo(leftNo, rightNo)
        end
        if op == 'or' then
            local leftYes, leftNo = evalCondition(state, left)
            local rightYes, rightNo = evalCondition(leftNo, right)
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
flow_narrowRef = narrowRef

---@class vm.flow
---@field cfg        vm.cfg
---@field result     vm.dataflow.result
---@field stmtBlock  table<parser.object, vm.cfg.block>   statement -> the block it sits in
---@field condBlock  table<parser.object, vm.cfg.block>   branch condition -> the block testing it
---@field exprBlock  table<parser.object, vm.cfg.block>   loop-header expression -> the block running it
---@field castsAt    table<parser.object, parser.object[]>  statement / condition -> the `---@cast` docs right before it
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

--- `vm.buildFlow`, remembered per function node (an enclosing function's flow answers for every
--- closure created in it).
---@param main parser.object
---@return vm.flow
function vm.getFlow(main)
    local cached = flowCache[main]
    if not cached then
        cached = vm.buildFlow(main)
        flowCache[main] = cached
    end
    return cached
end

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
            if after and not (before and before.finish > doc.finish) then
                castsAt[after] = castsAt[after] or {}
                table.insert(castsAt[after], doc)
            end
        end
    end

    -- Locals that no block statement declares (a function's parameters, `for` loop variables) hold
    -- their compiled type from the start; nothing in this analysis reassigns them but `setlocal`.
    ---@type table<vm.flow.key, vm.node>
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

    -- An upvalue (declared outside this function) enters with the state its enclosing function
    -- has at the point this function is created (narrowing that holds there holds inside: the
    -- old tracer behaves the same way), or, without such an answer, with its declaration's
    -- compiled type. Narrowing inside this function applies on top. Uses in functions nested
    -- in this one are seeded too, so that this flow can in turn answer for them.
    ---@type parser.object?
    local parentFunction = guide.getParentFunction(main)
    ---@type table<vm.flow.key, vm.node>|false|nil
    local parentState
    if parentFunction then
        parentState = vm.getFlow(parentFunction):stateAt(main) or false
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
            if not decl or seeded[decl] or stmtBlock[decl] then
                return
            end
            if main.type == 'main' or isInside(decl, main) then
                return
            end
            local outer = parentState and parentState[decl]
            seeded[decl] = (outer or vm.compileNode(decl)):copy()
        end)
    end

    ---@type vm.dataflow.spec
    local spec = {
        bottom  = function () return false end,
        initial = function () return seeded end,
        join    = stateJoin,
        equal   = stateEqual,
        transfer = function (block, stateIn)
            ---@cast stateIn table<vm.flow.key, vm.node>
            local state = copyState(stateIn)
            for _, stmt in ipairs(block.stmts) do
                applyStmt(state, stmt, castsAt)
            end
            if block.condition then
                applyCasts(state, castsAt[block.condition])
                local yes, no = evalCondition(state, block.condition)
                return state, { ['true'] = yes, ['false'] = no }
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
        castsAt   = castsAt,
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
    if not node and state and type(key) == 'string' then
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
        applyStmt(state, stmt, self.castsAt)
    end
    if condition then
        applyCasts(state, self.castsAt[condition])
    elseif owner then
        applyCasts(state, self.castsAt[owner])
    end
    ---@type vm.flow.state
    local at = state
    for i = #guards, 1, -1 do
        local guard = guards[i]
        local yes, no = evalCondition(at, guard[1])
        at = guard.op.type == 'and' and yes or no
        if not at then
            return nil
        end
    end
    return at or nil
end
