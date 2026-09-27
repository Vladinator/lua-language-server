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
---@field id    integer
---@field stmts parser.object[]
---@field succs vm.cfg.edge[]
---@field preds vm.cfg.block[]

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
        if not cur then
            -- unreachable code after a diverging statement: still real code (e.g. dead code after
            -- a `return`), but Phase 1 does not attach it to the graph -- nothing narrows it, and
            -- nothing should, since no execution reaches it. Revisit if a later phase needs these
            -- blocks to exist for some other reason (e.g. still reporting diagnostics on them).
            break
        end
        local t = stmt.type
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
        elseif t == 'label' then
            -- a label is a join point: whatever falls through from the statement before it, and
            -- every goto that targets it, both land here -- give it its own block even when
            -- nothing branches to it yet (most labels), so a later goto resolving to it always
            -- has a real block to point at regardless of visit order
            local labelBlock = self:newBlock()
            self:addEdge(cur, labelBlock, 'normal')
            ctx.labelBlocks[stmt] = labelBlock
            labelBlock.stmts[#labelBlock.stmts+1] = stmt
            cur = labelBlock
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

---@param stmt parser.object a while/loop/in node (block-doubles-as-statement-list)
---@param cur  vm.cfg.block
---@param ctx  vm.cfg.ctx
---@param kind 'while'|'for'
---@return vm.cfg.block exitBlock always returned, even when unreachable (nothing wires an edge
--- into it in that case, which the reachability check in the construction test is expected to
--- report -- see test/other/cfg-construction.lua)
function Builder:walkLoop(stmt, cur, ctx, kind)
    local headerBlock = self:newBlock()
    self:addEdge(cur, headerBlock, 'normal')
    local bodyEntry = self:newBlock()
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
        -- as belonging to the block the body falls through to, not a separate block of its own
        -- (Phase 1 does not yet track individual expressions, only statement-level blocks)
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
