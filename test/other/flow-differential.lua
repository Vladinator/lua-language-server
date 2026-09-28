-- Phase 3/5 of the tracer redesign (TRACER-REDESIGN.md): differential comparison of the new flow
-- analysis (vm/flow.lua) against the old tracer, over every read of a local in this repo's own
-- script/. For each `getlocal` read, the old answer is `vm.compileNode(read)` (what the compiler
-- really uses, tracer included) and the new one is `flow:getNode(read)`; both are rendered with
-- `vm.getInfer(node):view(uri)` and compared as strings.
--
-- This is a *measurement*, not yet a gate: vm/flow.lua only supports direct-reference truthy/nil
-- conditions so far, so a large "differs" / "no answer" count is expected and is the point -- the
-- categories printed below say which unported construct accounts for the most disagreement, which
-- is what decides what to port next. The only hard assertion is "no function crashed the
-- analysis". Once the disagreement count is low, this file becomes a ratchet (fail if it grows).
local files = require 'files'
local furi  = require 'file-uri'
local vm    = require 'vm'
local guide = require 'parser.guide'
local fs    = require 'bee.filesystem'
local fsu   = require 'fs-utility'

---@type string[]
local paths = {}
-- FLOW_DIR=<dir>: scan another directory (`lua-tests` exercises the secret / guard rules)
local scanDir = os.getenv('FLOW_DIR') or 'script'
fsu.scanDirectory(fs.path(scanDir), function (fullpath)
    local s = fullpath:string()
    if s:sub(-4) == '.lua' and not s:find('[/\\]meta[/\\]') then
        paths[#paths+1] = s
    end
end)
table.sort(paths)

local total, matched, noAnswer, differs, upvalues, crashes = 0, 0, 0, 0, 0, 0
---@type table<string, integer>
local categories = {}
---@type string[]
local samples = {}
local newTime, oldTime = 0, 0
-- FLOW_CTX=<text>: only sample mismatches of categories containing it
local ctxFilter = os.getenv('FLOW_CTX')
-- FLOW_FIELDS=1 also compares reads of field paths (`a.b`, `a[1]`)
local withFields = os.getenv('FLOW_FIELDS') == '1'

--- The type as text, plus every flag set on the node (what the plugin rules under test change).
---@param node vm.node
---@param uri uri
---@return string
local function viewOf(node, uri)
    local text = vm.getInfer(node):view(uri)
    ---@type string[]
    local flags = {}
    for name, value in pairs(node.flags or {}) do
        if value == true then
            flags[#flags+1] = name
        end
    end
    table.sort(flags)
    for _, name in ipairs(flags) do
        text = text .. '#' .. name
    end
    return text
end

---@param read parser.object
---@return string
local function context(read)
    local cursor = read.parent
    while cursor do
        local t = cursor.type
        if t == 'callargs' then
            local call = cursor.parent
            local callee = call and call.node
            if callee and callee.special then
                return 'arg of ' .. tostring(callee.special)
            end
            return 'call argument'
        end
        if t == 'ifblock' or t == 'elseifblock' or t == 'while' or t == 'repeat' then
            if cursor.filter and read.start >= cursor.filter.start and read.finish <= cursor.filter.finish then
                return 'inside a condition'
            end
            return 'inside a ' .. t .. ' body'
        end
        if t == 'function' or t == 'main' then
            break
        end
        cursor = cursor.parent
    end
    return 'plain'
end

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
            local targets = { state.ast }
            guide.eachSourceType(state.ast, 'function', function (func)
                targets[#targets+1] = func
            end)
            local main = state.ast
            ---@type table<integer, true>
            local castTouch = {}
            for _, doc in ipairs(main.docs or {}) do
                if doc.type == 'doc.as' and doc.touch then
                    castTouch[doc.touch] = true
                end
            end
            for _, target in ipairs(targets) do
                local clock = os.clock()
                local ok, result = xpcall(vm.buildFlowUnguarded, debug.traceback, target)
                newTime = newTime + (os.clock() - clock)
                if not ok then
                    crashes = crashes + 1
                    print('CRASH: ' .. path .. ':' .. (target.start // 10000 + 1) .. ' :: ' .. tostring(result))
                else
                    ---@type vm.flow
                    local flow = result
                    ---@param read parser.object
                    local function compare(read)
                        if (guide.getParentFunction(read) or main) ~= target then
                            return
                        end
                        total = total + 1
                        local decl = read.node
                        if decl and (guide.getParentFunction(decl) or main) ~= target then
                            upvalues = upvalues + 1
                        end
                        if castTouch[read.finish] then
                            -- `x --[[@as T]]` is applied by the compiler (vm.bindAs) before the
                            -- tracer is ever asked: a layer above flow, not a flow gap.
                            categories['inline @as cast (compiler layer, skipped)'] =
                                (categories['inline @as cast (compiler layer, skipped)'] or 0) + 1
                            return
                        end
                        local c1 = os.clock()
                        local newNode = flow:getNode(read)
                        newTime = newTime + (os.clock() - c1)
                        local c2 = os.clock()
                        local okOld, oldNode = pcall(vm.compileNode, read)
                        oldTime = oldTime + (os.clock() - c2)
                        if not okOld or not oldNode then
                            return
                        end
                        local oldView = viewOf(oldNode, uri)
                        if not newNode and read.type ~= 'getlocal' then
                            -- a path whose root is not a local (global, call result, ...): not tracked
                            local root = read
                            while root.node and root.type ~= 'getlocal' do
                                root = root.node
                            end
                            local kind = root.type == 'getglobal' and 'global' or root.type
                            local key = 'untracked field path, root is ' .. kind
                            categories[key] = (categories[key] or 0) + 1
                            if kind == 'getlocal' and #samples < 40 and ctxFilter == 'no answer' then
                                samples[#samples+1] = ('%s:%d  (local-rooted) old=%s'):format(path, read.start // 10000 + 1, oldView)
                            end
                            return
                        end
                        if not newNode then
                            noAnswer = noAnswer + 1
                            local key = 'no answer, ' .. context(read)
                            categories[key] = (categories[key] or 0) + 1
                            if #samples < 40 and ctxFilter == 'no answer' then
                                samples[#samples+1] = ('%s:%d  %s  old=%s'):format(path, read.start // 10000 + 1, tostring(read[1]), oldView)
                            end
                            return
                        end
                        local newView = viewOf(newNode, uri)
                        if newView == oldView then
                            matched = matched + 1
                        else
                            differs = differs + 1
                            local key = 'differs, ' .. context(read)
                            if read.type ~= 'getlocal' then
                                key = 'differs, FIELD read, ' .. context(read)
                            end
                            if oldView:find('unknown', 1, true) then
                                key = 'differs, old side has unknown (new is more precise)'
                            end
                            if decl and (guide.getParentFunction(decl) or main) ~= target then
                                key = 'differs, upvalue, ' .. context(read)
                            end
                            categories[key] = (categories[key] or 0) + 1
                            if #samples < 40 and (not ctxFilter or key:find(ctxFilter, 1, true)) then
                                samples[#samples+1] = ('%s:%d  old=%s  new=%s'):format(
                                    path, read.start // 10000 + 1, oldView, newView)
                            end
                        end
                    end
                    guide.eachSourceType(target, 'getlocal', compare)
                    if withFields then
                        guide.eachSourceType(target, 'getfield', compare)
                        guide.eachSourceType(target, 'getindex', compare)
                    end
                end
            end
        end
        files.remove(uri)
    end
end

print(('flow-differential: %d reads of locals across %d files'):format(total, #paths))
print(('  match %d (%.1f%%), differs %d, no answer %d, upvalue %d, crashed functions %d')
    :format(matched, matched / math.max(total, 1) * 100, differs, noAnswer, upvalues, crashes))
print(('  time: old compileNode %.2fs, new flow %.2fs (build + query)'):format(oldTime, newTime))
---@type string[]
local keys = {}
for k in pairs(categories) do
    keys[#keys+1] = k
end
table.sort(keys, function (a, b) return categories[a] > categories[b] end)
for _, k in ipairs(keys) do
    print(('  %6d  %s'):format(categories[k], k))
end
for _, s in ipairs(samples) do
    print('  sample: ' .. s)
end
assert(crashes == 0, crashes .. ' function(s) crashed vm.buildFlow')
