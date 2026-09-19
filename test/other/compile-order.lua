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
