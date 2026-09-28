-- Phase 3 of the tracer redesign (TRACER-REDESIGN.md): regression tests for vm.buildFlow
-- (vm/flow.lua), the real multi-variable flow analysis built on the CFG (Phase 1) and the
-- worklist dataflow engine (Phase 2). Each case is one small snippet with a single tracked local
-- `x` whose reads are checked against hand-computed expected types. Covers what vm/flow.lua
-- supports so far: declarations, reassignment, and narrowing of a *direct* reference to a local
-- used as a whole if/while condition (`x`, `not x`, `x == nil`, `x ~= nil`), including the exact
-- `while cond` shapes that broke the old tracer's reverted extension. Not covered yet (measured by
-- test/other/flow-differential.lua instead): calls such as assert(x)/type(x), and/or inside a
-- condition, field paths, globals, upvalues. Still standalone: not wired into vm.traceNode.
local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'

---@param script string a snippet whose only local named `x` is the one to narrow; every read
--- of `x` (in source order) is checked against `expected`
---@param expected string[]
local function checkNarrowing(script, expected)
    files.setText(TESTURI, script)
    local state = files.getState(TESTURI)
    assert(state)
    local main = state.ast
    ---@type parser.object?
    local declNode
    guide.eachSourceType(main, 'local', function (loc)
        if loc[1] == 'x' then
            declNode = loc
        end
    end)
    assert(declNode, 'no local named x found')
    ---@type parser.object[]
    local reads = {}
    guide.eachSourceType(main, 'getlocal', function (read)
        if read.node == declNode then
            reads[#reads+1] = read
        end
    end)
    table.sort(reads, function (a, b) return a.start < b.start end)

    local flow = vm.buildFlow(main)
    assert(#reads == #expected, ('expected %d reads, found %d'):format(#expected, #reads))
    for i, read in ipairs(reads) do
        local node = flow:getNode(read)
        assert(node, ('read %d: no answer from the flow analysis'):format(i))
        local actual = vm.getInfer(node):view(TESTURI)
        assert(actual == expected[i], ('read %d: expected %q, got %q'):format(i, expected[i], actual))
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
]], { 'string?', 'string', 'string?' })

-- if not x then ... end: falls through only when x was truthy
checkNarrowing([[
---@type string?
local x
if not x then
    print(x)
end
]], { 'string?', 'nil' })

-- an unconditional assignment before the if makes the if's own narrowing moot -- straight-line
-- assignment tracking has to actually run for this to come out right
checkNarrowing([[
---@type string?
local x
x = 'hi'
if x then
    print(x)
end
]], { 'string', 'string' })

-- while x do ... end: the body only runs while x is truthy
checkNarrowing([[
---@type string?
local x
while x do
    print(x)
end
]], { 'string?', 'string' })

-- if x == nil / if x ~= nil
checkNarrowing([[
---@type string?
local x
if x == nil then
    print(x)
end
]], { 'string?', 'nil' })

checkNarrowing([[
---@type string?
local x
if x ~= nil then
    print(x)
end
]], { 'string?', 'string' })

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
]], { 'string?', 'string' })

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
]], { 'string?', 'nil', 'string' })

print('dataflow-narrowing: OK')
