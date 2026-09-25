-- Companion of assign-readonly.lua (which owns the `readonly` type keyword: `---@param t readonly T`,
-- `---@type readonly T`). The value such a slot holds must not be mutated through that reference:
-- assigning one of its fields/indices (`t.x = v`, `t[k] = v`), or passing it as the mutated argument of
-- a stdlib call that mutates in place (`table.insert`, `table.remove`, `table.sort`, `rawset`), is
-- reported. Reading it, and passing it to anything else, is fine.
--
-- Only a direct reference is followed: `local u = t; u.x = v` is not seen (`u` was not itself declared
-- `readonly`), and neither is `f(t).x = v` or `t.inner.x = v` (only `t` itself, not what it contains, is
-- checked). This is the same "best effort, not a taint that survives everything" choice the secret
-- plugin makes for `nosecret`; a style that needs more can be silenced with
-- `---@diagnostic disable-next-line: mutate-readonly`. `table.move` is not covered at all: which
-- argument it mutates (the source, or the destination `a2`) depends on whether `a2` is given, and
-- getting that wrong would be worse than not checking it.

local files           = require 'files'
local guide           = require 'parser.guide'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local FIELD_MESSAGE = 'This value is `readonly`: assigning to it is not allowed.'
local CALL_MESSAGE  = 'This value is `readonly`: `%s` mutates it.'

protoDiagnostic.register {
    'mutate-readonly',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for mutating a value through a reference declared `readonly` (`---@param t readonly T`, `---@type readonly T`): assigning one of its fields/indices, or passing it to a mutating stdlib call (`table.insert`, `table.remove`, `table.sort`, `rawset`).',
}

--- The first argument of these `table.<name>` calls (and of `rawset`) is mutated.
---@type table<string, true>
local TABLE_MUTATORS = {
    insert = true,
    remove = true,
    sort   = true,
}

--- Is `loc` (a `local` or `self`) declared `readonly`, directly (`---@type readonly T`) or as a
--- parameter (`---@param x readonly T`)? Only its own doc comment counts, the same restriction
--- need-check-secret.lua notes for its flag: resolving through `vm.getDefs` would be unsound to call on
--- every plain local.
---@param loc parser.object
---@return boolean
local function isReadonlyDecl(loc)
    local docs = loc.bindDocs
    if not docs then
        return false
    end
    for i = 1, #docs do
        ---@type parser.object
        local doc = docs[i]
        if doc.type == 'doc.type' and doc.readonly then
            return true
        end
        if  doc.type == 'doc.param'
        and doc.param
        and doc.param[1] == loc[1]
        and doc.extends
        and doc.extends.readonly then
            return true
        end
    end
    return false
end

--- Is `source` a direct read (`getlocal`, including a read of an implicit `self`, which the parser
--- represents the same way) of a `readonly`-declared local?
---@param source parser.object?
---@return boolean
local function isReadonlyRef(source)
    return source ~= nil and source.type == 'getlocal'
       and source.node ~= nil and isReadonlyDecl(source.node)
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)

    ---@async
    guide.eachSourceTypes(state.ast, { 'setfield', 'setindex' }, function (source)
        delayer:delay()
        if isReadonlyRef(source.node) then
            ---@type parser.object
            local at = source.field or source.index or source
            callback {
                start   = at.start,
                finish  = at.finish,
                message = FIELD_MESSAGE,
            }
        end
    end)

    ---@async
    guide.eachSourceType(state.ast, 'call', function (source)
        local callee = source.node
        if not callee or not source.args or not source.args[1] then
            return
        end
        ---@type string?
        local mutator
        if callee.type == 'getfield'
        and callee.node and callee.node.type == 'getglobal' and callee.node[1] == 'table'
        and callee.field and TABLE_MUTATORS[callee.field[1]] then
            mutator = 'table.' .. callee.field[1]
        elseif callee.type == 'getglobal' and callee[1] == 'rawset' then
            mutator = 'rawset'
        end
        if not mutator then
            return
        end
        delayer:delay()
        local arg = source.args[1]
        if isReadonlyRef(arg) then
            callback {
                start   = arg.start,
                finish  = arg.finish,
                message = CALL_MESSAGE:format(mutator),
            }
        end
    end)
end
