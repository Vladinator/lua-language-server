-- A file that is not part of a workspace (VS Code with a single file open) is in no scope's list of
-- files. What is looked up by the names of the functions that declare something (`---@return never`,
-- the guards of the plugin) has to consider the file itself, or the feature does nothing there.
local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'

local uri = 'file:///outside-of-the-workspace/loose-never.lua'
files.setText(uri, [[
---@return never
local function Fail(message)
    error(message)
end

---@param name string?
local function f(name)
    if not name then
        Fail('name is required')
    end
    print(name)
    local same = name or Fail('unreachable')
    return same
end
]])
local state = files.getState(uri)
assert(state)

---@type string[]
local views = {}
guide.eachSourceType(state.ast, 'getlocal', function (source)
    if source[1] == 'name' and source.parent and source.parent.type == 'callargs' then
        views[#views+1] = vm.getInfer(source):view(uri)
    end
end)
assert(#views == 1 and views[1] == 'string', 'loose file: `name` after the never call is ' .. table.concat(views, ','))

---@type string?
local sameView
guide.eachSourceType(state.ast, 'local', function (source)
    if source[1] == 'same' then
        sameView = vm.getInfer(source):view(uri)
    end
end)
assert(sameView == 'string', 'loose file: `x or Fail()` is ' .. tostring(sameView))

files.remove(uri)
