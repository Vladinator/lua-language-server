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
