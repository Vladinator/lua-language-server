-- Opt-in (`status = 'None'`, off unless enabled): `arr[i]` reads an element of a `T[]` array in one of
-- the contexts `need-check-nil` treats as unsafe for an optional value (arithmetic, indexing further, a
-- call, a numeric `for` bound, ...). A Lua array carries no compile-time length, so the inferred element
-- type `T` (not `T?`) does not mean the value is actually there at runtime: an empty or short array
-- makes `arr[i]` `nil`. TypeScript's `noUncheckedIndexedAccess` is the same idea (`arr[i]` is `T |
-- undefined` there).
--
-- Only a plain `T[]` element triggers this, not a tuple `[T1, T2]` (whose length is part of the type)
-- and not a `table<K, V>` map (which never claimed a key exists in the first place). Off by default: most
-- reads are guarded by something the checker cannot see (a loop that stops at `#arr`, an index that came
-- from a `for` over the array itself), so turning it on finds candidates to review, not a default-on
-- check -- the same reason the built-in `unnecessary-assert` is disabled upstream over `assert(arg[1])`
-- where `arg` is a `T[]` (see that file's header: recognizing "this is an array-element index" from the
-- read's own shape, which is what this diagnostic does, was the fix it never got).

local files           = require 'files'
local guide            = require 'parser.guide'
local vm               = require 'vm'
local await            = require 'await'
local protoDiagnostic  = require 'proto.diagnostic'

local MESSAGE = 'This reads an element of an array (`T[]`): the index may be out of range, so the value can be `nil`.'

protoDiagnostic.register {
    'unchecked-array-index',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'None',
    description = 'Enable diagnostics for reading an element of a `T[]` array (`arr[i]`) in a context that treats the value as definitely not `nil` (arithmetic, further indexing, a call, a numeric `for` bound, ...). Off by default: a Lua array has no compile-time length, so most such reads are guarded by something the checker cannot see (a loop bound, a known constructor); this finds candidates to review.',
}

-- (the same "does this context need a non-nil value" detection as need-check-nil.lua's UNSAFE_BINARY_OPS
-- / UNSAFE_UNARY_OPS / checkNil; kept separate on purpose, a plugin is self-contained)
local UNSAFE_BINARY_OPS = {
    ['+']  = true, ['-']  = true, ['*']  = true, ['/']  = true,
    ['%']  = true, ['//'] = true, ['^']  = true, ['..'] = true,
    ['<']  = true, ['>']  = true, ['<='] = true, ['>='] = true,
    ['&']  = true, ['|']  = true, ['~']  = true, ['<<'] = true, ['>>'] = true,
}
local UNSAFE_UNARY_OPS = {
    ['-'] = true, ['#'] = true, ['~'] = true,
}

--- Does what comes after `src` (an `arr[i]` read) treat its result as definitely not `nil`?
---@param src parser.object
---@return boolean
local function isUnsafeContext(src)
    local nxt = src.next
    if nxt
    and (nxt.type == 'getfield' or nxt.type == 'getmethod' or nxt.type == 'getindex' or nxt.type == 'call')
    and not nxt.safe then
        return true
    end
    local parent = src.parent
    if not parent then
        return false
    end
    if parent.type == 'call' and parent.node == src then
        return not parent.safe
    end
    if parent.type == 'setindex' and parent.index == src then
        return true
    end
    if parent.type == 'binary'
    and parent.op and UNSAFE_BINARY_OPS[parent.op.type]
    and (parent[1] == src or parent[2] == src) then
        return true
    end
    if parent.type == 'unary' and parent.op and UNSAFE_UNARY_OPS[parent.op.type] then
        return true
    end
    -- a numeric `for`'s init/max/step: parent is the inner expList, not the loop itself (see
    -- need-check-nil.lua's identical comment)
    local loop = parent.parent
    if loop and loop.type == 'loop'
    and (loop.init == src or loop.max == src or loop.step == src) then
        return true
    end
    return false
end

--- Does `node` include a `T[]` array member (not a tuple, not a `table<K, V>` map)?
---@param node vm.node
---@return boolean
local function isArrayElement(node)
    for c in node:eachObject() do
        if c.type == 'doc.type.array' then
            return true
        end
    end
    return false
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)

    ---@async
    guide.eachSourceType(state.ast, 'getindex', function (source)
        if source.safe or not source.node or not source.index then
            return
        end
        if not isUnsafeContext(source) then
            return
        end
        delayer:delay()
        if not isArrayElement(vm.compileNode(source.node)) then
            return
        end
        callback {
            start   = source.start,
            finish  = source.finish,
            message = MESSAGE,
        }
    end)
end
