local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Method `%s` requires `%s: %s`, but the receiver\'s type argument for `%s` is `%s`.'

protoDiagnostic.register {
    'param-constraint-mismatch',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for calls of a method marked `---@requires T: Constraint` on a receiver whose class type argument for `T` does not satisfy the constraint (`Widget<number>` where the method requires `T: Frame`). The receiver may also inherit the method from a parent class (`---@class Numbers: Widget<number>`). The wowlua-ls diagnostic of the same name.',
}

---@class constraint.requirement
---@field doc    parser.object the `doc.requires`
---@field owners table<string, true> the classes the method is declared on

--- The `---@requires` docs of the definitions of the method a call names, with the classes each definition belongs to.
---@param callee parser.object a `getmethod` / `getfield`
---@return constraint.requirement[]
local function requirementsOf(callee)
    ---@type constraint.requirement[]
    local result = {}
    for _, def in ipairs(vm.getDefs(callee)) do
        if def.type ~= 'function' then
            goto CONTINUE
        end
        do
            -- `function Widget:Show()`: the receiver variable is typed with the class
            ---@type table<string, true>?
            local owners
            for _, doc in ipairs(def.bindDocs or {}) do
                if doc.type == 'doc.requires' and doc.name and doc.extends then
                    if not owners then
                        owners = {}
                        local holder = def.parent and def.parent.node
                        for obj in vm.compileNode(holder or def):eachObject() do
                            if obj.type == 'global' and obj.cate == 'type' then
                                ---@cast obj vm.global
                                owners[obj.name] = true
                            end
                        end
                    end
                    result[#result+1] = { doc = doc, owners = owners }
                end
            end
        end
        ::CONTINUE::
    end
    return result
end

--- The types the type parameters of a class stand for, given the type arguments written after its name. An argument that is a type
--- parameter of the class being walked from (`---@class Child<U>: Widget<U>`) takes what that class's own parameter stands for.
---@param uri         uri
---@param classGlobal vm.global
---@param signs       parser.object[]
---@param outer?      table<string, vm.node> what the type parameters of the class that names this one stand for
---@return table<string, vm.node>?
local function argumentsOf(uri, classGlobal, signs, outer)
    for _, set in ipairs(classGlobal:getSets(uri)) do
        if set.type == 'doc.class' and set.signs then
            ---@type table<string, vm.node>
            local resolved = {}
            for i, signName in ipairs(set.signs) do
                local signType = signs[i]
                local name = signName[1] --[[@as string?]]
                if signType and name then
                    local unit = signType
                    if signType.type == 'doc.type' and signType.types and #signType.types == 1 then
                        unit = signType.types[1]
                    end
                    local outerNode = outer and unit.type == 'doc.generic.name' and outer[unit[1] --[[@as string]]]
                    resolved[name] = outerNode or vm.compileNode(signType)
                end
            end
            return next(resolved) and resolved or nil
        end
    end
    return nil
end

---@class constraint.entry
---@field class     string the class name
---@field arguments table<string, vm.node>? what its type parameters stand for, when the receiver says

--- The class of the receiver and its parents, each with the type arguments the chain gives it.
---@param uri         uri
---@param classGlobal vm.global
---@param arguments?  table<string, vm.node>
---@param out         constraint.entry[]
---@param seen        table<vm.global, true>
local function collectChain(uri, classGlobal, arguments, out, seen)
    if seen[classGlobal] then
        return
    end
    seen[classGlobal] = true
    out[#out+1] = { class = classGlobal.name, arguments = arguments }
    for _, set in ipairs(classGlobal:getSets(uri)) do
        if set.type == 'doc.class' then
            for _, parent in ipairs(set.extends or {}) do
                if parent.type == 'doc.type.sign' and parent.node and parent.signs then
                    local parentGlobal = vm.getGlobal('type', parent.node[1])
                    if parentGlobal then
                        collectChain(uri, parentGlobal, argumentsOf(uri, parentGlobal, parent.signs, arguments), out, seen)
                    end
                elseif parent.type == 'doc.type.name' then
                    local parentGlobal = vm.getGlobal('type', parent[1])
                    if parentGlobal then
                        collectChain(uri, parentGlobal, nil, out, seen)
                    end
                end
            end
        end
    end
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    ---@async
    guide.eachSourceType(state.ast, 'call', function (call)
        delayer:delay()
        local callee = call.node
        if not callee or (callee.type ~= 'getmethod' and callee.type ~= 'getfield') then
            return
        end
        local requirements = requirementsOf(callee)
        if #requirements == 0 then
            return
        end
        local target = callee.type == 'getmethod' and callee.method or callee.field
        if not target then
            return
        end
        local methodName = guide.getKeyName(callee)
        for obj in vm.compileNode(callee.node):eachObject() do
            -- `Widget<Frame>` (the class and the types its parameters stand for) or a class that inherits from one
            ---@type constraint.entry[]
            local chain = {}
            if obj.type == 'doc.type.sign' and obj.node and obj.signs then
                local classGlobal = vm.getGlobal('type', obj.node[1])
                if classGlobal then
                    collectChain(uri, classGlobal, argumentsOf(uri, classGlobal, obj.signs), chain, {})
                end
            elseif obj.type == 'global' and obj.cate == 'type' then
                ---@cast obj vm.global
                collectChain(uri, obj, nil, chain, {})
            end
            for _, requirement in ipairs(requirements) do
                local doc  = requirement.doc
                local name = doc.name[1] --[[@as string]]
                -- the class the method is declared on (the one entry of the chain), with the arguments the receiver gives it
                for _, entry in ipairs(chain) do
                    local bound = entry.arguments and entry.arguments[name]
                    if bound and requirement.owners[entry.class] then
                        local constraint = vm.compileNode(doc.extends)
                        if not vm.canCastType(uri, constraint, bound:copy():removeOptional()) then
                            callback {
                                start   = target.start,
                                finish  = target.finish,
                                message = MESSAGE:format(
                                    tostring(methodName), name, vm.getInfer(constraint):view(uri), name, vm.getInfer(bound):view(uri)
                                ),
                            }
                        end
                    end
                end
            end
        end
    end)
end
