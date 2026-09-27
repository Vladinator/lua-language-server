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

    ---@param cond parser.object?
    ---@return boolean isTarget, boolean inverted
    local function conditionShape(cond)
        if not cond then
            return false, false
        end
        if cond.type == 'getlocal' and cond.node == declNode then
            return true, false
        end
        if cond.type == 'unary' and cond.op and cond.op.type == 'not'
        and cond[1] and cond[1].type == 'getlocal' and cond[1].node == declNode then
            return true, true
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
        local isTarget, inverted = conditionShape(block.condition)
        if isTarget then
            local truthy = state:copy():setTruthy()
            local falsy = state:copy():setFalsy()
            if inverted then
                return state, { ['true'] = falsy, ['false'] = truthy }
            else
                return state, { ['true'] = truthy, ['false'] = falsy }
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

print('dataflow-narrowing: OK')
