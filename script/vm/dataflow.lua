---@class vm
local vm = require 'vm.vm'

--- Phase 2 of the tracer redesign (see `TRACER-REDESIGN.md`): a generic worklist fixpoint engine
--- over a `vm.cfg` (Phase 1). No real narrowing logic lives here -- `spec.transfer` is supplied by
--- the caller; Phase 2's own tests instantiate it with a toy lattice to prove the *iteration
--- itself* terminates and converges correctly (loop back-edges included) before Phase 3 plugs in
--- real `vm.node` states and the ported `lookIntoChild` case table as the real transfer function.
---
--- Standard forward worklist dataflow: `stateIn[block]` is the join of every predecessor's
--- `stateOut`; `stateOut[block] = spec.transfer(block, stateIn[block])`. A block is only
--- re-processed (and its successors re-enqueued) when its own state actually changes, so this
--- terminates whenever `spec.join` is monotonic over a finite-height lattice (true of every
--- concrete state Phase 3+ will use: `vm.node`'s own type/flag universe is bounded per function).

---@class vm.dataflow.spec<S>
---@field bottom fun(): any        the lattice's bottom (least informative) value
---@field initial fun(): any       the state entering the CFG's own entry block
---@field join fun(a: any, b: any): any   must be monotonic: join(a, join(a, b)) == join(a, b)
---@field equal fun(a: any, b: any): boolean
---@field transfer fun(block: vm.cfg.block, stateIn: any): any

---@class vm.dataflow.result
---@field stateIn  table<vm.cfg.block, any>
---@field stateOut table<vm.cfg.block, any>
---@field iterations integer  how many times any block's transfer function actually ran; for a
--- termination sanity check in tests, not meant to be load-bearing for correctness itself

---@param cfg  vm.cfg
---@param spec vm.dataflow.spec
---@return vm.dataflow.result
function vm.runDataflow(cfg, spec)
    ---@type table<vm.cfg.block, any>
    local stateIn = {}
    ---@type table<vm.cfg.block, any>
    local stateOut = {}
    for _, block in ipairs(cfg.blocks) do
        -- both tables are fully populated up front, never left with a nil hole: a lattice value
        -- can legitimately be `false` (the boolean-reachability toy lattice the Phase 2 tests use
        -- is exactly this), so "never set yet" has to be tracked some other way than truthiness
        stateIn[block] = spec.bottom()
        stateOut[block] = spec.bottom()
    end

    ---@type table<vm.cfg.block, true>
    local queued = {}
    ---@type vm.cfg.block[]
    local worklist = { cfg.entry }
    queued[cfg.entry] = true

    local iterations = 0
    while #worklist > 0 do
        ---@type vm.cfg.block
        local block = table.remove(worklist)
        queued[block] = nil
        iterations = iterations + 1

        local newIn = spec.bottom()
        if block == cfg.entry then
            newIn = spec.join(newIn, spec.initial())
        end
        for _, pred in ipairs(block.preds) do
            newIn = spec.join(newIn, stateOut[pred])
        end

        if not spec.equal(stateIn[block], newIn) then
            stateIn[block] = newIn
            local newOut = spec.transfer(block, newIn)
            if not spec.equal(stateOut[block], newOut) then
                stateOut[block] = newOut
                for _, edge in ipairs(block.succs) do
                    if not queued[edge.to] then
                        queued[edge.to] = true
                        worklist[#worklist+1] = edge.to
                    end
                end
            end
        end
    end

    -- a block never reached by the worklist at all (unreachable from entry) simply keeps the
    -- bottom value both tables were pre-populated with above -- no hole to fill in here.
    return { stateIn = stateIn, stateOut = stateOut, iterations = iterations }
end
