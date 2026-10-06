-- Phase 3 of the tracer redesign (TRACER-REDESIGN.md): regression tests for vm.buildFlow
-- (vm/flow.lua), the real multi-variable flow analysis built on the CFG (Phase 1) and the
-- worklist dataflow engine (Phase 2). Each case is one small snippet with a single tracked local
-- `x` whose reads are checked against hand-computed expected types. Covers what vm/flow.lua
-- supports so far: declarations, reassignment, `---@cast`, `assert(x)`, and narrowing of a local by
-- an if/while condition (`x`, `not x`, `x == nil`, `x == 'lit'`, `type(x) == 'name'`, `and`/`or`), including the exact
-- `while cond` shapes that broke the old tracer's reverted extension. Not covered yet (measured by
-- test/other/flow-differential.lua instead): field paths, globals, upvalues. Still standalone: not wired into vm.traceNode.
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
        if expected[i] == '-' then
            -- nothing narrows this variable: the flow tracks only what a condition, an assertion or
            -- a cast names, and leaves the rest to the compiler
            -- (LLS_FLOW_EVAL=1 tracks every local, so it answers here too)
            assert(node == nil or os.getenv('LLS_FLOW_EVAL') ~= '0', ('read %d: expected no answer'):format(i))
            goto continue
        end
        assert(node, ('read %d: no answer from the flow analysis'):format(i))
        local actual = vm.getInfer(node):view(TESTURI)
        assert(actual == expected[i], ('read %d: expected %q, got %q'):format(i, expected[i], actual))
        ::continue::
    end
end

---@param script string a snippet with a table local `x`; every read of the field `x.y` (source
--- order) is checked against `expected`
---@param expected string[]
local function checkPath(script, expected)
    files.setText(TESTURI, script)
    local state = files.getState(TESTURI)
    assert(state)
    local main = state.ast
    ---@type parser.object[]
    local reads = {}
    guide.eachSourceType(main, 'getfield', function (read)
        if guide.getKeyName(read) == 'y' then
            reads[#reads+1] = read
        end
    end)
    table.sort(reads, function (a, b) return a.start < b.start end)
    local flow = vm.buildFlow(main)
    assert(#reads == #expected, ('expected %d reads, found %d'):format(#expected, #reads))
    for i, read in ipairs(reads) do
        local node = flow:getNode(read)
        if expected[i] == '-' then
            -- nothing narrows this path: no answer, the compiler's type stands
            assert(node == nil or os.getenv('LLS_FLOW_EVAL') ~= '0', ('path read %d: expected no answer'):format(i))
            goto continue
        end
        assert(node, ('path read %d: no answer from the flow analysis'):format(i))
        local actual = vm.getInfer(node):view(TESTURI)
        assert(actual == expected[i], ('path read %d: expected %q, got %q'):format(i, expected[i], actual))
        ::continue::
    end
end

-- straight-line: nothing narrows `x`, so the flow has no answer and the compiler's type stands
checkNarrowing([[
---@type string?
local x
print(x)
]], { '-' })

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

-- `and` / `or` compose: the right operand only runs where the left one held (`and`) or failed
-- (`or`), and what follows the whole condition is the join of the two ways out
checkNarrowing([[
---@type string?
local x
if x and #x > 0 then
    print(x)
end
]], { 'string?', 'string', 'string' })

checkNarrowing([[
---@type string?
local x
if not x or #x == 0 then
    return
end
print(x)
]], { 'string?', 'string', 'string' })

-- `assert(cond)` narrows what follows it
checkNarrowing([[
---@type string?
local x
assert(x)
print(x)
]], { 'string?', 'string' })

-- `type(x) == 'name'`
checkNarrowing([[
---@type string|number
local x
if type(x) == 'string' then
    print(x)
else
    print(x)
end
]], { 'string|number', 'string', 'number' })

-- `---@cast x T` before a statement
checkNarrowing([[
---@type string?
local x
---@cast x string
print(x)
]], { 'string' })

-- equality against a literal inside a loop: a non-converging fixpoint here once hung the walk
-- (`vm.node:narrow` leaves its fallback object out of the set index, so a set-based equality
-- said the state changed on every visit)
checkNarrowing([[
---@type string
local x
for _ = 1, 2 do
    if x ~= 'public' then
        return
    end
end
print(x)
]], { 'string', 'string' })

-- field paths: a guard narrows `x.y`, an assignment sets it, and writing `x` (or a prefix) forgets it
checkPath([[
---@class T
---@field y string?
---@type T
local x

if x.y then
    print(x.y)
end
print(x.y)
]], { 'string?', 'string', 'string?' })

checkPath([[
---@class T
---@field y string?
---@type T
local x

x.y = 'a'
print(x.y)
x = {}
print(x.y)
if x.y then end
]], { 'string', 'string?', 'string?' })

checkPath([[
---@class T
---@field y string?
---@type T
local x

if not x.y then
    x.y = 'a'
end
print(x.y)
]], { 'string?', 'string' })

-- the plugin-facing registry: a rule says which arguments a call narrows and how, and the flow applies
-- it on the true / false edges of a condition, or after the call when it is a statement
vm.registerFlowNarrowing {
    statement = true, -- (matches by name: it is asked about every call statement)
    match = function (callee)
        return callee.type == 'getglobal' and (callee[1] == 'flowIsString' or callee[1] == 'flowAssertString')
    end,
    ---@param call parser.object
    ---@return vm.flow.narrowing[]
    narrowings = function (call)
        local target = call.args and call.args[1]
        if not target then
            return {}
        end
        if call.node[1] == 'flowIsString' then
            return { {
                target    = target,
                whenTrue  = function (node, uri) return node:copy():narrow(uri, 'string') end,
                whenFalse = function (node) return node:copy():remove('string') end,
            } }
        end
        return { { target = target, after = function (node, uri) return node:copy():narrow(uri, 'string') end } }
    end,
}

checkNarrowing([[
---@type string|number
local x
if flowIsString(x) then
    print(x)
else
    print(x)
end
]], { 'string|number', 'string', 'number' })

checkNarrowing([[
---@type string|number
local x
flowAssertString(x)
print(x)
]], { 'string|number', 'string' })

-- a rule may narrow a FIELD of its argument without that field being written in the code: the target is a made-up `getfield`
-- node (base = the argument, field = the key it is about), which the flow tracks like a read of that path
---@type table<parser.object, parser.object>
local madeUpReads = {}
vm.registerFlowNarrowing {
    match = function (callee)
        return callee.type == 'getglobal' and callee[1] == 'flowKeyIsString'
    end,
    ---@param call parser.object
    ---@return vm.flow.narrowing[]
    narrowings = function (call)
        local base, key = call.args and call.args[1], call.args and call.args[2]
        if not base or not key or key.type ~= 'string' then
            return {}
        end
        local read = madeUpReads[key]
        if not read then
            ---@type parser.object
            read = { type = 'getfield', start = key.start, finish = key.finish, parent = call, node = base, virtual = true }
            read.field = { type = 'field', start = key.start, finish = key.finish, parent = read, [1] = key[1] }
            madeUpReads[key] = read
        end
        return { {
            target    = read,
            whenTrue  = function (node, uri) return node:copy():narrow(uri, 'string') end,
            whenFalse = function (node) return node:copy():remove('string') end,
        } }
    end,
}

checkPath([[
---@class FlowKey.Box
---@field y string|number
---@field z string|number
---@type FlowKey.Box
local x
if flowKeyIsString(x, 'y') then
    print(x.y)
else
    print(x.y)
end
]], { 'string', 'number' })

-- another key of the same table, and a key that is not a literal, narrow nothing of `y`
checkPath([[
---@class FlowKey.Box
---@field y string|number
---@field z string|number
---@type FlowKey.Box
local x
if flowKeyIsString(x, 'z') then
    print(x.y)
end
---@type string
local key
if flowKeyIsString(x, key) then
    print(x.y)
end
]], { '-', '-' })

-- a flag that a narrowing sets for ONE branch (vm.registerBranchLocalFlag): `zzFlag` holds because of a proof (`zzProof` marks that) and the
-- proof does not survive a join unless every path has it; a `zzFlag` a value really has stays
vm.registerPropagatingFlag('zzFlag')
vm.registerBranchLocalFlag('zzFlag', 'zzProof')
vm.registerFlowNarrowing {
    statement = true,
    match = function (callee)
        return callee.type == 'getglobal' and (callee[1] == 'flowProve' or callee[1] == 'flowProveNow' or callee[1] == 'flowOwn')
    end,
    ---@param call parser.object
    ---@return vm.flow.narrowing[]
    narrowings = function (call)
        local target = call.args and call.args[1]
        if not target then
            return {}
        end
        local name = call.node[1]
        ---@type fun(node: vm.node): vm.node
        local prove = function (node)
            local out = node:copy()
            out:setFlag('zzFlag')
            if name ~= 'flowOwn' then
                out:setFlag('zzProof')
            end
            return out
        end
        if name == 'flowProveNow' then
            return { { target = target, after = prove } }
        end
        return { { target = target, whenTrue = prove } }
    end,
}

---@param script   string a snippet whose only local named `x` is the one to follow; every read of `x` (source order) is checked
---@param expected boolean[] whether the read carries `zzFlag`
local function checkBranchFlag(script, expected)
    files.setText(TESTURI, script)
    local state = assert(files.getState(TESTURI))
    ---@type parser.object?
    local declNode
    guide.eachSourceType(state.ast, 'local', function (loc)
        if loc[1] == 'x' then
            declNode = loc
        end
    end)
    assert(declNode, 'no local named x found')
    ---@type parser.object[]
    local reads = {}
    guide.eachSourceType(state.ast, 'getlocal', function (read)
        if read.node == declNode then
            reads[#reads+1] = read
        end
    end)
    table.sort(reads, function (a, b) return a.start < b.start end)
    local flow = vm.buildFlow(state.ast)
    assert(#reads == #expected, ('expected %d reads, found %d'):format(#expected, #reads))
    for i, read in ipairs(reads) do
        local node = flow:getNode(read)
        local has = node ~= nil and node:hasFlag('zzFlag')
        assert(has == expected[i], ('read %d: expected flag %s, got %s'):format(i, tostring(expected[i]), tostring(has)))
    end
end

-- the proof holds in its branch, not in the other one, not after the join
checkBranchFlag([[
---@type number
local x
if flowProve(x) then
    print(x)
else
    print(x)
end
print(x)
]], { false, true, false, false }) -- (the first read is the argument of the guard itself)

-- an early exit: the path that goes on is the proven one
checkBranchFlag([[
---@type number
local x
if not flowProve(x) then
    return
end
print(x)
]], { false, true })

-- every path has it (a statement that proves it, on both sides): it stays
checkBranchFlag([[
---@type number
local x
local c = 1
if c > 0 then
    flowProveNow(x)
else
    flowProveNow(x)
end
print(x)
]], { false, false, true })

-- every path has it, and the paths differ in their types (the join really merges two nodes): it stays
checkBranchFlag([[
---@type number|string
local x
if type(x) == 'number' then
    flowProveNow(x)
else
    flowProveNow(x)
end
print(x)
]], { false, false, false, true })

-- one path only: it does not
checkBranchFlag([[
---@type number
local x
local c = 1
if c > 0 then
    flowProveNow(x)
end
print(x)
]], { false, false })

-- a flag the value really has (no proof) is not a proof: it survives the join
checkBranchFlag([[
---@type number
local x
if flowOwn(x) then
    print(x)
end
print(x)
]], { false, true, true })

-- (LLS_FLOW_EVAL=1) a `for` variable's type is evaluated where the loop starts
if os.getenv('LLS_FLOW_EVAL') ~= '0' then
    files.setText(TESTURI, [[
---@param t (string|number)[]
local function f(t)
    for _, x in ipairs(t) do
        if type(x) == 'string' then
            print(x)
        end
    end
end
]])
    local loopState = files.getState(TESTURI)
    assert(loopState)
    guide.eachSourceType(loopState.ast, 'function', function (fn)
        local flow = vm.buildFlow(fn)
        ---@type string[]
        local views = {}
        guide.eachSourceType(fn, 'getlocal', function (read)
            if read[1] == 'x' then
                local node = flow:getNode(read)
                views[#views+1] = node and vm.getInfer(node):view(TESTURI) or 'nil'
            end
        end)
        table.sort(views)
        assert(table.concat(views, ',') == 'string,string|number', 'for variable: ' .. table.concat(views, ','))
    end)
end

-- a field path rooted at a global narrows and forgets the same way a local's does
checkPath([[
---@class T
---@field y string?
---@type T
G = G

if G.y then
    print(G.y)
end
print(G.y)
]], { 'string?', 'string', 'string?' })

print('dataflow-narrowing: OK')
