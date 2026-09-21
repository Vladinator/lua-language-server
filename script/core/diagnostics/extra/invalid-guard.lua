-- Type guards, like TypeScript's `x is T` and `asserts x is T`:
--
--     ---@guard v is string          a function that returns true when `v` is a string
--     ---@guard v is not nil         ... when `v` is not nil (`is not T`: the other way round)
--     ---@asserts v is table         a function that raises an error unless `v` is a table
--
-- In the branch of a condition where the guard holds the argument has the type `T`, in the other one
-- `T` is taken away from it (`if IsString(x) then ... else ... end`, `not`, `and`, `or`, `while`); after
-- the call of an `@asserts` function used as a statement the argument has the type `T`.
-- `v` is a parameter of the function (`self` too). The callee is found through its name first: only the
-- names of functions that carry one of the tags are looked into at all, so calls of every other function
-- cost nothing (compiling a callee inside the tracer is what this has to avoid).
--
-- Everything is here: the tags, the narrowing rule and the diagnostic `invalid-guard`, wired in through
-- the registries in parser/docTags.lua and vm/narrow.lua. Deleting this file removes the feature.
-- Its tests are next to it.

local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'
local docTags         = require 'parser.docTags'
local scope           = require 'workspace.scope'

protoDiagnostic.register {
    'invalid-guard',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for a `---@guard x is T` / `---@asserts x is T` that is not of that form, or names something that is not a parameter of the function it is bound to.',
}

docTags.registerGuardTag('guard', 'doc.guard',
    'A function that returns true when its parameter has a type: `---@guard v is string`, or `---@guard v is not nil`.\n\n'
    .. 'In the branch of a condition where the call holds, the argument has that type; in the other branch it is taken away.')
docTags.registerGuardTag('asserts', 'doc.asserts',
    'A function that raises an error unless its parameter has a type: `---@asserts v is table`.\n\n'
    .. 'After a call used as a statement the argument has that type.')

for _, docType in ipairs { 'doc.guard', 'doc.asserts' } do
    docTags.registerBindRule(docType, function (doc, source, isParam)
        return source.type == 'function'
    end)
end

---@param doc parser.object
---@return boolean
local function isGuardDoc(doc)
    return doc.type == 'doc.guard' or doc.type == 'doc.asserts'
end

-- The names --------------------------------------------------------------------------------------

--- The name a function is known by: `local function f`, `function M.f`, `function M:f`,
--- `M.f = function`, `{ f = function ... }`.
---@param source parser.object?
---@return string?
local function nameOf(source)
    if not source then
        return nil
    end
    if source.type == 'function' then
        source = source.parent
        if not source then
            return nil
        end
    end
    local t = source.type
    if t == 'local' or t == 'setlocal' or t == 'setglobal' then
        return source[1] --[[@as string?]]
    elseif t == 'setfield' or t == 'tablefield' then
        return source.field and source.field[1] --[[@as string?]]
    elseif t == 'setmethod' then
        return source.method and source.method[1] --[[@as string?]]
    end
    return nil
end

---@param uri uri
---@return table<string, true>|false
local function getFileNames(uri)
    local cache = files.getCache(uri)
    if not cache then
        return false
    end
    ---@type table<string, true>|false|nil
    local names = cache['type-guard.names']
    if names ~= nil then
        return names
    end
    ---@type table<string, true>
    local found = {}
    local state = files.getState(uri)
    for _, doc in ipairs(state and state.ast.docs or {}) do
        if isGuardDoc(doc) then
            -- a name that cannot be found matches every callee (the price is only the lookup)
            found[nameOf(doc.bindSource) or '*'] = true
        end
    end
    names = next(found) ~= nil and found
    cache['type-guard.names'] = names
    return names
end

--- The names of the functions that carry a guard, in the workspace of `uri`. Worked out from the
--- (cached, per file) names of each file; dropped with the rest of `vm.getCache` when a file changes.
---@param uri uri
---@return table<string, true>
local function getNames(uri)
    local cache = vm.getCache('type-guard.names') --[[@as table<string, table<string, true>>]]
    local key   = scope.getScope(uri):getName()
    local names = cache[key]
    if names then
        return names
    end
    ---@type table<string, true>
    names = {}
    for fileUri in files.eachFile(uri) do
        local fileNames = getFileNames(fileUri)
        if fileNames then
            for name in pairs(fileNames) do
                names[name] = true
            end
        end
    end
    cache[key] = names
    return names
end

---@param callee parser.object
---@return string?
local function calleeName(callee)
    local t = callee.type
    if t == 'getlocal' or t == 'getglobal' then
        return callee[1] --[[@as string?]]
    elseif t == 'getfield' then
        return callee.field and callee.field[1] --[[@as string?]]
    elseif t == 'getmethod' then
        return callee.method and callee.method[1] --[[@as string?]]
    end
    return nil
end

-- The narrowing ----------------------------------------------------------------------------------

--- The guards of the functions a callee can be: the tag and the position of its parameter.
---@class typeGuard.found
---@field doc   parser.object
---@field index integer

---@param callee parser.object
---@return typeGuard.found[]
local function findGuards(callee)
    ---@type typeGuard.found[]
    local found = {}
    for _, def in ipairs(vm.getDefs(callee)) do
        ---@type parser.object?
        local func = def.type == 'function' and def
            or (def.value and def.value.type == 'function' and def.value)
            or nil
        if func then
            -- (the docs are bound to the function and to what it is assigned to)
            for _, holder in ipairs { func, def } do
                for _, doc in ipairs(holder.bindDocs or {}) do
                    if isGuardDoc(doc) and doc.param then
                        for index, arg in ipairs(func.args or {}) do
                            if arg[1] == doc.param[1] then
                                found[#found+1] = { doc = doc, index = index }
                            end
                        end
                    end
                end
            end
        end
    end
    return found
end

--- What `node` is when the value is known to be one of the types `typeNode` holds.
---@param uri      uri
---@param node     vm.node
---@param typeNode vm.node
---@return vm.node
local function narrowTo(uri, node, typeNode)
    ---@type vm.node?
    local result
    for c in typeNode:eachObject() do
        ---@type string?
        local name
        if c.type == 'global' and c.cate == 'type' then
            local typeName = c.name
            if type(typeName) == 'string' then
                name = typeName
            end
        elseif c.type == 'nil' then
            name = 'nil'
        end
        ---@type vm.node
        local part
        if name then
            -- what of the node is that type; when nothing is, the type itself (`any` becomes it)
            part = node:copy()
            part:narrow(uri, name)
            -- an `any` / `unknown` is every type, so it is that one now
            local wasAny = part:hasType('any') or part:hasType('unknown')
            if wasAny then
                part:remove('any')
                part:remove('unknown')
                local declared = vm.getGlobal('type', name)
                if declared then
                    part:merge(declared)
                end
            end
        else
            part = vm.createNode(c)
        end
        if result then
            result:merge(part)
        else
            result = part
        end
    end
    return result or node
end

---@param node     vm.node
---@param typeNode vm.node
---@return vm.node
local function without(node, typeNode)
    local result = node:copy()
    result:removeNode(typeNode)
    return result
end

vm.registerCallNarrowing {
    statement = true,
    match = function (callee)
        local name = calleeName(callee)
        if not name then
            return false
        end
        local names = getNames(guide.getUri(callee))
        return names[name] == true or names['*'] == true
    end,
    ---@param tracer   vm.tracer
    ---@param action   parser.object call
    ---@param topNode  vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    narrow = function (tracer, action, topNode, outNode)
        local callee = action.node
        -- (the arguments of a call with a colon start with the implicit `self`, which stands for the object)
        local args = action.args or {}
        for _, guard in ipairs(findGuards(callee)) do
            ---@type parser.object?
            local target = args[guard.index]
            if target and target.type == 'self' and callee.type == 'getmethod' then
                target = callee.node
            end
            if target and tracer.getMap[target] then
                local doc = guard.doc
                -- the read itself gets the state before the call
                tracer:lookIntoChild(target, topNode, outNode)
                local typeNode = vm.compileNode(doc.extends)
                if doc.type == 'doc.guard' and outNode then
                    if doc.negated then
                        topNode, outNode = without(topNode, typeNode), narrowTo(tracer.uri, outNode, typeNode)
                    else
                        topNode, outNode = narrowTo(tracer.uri, topNode, typeNode), without(outNode, typeNode)
                    end
                elseif doc.type == 'doc.asserts' and not outNode then
                    if doc.negated then
                        topNode = without(topNode, typeNode)
                    else
                        topNode = narrowTo(tracer.uri, topNode, typeNode)
                    end
                end
            end
        end
        return topNode, outNode
    end,
}

-- The diagnostic ---------------------------------------------------------------------------------

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state or not state.ast.docs then
        return
    end
    for _, doc in ipairs(state.ast.docs) do
        if not isGuardDoc(doc) then
            goto CONTINUE
        end
        await.delay()
        if not doc.param or not doc.extends then
            callback {
                start   = doc.start,
                finish  = doc.finish,
                message = 'Expected `x is T` (or `x is not T`) with `x` a parameter of the function.',
            }
            goto CONTINUE
        end
        ---@type parser.object?
        local source = doc.bindSource
        ---@type parser.object?
        local func = source and (source.type == 'function' and source
            or (source.value and source.value.type == 'function' and source.value)
            or nil) or nil
        if not func then
            callback {
                start   = doc.start,
                finish  = doc.finish,
                message = 'This tag has to be above a function.',
            }
            goto CONTINUE
        end
        local found = false
        for _, arg in ipairs(func.args or {}) do
            if arg[1] == doc.param[1] then
                found = true
                break
            end
        end
        if not found then
            callback {
                start   = doc.param.start,
                finish  = doc.param.finish,
                message = ('`%s` is not a parameter of this function.'):format(doc.param[1]),
            }
        end
        ::CONTINUE::
    end
end
