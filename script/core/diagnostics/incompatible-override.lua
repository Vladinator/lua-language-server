local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE_METHOD = 'The override of `%s` in `%s` does not fit the one of `%s`: what it needs, takes or gives differs from what that class declares.'
local MESSAGE_FIELD  = 'The field `%s` of `%s` redeclares the one of `%s` with a type that does not fit it: `%s` is not assignable to `%s`.'

protoDiagnostic.register {
    'incompatible-override',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for a class that overrides a member of a class it inherits from with something that does not fit it (TypeScript\'s "class incorrectly extends"): a method that needs more arguments, takes or gives other types, or a field redeclared with a type that is not assignable to the parent\'s. A narrower type is an override; a wider or unrelated one is a collision.',
}

--- The classes `className` inherits from, nearest first.
---@param uri       uri
---@param className string
---@return vm.global[]
local function parentsOf(uri, className)
    local class = vm.getGlobal('type', className)
    if not class then
        return {}
    end
    ---@type vm.global[]
    local parents = {}
    for i, entry in ipairs(vm.getClassGenericChain(uri, class)) do
        if i > 1 then
            local parent = vm.getGlobal('type', entry.class)
            if parent then
                parents[#parents+1] = parent
            end
        end
    end
    return parents
end

--- What the nearest parent that declares `key` says it is: the function, or the type of a field.
---@param uri    uri
---@param parents vm.global[]
---@param key    string
---@return vm.node? node
---@return vm.global? class the parent that declares it
local function baseMemberOf(uri, parents, key)
    for _, parent in ipairs(parents) do
        ---@type vm.node?
        local found
        vm.getClassFields(uri, parent, key, function (src)
            -- (a parent's own parents come through the same call: nothing to add)
            found = found or vm.createNode()
            found:merge(vm.compileNode(src))
        end)
        if found and not found:isEmpty() then
            return found, parent
        end
    end
    return nil, nil
end

--- The function or `fun(...)` a node holds, when it holds exactly one.
---@param node vm.node
---@return parser.object?
local function singleFunction(node)
    ---@type parser.object?
    local found
    for obj in node:eachObject() do
        if obj.type == 'function' or obj.type == 'doc.type.function' then
            if found then
                return nil
            end
            found = obj
        elseif obj.type ~= 'local' and obj.type ~= 'variable' and obj.type ~= 'self' then
            return nil
        end
    end
    return found
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    -- methods: `function Child:update(dt)` / `function Child.update(self, dt)` / `Child.update = function ...`
    ---@async
    guide.eachSourceTypes(state.ast, { 'setmethod', 'setfield' }, function (source)
        local value = source.value
        if not value or value.type ~= 'function' then
            return
        end
        local key = guide.getKeyName(source)
        if type(key) ~= 'string' then
            return
        end
        await.delay()
        local childClass = source.node and vm.getDefinedClass(uri, source.node)
        if not childClass then
            return
        end
        local base, baseClass = baseMemberOf(uri, parentsOf(uri, childClass.name), key)
        local baseFunction = base and singleFunction(base)
        if not baseFunction or not baseClass then
            return
        end
        -- a method written with a colon takes `self` first, a function with a dot does not: only like with like is compared
        local baseIsMethod = false
        for _, arg in ipairs(baseFunction.args or {}) do
            if arg.type == 'self' then
                baseIsMethod = true
            end
        end
        local childIsMethod = source.type == 'setmethod'
        if baseFunction.type == 'function' and baseIsMethod ~= childIsMethod then
            return
        end
        if vm.functionTypeMismatch(uri, value, baseFunction) then
            -- (the name of the method, not `Child:`)
            local nameNode = source.method or source.field or source
            callback {
                start   = nameNode.start,
                finish  = nameNode.finish,
                message = MESSAGE_METHOD:format(key, childClass.name, baseClass.name),
            }
        end
    end)

    -- fields: `---@field name T` in a class that inherits a `name`
    ---@async
    guide.eachSourceType(state.ast, 'doc.field', function (field)
        local key = vm.getKeyName(field)
        local className = field.class and field.class.class and field.class.class[1]
        if type(key) ~= 'string' or type(className) ~= 'string' then
            return
        end
        await.delay()
        local base, baseClass = baseMemberOf(uri, parentsOf(uri, className), key)
        if not base or not baseClass then
            return
        end
        local mine = vm.compileNode(field)
        if mine:isEmpty() then
            return
        end
        -- (a field declared as `nil` takes an inherited member away: not a collision)
        if vm.getInfer(mine):view(uri) == 'nil' then
            return
        end
        local mineFunction  = singleFunction(mine)
        local baseFunction  = singleFunction(base)
        if mineFunction then
            -- (a base that is only `function`, or says nothing precise, is not compared)
            if not baseFunction then
                return
            end
            if vm.functionTypeMismatch(uri, mineFunction, baseFunction) then
                callback {
                    start   = field.field and field.field.start or field.start,
                    finish  = field.field and field.field.finish or field.finish,
                    message = MESSAGE_METHOD:format(key, className, baseClass.name),
                }
            end
            return
        end
        -- (`T?` over `T` is the usual way to make an inherited field optional: only a real conflict of types is reported)
        if vm.isSubType(uri, mine:copy():removeOptional():remove 'nil', base) == false then
            callback {
                start   = field.field and field.field.start or field.start,
                finish  = field.field and field.field.finish or field.finish,
                message = MESSAGE_FIELD:format(
                    key,
                    className,
                    baseClass.name,
                    vm.getInfer(mine):view(uri),
                    vm.getInfer(base):view(uri)
                ),
            }
        end
    end)
end
