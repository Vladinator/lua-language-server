---@class vm
local vm      = require 'vm.vm'
local guide   = require 'parser.guide'
local docTags = require 'parser.docTags'

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

---@alias vm.flow.key parser.object|vm.global|string

--- Marks one key's value in a state table as *proven impossible by narrowing* (`if x then` on an
--- `x` whose type has no falsy member, taken on the false edge) without saying the whole state is
--- unreachable: only that one variable's claim is unreliable (see TRACER-REDESIGN.md, "Blocker A" --
--- a table<K,V> index read is typed non-optional by the checker even though it can be nil at
--- runtime, so "this variable can't be here" is not sound the way "the CFG can't reach here" is).
--- A join absorbs it (the other edge's real value wins); every place that reads a state value
--- checks for it first and treats it as "no answer from this analysis", never as a real vm.node.
--- `false` stays reserved for genuine block-level unreachability (no predecessor at all).
local IMPOSSIBLE = setmetatable({}, { __tostring = function () return 'vm.flow: impossible' end })

--- What a flow knows beyond its states: `castsAt`, the `---@cast` docs right before a statement or
--- condition, and `interesting`, the locals and paths something in the function can narrow or
--- assign a guarded value to. Only those are tracked: the rest is answered by nobody here (a read
--- of an untouched variable is its compiled type, which is not this analysis's business), and so
--- costs no compile at all -- compiling every parameter and local of a function up front is what
--- ran into compiles that were still open further down the stack.
---@class vm.flow.context
---@field castsAt     table<parser.object, parser.object[]>
---@field castsInside table<parser.object, parser.object[]>  a statement / condition -> the casts written in the middle of it
---@field interesting table<vm.flow.key, true>
---@field boolCondExpr table<parser.object, parser.object>  a `local` declaration -> its own value expression, when that expression is itself something `evalCondition` can narrow (see `activeBoolCond`)
---@field correlatedGroups table<vm.flow.key, vm.flow.key[]>  `---@correlated` groups declared in this function (see `activeCorrelated`)
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

--- Is `key` a field-path key (a `#N.name` string) or the per-file object of a plain global
--- variable (`vm.getGlobalNode`)? Both use the "only kept when both sides have it / starts from
--- the static type when untouched" rules that a local's own decl key does not need: a local is
--- always seeded up front (see `seeded` in `vm.buildFlow`), these are not.
---@param key vm.flow.key
---@return boolean
local function isPathLike(key)
    return type(key) == 'string' or (type(key) == 'table' and key.type == 'global')
end

--- The path key of a field access rooted at a local or a plain global, or nil (a call, a dynamic
--- key, or a field of something else this analysis does not root a path at).
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
    elseif parent and (parent.type == 'getglobal' or parent.type == 'setglobal') then
        local globalVar = vm.getGlobalNode(parent)
        if not globalVar then
            return nil
        end
        base = declKey(globalVar --[[@as parser.object]])
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

--- What makes two objects of a node "the same": the object itself, except for the literals the
--- compiler makes up (`a == b` gives a `boolean` with `parent = source`): a new one for each
--- compile of the same source, equal in everything that matters. Without this a loop that assigns
--- from such an expression never settles (each pass adds one more equal-looking object).
---@param obj vm.node.object
---@return any
local function objectKey(obj)
    if type(obj) == 'table' and obj.start and obj.finish and obj.parent and obj.type ~= 'global' then
        return ('%s@%s-%s#%s#%s'):format(tostring(obj.type), tostring(obj.start), tostring(obj.finish),
            tostring(obj.parent), tostring(obj[1]))
    end
    return obj
end

---@param node vm.node
---@return table<any, true> keys
---@return integer count
local function keySet(node)
    ---@type table<any, true>
    local keys = {}
    local count = 0
    for i = 1, #node do
        local key = objectKey(node[i])
        if not keys[key] then
            keys[key] = true
            count = count + 1
        end
    end
    return keys, count
end

--- Is `obj` the literal `nil` type -- redundant to keep as its own array member once `.optional`
--- is also set (both mean "can be nil"; carrying both is how a join of an explicit nil-only node
--- -- `evalCondition`'s `x == nil` true edge makes one -- with an ordinary `T?` produces the
--- double `(T|nil)?` rendering instead of plain `T?`).
---@param obj vm.node.object
---@return boolean
local function isNilObject(obj)
    return obj.type == 'nil' or (obj.type == 'global' and obj.cate == 'type' and obj.name == 'nil')
end

--- `node` without the objects that repeat an earlier one by `objectKey`, and without a redundant
--- explicit `nil` member once `.optional` is set; the node itself when neither applies.
---@param node vm.node
---@return vm.node
local function dedupe(node)
    local _, count = keySet(node)
    local hasRedundantNil = false
    if node.optional == true then
        for i = 1, #node do
            if isNilObject(node[i]) then
                hasRedundantNil = true
                break
            end
        end
    end
    if count == #node and not hasRedundantNil then
        return node
    end
    local out = vm.createNode()
    ---@type table<any, true>
    local seen = {}
    for i = 1, #node do
        local obj = node[i]
        local key = objectKey(obj)
        if not seen[key] and not (node.optional == true and isNilObject(obj)) then
            seen[key] = true
            out:merge(obj)
        end
    end
    if node.optional then
        out:addOptional()
    end
    for name, value in pairs(node.flags or {}) do
        if value == true then
            out:setFlag(name)
        end
    end
    return out
end

---@param a vm.node
---@param b vm.node
---@return boolean
local function nodeEqual(a, b)
    if a == b then
        return true
    end
    if a == IMPOSSIBLE or b == IMPOSSIBLE then
        return false
    end
    if (a.optional == true) ~= (b.optional == true) then
        return false
    end
    local aKeys, aCount = keySet(a)
    local bKeys, bCount = keySet(b)
    if aCount ~= bCount then
        return false
    end
    for key in pairs(aKeys) do
        if not bKeys[key] then
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
        if current == IMPOSSIBLE then
            out[decl] = node
        elseif node == IMPOSSIBLE then
            -- (out[decl] already current)
        elseif not current then
            out[decl] = node
        elseif not nodeEqual(current, node) then
            out[decl] = dedupe(current:copy():merge(node))
        end
    end
    for key in pairs(out) do
        if isPathLike(key) and (not a[key] or not b[key]) then
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
--- (`LLS_FLOW_EVAL=1`, implies the flow itself) compute assignments on a private cache, see below
--- Default since TRACER-REDESIGN.md 10.15 (both B5 blockers fixed, validated clean workspace-wide
--- and on 3 real corpora): on unless explicitly turned off with `LLS_FLOW_EVAL=0`, which also keeps
--- the old `LLS_FLOW=1`-only (narrowing, no RHS eval) and default-off (`LLS_FLOW=0`, old tracer
--- only) modes reachable for differential comparison -- see `vm.flowEnabled` below.
local evalEnabled = os.getenv('LLS_FLOW_EVAL') ~= '0'

---@type fun(expr: parser.object?): vm.flow.key?
local refKey

--- `---@correlated` groups active for the flow currently being run -- forward-declared here
--- (same pattern as `refKey` above) because `narrowRef`'s propagation helpers read it before its
--- own declaration, further down, where it sits next to `activeCasts`/`activeBoolCond`.
---@type table<vm.flow.key, vm.flow.key[]>
local activeCorrelated = {}

--- The variables a `for` declares: `in` has a `list` of them, a numeric loop a single local.
---@param vars parser.object
---@return parser.object[]
local function varsOf(vars)
    if vars.type == 'list' or not vars.type then
        return vars
    end
    return { vars }
end

--- The `for` statement a loop-header expression belongs to (`in`'s expressions sit in a `list`).
---@param expr parser.object
---@return parser.object?
local function loopOf(expr)
    local parent = expr.parent
    if parent and parent.type == 'list' then
        parent = parent.parent
    end
    return parent
end

---@type fun(node: vm.node, doc: parser.object): vm.node
local castNode

--- What a read of a local is, when `---@cast` docs sit inside the item it is in, before it.
---@param ctx  vm.flow.context
---@param item parser.object?
---@param read parser.object
---@param node vm.node
---@return vm.node
local function withInsideCasts(ctx, item, read, node)
    if node == IMPOSSIBLE then
        return node
    end
    ---@type parser.object[]?
    local casts = item and ctx.castsInside[item]
    if not casts or read.type ~= 'getlocal' then
        return node
    end
    for _, doc in ipairs(casts) do
        if doc.finish <= read.start and vm.getCastTargetHead(doc) == read.node then
            node = castNode(node, doc)
        end
    end
    return node
end

--- The seeds for evaluating something made of `roots`: every read inside them that the flow
--- tracks is answered from `state`; the reads it does not track keep the old walk's answer, and a
--- field path it does not track is its static type.
---@param roots parser.object[]
---@param state table<vm.flow.key, vm.node>
---@param ctx?  vm.flow.context
---@param item? parser.object the statement the roots belong to (its inside casts apply)
---@return table<parser.object, vm.node>
local function seedsOf(roots, state, ctx, item)
    ---@type table<parser.object, vm.node>
    local seeds = {}
    for _, root in ipairs(roots) do
        for _, read in ipairs(vm.eachReadIn(root)) do
            local key = refKey(read)
            local node = key and state[key]
            if node == IMPOSSIBLE then
                node = nil
            end
            if node then
                seeds[read] = ctx and withInsideCasts(ctx, item, read, node) or node
            elseif read.type == 'getlocal' then
                seeds[read] = vm.compileNode(read)
            end
        end
    end
    return seeds
end

--- What each evaluated source gave for which seeds, for the flow being built. A block's transfer
--- function runs again whenever its input changes; evaluating again with the same seeds has to give
--- the *same objects* (each compile makes fresh ones for `n + 1`), or the states never compare equal
--- and a loop never settles.
---@type table<parser.object, { seeds: table<parser.object, vm.node>, result: vm.node }>?
local evalMemo

--- A flow that takes more than this many steps (a block's transfer, a statement's evaluation) to
--- build is dropped (the old walk answers that function): a generated data file or a huge function
--- can make the analysis cost far more than it is worth. Steps, not seconds: the same code has to
--- give the same answer on a slow and a fast machine.
local BUDGET_STEPS = 40000
--- ... and a function longer than this many lines is not tried at all.
local MAX_LINES = 6000
---@type integer?
local stepsLeft

local function checkBudget()
    if stepsLeft then
        stepsLeft = stepsLeft - 1
        if stepsLeft < 0 then
            error(CYCLE, 0)
        end
    end
end

---@param source parser.object
---@param seeds  table<parser.object, vm.node>
---@param scope? parser.object
---@return vm.node
local function evalMemoized(source, seeds, scope)
    checkBudget()
    local memo = evalMemo and evalMemo[source]
    if memo then
        local same = true
        for read, node in pairs(seeds) do
            local before = memo.seeds[read]
            if not before or not nodeEqual(before, node) then
                same = false
                break
            end
        end
        if same then
            for read in pairs(memo.seeds) do
                if not seeds[read] then
                    same = false
                    break
                end
            end
        end
        if same then
            return memo.result
        end
    end
    local result = dedupe(vm.evalInState(source, seeds, scope))
    if evalMemo then
        evalMemo[source] = { seeds = seeds, result = result }
    end
    return result
end

---@param stmt  parser.object
---@param state table<vm.flow.key, vm.node>
---@param ctx   vm.flow.context
---@return vm.node
local function assignNode(stmt, state, ctx)
    if vm.isCompiling(stmt) then
        error(CYCLE, 0)
    end
    if evalEnabled and stmt.value then
        -- (option (b), TRACER-REDESIGN.md section 10) the right-hand side is compiled on a private
        -- cache where the reads the flow tracks are answered from `state`
        return vm.getAssignNode(stmt, evalMemoized(stmt, seedsOf({ stmt }, state, ctx, stmt))):copy()
    end
    return vm.getAssignNode(stmt):copy()
end

---@type fun(state: vm.flow.state, expr: parser.object?): vm.flow.state, vm.flow.state
local flow_evalCondition
---@type fun(expr: parser.object, items: parser.object[])
local addOperands
---@type fun(state: table<vm.flow.key, vm.node>, expr: parser.object?, fn: fun(node: vm.node): vm.node): vm.flow.state
local flow_narrowRef

--- `node` with the `---@cast` of `doc` applied (the way the old tracer's fastWardCasts does).
---@param node vm.node
---@param doc  parser.object
---@return vm.node
function castNode(node, doc)
    local out = node:copy()
    for _, cast in ipairs(doc.casts) do
        if cast.mode == '+' then
            if cast.optional then
                out:addOptional()
            end
            if cast.extends then
                out:merge(vm.compileNode(cast.extends))
            end
        elseif cast.mode == '-' then
            if cast.optional then
                out:removeOptional()
            end
            if cast.extends then
                out:removeNode(vm.compileNode(cast.extends))
            end
        elseif cast.extends then
            out:clear()
            out:merge(vm.compileNode(cast.extends))
        end
    end
    return out
end

--- Applies the `---@cast x ...` docs that sit right before an item (statement or condition), the
--- way the old tracer's fastWardCasts does. Only plain local names are handled (`---@cast a.b` is a
--- field path, not a variable).
---@param state table<vm.flow.key, vm.node>
---@param casts parser.object[]?
local function applyCasts(state, casts)
    for _, doc in ipairs(casts or {}) do
        local decl = vm.getCastTargetHead(doc)
        if decl and not doc.name[1]:find('.', 1, true) then
            ---@cast decl parser.object|vm.global
            local node = state[decl]
            if node and node ~= IMPOSSIBLE then
                state[decl] = castNode(node, doc)
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
            state[stmt] = assignNode(stmt, state, ctx)
        end
    elseif t == 'setlocal' then
        local decl = stmt.node
        if decl then
            killBelow(state, declKey(decl))
            if state[decl] then
                state[decl] = assignNode(stmt, state, ctx)
            end
        end
    elseif t == 'setfield' or t == 'setindex' then
        local key = pathKey(stmt)
        if key then
            killBelow(state, key)
            if ctx.interesting[key] then
                state[key] = assignNode(stmt, state, ctx)
            end
        end
    elseif t == 'setglobal' then
        local globalVar = vm.getGlobalNode(stmt)
        if globalVar then
            killBelow(state, declKey(globalVar --[[@as parser.object]]))
            if ctx.interesting[globalVar] then
                state[globalVar] = assignNode(stmt, state, ctx)
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
        if not before:isTyped() then
            -- all the compiler knew of it was `nil` (`local x = known and unknownCall()`): what is
            -- left when nil is taken away is not "nothing" but something it has no type for
            after = after:copy()
            after:merge(vm.declareGlobal('type', 'unknown'))
        else
            -- proven impossible -- but only *this key's* claim, not the whole state (see IMPOSSIBLE)
            local out = copyState(state)
            out[key] = IMPOSSIBLE
            return out
        end
    end
    local out = copyState(state)
    out[key] = after
    return out
end

--- What an expression refers to, when it is something this analysis tracks: a local (by its
--- declaration node) or a field path rooted at a local (by its path string).
---@param expr parser.object?
---@return vm.flow.key?
function refKey(expr)
    if not expr then
        return nil
    end
    if expr.type == 'getlocal' then
        return expr.node
    end
    if expr.type == 'getfield' or expr.type == 'getindex' then
        return pathKey(expr)
    end
    if expr.type == 'getglobal' then
        return vm.getGlobalNode(expr)
    end
    return nil
end

--- Whether `node` can only ever be `nil` -- every member is the nil type (via `isNilObject`), and
--- there is at least one (an empty node with nothing narrowed yet is "unknown", not "only nil").
---@param node vm.node
---@return boolean
local function isNilOnly(node)
    if #node == 0 then
        return false
    end
    for i = 1, #node do
        if not isNilObject(node[i]) then
            return false
        end
    end
    return true
end

--- `---@correlated` propagation: `key` just narrowed from `current` to `newNode` (by whatever
--- transform the caller applied -- a truthy/falsy check, `== nil`, a guard, ...). If that changed
--- `key`'s own nil-possibility, apply the same nil-dimension change to every sibling in its
--- correlated group (if any) -- narrowing one narrows the others together, same as wowlua-ls's own
--- semantics ("always nil or always non-nil together"). Only the nil dimension: a narrowing that
--- picks a concrete non-nil type (`type(x)=='string'`) does not propagate anything beyond that, since
--- correlation makes no claim about *which* type a sibling holds, only whether it is nil.
---@param state   vm.flow.state
---@param key     vm.flow.key
---@param current vm.node
---@param newNode vm.node
---@return vm.flow.state
local function propagateCorrelated(state, key, current, newNode)
    local siblings = activeCorrelated[key]
    if not siblings or not state then
        return state
    end
    local wasOptional = current:isOptional() or isNilOnly(current)
    local nowNilOnly = isNilOnly(newNode)
    local nowNonNil = not newNode:isOptional() and not nowNilOnly and hasTypes(newNode)
    if not (wasOptional and (nowNilOnly or nowNonNil)) then
        return state
    end
    for _, sibling in ipairs(siblings) do
        if not state then
            return state
        end
        ---@type vm.node?
        local siblingCurrent = state[sibling]
        if siblingCurrent == IMPOSSIBLE then
            siblingCurrent = nil
        end
        if siblingCurrent then
            if nowNilOnly then
                local nilNode = vm.createNode(vm.declareGlobal('type', 'nil'))
                state = narrowedState(state, sibling, siblingCurrent, nilNode)
            elseif nowNonNil and siblingCurrent:isOptional() then
                state = narrowedState(state, sibling, siblingCurrent, siblingCurrent:copy():removeOptional())
            end
        end
    end
    return state
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
    if current == IMPOSSIBLE then
        current = nil
    end
    if not current and isPathLike(key) then
        current = staticNodeOf(expr)
    end
    if not current then
        return state
    end
    local newNode = fn(current)
    local narrowed = narrowedState(state, key, current, newNode)
    return propagateCorrelated(narrowed, key, current, newNode)
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

--- A boolean local's own value expression (`local isStr = type(x) == 'string'`), by its `local`
--- declaration statement -- so `if isStr then` can narrow whatever *that* expression would have
--- narrowed, not just `isStr` itself. Set around the flow being run, same pattern as `activeCasts`.
--- Mirrors TypeScript's narrowing of aliased conditions (`const isStr = typeof x === 'string'`).
---@type table<parser.object, parser.object>
local activeBoolCond = {}

-- `---@correlated f1, f2, ...` (wowlua-ls interop): locals or fields that are always nil/non-nil
-- together -- narrowing one narrows every sibling in its group the same way, on the nil dimension
-- only (not full type narrowing: correlation only claims "together nil or together not", nothing
-- about which concrete type). `activeCorrelated` itself is forward-declared near `refKey`, above --
-- this is just where it's set around the flow being run, same pattern as `activeCasts`/
-- `activeBoolCond`, built once per function from the `---@correlated` docs inside it (see
-- `buildFlowBody`'s `castsAt`-style scan).
docTags.registerNameListTag('correlated', 'doc.correlated',
    'Fields or locals that are always nil/non-nil together: narrowing one narrows every sibling '
    .. 'the same way. On a `---@class` (`---@correlated f1, f2`), names its fields; as a statement '
    .. 'inside a function (between the declarations and the code that uses them), names locals.')

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

--- Whether `expr` is a shape `evalCondition` below actually narrows something from (a comparison,
--- `type(x)`, `and`/`or`, a registered guard call) -- as opposed to a literal, `nil`, or a plain
--- reference with nothing to compose. Used only to decide which `local` declarations are worth
--- remembering for `if theLocal then` to alias (see `boolCondExpr`, `hasBoolCond`): registering
--- every `local x = <anything>` would defeat the point of `hasBoolCond`, which exists to keep the
--- reentrant-read protection in `vm.traceNodeByFlow` off functions that do not need it.
--- `local x = f()` wraps a single-value call RHS in a `select` node (parser/compile.lua), even
--- though there is no multi-value context here. Unwrap it so a guard call's own shape (`call`)
--- is what the condition logic below actually sees, same as it would in `if f() then`.
---@param expr parser.object
---@return parser.object
local function unwrapSelectCall(expr)
    if expr.type == 'select' and expr.vararg then
        return expr.vararg
    end
    return expr
end

---@param expr parser.object?
---@return boolean
local function isAliasableCond(expr)
    if not expr then
        return false
    end
    expr = unwrapSelectCall(expr)
    local t = expr.type
    if t == 'paren' then
        return isAliasableCond(expr.exp)
    end
    if t == 'unary' then
        return expr.op and expr.op.type == 'not' and isAliasableCond(expr[1]) or false
    end
    if t == 'binary' and expr.op then
        local op = expr.op.type
        if op == 'and' or op == 'or' then
            return isAliasableCond(expr[1]) or isAliasableCond(expr[2])
        end
        return op == '==' or op == '~='
    end
    if t == 'call' then
        return #vm.getFlowNarrowings(expr) > 0
    end
    return false
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
        local selfYes = narrowRef(state, expr, function (node) return node:copy():setTruthy() end)
        local selfNo  = narrowRef(state, expr, function (node) return node:copy():setFalsy() end)
        -- A boolean local holding a narrowing condition's own result (`local isStr =
        -- type(x)=='string'; if isStr then`): `isStr` is true exactly when that expression was, so
        -- whatever it would have narrowed applies here too, on top of `isStr`'s own truthy/falsy
        -- narrowing (not instead of it -- both are real constraints on the same edge).
        local aliasExpr = expr.type == 'getlocal' and activeBoolCond[expr.node]
        if aliasExpr then
            local yes = evalCondition(selfYes, aliasExpr)
            local _, no = evalCondition(selfNo, aliasExpr)
            return yes, no
        end
        return selfYes, selfNo
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
                yes = narrowRef(state, left, function (node)
                    local nilNode = vm.createNode(vm.declareGlobal('type', 'nil'))
                    -- (a variable the compiler knows no type of is still anything: `unknown|nil`)
                    if not hasTypes(node) then
                        nilNode:merge(vm.declareGlobal('type', 'unknown'))
                    end
                    return nilNode
                end)
                no = narrowRef(state, left, function (node) return node:copy():removeOptional() end)
            elseif left.type == 'call' and right.type == 'string'
            and left.node and left.node.special == 'type'
            and refKey(left.args and left.args[1]) then
                -- if type(x) == 'string' then
                local name = right[1]
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
                local fieldName = left.field[1]
                local checker = right
                ---@type vm.node?
                local base
                local baseKey = refKey(left.node)
                if baseKey then
                    local tracked = state[baseKey]
                    if tracked and tracked ~= IMPOSSIBLE then
                        base = tracked
                    else
                        base = staticNodeOf(left.node)
                    end
                end
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
---@field stmtIn     table<parser.object, table<vm.flow.key, vm.node>>  statement -> the state right before it
---@field blockEnd   table<vm.cfg.block, table<vm.flow.key, vm.node>>   block -> the state after its statements
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
    if not cached and (main.finish - main.start) // 10000 > MAX_LINES then
        -- (too long to be worth it: see MAX_LINES; also asked for as the parent of a closure)
        return nil
    end
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

--- A read of `main`'s own function, asked for again from inside the build of its own flow (the
--- read that triggered the build needs its own static type to seed the flow, which means
--- compiling it, which reaches this same build again -- `building` above answers that nested
--- request from the old tracer instead of waiting on the flow. The old tracer's answer is
--- correct for the idioms it independently understands (`type(x) == 'string'` directly), but not
--- for one only the new flow narrows (a boolean local aliasing a condition): so what the old
--- tracer returns here must not become this read's permanent answer once the flow -- which does
--- get it right -- exists. Recorded by `vm.traceNodeByFlow` and dropped once the build that
--- caused it finishes, forcing a fresh compile that finds the now-built flow.
--- Scoped to functions with at least one `boolCondExpr` entry (`hasBoolCond`, set while building):
--- for every other function the old tracer's answer to this same reentrant read already agrees
--- with the flow's own (every idiom besides the alias one is one the old tracer understands
--- natively) -- dropping and recompiling those too found real regressions elsewhere in the repo
--- self-check (a read recompiled a second time, outside the context it first ran in, can land on
--- a different, unrelated compiler quirk), for no behavior change, so it stays off there.
---@type table<parser.object, parser.object[]>
local pendingRebuild = setmetatable({}, { __mode = 'k' })

---@type table<parser.object, true>
local hasBoolCond = setmetatable({}, { __mode = 'k' })

---@type table<parser.object, true>
local failed = setmetatable({}, { __mode = 'k' })
local prebuilding = false

--- The flow of `main` when it has been built (and is still valid), else nil.
---@param main parser.object
---@return vm.flow?
local function peekFlow(main)
    if flowEpoch ~= vm.nodeCache then
        return nil
    end
    return flowCache[main]
end

--- Default on (see `evalEnabled` above): true whenever eval is enabled (the default), or when
--- `LLS_FLOW=1` selects the narrowing-only mode with eval explicitly turned off
--- (`LLS_FLOW_EVAL=0 LLS_FLOW=1`). `LLS_FLOW_EVAL=0` alone (no `LLS_FLOW=1`) is the old tracer only.
vm.flowEnabled = evalEnabled or os.getenv('LLS_FLOW') == '1'

--- Called by the compiler on a source's first-ever compile (any depth, see the comment on
--- `vm.beforeFreshCompile` in vm/compiler.lua) to build the flow of the function the source is in.
--- A build that would consume a node genuinely open on the current compile stack aborts through
--- `vm.isCompiling`/`CYCLE` below instead (`prebuildOne`'s `pcall` treats that as a silent miss,
--- not an error: the old tracer answers that read instead, same as any other flow-build failure).
---@param func parser.object
local function prebuildOne(func)
    if building[func] then
        return
    end
    if (func.finish - func.start) // 10000 > MAX_LINES then
        failed[func] = true
        return
    end
    if flowEpoch ~= vm.nodeCache then
        failed = setmetatable({}, { __mode = 'k' })
    elseif flowCache[func] or failed[func] then
        return
    end
    prebuilding = true
    local ok, flow = pcall(vm.getFlow, func)
    prebuilding = false
    if not ok then
        if flow ~= CYCLE then
            log.error(('flow analysis failed at %s:%d: %s'):format(guide.getUri(func), func.start // 10000 + 1, tostring(flow)))
        end
        failed[func] = true
    elseif not flow then
        failed[func] = true
    end
end

---@type table<parser.object, table>
local fileBuilt = setmetatable({}, { __mode = 'k' })

---@param source parser.object | vm.generic | vm.global | vm.variable
function vm.prebuildFlow(source)
    -- (only syntax nodes of code: not a vm.global / vm.variable, not a doc node)
    if prebuilding or not source.start or source.type == 'global' or source.type == 'variable'
    or source.type:sub(1, 4) == 'doc.' then
        return
    end
    ---@cast source parser.object
    local root = guide.getRoot(source)
    local func = guide.getParentFunction(source) or root
    if not func then
        return
    end
    prebuildOne(func)
    -- The whole file, once: a read compiled from inside another compile (a callee, a return value)
    -- finds its function's flow already built, instead of the old walk answering it.
    if evalEnabled and root and fileBuilt[root] ~= vm.nodeCache then
        fileBuilt[root] = vm.nodeCache
        ---@type parser.object[]
        local funcs = { root }
        guide.eachSourceType(root, 'function', function (fn)
            funcs[#funcs+1] = fn
        end)
        table.sort(funcs, function (a, b) return a.start < b.start end)
        for _, fn in ipairs(funcs) do
            prebuildOne(fn)
        end
    end
end

if vm.flowEnabled then
    vm.beforeFreshCompile = vm.prebuildFlow
end

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
    -- An upvalue whose own home scope (often the main chunk) is itself too large for a flow ever
    -- to be built (`vm.getFlow`'s `MAX_LINES` cap below) can never get a real seeded answer here --
    -- every function between that home scope and `func` falls back to the upvalue's bare declared
    -- type when seeding it, silently losing whatever narrowing happened in the oversized scope
    -- (found 2026-09-30 from a real ~16,700-line file, TRACER-REDESIGN.md 10.24: a closure reading
    -- a root-scope local assigned exactly once still saw it as nilable). Deferring to the old
    -- tracer here instead -- confirmed separately to get this shape right, via its own `'function'`
    -- case closure propagation, which has no such size limit -- is strictly safer than trusting a
    -- fabricated fallback seed.
    if source.type == 'getlocal' and source.node then
        local declFunc = guide.getParentFunction(source.node) or guide.getRoot(source.node)
        if declFunc and declFunc ~= func and (declFunc.finish - declFunc.start) // 10000 > MAX_LINES then
            return nil
        end
    end
    -- A request never builds a flow: a build compiles statements, and doing that from inside an
    -- open compile met half-built nodes that stayed (loop variables typed `unknown` for good).
    -- Flows are built by `vm.prebuildFlow`, before a compile that starts from nothing begins; a
    -- read whose function has no flow yet (first asked for from inside another function's compile)
    -- is answered by the old walk. Known limitation of the hybrid, see TRACER-REDESIGN.md.
    -- When the read that triggered the build itself needs re-asking this way (compiling it
    -- needs its own static type, to seed the flow being built), the old tracer's answer here
    -- must not stick once the flow exists: `vm.buildFlow` drops it below, from this list.
    if building[func] then
        if hasBoolCond[func] then
            local list = pendingRebuild[func]
            if not list then
                list = {}
                pendingRebuild[func] = list
            end
            list[#list+1] = source
        end
        return nil
    end
    local ok, result = pcall(function ()
        local flow = peekFlow(func)
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
    local dirty = pendingRebuild[main]
    if dirty then
        pendingRebuild[main] = nil
        for _, source in ipairs(dirty) do
            vm.removeNode(source)
        end
    end
    if not ok then
        error(result, 0)
    end
    return result
end

---@param main parser.object a 'main' or 'function' node
---@return vm.flow
function vm.buildFlowUnguarded(main)
    local savedMemo, savedSteps = evalMemo, stepsLeft
    evalMemo = {}
    stepsLeft = stepsLeft or BUDGET_STEPS
    local ok, result = pcall(vm.buildFlowBody, main)
    evalMemo = savedMemo
    stepsLeft = savedSteps
    if not ok then
        error(result, 0)
    end
    return result
end

---@param main parser.object
---@return vm.flow
function vm.buildFlowBody(main)
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
        for _, expr in ipairs(block.exprs or {}) do
            items[#items+1] = expr
        end
    end
    table.sort(items, function (a, b) return a.start < b.start end)
    ---@type table<parser.object, parser.object[]>
    local castsAt = {}
    ---@type table<parser.object, parser.object[]>
    local castsInside = {}
    ---@type parser.object[]
    local rootDocs = guide.getRoot(main).docs or {}
    for _, doc in ipairs(rootDocs) do
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
            elseif before and before.finish > doc.finish then
                -- written in the middle of a statement or condition, not before a part of it: it
                -- holds for the reads of that item that come after it
                castsInside[before] = castsInside[before] or {}
                table.insert(castsInside[before], doc)
            end
        end
    end

    -- `---@correlated f1, f2, ...` as a statement inside this function: locals that are always
    -- nil/non-nil together. Each name is resolved to its `local` declaration visible at the tag's
    -- own position (same primitive go-to-definition uses) -- the group is every other name's
    -- declaration, keyed by each member's own declaration (matching `refKey`'s shape for a local).
    ---@type table<vm.flow.key, vm.flow.key[]>
    local correlatedGroups = {}
    for _, doc in ipairs(rootDocs) do
        if doc.type == 'doc.correlated' and doc.names
        and doc.start >= main.start and doc.finish <= main.finish then
            ---@type parser.object[]
            local decls = {}
            for _, nameObj in ipairs(doc.names) do
                local decl = guide.getLocal(main, nameObj[1], doc.start)
                if decl then
                    decls[#decls+1] = decl
                end
            end
            if #decls > 1 then
                for i, decl in ipairs(decls) do
                    local siblings = correlatedGroups[decl] or {}
                    for j, other in ipairs(decls) do
                        if j ~= i then
                            siblings[#siblings+1] = other
                        end
                    end
                    correlatedGroups[decl] = siblings
                end
            end
        end
    end

    -- What is worth tracking: whatever a branch condition, an assertion-like call or a cast names.
    ---@type table<vm.flow.key, true>
    local interesting = {}
    for decl in pairs(correlatedGroups) do
        interesting[decl] = true
    end
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
    ---@type table<parser.object, parser.object>
    local boolCondExpr = {}
    for _, block in ipairs(cfg.blocks) do
        if block.condition then
            noteCondition(block.condition)
        end
        for _, stmt in ipairs(block.stmts) do
            if stmt.type == 'call' and stmt.node
            and (stmt.node.special == 'assert' or #vm.getFlowNarrowings(stmt, true) > 0) then
                noteRefs(stmt)
            elseif stmt.type == 'local' and stmt.value and isAliasableCond(stmt.value) then
                -- `local isStr = type(x) == 'string'`: remember `isStr`'s own value expression so
                -- `if isStr then` can narrow whatever that expression would have (activeBoolCond,
                -- evalCondition); restricted to a shape `evalCondition` actually narrows (not every
                -- `local x = <anything>`) so `hasBoolCond` below stays true only for the functions
                -- that need the reentrant-read protection it gates, in `vm.traceNodeByFlow`.
                local value = unwrapSelectCall(stmt.value)
                boolCondExpr[stmt] = value
                hasBoolCond[main] = true
                noteCondition(value)
            end
        end
    end
    -- What a closure narrows of its upvalues has to be tracked here too: it starts from this
    -- function's state at the point it is created.
    for _, kind in ipairs { 'ifblock', 'elseifblock', 'while', 'repeat' } do
        guide.eachSourceType(main, kind, function (node)
            if node.filter and (guide.getParentFunction(node) or main) ~= main then
                noteCondition(node.filter)
            end
        end)
    end
    for _, docs in pairs(castsAt) do
        for _, doc in ipairs(docs) do
            local head = vm.getCastTargetHead(doc)
            if head and head.type ~= 'global' then
                interesting[head] = true
            end
        end
    end
    if evalEnabled then
        -- (option (b)) every local is tracked, so that no read of one needs the old walk; a field
        -- path is tracked when something in the function assigns it or a condition names it
        for _, block in ipairs(cfg.blocks) do
            for _, stmt in ipairs(block.stmts) do
                if stmt.type == 'setfield' or stmt.type == 'setindex' then
                    local key = pathKey(stmt)
                    if key then
                        interesting[key] = true
                    end
                elseif stmt.type == 'setglobal' then
                    local globalVar = vm.getGlobalNode(stmt)
                    if globalVar then
                        interesting[globalVar] = true
                    end
                end
            end
        end
        setmetatable(interesting, { __index = function (_, key)
            return type(key) ~= 'string' or nil
        end })
    end
    ---@type vm.flow.context
    local ctx = { castsAt = castsAt, castsInside = castsInside, interesting = interesting, boolCondExpr = boolCondExpr, correlatedGroups = correlatedGroups }

    -- The variables each `for` loop declares, by the block that evaluates the loop's expressions.
    ---@type table<parser.object, true>
    local loopVars = {}
    ---@type table<vm.cfg.block, parser.object[]>
    local loopsAt = {}
    if evalEnabled then
        for _, block in ipairs(cfg.blocks) do
            ---@type table<parser.object, true>
            local seen = {}
            for _, expr in ipairs(block.exprs or {}) do
                local loop = loopOf(expr)
                if loop and not seen[loop] then
                    seen[loop] = true
                    loopsAt[block] = loopsAt[block] or {}
                    table.insert(loopsAt[block], loop)
                    local vars = loop.type == 'in' and loop.keys or loop.loc
                    if vars then
                        for _, var in ipairs(varsOf(vars)) do
                            loopVars[var] = true
                        end
                    end
                end
            end
        end
    end

    -- Locals that no block statement declares (a function's parameters, `for` loop variables) hold
    -- their compiled type from the start; nothing in this analysis reassigns them but `setlocal`.
    ---@type table<vm.flow.key, vm.node>
    local seeded = {}
    for _, declType in ipairs { 'local', 'self' } do
        guide.eachSourceType(main, declType, function (loc)
            if stmtBlock[loc] or not interesting[loc] then
                return
            end
            -- A `for` variable's type comes from the iterator call, whose arguments are reads in
            -- this very function: seeding it means compiling, from inside this build, what asks
            -- this flow for those reads. The old walk answers reads of loop variables.
            if not evalEnabled and loc.parent and (loc.parent.type == 'in' or loc.parent.type == 'loop') then
                return
            end
            -- (option (b): a loop variable is assigned where the loop starts, see the transfer function)
            if evalEnabled and loopVars[loc] then
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
    -- (a function written directly in the main chunk has the chunk as its parent)
    local parentFunction = guide.getParentFunction(main) or (main.type ~= 'main' and guide.getRoot(main) or nil)
    ---@type table<vm.flow.key, vm.node>|false|nil
    local parentState
    if parentFunction and (evalEnabled or next(interesting) ~= nil) then
        local parentFlow = vm.getFlow(parentFunction)
        parentState = parentFlow and parentFlow:stateAt(main) or false
        -- field paths the enclosing function has narrowed or assigned (`m.queue = {}` above the
        -- closure) hold inside it too
        for key, node in pairs(parentState or {}) do
            if isPathLike(key) then
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
            checkBudget()
            local savedCasts = activeCasts
            local savedBoolCond = activeBoolCond
            local savedCorrelated = activeCorrelated
            activeCasts = ctx.castsAt
            activeBoolCond = ctx.boolCondExpr
            activeCorrelated = ctx.correlatedGroups
            local state = copyState(stateIn)
            for _, stmt in ipairs(block.stmts) do
                applyStmt(state, stmt, ctx)
            end
            for _, expr in ipairs(block.exprs or {}) do
                applyCasts(state, ctx.castsAt[expr])
            end
            for _, loop in ipairs(loopsAt[block] or {}) do
                -- option (b): what the loop's variables are, given the state where its expressions run
                local vars = loop.type == 'in' and loop.keys or loop.loc
                ---@type parser.object[]
                local roots = {}
                for _, expr in ipairs(block.exprs or {}) do
                    if loopOf(expr) == loop then
                        roots[#roots+1] = expr
                    end
                end
                local seeds = seedsOf(roots, state)
                for _, var in ipairs(vars and varsOf(vars) or {}) do
                    state[var] = evalMemoized(var, seeds, loop):copy()
                end
            end
            if block.condition then
                applyCasts(state, ctx.castsAt[block.condition])
                local yes, no = evalCondition(state, block.condition)
                activeCasts = savedCasts
                activeBoolCond = savedBoolCond
                activeCorrelated = savedCorrelated
                return state, { ['true'] = yes, ['false'] = no }
            end
            activeCasts = savedCasts
            activeBoolCond = savedBoolCond
            activeCorrelated = savedCorrelated
            return state
        end,
    }

    local result = vm.runDataflow(cfg, spec)

    -- The state before each statement and at the end of each block, from the settled block inputs,
    -- so a query does not re-run a block's statements (each one is an evaluation).
    ---@type table<parser.object, table<vm.flow.key, vm.node>>
    local stmtIn = {}
    ---@type table<vm.cfg.block, table<vm.flow.key, vm.node>>
    local blockEnd = {}
    local savedCasts = activeCasts
    local savedBoolCond = activeBoolCond
    local savedCorrelated = activeCorrelated
    activeCasts = castsAt
    activeBoolCond = boolCondExpr
    activeCorrelated = correlatedGroups
    for _, block in ipairs(cfg.blocks) do
        local stateIn = result.stateIn[block]
        if stateIn then
            local state = copyState(stateIn)
            for _, stmt in ipairs(block.stmts) do
                stmtIn[stmt] = copyState(state)
                applyStmt(state, stmt, ctx)
            end
            blockEnd[block] = state
        end
    end
    activeCasts = savedCasts
    activeBoolCond = savedBoolCond
    activeCorrelated = savedCorrelated

    return setmetatable({
        cfg       = cfg,
        result    = result,
        stmtBlock = stmtBlock,
        condBlock = condBlock,
        exprBlock = exprBlock,
        ctx       = ctx,
        stmtIn    = stmtIn,
        blockEnd  = blockEnd,
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
    if node == IMPOSSIBLE then
        node = nil
    elseif node and read.type == 'getlocal' then
        node = withInsideCasts(self.ctx, self:itemOf(read), read, node)
    end
    if not node and state and isPathLike(key) and self.ctx.interesting[key] then
        return staticNodeOf(read)
    end
    return node
end

--- The statement or condition of this function that `node` is part of.
---@param node parser.object
---@return parser.object?
function flow:itemOf(node)
    ---@type parser.object?
    local cursor = node
    while cursor do
        if self.stmtBlock[cursor] or self.condBlock[cursor] then
            return cursor
        end
        cursor = cursor.parent
    end
    return nil
end

--- Every tracked local's node at the point where `node` (any expression or statement of this
--- function) is evaluated; nil when the analysis has no answer there.
---@param node parser.object
---@return table<vm.flow.key, vm.node>?
function flow:stateAt(node)
    ---@type vm.cfg.block?, parser.object?, parser.object?, parser.object?
    local block, owner, condition, exprItem
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
            exprItem = cursor
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
    ---@type table<vm.flow.key, vm.node>?
    local cached
    if owner then
        cached = self.stmtIn[owner]
    else
        cached = self.blockEnd[block]
    end
    if not cached then
        return nil
    end
    local state = copyState(cached)
    if exprItem then
        for _, expr in ipairs(block.exprs or {}) do
            applyCasts(state, self.ctx.castsAt[expr])
            if expr == exprItem then
                break
            end
        end
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
        local savedBoolCond = activeBoolCond
        local savedCorrelated = activeCorrelated
        activeCasts = self.ctx.castsAt
        activeBoolCond = self.ctx.boolCondExpr
        activeCorrelated = self.ctx.correlatedGroups
        local yes, no = evalCondition(at, guard[1])
        activeCasts = savedCasts
        activeBoolCond = savedBoolCond
        activeCorrelated = savedCorrelated
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
