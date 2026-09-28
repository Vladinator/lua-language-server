---@class vm
local vm    = require 'vm.vm'
local guide = require 'parser.guide'

--- Option (b) of the tracer redesign (TRACER-REDESIGN.md, section 10): compile a statement or an
--- expression with the compiler itself, on a private cache, with chosen reads already answered.
--- Nothing is written to the shared node cache, so a flow can ask "what would this assignment
--- give if `x` were narrowed like this" without compiling from inside the compile that asked.
---
--- The scratch cache reads through to the shared one and keeps its writes to itself. While it is
--- installed, `vm.traceNode` answers nil (`vm.flowEvaluating`): a read is what it was seeded with,
--- and a local read that was not seeded is empty, so the caller has to seed every read of a local.

vm.flowEvaluating = false

---@type table<parser.object, vm.node>?
local activeSeeds

--- The seed of a read during a scratch evaluation (a private copy), or nil.
---@param read parser.object
---@return vm.node?
function vm.evalSeed(read)
    local seed = activeSeeds and activeSeeds[read]
    if seed then
        return seed:copy()
    end
    return nil
end

---@type table<parser.object, parser.object[]>
local readsCache = setmetatable({}, { __mode = 'k' })

--- The reads (of a local, or a field of one) inside `source`, not inside a nested function.
---@param source parser.object
---@return parser.object[]
function vm.eachReadIn(source)
    local cached = readsCache[source]
    if cached then
        return cached
    end
    local scope = guide.getParentFunction(source) or guide.getRoot(source)
    ---@type parser.object[]
    local reads = {}
    ---@type table<parser.object, true>
    local seen = {}
    for _, kind in ipairs { 'getlocal', 'getfield', 'getindex' } do
        guide.eachSourceType(source, kind, function (read)
            if not seen[read] and (guide.getParentFunction(read) or guide.getRoot(read)) == scope then
                seen[read] = true
                reads[#reads+1] = read
            end
        end)
    end
    readsCache[source] = reads
    return reads
end

--- The statement being evaluated (only what is inside it can depend on the seeds), and the shared
--- cache to compile everything else into.
---@type parser.object?
local evaluated
--- `local s, e = f()`: `e`'s value is a `select` of a call that is not below `e` in the tree, and
--- its reads are as much part of the statement as `s`'s.
---@type parser.object?
local evaluatedCall
---@type table<any, vm.node>?
local sharedCache

---@param source parser.object
---@return boolean
local function isInside(source)
    ---@type parser.object?
    local node = source
    while node do
        if node == evaluated or (evaluatedCall and node == evaluatedCall) then
            return true
        end
        node = node.parent
    end
    return false
end

--- Called by the compiler for a source that is not cached while a scratch evaluation runs. What is
--- outside the function of the evaluated statement (a callee, a class, a global, another file) does
--- not depend on the seeded reads, and its compile needs the ordinary tracer: it is compiled the
--- ordinary way, into the shared cache, and comes back from there. What is inside is compiled in the
--- scratch cache (returns nil).
---@param source parser.object | vm.generic | vm.global | vm.variable
---@return vm.node?
function vm.compileOutsideScratch(source)
    if not sharedCache or (source.start and isInside(source --[[@as parser.object]])) then
        return nil
    end
    local scratch = vm.nodeCache
    vm.nodeCache = sharedCache
    vm.flowEvaluating = false
    local ok, result = pcall(vm.compileNode, source)
    vm.nodeCache = scratch
    vm.flowEvaluating = true
    if not ok then
        error(result, 0)
    end
    return result
end

--- The node `source` compiles to when `seeds` hold the answers of some of the reads inside it.
--- A private copy: safe to keep. Errors are propagated after the shared cache is restored.
---@param source parser.object
---@param seeds  table<parser.object, vm.node>
---@param scope? parser.object what the seeded reads are inside of, when that is more than `source` (a loop variable: the loop)
---@return vm.node
function vm.evalInState(source, seeds, scope)
    local shared = vm.nodeCache
    ---@type table<any, vm.node>
    local scratch = setmetatable({}, { __index = shared })
    local wasEvaluating = vm.flowEvaluating
    local wasEvaluated, wasShared, wasSeeds, wasCall = evaluated, sharedCache, activeSeeds, evaluatedCall
    activeSeeds = seeds
    evaluated = scope or source
    local value = source.value
    evaluatedCall = value and value.type == 'select' and value.vararg or nil
    sharedCache = shared
    vm.nodeCache = scratch
    vm.flowEvaluating = true
    local ok, result = pcall(function ()
        -- (the seeds are not written into the scratch cache: a cached read would skip its compile,
        -- and with it what follows the read there, such as matchCall narrowing the callee of a call.
        -- The compiler asks `vm.evalSeed` instead, in the getlocal / getfield cases.)
        return vm.compileNode(source):copy()
    end)
    vm.nodeCache = shared
    vm.flowEvaluating = wasEvaluating
    evaluated, sharedCache, activeSeeds, evaluatedCall = wasEvaluated, wasShared, wasSeeds, wasCall
    if not ok then
        error(result, 0)
    end
    return result
end
