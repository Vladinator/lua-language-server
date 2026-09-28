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

--- The reads (of a local, or a field of one) inside `source`, not inside a nested function.
---@param source parser.object
---@return parser.object[]
function vm.eachReadIn(source)
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
    return reads
end

--- The function (or main chunk) whose statement is being evaluated, and the shared cache to
--- compile everything else into.
---@type parser.object?
local home
---@type table<any, vm.node>?
local sharedCache

---@param source parser.object
---@return boolean
local function isInside(source)
    if not home then
        return false
    end
    ---@type parser.object?
    local fn = source.type == 'function' and source or guide.getParentFunction(source)
    while fn do
        if fn == home then
            return true
        end
        fn = guide.getParentFunction(fn)
    end
    return home.type == 'main' and guide.getRoot(source) == home
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
---@return vm.node
function vm.evalInState(source, seeds)
    local shared = vm.nodeCache
    ---@type table<any, vm.node>
    local scratch = setmetatable({}, { __index = shared })
    local wasEvaluating = vm.flowEvaluating
    local wasHome, wasShared = home, sharedCache
    home = guide.getParentFunction(source) or guide.getRoot(source)
    sharedCache = shared
    vm.nodeCache = scratch
    vm.flowEvaluating = true
    local ok, result = pcall(function ()
        for read, node in pairs(seeds) do
            -- (`x --[[@as T]]`: the compiler applies the cast to the read before anything else, so
            -- it is the cast that is cached for the read, not the seed)
            if not vm.bindAs(read) then
                scratch[read] = node:copy()
            end
        end
        return vm.compileNode(source):copy()
    end)
    vm.nodeCache = shared
    vm.flowEvaluating = wasEvaluating
    home, sharedCache = wasHome, wasShared
    if not ok then
        error(result, 0)
    end
    return result
end
