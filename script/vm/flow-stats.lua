--- Counters for the flow engine (vm/flow.lua), for the performance work of `PERF-ANALYSIS.md` in the docs repo. Off unless the
--- environment variable `LLS_FLOW_STATS=<file>` is set: the callers test `stats.enabled` first, so a normal run pays nothing but that test.
---
--- A counter is `stats.add(name, amount?)`, a time is `stats.time(name, seconds)` (CPU seconds from `os.clock`, summed, with the number of
--- samples). The file is rewritten every two seconds of CPU time while something is counted (and by `stats.dump()`), one `name<TAB>value` line
--- each, sorted, so two runs diff with a plain `diff`.
local m = {}

m.enabled = os.getenv('LLS_FLOW_STATS') ~= nil

---@type table<string, number>
local counters = {}
---@type table<string, number>
local seconds = {}
local lastDump = 0

--- Forgets every counter and time (for the tests).
function m.reset()
    counters = {}
    seconds = {}
end

--- Writes the counters to `path` (default: the file named by the variable).
---@param path? string
function m.dump(path)
    path = path or os.getenv('LLS_FLOW_STATS')
    if not path then
        return
    end
    local file = io.open(path, 'w')
    if not file then
        return
    end
    ---@type string[]
    local names = {}
    for name in pairs(counters) do
        names[#names+1] = name
    end
    for name in pairs(seconds) do
        names[#names+1] = name .. ' (s)'
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local counted = counters[name]
        ---@type string
        local text
        if counted ~= nil then
            text = tostring(counted)
        else
            text = ('%.3f'):format(seconds[name:sub(1, -5)])
        end
        file:write(name, '\t', text, '\n')
    end
    file:close()
end

local function maybeDump()
    local now = os.clock()
    if now - lastDump >= 2 then
        lastDump = now
        m.dump()
    end
end

---@param name string
---@return number
function m.get(name)
    return counters[name] or 0
end

---@param name   string
---@param amount? number
function m.add(name, amount)
    counters[name] = (counters[name] or 0) + (amount or 1)
    maybeDump()
end

---@param name string
---@param took number CPU seconds
function m.time(name, took)
    seconds[name] = (seconds[name] or 0) + took
    counters[name .. ' calls'] = (counters[name .. ' calls'] or 0) + 1
    maybeDump()
end

--- A number for a distribution, kept as sum / count / max (`name sum`, `name n`, `name max`).
---@param name  string
---@param value number
function m.sample(name, value)
    counters[name .. ' sum'] = (counters[name .. ' sum'] or 0) + value
    counters[name .. ' n']   = (counters[name .. ' n'] or 0) + 1
    if value > (counters[name .. ' max'] or 0) then
        counters[name .. ' max'] = value
    end
    maybeDump()
end

return m
