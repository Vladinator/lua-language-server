-- Option (b), phase B1 (TRACER-REDESIGN.md section 10): vm.evalInState compiles a statement on a
-- private cache with its reads pre-answered. Seeded with what the old walk answers for each read,
-- it has to give the same type as the ordinary compile, and it must leave the shared cache alone.
local files = require 'files'
local furi  = require 'file-uri'
local vm    = require 'vm'
local guide = require 'parser.guide'
local fs    = require 'bee.filesystem'
local fsu   = require 'fs-utility'

---@type string[]
local paths = {}
fsu.scanDirectory(fs.path(os.getenv('EVAL_DIR') or 'script'), function (fullpath)
    local s = fullpath:string()
    if s:sub(-4) == '.lua' and not s:find('meta', 1, true) then
        paths[#paths+1] = s
    end
end)
table.sort(paths)

local total, same, differs, leaked, crashes = 0, 0, 0, 0, 0
---@type string[]
local samples = {}
for _, path in ipairs(paths) do
    local f = io.open(path, 'rb')
    if f then
        local text = f:read 'a'
        f:close()
        local uri = furi.encode(path)
        files.setText(uri, text)
        local state = files.getState(uri)
        if state and state.ast then
            ---@type parser.object[]
            local stmts = {}
            for _, kind in ipairs { 'local', 'setlocal' } do
                guide.eachSourceType(state.ast, kind, function (stmt)
                    if stmt.value then
                        stmts[#stmts+1] = stmt
                    end
                end)
            end
            for _, stmt in ipairs(stmts) do
                total = total + 1
                local ordinary = vm.compileNode(stmt)
                local ordinaryView = vm.getInfer(ordinary):view(uri)
                ---@type table<parser.object, vm.node>
                local seeds = {}
                for _, read in ipairs(vm.eachReadIn(stmt.value)) do
                    seeds[read] = vm.compileNode(read)
                end
                -- (every 40th: count what the shared cache holds around the evaluation)
                ---@type integer?
                local before
                if total % 40 == 0 then
                    before = 0
                    for _ in pairs(vm.nodeCache) do
                        before = before + 1
                    end
                end
                local okEval, node = pcall(vm.evalInState, stmt, seeds)
                if before then
                    local after = 0
                    for _ in pairs(vm.nodeCache) do
                        after = after + 1
                    end
                    if after ~= before then
                        leaked = leaked + 1
                    end
                end
                if not okEval then
                    crashes = crashes + 1
                    if #samples < 20 then
                        samples[#samples+1] = ('%s:%d  CRASH %s'):format(path, stmt.start // 10000 + 1, tostring(node))
                    end
                else
                    local view = vm.getInfer(node):view(uri)
                    if view == ordinaryView then
                        same = same + 1
                    else
                        differs = differs + 1
                        if #samples < 20 then
                            samples[#samples+1] = ('%s:%d  ordinary=%s  scratch=%s'):format(path, stmt.start // 10000 + 1, ordinaryView, view)
                        end
                    end
                    if vm.getInfer(vm.compileNode(stmt)):view(uri) ~= ordinaryView or vm.compileNode(stmt) ~= ordinary then
                        leaked = leaked + 1
                    end
                end
            end
        end
        files.remove(uri)
    end
end
print(('eval-scratch: %d assignments, same %d, differs %d, crashes %d, shared cache disturbed %d')
    :format(total, same, differs, crashes, leaked))
for _, s in ipairs(samples) do
    print('  sample: ' .. s)
end
assert(crashes == 0 and leaked == 0, 'vm.evalInState crashed or disturbed the shared cache')
