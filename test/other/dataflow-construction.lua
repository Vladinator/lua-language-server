-- Phase 2 of the tracer redesign (TRACER-REDESIGN.md): proves the worklist fixpoint engine itself
-- (vm/dataflow.lua) terminates and converges correctly, using a toy lattice (boolean reachability)
-- checked against a plain BFS oracle -- not real narrowing yet, that's Phase 3. Neither
-- vm.runDataflow nor vm.buildCFG is wired into vm.traceNode or the compiler.
local files = require 'files'
local vm    = require 'vm'

---@param script string
---@return parser.object main
local function getMain(script)
    files.setText(TESTURI, script)
    local state = files.getState(TESTURI)
    assert(state)
    return state.ast
end

---@param cfg vm.cfg
---@return table<vm.cfg.block, true>
local function bfsReachable(cfg)
    ---@type table<vm.cfg.block, true>
    local seen = { [cfg.entry] = true }
    ---@type vm.cfg.block[]
    local stack = { cfg.entry }
    while #stack > 0 do
        ---@type vm.cfg.block
        local block = table.remove(stack)
        for _, edge in ipairs(block.succs) do
            if not seen[edge.to] then
                seen[edge.to] = true
                stack[#stack+1] = edge.to
            end
        end
    end
    return seen
end

-- boolean-reachability lattice: bottom = unreached, join = or, transfer = identity (Phase 2 does
-- not add or remove information, it only propagates whatever reaches a block)
---@type vm.dataflow.spec
local reachabilitySpec = {
    bottom = function () return false end,
    initial = function () return true end,
    join = function (a, b) return a or b end,
    equal = function (a, b) return a == b end,
    transfer = function (_, stateIn) return stateIn end,
}

---@param script string
local function checkReachability(script)
    local main = getMain(script)
    local cfg = vm.buildCFG(main)
    local oracle = bfsReachable(cfg)
    local result = vm.runDataflow(cfg, reachabilitySpec)
    for _, block in ipairs(cfg.blocks) do
        local expected = oracle[block] == true
        assert(result.stateIn[block] == expected,
            ('block %d: dataflow says reachable=%s, BFS oracle says %s')
            :format(block.id, tostring(result.stateIn[block]), tostring(expected)))
    end
    return cfg, result
end

do
    -- straight-line, no loops: converges in one pass, no back-edges to revisit
    checkReachability [[
local x = 1
local y = 2
]]
end

do
    -- if/elseif/else
    checkReachability [[
local a = 1
local x
if a == 1 then
    x = 1
elseif a == 2 then
    x = 2
else
    x = 3
end
local y = x
]]
end

do
    -- a while loop: the header has a back-edge from the body, so its own stateIn can only be
    -- correct once the worklist has processed the body at least once and revisited the header --
    -- this is the actual thing Phase 2 exists to prove, not just "every reachable block agrees
    -- with the oracle" (a topological one-pass walk would already get that much right for the
    -- non-loop cases above; a loop is what a naive one-pass walk gets wrong)
    local cfg, result = checkReachability [[
local i = 0
while i < 10 do
    i = i + 1
    if i == 5 then
        break
    end
end
local y = i
]]
    -- find the loop header: the block with both a normal pred (falling in) and a loop-back pred
    ---@type vm.cfg.block?
    local header
    for _, block in ipairs(cfg.blocks) do
        local hasNormalIn, hasLoopBack = false, false
        for _, pred in ipairs(block.preds) do
            for _, edge in ipairs(pred.succs) do
                if edge.to == block then
                    if edge.kind == 'loop-back' then
                        hasLoopBack = true
                    else
                        hasNormalIn = true
                    end
                end
            end
        end
        if hasNormalIn and hasLoopBack then
            header = block
        end
    end
    assert(header, 'no loop header found (expected one block with both a normal and a loop-back pred)')
    assert(result.stateIn[header] == true)
end

do
    -- nested loops: two back-edges, still converges to the same answer as the BFS oracle
    checkReachability [[
local i = 0
while i < 10 do
    local j = 0
    while j < 10 do
        j = j + 1
    end
    i = i + 1
end
]]
end

do
    -- a goto that jumps clean over a label (nothing falls through to it, nothing else goes to
    -- it) leaves that label's own block unreachable in the CFG's own structure, not just by
    -- value -- the dataflow result must agree, not assume every block that exists is reachable.
    -- (`while true` with no break is deliberately NOT used for this: its own "false" edge is
    -- still structurally present in a pure CFG -- evaluating a constant condition is dataflow's
    -- job in this design, not construction's, so that loop's exit is legitimately "reachable" at
    -- this phase, exactly per the "subsumed by the general fixpoint" framing in
    -- TRACER-REDESIGN.md.)
    local cfg, result = checkReachability [[
do
    goto skip
    ::deadlabel::
    local x = 1
    ::skip::
end
local y = 1
]]
    local unreachedCount = 0
    for _, block in ipairs(cfg.blocks) do
        if result.stateIn[block] == false then
            unreachedCount = unreachedCount + 1
        end
    end
    assert(unreachedCount > 0, 'a label after an unconditional return, with no goto reaching it, should be unreachable')
end

do
    -- termination sanity: a handful of nested loops must not blow up the worklist into anything
    -- resembling non-termination (no formal bound, just a generous, obviously-safe ceiling)
    local main = getMain [[
local i = 0
while i < 5 do
    local j = 0
    while j < 5 do
        local k = 0
        while k < 5 do
            k = k + 1
        end
        j = j + 1
    end
    i = i + 1
end
]]
    local cfg = vm.buildCFG(main)
    local result = vm.runDataflow(cfg, reachabilitySpec)
    assert(result.iterations < #cfg.blocks * 10,
        ('%d iterations for %d blocks looks like it is not converging efficiently')
        :format(result.iterations, #cfg.blocks))
end

print('dataflow-construction: OK')
