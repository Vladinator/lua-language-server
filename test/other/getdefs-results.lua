local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'

---@diagnostic disable: await-in-sync

-- `vm.getDefs` hands out places that define something: assignments and literals, as sources of the file. A node also holds `vm.variable`s
-- (and `vm.generic`s) and the search sees them, but none of them is a result. Measured on a real project (2026-10-19): 12,994 variables
-- reached `getDefs`, 0 were returned. This pins that, on a mixed snippet, for every source in it (so a change of the filter, or of what a
-- node holds, shows here), and that `vm.hasDef` says "yes" exactly when `vm.getDefs` has a result.

local script = [[
---@class DefsA
---@field x number
local A = {}

---@param p DefsA
---@param q? string
---@return number
local function f(p, q)
    local n = p.x
    local t = { a = 1, b = 'two', [3] = true }
    t.c = n
    n = n + 1
    gdef = q or 'default'
    return t.a + n + #gdef
end

---@generic T
---@param v T
---@return T
local function id(v) return v end

local s = id('text')
local r = id(1)
f(A, s)
print(gdef, r, A.x, f)
]]

files.setText(TESTURI, script)
local state = assert(files.getState(TESTURI))

local checked, withResults, variables = 0, 0, 0
guide.eachSource(state.ast, function (source)
    if source.type == 'getlocal' or source.type == 'getfield' or source.type == 'getglobal' or source.type == 'getmethod'
    or source.type == 'setlocal' or source.type == 'setfield' or source.type == 'setglobal' or source.type == 'call'
    or source.type == 'local' or source.type == 'function' then
        local defs = vm.getDefs(source)
        checked = checked + 1
        for _, def in ipairs(defs) do
            assert(def.type ~= 'variable', source.type .. ' at ' .. source.start .. ': a variable is no result')
            assert(def.type ~= nil, source.type .. ' at ' .. source.start .. ': a result has a type (not a generic)')
            assert(guide.isAssign(def) or guide.isLiteral(def), ('%s at %d: a `%s` is neither an assignment nor a literal'):format(
                source.type, source.start, def.type))
        end
        if #defs > 0 then
            withResults = withResults + 1
        end
        assert(vm.hasDef(source) == (#defs > 0), ('%s at %d: hasDef says %s, getDefs has %d'):format(
            source.type, source.start, tostring(vm.hasDef(source)), #defs))
        -- (the variable of the node is there for the search: it must not have been made a result)
        for obj in vm.compileNode(source):eachObject() do
            if obj.type == 'variable' then
                variables = variables + 1
            end
        end
    end
end)

assert(checked > 20, 'the snippet has sources to ask for: ' .. checked)
assert(withResults > 10, 'and most of them have a definition: ' .. withResults)
assert(variables > 0, 'the nodes of the snippet do hold variables (else this checks nothing): ' .. variables)

files.remove(TESTURI)
