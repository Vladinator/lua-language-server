-- Standing benchmark for the tracer redesign (TRACER-REDESIGN.md): vm.buildCFG's own cost (Phase
-- 1) and, since Phase 2, vm.runDataflow's cost with the toy boolean-reachability lattice (not a
-- real workload -- Phase 3 will substitute real vm.node states and the ported narrowing logic,
-- which is the number that will actually matter for the cutover decision; this is an early,
-- cheap signal, not a final answer). Re-run after every phase that touches vm/cfg.lua or
-- vm/dataflow.lua -- the redesign's own stated requirement is "keep the new engine similar to the
-- old one in performance, not just in behavior" (user, 2026-09-27), and this is the number to
-- compare against at each step, not just the final cutover.
-- Numbers as of Phase 1 (CFG construction only, this fork's own script/ folder, ~3,400
-- functions): ~18-20us/function, ~7-8% on top of the parse/compile time already paid regardless.
-- Numbers as of Phase 2 (+ the toy-lattice dataflow pass): see the printed "dataflow time" line
-- below -- record new numbers here as later phases land.
local files    = require 'files'
local furi     = require 'file-uri'
local vm       = require 'vm'
local guide    = require 'parser.guide'
local fs       = require 'bee.filesystem'
local fsu      = require 'fs-utility'

local root = fs.path 'script'

---@type string[]
local paths = {}
fsu.scanDirectory(root, function (fullpath)
    local s = fullpath:string()
    if s:sub(-4) == '.lua' then
        paths[#paths+1] = s
    end
end)
print('files: ' .. #paths)

---@type vm.dataflow.spec
local reachabilitySpec = {
    bottom = function () return false end,
    initial = function () return true end,
    join = function (a, b) return a or b end,
    equal = function (a, b) return a == b end,
    transfer = function (_, stateIn) return stateIn end,
}

local funcCount  = 0
local blockCount = 0
local edgeCount  = 0
local totalTime  = 0
local dataflowTime = 0
local parseTime  = 0
local failures   = 0

for _, path in ipairs(paths) do
    local f = io.open(path, 'rb')
    if f then
        local text = f:read 'a'
        f:close()
        local uri = furi.encode(path)
        local pclock = os.clock()
        files.setText(uri, text)
        local state = files.getState(uri)
        parseTime = parseTime + (os.clock() - pclock)
        if state and state.ast then
            ---@type parser.object[]
            local targets = {}
            guide.eachSourceType(state.ast, 'function', function (func)
                targets[#targets+1] = func
            end)
            targets[#targets+1] = state.ast
            for _, target in ipairs(targets) do
                local clock = os.clock()
                local ok, cfg = pcall(vm.buildCFG, target)
                totalTime = totalTime + (os.clock() - clock)
                if ok and cfg then
                    funcCount = funcCount + 1
                    blockCount = blockCount + #cfg.blocks
                    for _, block in ipairs(cfg.blocks) do
                        edgeCount = edgeCount + #block.succs
                    end
                    local dclock = os.clock()
                    vm.runDataflow(cfg, reachabilitySpec)
                    dataflowTime = dataflowTime + (os.clock() - dclock)
                else
                    failures = failures + 1
                    print('FAIL: ' .. path .. ' :: ' .. tostring(cfg))
                end
            end
        end
        files.remove(uri)
    end
end

print(('functions: %d, blocks: %d, edges: %d'):format(funcCount, blockCount, edgeCount))
print(('parse+compile time (baseline, not CFG): %.3fs'):format(parseTime))
print(('CFG build time: %.3fs total, %.1fus/function avg'):format(totalTime, totalTime / math.max(funcCount, 1) * 1e6))
print(('CFG build overhead vs parse: %.1f%%'):format(totalTime / math.max(parseTime, 1e-6) * 100))
print(('dataflow time (toy lattice): %.3fs total, %.1fus/function avg'):format(dataflowTime, dataflowTime / math.max(funcCount, 1) * 1e6))
assert(failures == 0, failures .. ' function(s) failed to build a CFG')
assert(funcCount > 0, 'no functions were found to benchmark -- the scan itself is broken')
