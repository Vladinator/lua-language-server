local files      = require 'files'
local vm         = require 'vm'
local guide      = require 'parser.guide'
local findSource = require 'core.find-source'

---@class core.call-hierarchy.item
---@field name         string
---@field isMethod     boolean
---@field uri          uri
---@field start        integer the function
---@field finish       integer
---@field nameStart    integer
---@field nameFinish   integer

---@class core.call-hierarchy.call
---@field item   core.call-hierarchy.item the other end: the caller (incoming) or the callee (outgoing)
---@field ranges { start: integer, finish: integer }[] where the calls are written, in the caller

local accept = {
    ['local']     = true,
    ['getlocal']  = true,
    ['setlocal']  = true,
    ['getglobal'] = true,
    ['setglobal'] = true,
    ['field']     = true,
    ['method']    = true,
    ['getfield']  = true,
    ['getmethod'] = true,
    ['setfield']  = true,
    ['setmethod'] = true,
    ['function']  = true,
}

--- The parents that give a function a name to call it by.
---@type table<string, true>
local NAMED_BY = {
    ['local']      = true,
    ['setlocal']   = true,
    ['setglobal']  = true,
    ['setmethod']  = true,
    ['setfield']   = true,
    ['tablefield'] = true,
}

--- The name a function is known by and the token that carries it: `helper`, `Class:method`, `Class.field`.
---@param func parser.object a `function`
---@return string name
---@return boolean isMethod
---@return parser.object nameNode
local function nameOf(func)
    local parent = func.parent
    if parent then
        if parent.type == 'local' or parent.type == 'setglobal' then
            return parent[1] or '?', false, parent
        end
        if parent.type == 'setlocal' and parent.node then
            return parent.node[1] or '?', false, parent.node
        end
        if parent.type == 'setmethod' or parent.type == 'setfield' then
            local isMethod = parent.type == 'setmethod'
            local key  = isMethod and parent.method or parent.field
            local base = parent.node and parent.node[1]
            local prefix = type(base) == 'string' and base or ''
            if key then
                return prefix .. (isMethod and ':' or '.') .. tostring(key[1]), isMethod, key
            end
        end
        if parent.type == 'tablefield' and parent.field then
            return tostring(parent.field[1]), false, parent.field
        end
    end
    return '<anonymous>', false, func
end

---@param func parser.object
---@return core.call-hierarchy.item
local function itemOf(func)
    local name, isMethod, node = nameOf(func)
    return {
        name       = name,
        isMethod   = isMethod,
        uri        = guide.getUri(func),
        start      = func.start,
        finish     = func.finish,
        nameStart  = node.start,
        nameFinish = node.finish,
    }
end

--- The function object an item stands for.
---@param item core.call-hierarchy.item
---@return parser.object?
local function functionOf(item)
    local state = files.getState(item.uri)
    if not state then
        return nil
    end
    ---@type parser.object?
    local found
    guide.eachSourceType(state.ast, 'function', function (func)
        if func.start == item.start and func.finish == item.finish then
            found = func
        end
    end)
    return found
end

--- The functions a name refers to, written in code (not the standard library or an API stub).
---@param source parser.object
---@return parser.object[]
local function functionsOf(source)
    ---@type parser.object[]
    local funcs = {}
    ---@type table<parser.object, true>
    local seen = {}
    for _, def in ipairs(vm.getDefs(source)) do
        local func = def.type == 'function' and def
            or def.value and def.value.type == 'function' and def.value
            or nil
        if func and not seen[func] and not vm.isMetaFile(guide.getUri(func)) then
            seen[func] = true
            funcs[#funcs+1] = func
        end
    end
    return funcs
end

--- The function under the cursor: its definition, or a call of it.
---@param uri      uri
---@param position integer
---@return core.call-hierarchy.item[]?
local function prepare(uri, position)
    local state = files.getState(uri)
    if not state then
        return nil
    end
    local source = findSource(state, position, accept)
    if not source then
        return nil
    end
    ---@type parser.object[]
    local funcs
    if source.type == 'function' then
        funcs = { source }
    else
        funcs = functionsOf(source)
    end
    if #funcs == 0 then
        return nil
    end
    ---@type core.call-hierarchy.item[]
    local items = {}
    ---@type table<parser.object, true>
    local seen = {}
    for _, func in ipairs(funcs) do
        if not seen[func] then
            seen[func] = true
            items[#items+1] = itemOf(func)
        end
    end
    return items
end

--- The place of the callee in a call (its name), for the "from" ranges.
---@param call parser.object
---@return { start: integer, finish: integer }
local function callRange(call)
    local callee = call.node
    if callee then
        local name = callee.method or callee.field or callee
        return { start = name.start, finish = name.finish }
    end
    return { start = call.start, finish = call.finish }
end

---@param calls   core.call-hierarchy.call[]
---@param byFunc  table<parser.object, core.call-hierarchy.call>
---@param func    parser.object
---@param range   { start: integer, finish: integer }
local function addCall(calls, byFunc, func, range)
    local entry = byFunc[func]
    if not entry then
        entry = { item = itemOf(func), ranges = {} }
        byFunc[func] = entry
        calls[#calls+1] = entry
    end
    entry.ranges[#entry.ranges+1] = range
end

--- Who calls the function: every call of it written inside another function, grouped by that function.
---@async
---@param item core.call-hierarchy.item
---@return core.call-hierarchy.call[]
local function incoming(item)
    local func = functionOf(item)
    ---@type core.call-hierarchy.call[]
    local calls = {}
    if not func then
        return calls
    end
    local definition = func.parent
    -- (a function nobody named, such as an argument, is not called by name)
    if not definition or not NAMED_BY[definition.type] then
        return calls
    end
    ---@type table<parser.object, core.call-hierarchy.call>
    local byFunc = {}
    for _, ref in ipairs(vm.getRefs(definition)) do
        local parent = ref.parent
        -- (a method or field name hangs below its `getmethod` / `getfield`)
        if parent and (parent.type == 'getmethod' or parent.type == 'getfield') and parent.node ~= ref then
            ref = parent
            parent = ref.parent
        end
        if parent and parent.type == 'call' and parent.node == ref then
            local caller = guide.getParentFunction(parent)
            if caller and caller.type == 'function' then
                addCall(calls, byFunc, caller, callRange(parent))
            end
        end
    end
    table.sort(calls, function (a, b)
        return a.item.start < b.item.start
    end)
    return calls
end

--- What the function calls: the calls written directly in its body (not in the functions nested in it), grouped by callee.
---@async
---@param item core.call-hierarchy.item
---@return core.call-hierarchy.call[]
local function outgoing(item)
    local func = functionOf(item)
    ---@type core.call-hierarchy.call[]
    local calls = {}
    if not func then
        return calls
    end
    ---@type table<parser.object, core.call-hierarchy.call>
    local byFunc = {}
    guide.eachSourceType(func, 'call', function (call)
        if guide.getParentFunction(call) ~= func or not call.node then
            return
        end
        for _, callee in ipairs(functionsOf(call.node)) do
            addCall(calls, byFunc, callee, callRange(call))
        end
    end)
    table.sort(calls, function (a, b)
        return a.item.start < b.item.start
    end)
    return calls
end

return {
    prepare  = prepare,
    incoming = incoming,
    outgoing = outgoing,
}
