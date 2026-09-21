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

-- A variable that is assigned from itself in a loop (`n = n + 1`) must have the same type
-- whichever of its reads is asked for first. Compiling the assignment reads `n`, whose walk
-- gets back to the assignment, which is still being compiled: the walk used to go on from the
-- half-built assignment and keep what it derived (the reads after it in the loop, the exit of
-- the loop), and the walk that was compiling the assignment could not correct that, because a
-- read is only visited once. `print(n)` came out `unknown` when it was asked for first, in every
-- kind of loop; the editor showed it when another diagnostic happened to compile the field
-- assignments of the file first (`nr = linenr` in `plugins/ffi/c-parser/cpp.lua`).
--
-- For every source that has a type the checks compile each one in a fresh state, alone and
-- in reverse order, and compare with the types in source order.
---@type table<string, string>
local loops = {
    for_count = [==[
local n = 0
for i = 1, 10 do
    n = n + 1
    print(n)
end
print(n)
]==],
    while_count = [==[
local n = 0
while n < 10 do
    n = n + 1
    print(n)
end
print(n)
]==],
    repeat_count = [==[
local n = 0
repeat
    n = n + 1
until n > 10
print(n)
]==],
    nested = [==[
local n = 0
for i = 1, 10 do
    for j = 1, 10 do
        n = n + 1
        print(n)
    end
    print(n)
end
print(n)
]==],
    concat = [==[
local s = ''
for i = 1, 10 do
    s = s .. 'x'
    print(s)
end
print(s)
]==],
    iterator = [==[
---@param t string[]
local function f(t)
    local n = 0
    local s = ''
    for _, v in ipairs(t) do
        n = n + 1
        s = s .. v
        print(n, s)
    end
    return n, s
end
]==],
    -- two variables that feed each other: the walk of one gets to an assignment that is open
    -- because of the other
    mutual = [==[
local a, b = 0, 0
for i = 1, 10 do
    a = b + 1
    b = a + 1
    print(a, b)
end
print(a, b)
]==],
    -- declared nil, assigned under a condition, then used
    guarded = [==[
---@param a boolean
local function f(a)
    local i = 1
    while i < 10 do
        local n = nil
        if a then
            n = i
        end
        if n then
            print(n)
        else
            n = i
        end
        i = n + 1
    end
end
]==],
}

---@param name string
---@param text string
---@return parser.object[]
local function loopSources(name, text)
    files.remove(TESTURI)
    files.setText(TESTURI, text)
    local state = files.getState(TESTURI)
    assert(state, name)
    ---@type parser.object[]
    local list = {}
    guide.eachSource(state.ast, function (source)
        if source.type == 'local' or source.type == 'getlocal' or source.type == 'setlocal' then
            list[#list+1] = source
        end
    end)
    return list
end

---@type string[]
local loopNames = {}
for key in pairs(loops) do
    ---@type string
    local loopName = key
    loopNames[#loopNames+1] = loopName
end
table.sort(loopNames)
for k = 1, #loopNames do
    local name = loopNames[k]
    local text = loops[name]
    ---@type string[]
    local want = {}
    for i, source in ipairs(loopSources(name, text)) do
        want[i] = vm.getInfer(source):view(TESTURI)
        assert(want[i] ~= 'unknown', ('%s: source %d is `unknown` in source order'):format(name, i))
    end
    -- each source alone, first
    local count = #loopSources(name, text)
    for i = 1, count do
        local view = vm.getInfer(loopSources(name, text)[i]):view(TESTURI)
        assert(view == want[i], ('%s: source %d asked first is `%s`, in source order `%s`'):format(name, i, view, want[i]))
    end
    -- reverse order
    local list = loopSources(name, text)
    for i = #list, 1, -1 do
        vm.getInfer(list[i])
    end
    for i, source in ipairs(list) do
        local view = vm.getInfer(source):view(TESTURI)
        assert(view == want[i], ('%s: source %d in reverse order is `%s`, in source order `%s`'):format(name, i, view, want[i]))
    end
end

files.remove(TESTURI)
