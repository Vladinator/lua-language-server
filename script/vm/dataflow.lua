---@class vm
local vm = require 'vm.vm'

--- Phase 2/3 of the tracer redesign (see `TRACER-REDESIGN.md`): a generic worklist fixpoint engine
--- over a `vm.cfg` (Phase 1). No real narrowing logic lives here -- `spec.transfer` is supplied by
--- the caller. Phase 2's own tests instantiate it with a toy lattice to prove the *iteration
--- itself* terminates and converges correctly (loop back-edges included); Phase 3 plugs in real
--- `vm.node` states and the ported `lookIntoChild` case table as the real transfer function.
---
--- Standard forward worklist dataflow: `stateIn[block]` is the join of every predecessor's own
--- output *along the specific edge reaching this block* (see `transfer`'s second return value
--- below); a block is only re-processed (and its successors re-enqueued) when its own output
--- actually changes, so this terminates whenever `spec.join` is monotonic over a finite-height
--- lattice (true of every concrete state Phase 3+ will use: `vm.node`'s own type/flag universe is
--- bounded per function).

---@class vm.dataflow.spec<S>
---@field bottom fun(): any        the lattice's bottom (least informative) value
---@field initial fun(): any       the state entering the CFG's own entry block
---@field join fun(a: any, b: any): any   must be monotonic: join(a, join(a, b)) == join(a, b)
---@field equal fun(a: any, b: any): boolean
---@field transfer fun(block: vm.cfg.block, stateIn: any): any, table<vm.cfg.edgeKind, any>?
--- the second return value is optional: a block whose own `succs` carry different meanings per
--- edge kind (a test block's 'true'/'false' edges, most notably -- see `vm.cfg.block.condition`)
--- can supply a *different* output state per edge kind here, instead of the one `stateOut` every
--- edge would otherwise inherit. An edge kind with no entry in this table (or when the whole
--- table is omitted) falls back to the plain `stateOut` -- so a block with no branching-specific
--- narrowing (the overwhelming majority) never needs to think about this at all.

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
    ---@type table<vm.cfg.block, table<vm.cfg.edgeKind, any>>
    local edgeOut = {}
    for _, block in ipairs(cfg.blocks) do
        -- every table is fully populated up front, never left with a nil hole: a lattice value
        -- can legitimately be `false` (the boolean-reachability toy lattice Phase 2's own tests
        -- use is exactly this), so "never set yet" has to be tracked some other way than
        -- truthiness (edgeOut[block] itself stays a real, if possibly empty, table for the same
        -- reason -- "no override for this edge kind" is a missing *key*, not a falsy value)
        stateIn[block] = spec.bottom()
        stateOut[block] = spec.bottom()
        edgeOut[block] = {}
    end

    ---@type table<vm.cfg.block, true>
    local queued = {}
    ---@type vm.cfg.block[]
    -- Blocks come out in creation order (the order of the source, so a block is normally visited
    -- after the blocks that flow into it): a min-heap on `block.id`. A plain stack revisits a loop
    -- body once per change of anything downstream of it.
    ---@type vm.cfg.block[]
    local worklist = {}
    ---@param block vm.cfg.block
    local function push(block)
        local i = #worklist + 1
        worklist[i] = block
        while i > 1 do
            local parent = i // 2
            if worklist[parent].id <= worklist[i].id then
                break
            end
            worklist[parent], worklist[i] = worklist[i], worklist[parent]
            i = parent
        end
    end
    ---@return vm.cfg.block
    local function pop()
        local top = worklist[1]
        local last = table.remove(worklist)
        local size = #worklist
        if size > 0 then
            worklist[1] = last
            local i = 1
            while true do
                local left, right = i * 2, i * 2 + 1
                local smallest = i
                if left <= size and worklist[left].id < worklist[smallest].id then
                    smallest = left
                end
                if right <= size and worklist[right].id < worklist[smallest].id then
                    smallest = right
                end
                if smallest == i then
                    break
                end
                worklist[smallest], worklist[i] = worklist[i], worklist[smallest]
                i = smallest
            end
        end
        return top
    end
    push(cfg.entry)
    queued[cfg.entry] = true

    local iterations = 0
    while #worklist > 0 do
        ---@type vm.cfg.block
        local block = pop()
        queued[block] = nil
        iterations = iterations + 1
        -- a lattice of finite height converges in far fewer visits; hitting this means the
        -- spec's join/equal/transfer is not monotone: fail loudly instead of hanging the server
        if iterations > 1000 + 200 * #cfg.blocks then
            error('dataflow did not converge (non-monotone join/equal/transfer)')
        end

        local newIn = spec.bottom()
        if block == cfg.entry then
            newIn = spec.join(newIn, spec.initial())
        end
        for _, pred in ipairs(block.preds) do
            -- the state pred emits is whatever it published for *this specific edge's kind*
            -- (edgeOut), falling back to its plain stateOut when it never overrode that kind
            for _, edge in ipairs(pred.succs) do
                if edge.to == block then
                    local predOut = edgeOut[pred][edge.kind]
                    if predOut == nil then
                        predOut = stateOut[pred]
                    end
                    newIn = spec.join(newIn, predOut)
                end
            end
        end

        if not spec.equal(stateIn[block], newIn) then
            stateIn[block] = newIn
            local newOut, edgeOverrides = spec.transfer(block, newIn)

            local changed = not spec.equal(stateOut[block], newOut)
            if edgeOverrides then
                for kind, val in pairs(edgeOverrides) do
                    local prevVal = edgeOut[block][kind]
                    if prevVal == nil or not spec.equal(prevVal, val) then
                        changed = true
                    end
                end
            end

            if changed then
                stateOut[block] = newOut
                if edgeOverrides then
                    for kind, val in pairs(edgeOverrides) do
                        edgeOut[block][kind] = val
                    end
                end
                for _, edge in ipairs(block.succs) do
                    if not queued[edge.to] then
                        queued[edge.to] = true
                        push(edge.to)
                    end
                end
            end
        end
    end

    -- a block never reached by the worklist at all (unreachable from entry) simply keeps the
    -- bottom value every table was pre-populated with above -- no hole to fill in here.
    return { stateIn = stateIn, stateOut = stateOut, iterations = iterations }
end
