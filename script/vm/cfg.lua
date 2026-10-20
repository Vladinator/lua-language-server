---@class vm
local vm = require 'vm.vm'

--- Phase 1 of the tracer redesign (see `TRACER-REDESIGN.md` in the docs repo): a control-flow
--- graph builder. This file only builds structure -- no dataflow, no narrowing, nothing wired
--- into the compiler yet. `vm.buildCFG` is the only entry point; nothing outside this file should
--- reach into a `vm.cfg.block`'s own fields directly once a dataflow pass exists on top of this,
--- but for now (construction-only) they are plain, inspectable tables on purpose, to make the
--- construction-validity tests in `test/other/cfg-construction.lua` straightforward.
---
--- A block's own `stmts` are the *direct* statements of one straight-line run: every entry in
--- some AST block-array (main/function/ifblock/elseifblock/elseblock/while/repeat/loop/in/do, the
--- "a block doubles as its own statement list" shape throughout this codebase) that isn't itself
--- one of `if`/`while`/`repeat`/`loop`/`in`/`do`/`break`/`goto`/`label`/`return` (those instead end
--- the current block and start new ones, wired with the appropriate edges).

---@alias vm.cfg.edgeKind
---| 'normal'    # unconditional fallthrough
---| 'true'      # the condition just evaluated was truthy
---| 'false'     # the condition just evaluated was falsy
---| 'break'     # a `break` statement leaving its innermost loop
---| 'loop-back' # a loop body's own end (or repeat/until's false branch) back to its header
---| 'return'    # a `return` statement, or falling off the end of the function/chunk
---| 'goto'      # a `goto` statement to a label

---@class vm.cfg.edge
---@field to   vm.cfg.block
---@field kind vm.cfg.edgeKind

---@class vm.cfg.block
---@field id        integer
---@field stmts     parser.object[]
---@field succs     vm.cfg.edge[]
---@field preds     vm.cfg.block[]
---@field exprs     parser.object[]? expressions evaluated once in this block that are not
--- statements of it: a `for` loop's `init`/`max`/`step` or generic-`for` `exps`, which run in
--- the block *before* the loop header. Without this a read inside them belongs to no block
---@field condition parser.object? the expression whose truthiness this block's own 'true'/'false'
--- edges (if it has them) split on -- an `if`/`elseif`/`while`'s own `.filter`, or a `repeat`'s
--- `.filter` (the `until` expression, on the block the body falls through to, note the *inverted*
--- sense: `until`'s 'true' edge is the one that EXITS the loop, `elseif`/`if`/`while`'s 'true'
--- edge is the one that ENTERS the body). Phase 1 (pure structure) never read this; Phase 3's
--- dataflow transfer functions are what actually narrow along it.

---@class vm.cfg
---@field entry  vm.cfg.block
---@field exit   vm.cfg.block  a single sentinel every `return` (explicit or implicit) edges into
---@field blocks vm.cfg.block[]
---@field danglingGotos parser.object[] `goto`s whose label never resolved to a block (should stay
--- empty for any code the parser itself accepted; kept instead of asserting, so a construction
--- test can report it precisely rather than the builder crashing on unexpected input)

---@class vm.cfg.builder
---@field blocks vm.cfg.block[]
---@field nextId integer
local Builder = {}
Builder.__index = Builder

---@return vm.cfg.builder
local function newBuilder()
    return setmetatable({ blocks = {}, nextId = 1 }, Builder)
end

---@return vm.cfg.block
function Builder:newBlock()
    ---@type vm.cfg.block
    local block = { id = self.nextId, stmts = {}, succs = {}, preds = {} }
    self.nextId = self.nextId + 1
    self.blocks[#self.blocks+1] = block
    return block
end

---@param from vm.cfg.block?
---@param to   vm.cfg.block?
---@param kind vm.cfg.edgeKind
function Builder:addEdge(from, to, kind)
    if not from or not to then
        return
    end
    from.succs[#from.succs+1] = { to = to, kind = kind }
    to.preds[#to.preds+1] = from
end

---@class vm.cfg.pendingGoto
---@field from     vm.cfg.block
---@field gotoStmt parser.object

---@class vm.cfg.ctx
---@field breakTarget    vm.cfg.block?
---@field labelBlocks    table<parser.object, vm.cfg.block>
---@field pendingGotos   vm.cfg.pendingGoto[]
---@field exit           vm.cfg.block

---@param stmtList parser.object[] a block-doubles-as-statement-list node (or a plain array)
---@param cur      vm.cfg.block?   the open block to keep appending to; nil means unreachable
---@param ctx      vm.cfg.ctx
---@return vm.cfg.block? stillOpen the block execution falls through to after `stmtList`, or nil
--- if every path through it diverges (return/break/goto/a `never` call)
function Builder:walkBlock(stmtList, cur, ctx)
    for _, stmt in ipairs(stmtList) do
        local t = stmt.type
        if t == 'label' then
            -- a label is a join point: whatever falls through from the statement before it, and
            -- every goto that targets it, both land here -- give it its own block even when
            -- nothing branches to it yet (most labels), so a later goto resolving to it always
            -- has a real block to point at regardless of visit order. The one case handled here,
            -- not in the dispatch below: `cur` can be nil (unreachable code before the label,
            -- textually) since a `goto` elsewhere in the function can still target this label even
            -- though nothing falls into it -- `addEdge` no-ops on a nil `from`, and processing of
            -- the statements after it resumes normally from the label's own fresh block.
            local labelBlock = self:newBlock()
            self:addEdge(cur, labelBlock, 'normal')
            ctx.labelBlocks[stmt] = labelBlock
            labelBlock.stmts[#labelBlock.stmts+1] = stmt
            cur = labelBlock
            goto CONTINUE
        end
        if not cur then
            -- unreachable code after a diverging statement: still real code (e.g. dead code after
            -- a `return`), but Phase 1 does not attach it to the graph -- nothing narrows it, and
            -- nothing should, since no execution reaches it. Revisit if a later phase needs these
            -- blocks to exist for some other reason (e.g. still reporting diagnostics on them).
            goto CONTINUE
        end
        if t == 'if' then
            cur = self:walkIf(stmt, cur, ctx)
        elseif t == 'while' then
            cur = self:walkLoop(stmt, cur, ctx, 'while')
        elseif t == 'repeat' then
            cur = self:walkRepeat(stmt, cur, ctx)
        elseif t == 'loop' or t == 'in' then
            cur = self:walkLoop(stmt, cur, ctx, 'for')
        elseif t == 'do' then
            cur = self:walkBlock(stmt, cur, ctx)
        elseif t == 'break' then
            cur.stmts[#cur.stmts+1] = stmt
            self:addEdge(cur, ctx.breakTarget, 'break')
            cur = nil
        elseif t == 'goto' then
            cur.stmts[#cur.stmts+1] = stmt
            ctx.pendingGotos[#ctx.pendingGotos+1] = { from = cur, gotoStmt = stmt }
            cur = nil
        elseif t == 'return' then
            cur.stmts[#cur.stmts+1] = stmt
            self:addEdge(cur, ctx.exit, 'return')
            cur = nil
        else
            cur.stmts[#cur.stmts+1] = stmt
            if vm.isNeverExpr(stmt) then
                -- not itself a control-flow statement, but a call to error()/os.exit()/a `never`
                -- function (vm.isNeverExpr, not vm.blockExits: that one only reads a block-level
                -- flag on ifblock/elseifblock/elseblock/function, this reads the call's own
                -- hasExit/isNeverCall directly): nothing after this point in the same
                -- straight-line run is reachable, same as an explicit return, just without
                -- return's own edge to the exit sentinel (this genuinely never returns, not even
                -- to the caller in the normal sense)
                cur = nil
            end
        end
        ::CONTINUE::
    end
    return cur
end

---@param ifStmt parser.object
---@param cur    vm.cfg.block
---@param ctx    vm.cfg.ctx
---@return vm.cfg.block?
function Builder:walkIf(ifStmt, cur, ctx)
    ---@type vm.cfg.block?
    local joinBlock
    ---@type vm.cfg.block?
    local testBlock = cur
    for _, subBlock in ipairs(ifStmt) do
        ---@type vm.cfg.block?
        local bodyEntry
        if subBlock.filter then
            bodyEntry = self:newBlock()
            if testBlock then
                testBlock.condition = subBlock.filter
            end
            self:addEdge(testBlock, bodyEntry, 'true')
        else
            -- elseblock: unconditional, no separate test block -- its body starts right where the
            -- last failed condition left off
            bodyEntry = testBlock
        end
        -- walkBlock's own per-statement vm.isNeverExpr check (see the generic branch above)
        -- already stops at an error()/os.exit()/`never`-call statement wherever it sits in the
        -- clause, so bodyExit is already nil in that case -- no separate vm.blockExits check
        -- needed here.
        local bodyExit = self:walkBlock(subBlock, bodyEntry, ctx)
        if bodyExit then
            joinBlock = joinBlock or self:newBlock()
            self:addEdge(bodyExit, joinBlock, 'normal')
        end
        if subBlock.filter then
            local nextTest = self:newBlock()
            self:addEdge(testBlock, nextTest, 'false')
            testBlock = nextTest
        else
            testBlock = nil
        end
    end
    if testBlock then
        -- no else clause: every condition can fail and reach here
        joinBlock = joinBlock or self:newBlock()
        self:addEdge(testBlock, joinBlock, 'normal')
    end
    return joinBlock
end

--- Syntactic kinds of value that are never `nil`: assigning one of these to a field cannot remove the field.
local NEVER_NIL_VALUE = {
    ['string'] = true, ['number'] = true, ['integer'] = true, ['boolean'] = true,
    ['table'] = true, ['function'] = true,
}

--- Does `local rec = { ... }` certainly hold at least one entry whenever it is iterated with `pairs` (or `ipairs`: a first positional
--- entry)? Only when the constructor itself has one, and nothing in the code can take it away: every use is a read, a write of a value
--- that is never nil, or the `pairs` / `ipairs` call itself. Passing it anywhere else (a function could `table.wipe` it), a computed key,
--- a reassignment or an assignment of something that may be nil all make it "may be empty".
---@param loc  parser.object a `local`
---@param positional boolean `ipairs`: the first entry has to be positional
---@return boolean
local function holdsAnEntry(loc, positional)
    local value = loc.type == 'local' and loc.value
    if not value or value.type ~= 'table' then
        return false
    end
    ---@type boolean?
    local hasEntry
    for i, item in ipairs(value) do
        local itemValue = item.value
        if item.type == 'varargs' then
            return false
        end
        if itemValue and NEVER_NIL_VALUE[itemValue.type] then
            if positional then
                hasEntry = hasEntry or (i == 1 and item.type == 'tableexp')
            else
                hasEntry = true
            end
        end
    end
    if not hasEntry then
        return false
    end
    for _, ref in ipairs(loc.ref or {}) do
        local parent = ref.parent
        if ref.type ~= 'getlocal' or not parent then
            return false
        end
        if parent.node == ref then
            local t = parent.type
            if t == 'setfield' or t == 'setmethod' or t == 'setindex' then
                local assigned = parent.value
                if not assigned or not NEVER_NIL_VALUE[assigned.type] then
                    return false
                end
                if t == 'setindex' and (not parent.index or (parent.index.type ~= 'string' and parent.index.type ~= 'integer' and parent.index.type ~= 'number')) then
                    return false
                end
            elseif t ~= 'getfield' and t ~= 'getmethod' and t ~= 'getindex' then
                return false
            end
        elseif parent.type == 'callargs' and parent.parent and parent.parent.type == 'call'
        and parent.parent.node and (parent.parent.node.special == 'pairs' or parent.parent.node.special == 'ipairs') then
            -- an iteration (this loop's own, or another one: iterating takes nothing away)
        else
            return false
        end
    end
    return true
end

--- A loop whose body certainly runs at least once: `for i = 1, 3`, or `for k, v in pairs(rec)` over a local table constructor that
--- certainly holds an entry (see `holdsAnEntry`). Syntactic on purpose: the graph is built before any type is known.
---@param stmt parser.object a loop / in node
---@return boolean
local function runsAtLeastOnce(stmt)
    if stmt.type == 'loop' then
        local init, max, step = stmt.init, stmt.max, stmt.step
        ---@param expr? parser.object
        local function number(expr)
            return expr and (expr.type == 'integer' or expr.type == 'number') and type(expr[1]) == 'number' and expr[1] or nil
        end
        local a, b = number(init), number(max)
        if not a or not b then
            return false
        end
        if step == nil then
            return a <= b
        end
        local s = number(step)
        if not s or s == 0 then
            return false
        end
        return s > 0 and a <= b or s < 0 and a >= b
    end
    if stmt.type == 'in' and stmt.exps and #stmt.exps == 1 then
        local call = stmt.exps[1]
        local special = call.type == 'call' and call.node and call.node.special
        if (special == 'pairs' or special == 'ipairs') and call.args and #call.args == 1 then
            local arg = call.args[1]
            if arg.type == 'getlocal' and arg.node then
                return holdsAnEntry(arg.node, special == 'ipairs')
            end
        end
    end
    return false
end

---@param stmt parser.object a while/loop/in node (block-doubles-as-statement-list)
---@param cur  vm.cfg.block
---@param ctx  vm.cfg.ctx
---@param kind 'while'|'for'
---@return vm.cfg.block exitBlock always returned, even when unreachable (nothing wires an edge
--- into it in that case, which the reachability check in the construction test is expected to
--- report -- see test/other/cfg-construction.lua)
function Builder:walkLoop(stmt, cur, ctx, kind)
    if kind == 'for' then
        ---@type parser.object[]
        local exprs = {}
        if stmt.type == 'loop' then
            exprs = { stmt.init, stmt.max, stmt.step }
        elseif stmt.type == 'in' and stmt.exps then
            exprs = stmt.exps
        end
        for _, expr in ipairs(exprs) do
            cur.exprs = cur.exprs or {}
            cur.exprs[#cur.exprs+1] = expr
        end
    end
    local headerBlock = self:newBlock()
    -- a `for` whose body certainly runs once is entered straight into the body the first time: the way past the loop that skips
    -- it does not exist, so what the body assigns is what is there afterwards (the header is only reached from the loop-back edge)
    local entersBody = kind == 'for' and runsAtLeastOnce(stmt)
    if not entersBody then
        self:addEdge(cur, headerBlock, 'normal')
    end
    if kind == 'while' then
        -- numeric/generic for's own "more iterations remain" isn't a plain boolean expression
        -- (it's driven by the loop variable against init/max, or the iterator call) -- deferred,
        -- not tracked as a `.condition` yet; only `while`'s filter is a real narrowable condition
        headerBlock.condition = stmt.filter
    end
    local bodyEntry = self:newBlock()
    if entersBody then
        self:addEdge(cur, bodyEntry, 'normal')
    end
    self:addEdge(headerBlock, bodyEntry, 'true')
    local exitBlock = self:newBlock()
    self:addEdge(headerBlock, exitBlock, 'false')

    local prevBreak = ctx.breakTarget
    ctx.breakTarget = exitBlock
    local bodyExit = self:walkBlock(stmt, bodyEntry, ctx)
    ctx.breakTarget = prevBreak

    if bodyExit then
        self:addEdge(bodyExit, headerBlock, 'loop-back')
    end
    return exitBlock
end

---@param stmt parser.object a repeat node
---@param cur  vm.cfg.block
---@param ctx  vm.cfg.ctx
---@return vm.cfg.block
function Builder:walkRepeat(stmt, cur, ctx)
    local bodyEntry = self:newBlock()
    self:addEdge(cur, bodyEntry, 'normal')
    local exitBlock = self:newBlock()

    local prevBreak = ctx.breakTarget
    ctx.breakTarget = exitBlock
    local bodyExit = self:walkBlock(stmt, bodyEntry, ctx)
    ctx.breakTarget = prevBreak

    if bodyExit then
        -- the `until` condition is evaluated once per iteration, right after the body; treated
        -- as belonging to the block the body falls through to, not a separate block of its own.
        -- Inverted sense vs if/while: here 'true' EXITS the loop (the until condition held).
        bodyExit.condition = stmt.filter
        self:addEdge(bodyExit, exitBlock, 'true')
        self:addEdge(bodyExit, bodyEntry, 'loop-back')
    end
    return exitBlock
end

---@param main parser.object a 'main' or 'function' node (block-doubles-as-statement-list)
---@return vm.cfg
function vm.buildCFG(main)
    local builder = newBuilder()
    local exit = builder:newBlock()
    local entry = builder:newBlock()
    ---@type vm.cfg.pendingGoto[]
    local pendingGotos = {}
    ---@type vm.cfg.ctx
    local ctx = { breakTarget = nil, labelBlocks = {}, pendingGotos = pendingGotos, exit = exit }

    local finalBlock = builder:walkBlock(main, entry, ctx)
    if finalBlock then
        -- falling off the end of the function/chunk is an implicit return
        builder:addEdge(finalBlock, exit, 'return')
    end

    ---@type parser.object[]
    local dangling = {}
    local gotos = pendingGotos
    for _, pending in ipairs(gotos) do
        ---@type parser.object?
        local target = pending.gotoStmt.node
        local labelBlock = target and ctx.labelBlocks[target]
        if labelBlock then
            builder:addEdge(pending.from, labelBlock, 'goto')
        else
            dangling[#dangling+1] = pending.gotoStmt
        end
    end

    return {
        entry  = entry,
        exit   = exit,
        blocks = builder.blocks,
        danglingGotos = dangling,
    }
end
