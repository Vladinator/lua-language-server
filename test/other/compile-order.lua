-- The type of a read must not depend on which node the editor happens to compile first.
--
-- `path = path:string()` is circular: compiling the method `path:string` needs `path`, the walk
-- of `path` (vm/tracer.lua) needs the assignment after the `if`, and its value is that very
-- call. Compiled from the method first, the assignment used to fall back to the declared type
-- `(string|P)?`, and the tracer kept what it had derived from that, so `path` after the `if`
-- was `(string|P)?` instead of `string`.
local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'

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

files.setText(TESTURI, script)
local state = files.getState(TESTURI)
assert(state)

---@type parser.object?, parser.object?
local method, last
guide.eachSource(state.ast, function (source)
    if source.type == 'getmethod' and source.method and source.method[1] == 'string' then
        method = source
    end
    if source.type == 'getlocal' and source[1] == 'path' and (not last or source.start > last.start) then
        last = source   -- the last read, the one in `return path`
    end
end)
assert(method and last)

-- ask for the method first, the way a diagnostic walking the file does
vm.compileNode(method)
local view = vm.getInfer(last):view(TESTURI)
assert(view == 'string', ('expected `string`, got `%s`'):format(view))

files.remove(TESTURI)

-- A read inside the value of an assignment sees the variable as it was BEFORE the assignment.
-- Asking for a later read first walks on from the assignment, and that walk used to visit the
-- assignment's own statement as well: the `id` in `id = f(id)` then got the type of `f`'s
-- result (`any`) instead of `string?`, for as long as the tracer lived (the CLI check goes
-- through the file in an order where that happens, the editor in another, which is how a
-- `string?` passed to `string.match` was reported in the editor only).
local script2 = [==[
local stringMatch = string.match

---@param name string
local function g(name)
    ---@type string[]
    local pg = {}
    for idVal in string.gmatch(name, '[^%.]+') do
        local id = idVal --[[@as string?]]
        id = stringMatch(id, '^%s*(.-)%s*$')
        if id ~= '' then
            pg[#pg+1] = id
        end
    end
    return pg
end
]==]

files.setText(TESTURI, script2)
local state2 = files.getState(TESTURI)
assert(state2)

---@type parser.object?, parser.object?
local arg, after
guide.eachSource(state2.ast, function (source)
    if source.type ~= 'getlocal' or source[1] ~= 'id' then
        return
    end
    if source.parent and source.parent.type == 'callargs' then
        arg = source
    else
        after = source   -- `pg[#pg+1] = id`
    end
end)
assert(arg and after)

vm.compileNode(after)
local argView = vm.getInfer(vm.compileNode(arg)):view(TESTURI)
assert(argView == 'string?', ('expected `string?`, got `%s`'):format(argView))

files.remove(TESTURI)

-- The walk of a variable (vm/tracer.lua) and the compile of what it needs can ask each other for
-- answers: the walk of `clock` reaches an `if` whose condition reads `last`, `last`'s walk
-- compiles `last = clock.now()`, which reads `clock` again, while the first walk of `clock` is
-- still running and has not reached that read. The answer for it used to be empty and was
-- cached, so `last = clock.now()` came out unknown (it depended on which read was asked for
-- first, i.e. on the order in which diagnostics happened to run).
local script3 = [==[
---@class Clock
---@field now fun(): integer

---@type Clock
local clock

---@param cb   fun(f: fun())
---@param quiet boolean
local function run(cb, quiet)
    local last = clock.now()
    cb(function ()
        if not quiet and clock.now() - last >= 500 then
            last = clock.now()
        end
    end)
end
]==]

files.setText(TESTURI, script3)
local state3 = files.getState(TESTURI)
assert(state3)

---@type parser.object[]
local clockReads = {}
---@type parser.object?
local reassign
guide.eachSource(state3.ast, function (source)
    if source.type == 'getlocal' and source[1] == 'clock' then
        clockReads[#clockReads+1] = source
    end
    if source.type == 'setlocal' and source.node[1] == 'last' then
        reassign = source
    end
end)
table.sort(clockReads, function (a, b) return a.start < b.start end)
assert(#clockReads == 3 and reassign)

vm.compileNode(clockReads[1])   -- the first read starts the walk of `clock`
local reassignView = vm.getInfer(reassign):view(TESTURI)
assert(reassignView == 'integer', ('expected `integer`, got `%s`'):format(reassignView))

files.remove(TESTURI)

-- Three locals that assign each other in one loop (a binary search): compiling `left = index + 1`
-- reads `index`, whose walk is running and needs `index = left + ...`, which needs `left` again.
-- The assignments that ran into the open compile came back empty and were cached as unknown
-- (`right = index` stayed `unknown` when the read in `list[index]` was asked for first).
files.setText(TESTURI, [==[
---@param list integer[]
---@param want integer
local function search(list, want)
    ---@type integer
    local index
    local left  = 1
    local right = #list
    for _ = 1, 1000 do
        index = left + (right - left) // 2
        if index <= left then
            break
        elseif index >= right then
            break
        end
        if list[index] < want then
            left = index + 1
        else
            right = index
        end
    end
    return index
end
]==])
local state5 = files.getState(TESTURI)
assert(state5)

---@type parser.object?, parser.object?
local firstRead, rightAssign
guide.eachSource(state5.ast, function (source)
    if source.type == 'getindex' and source.index and source.index[1] == 'index' then
        firstRead = source.index
    end
    if source.type == 'setlocal' and source.node[1] == 'right' then
        rightAssign = source
    end
end)
assert(firstRead and rightAssign)

vm.compileNode(firstRead)
local rightView = vm.getInfer(rightAssign):view(TESTURI)
assert(rightView == 'integer', ('expected `integer`, got `%s`'):format(rightView))

files.remove(TESTURI)
