-- Phase 3 of the tracer redesign (TRACER-REDESIGN.md), first slice: a real, working transfer
-- function for ONE tracked local variable, proving the CFG (Phase 1) + dataflow engine (Phase 2)
-- can produce correct narrowing answers -- not a full port of vm/tracer.lua's 28-case
-- lookIntoChild table yet (see the doc's own phase list for what's left). Covers: straight-line
-- assignment tracking within and across blocks, and if/while's most common real shape (truthy/
-- falsy narrowing of a DIRECT reference to the tracked variable used as the whole condition --
-- `if x then`, `while x do`, `if not x then`). Does NOT yet cover: comparisons (`if x == nil`),
-- calls (`assert(x)`), any narrowing family besides plain truthy/falsy, more than one tracked
-- variable at once, or vm.traceNode's own resolution -- this is a standalone experiment, still not
-- wired into anything live.
--
-- Node equality for convergence detection: vm.getInfer(node):view(uri) string comparison. A real
-- port needs a real structural equality on vm.node (open question, not solved here) -- this is a
-- pragmatic proxy sufficient to prove the mechanism works, not a production-ready answer.
local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'

---@param script string
---@return parser.object main
---@return uri uri
local function getMain(script)
    files.setText(TESTURI, script)
    local state = files.getState(TESTURI)
    assert(state)
    return state.ast, TESTURI
end

---@param declNode parser.object the tracked local's own 'local' declaration node
---@param uri      uri
---@return vm.dataflow.spec
local function buildSingleVariableSpec(declNode, uri)
    local function view(node)
        return vm.getInfer(node):view(uri)
    end
    local function nodeEqual(a, b)
        return view(a) == view(b)
    end

    local declaredNode = vm.compileNode(declNode)

    ---@param stmt parser.object
    ---@return boolean
    local function assignsTarget(stmt)
        return stmt.type == 'setlocal' and stmt.node == declNode
    end

    ---@alias narrow.shape 'truthy'|'nileq'|false

    ---@param cond parser.object?
    ---@return narrow.shape shape, boolean inverted
    local function conditionShape(cond)
        if not cond then
            return false, false
        end
        if cond.type == 'getlocal' and cond.node == declNode then
            return 'truthy', false
        end
        if cond.type == 'unary' and cond.op and cond.op.type == 'not'
        and cond[1] and cond[1].type == 'getlocal' and cond[1].node == declNode then
            return 'truthy', true
        end
        if cond.type == 'binary' and cond.op
        and (cond.op.type == '==' or cond.op.type == '~=') then
            ---@type parser.object?, parser.object?
            local varSide, otherSide
            if cond[1] and cond[1].type == 'getlocal' and cond[1].node == declNode then
                varSide, otherSide = cond[1], cond[2]
            elseif cond[2] and cond[2].type == 'getlocal' and cond[2].node == declNode then
                varSide, otherSide = cond[2], cond[1]
            end
            if varSide and otherSide and otherSide.type == 'nil' then
                return 'nileq', cond.op.type == '~='
            end
        end
        return false, false
    end

    ---@param block vm.cfg.block
    ---@param stateIn vm.node
    ---@return vm.node, table<vm.cfg.edgeKind, vm.node>?
    local function transfer(block, stateIn)
        local state = stateIn
        for _, stmt in ipairs(block.stmts) do
            if stmt == declNode then
                state = declaredNode:copy()
            elseif assignsTarget(stmt) then
                if stmt.value then
                    state = vm.compileNode(stmt.value):copy()
                else
                    state = vm.createNode(vm.declareGlobal('type', 'nil'))
                end
            end
        end
        local shape, inverted = conditionShape(block.condition)
        if shape == 'truthy' then
            local truthy = state:copy():setTruthy()
            local falsy = state:copy():setFalsy()
            if inverted then
                return state, { ['true'] = falsy, ['false'] = truthy }
            else
                return state, { ['true'] = truthy, ['false'] = falsy }
            end
        elseif shape == 'nileq' then
            -- `x == nil`: 'true' means x IS nil (a fresh nil-only node, regardless of what state
            -- was); `x ~= nil` inverts which edge gets which. Either way 'not nil' is
            -- state:removeOptional(), not setTruthy() -- `x == nil` cares specifically about nil,
            -- not general falsiness (`x` could be `false` and still not equal `nil`).
            local isNil = vm.createNode(vm.declareGlobal('type', 'nil'))
            local notNil = state:copy():removeOptional()
            if inverted then
                return state, { ['true'] = notNil, ['false'] = isNil }
            else
                return state, { ['true'] = isNil, ['false'] = notNil }
            end
        end
        return state
    end

    ---@type vm.dataflow.spec
    return {
        bottom = function () return vm.createNode() end,
        initial = function () return declaredNode:copy() end,
        join = function (a, b) return a:copy():merge(b) end,
        equal = nodeEqual,
        transfer = transfer,
    }
end

---@param cfg vm.cfg
---@param declNode parser.object
---@return parser.object[] reads every getlocal reference to declNode found in the CFG's own blocks
local function collectReads(cfg, declNode)
    ---@type parser.object[]
    local reads = {}
    for _, block in ipairs(cfg.blocks) do
        for _, stmt in ipairs(block.stmts) do
            guide.eachSource(stmt, function (s)
                if s.type == 'getlocal' and s.node == declNode then
                    reads[#reads+1] = s
                end
            end)
        end
    end
    return reads
end

---@param script string a snippet whose only local named `x` is the one to narrow; every
--- `print(x)` call's own argument is checked against `expected`, in source order
---@param expected string[]
local function checkNarrowing(script, expected)
    local main, uri = getMain(script)
    ---@type parser.object?
    local declNode
    guide.eachSourceType(main, 'local', function (loc)
        if loc[1] == 'x' then
            declNode = loc
        end
    end)
    assert(declNode, 'no local named x found')
    local cfg = vm.buildCFG(main)
    local spec = buildSingleVariableSpec(declNode, uri)
    local result = vm.runDataflow(cfg, spec)

    -- for each read, find which block contains it and re-run the block's own straight-line part
    -- of the transfer up to that exact statement (the dataflow result only has whole-block
    -- stateIn/stateOut; a block can contain more than one statement involving x)
    ---@type string[]
    local actual = {}
    local reads = collectReads(cfg, declNode)
    for _, read in ipairs(reads) do
        for _, block in ipairs(cfg.blocks) do
            local found = false
            local state = result.stateIn[block]
            for _, stmt in ipairs(block.stmts) do
                guide.eachSource(stmt, function (s)
                    if s == read then
                        found = true
                    end
                end)
                if found then
                    break
                end
                if stmt == declNode then
                    state = vm.compileNode(declNode):copy()
                elseif stmt.type == 'setlocal' and stmt.node == declNode then
                    state = stmt.value and vm.compileNode(stmt.value):copy()
                        or vm.createNode(vm.declareGlobal('type', 'nil'))
                end
            end
            if found then
                actual[#actual+1] = vm.getInfer(state):view(uri)
                break
            end
        end
    end

    assert(#actual == #expected, ('expected %d reads, found %d'):format(#expected, #actual))
    for i, exp in ipairs(expected) do
        assert(actual[i] == exp, ('read %d: expected %q, got %q'):format(i, exp, actual[i]))
    end
end

-- straight-line: no narrowing needed, just tracks the declared type through
checkNarrowing([[
---@type string?
local x
print(x)
]], { 'string?' })

-- if x then: truthy narrows string? to string inside, unnarrowed after
checkNarrowing([[
---@type string?
local x
if x then
    print(x)
end
print(x)
]], { 'string', 'string?' })

-- if not x then ... end: falls through only when x was truthy
checkNarrowing([[
---@type string?
local x
if not x then
    print(x)
end
]], { 'nil' })

-- an unconditional assignment before the if makes the if's own narrowing moot -- straight-line
-- assignment tracking has to actually run for this to come out right
checkNarrowing([[
---@type string?
local x
x = 'hi'
if x then
    print(x)
end
]], { 'string' })

-- while x do ... end: the body only runs while x is truthy
checkNarrowing([[
---@type string?
local x
while x do
    print(x)
end
]], { 'string' })

-- if x == nil / if x ~= nil
checkNarrowing([[
---@type string?
local x
if x == nil then
    print(x)
end
]], { 'nil' })

checkNarrowing([[
---@type string?
local x
if x ~= nil then
    print(x)
end
]], { 'string' })

-- the exact shape that broke the OLD engine's `while cond` extension attempt (2026-09-27,
-- SUMMARY-LOG.md/TODO-ARCHIVE.md): a loop condition testing the tracked variable against nil,
-- with a reassignment inside the body feeding back through the loop-back edge. The old engine's
-- calcNode shortcut had no notion of "the state entering the whole loop" and broke a
-- previously-correct answer trying to add one; this engine computes it directly, as a
-- consequence of doing real per-point dataflow rather than a backward/forward hybrid walk -- the
-- loop only exits when the header's own condition (x == nil) is false, i.e. x is not nil,
-- regardless of what the loop body's own back-edge contributes to the entering state.
checkNarrowing([[
---@type string?
local x
while x == nil do
    x = 'reset'
end
print(x)
]], { 'string' })

-- the *literal* original repro (SUMMARY-LOG.md, 2026-09-27): an inner guard makes the
-- reassignment provably unreachable (entering the outer loop body already proves x == nil, so
-- the inner `if x == nil` is always true, so `return` always fires first -- `x = nil` never
-- runs). The old engine's reverted extension anchored on this unreachable code and broke a
-- previously-correct answer. This engine needs no explicit reachability analysis for it: entering
-- the inner true branch narrows state to a fresh nil-only node the same way the outer one did,
-- and the inner FALSE branch (removeOptional on an already-nil-only node) becomes an EMPTY node
-- -- which correctly represents "this path cannot happen" on its own, so the unreachable
-- assignment contributes nothing back through the loop-back edge (merging an empty node into
-- anything is a no-op). Reachability falls out of the value lattice itself, not a separate check.
checkNarrowing([[
---@type string?
local x
while x == nil do
    if x == nil then
        return
    end
    x = nil
end
print(x)
]], { 'string' })

print('dataflow-narrowing: OK')
