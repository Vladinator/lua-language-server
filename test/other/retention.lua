-- A file that was edited must be collectable: nothing of the compile bookkeeping may keep the AST of the old text alive.
--
-- `taintedBy` (vm/compiler.lua) remembers which completed nodes consumed the half-built content of a still-open
-- compile. It was a strong table keyed by the nodes, and entries that were never dropped kept the whole AST of the
-- old text of a file alive: ~190 MB retained per save of a 19,000-line file (found 2026-10-04 with
-- `tools/load_bench.py --edit-rounds --memlog`). This test compiles the circular case of compile-order.lua, replaces
-- the text, and asks the collector whether the old tree is gone.
local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'
local core  = require 'core.diagnostics'

---@diagnostic disable: await-in-sync

local script = [[
---@class P
---@field string fun(self: P): string

---@param path? string|P
local function f(path)
    if not path then
        return
    end
    if type(path) ~= 'string' then
        path = path:string()
    end
    return path
end
]]

--- Parses and compiles `text` the way the editor does; returns a weak table holding its tree (nothing else keeps it).
---@param text string
---@return table<integer, any> weak
local function compileAll(text)
    files.setText(TESTURI, text)
    local ast = assert(files.getState(TESTURI)).ast
    guide.eachSource(ast, function (source)
        if source.type == 'getmethod' and source.method and source.method[1] == 'string' then
            vm.compileNode(source) -- (the method that makes the cycle first)
        end
    end)
    guide.eachSource(ast, function (source)
        if source.type == 'getlocal' or source.type == 'setlocal' or source.type == 'getmethod' then
            vm.compileNode(source)
        end
    end)
    -- every diagnostic, in the order they run (nested compiles, cycles)
    core(TESTURI, false, function () end)
    ---@type table<integer, any>
    local weak = setmetatable({}, { __mode = 'v' })
    weak[1] = ast
    return weak
end

--- Compiles `text`, replaces it, drops the node cache and collects. Returns whether the old tree was collected.
---@param text string
---@return boolean collected
local function oldTreeCollected(text)
    ---@type table<integer, any>
    local weak = compileAll(text)
    -- (the parser keeps the state of its last parse in a module upvalue until the next one: parse the new text)
    files.setText(TESTURI, 'local x = 1')
    assert(files.getState(TESTURI))
    -- (the shared caches are dropped by their next use after a change, `vm.getCache` flushes the whole `vm.cache` then)
    vm.getCache 'retention-test'
    vm.clearNodeCache()
    for _ = 1, 3 do
        collectgarbage()
    end
    local collected = weak[1] == nil
    files.remove(TESTURI)
    return collected
end

--- A real file of the repo: big enough to leave entries behind that the small cases do not.
---@param name string
---@return string
local function readFile(name)
    local f = assert(io.open(name, 'rb'))
    local text = f:read('a')
    f:close()
    return text
end

local plain = 'local a = 1' .. string.char(10) .. 'return a + 1' .. string.char(10)
assert(oldTreeCollected(readFile('script/vm/infer.lua')), 'the AST of a replaced real file (script/vm/infer.lua) is still alive')
assert(oldTreeCollected(plain), 'the AST of a plain replaced text is still alive')
assert(oldTreeCollected(script), 'the AST of a replaced text is still alive after the nodes of the circular case were compiled')

-- `taintedBy` itself: the harness never leaves a stale entry behind (the server did, with diagnoses that were cancelled
-- or interleaved), so the leak is guarded structurally: the table has to be weak-keyed.
---@type any
local taintedBy
for i = 1, 40 do
    local name, value = debug.getupvalue(vm.compileNode, i)
    if not name then
        break
    end
    if name == 'taintedBy' then
        taintedBy = value
    end
end
assert(taintedBy, 'vm.compileNode has no `taintedBy` upvalue any more: update this test')
---@type table?
local meta = getmetatable(taintedBy)
local mode = meta and meta.__mode
assert(type(mode) == 'string' and mode:find('k', 1, true), '`taintedBy` must be weak-keyed (it keeps the whole AST of an edited file alive otherwise)')
