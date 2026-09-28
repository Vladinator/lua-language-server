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

--- The node `source` compiles to when `seeds` hold the answers of some of the reads inside it.
--- A private copy: safe to keep. Errors are propagated after the shared cache is restored.
---@param source parser.object
---@param seeds  table<parser.object, vm.node>
---@return vm.node
function vm.evalInState(source, seeds)
    local shared = vm.nodeCache
    local scratch = setmetatable({}, { __index = shared })
    local wasEvaluating = vm.flowEvaluating
    vm.nodeCache = scratch
    vm.flowEvaluating = true
    local ok, result = pcall(function ()
        for read, node in pairs(seeds) do
            scratch[read] = node:copy()
        end
        return vm.compileNode(source):copy()
    end)
    vm.nodeCache = shared
    vm.flowEvaluating = wasEvaluating
    if not ok then
        error(result, 0)
    end
    return result
end
