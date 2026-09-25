-- `readonly` (TypeScript's keyword) has two independent uses, both owned by this file:
--
--   * `---@field readonly name string` -- the FIELD is set once, when the object is built, and not
--     changed after that: assigning it (`obj.name = v`, `obj['name'] = v`) is reported on the field.
--     What is not an assignment after the fact:
--       - the table constructor that builds the object (`{ name = v }`);
--       - anything inside a function that builds objects by its name: `new`, `init`, `constructor`,
--         `ctor`, `__init`, `create`;
--       - an assignment to a local of the same function that this function made from a table
--         constructor or `setmetatable(...)` (`local o = setmetatable({}, C); o.name = v`).
--     Constructors in Lua come in many styles (metatables, factories, mixins), so this is deliberately
--     forgiving: a style that is not covered is silenced with
--     `---@diagnostic disable-next-line: assign-readonly`.
--   * `readonly T` as a type keyword (`---@param t readonly T`, `---@type readonly T`) -- the VALUE that
--     reference points at must not be mutated through it: assigning one of its fields/indices, or
--     passing it to a mutating stdlib call, is reported by the companion `mutate-readonly.lua`, which
--     only reads the keyword.
--
-- Both keywords are registered here; nothing else knows about either. Deleting the file removes both
-- features (and its companion, whose diagnostic does nothing once the keyword no longer exists). Its
-- own tests are next to it.

local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'
local docTags         = require 'parser.docTags'
local scope           = require 'workspace.scope'

--- The `readonly` keyword of `---@field readonly name T`: a bare keyword like `public` / `private`, so it
--- reads as a keyword and not as a field called `readonly`. Written as ["readonly"] for that reason.
---@class parser.object
---@field ["readonly"]? boolean

local MESSAGE = 'Field `%s` is readonly: it is set when the object is built, not after.'

protoDiagnostic.register {
    'assign-readonly',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for assigning a field that is declared `readonly` (`---@field readonly name string`) outside the code that builds the object.',
}

docTags.registerFieldKeyword('readonly', 'readonly',
    'The field is set when the object is built and not changed after: `---@field readonly name string`.')

-- `readonly` in front of a type item (`---@param t readonly T`, `---@type readonly T`): the value that
-- slot holds must not be mutated through it. `mutate-readonly.lua` reports assigning one of its fields
-- or passing it to a mutating stdlib call; nothing here reads it.
docTags.registerTypeKeyword('readonly', 'readonly',
    'The value this slot holds must not be mutated through it: `---@param t readonly T`, `---@type readonly T`. Assigning a field / index, or passing it to a mutating call (`table.insert`, ...), is reported by `mutate-readonly`.')

--- Functions that build objects, by name.
---@type table<string, true>
local BUILDERS = {
    new         = true,
    init        = true,
    constructor = true,
    ctor        = true,
    __init      = true,
    create      = true,
}

--- The names of the fields that some class declares `readonly`. Worked out once per scope until a file
--- changes: most workspaces have none and then no assignment needs a second look.
---@param uri uri
---@return table<string|integer, true>
local function getReadonlyNames(uri)
    local cache = vm.getCache('assign-readonly.names') --[[@as table<string, table<string|integer, true>>]]
    local key   = scope.getScope(uri):getName()
    local names = cache[key]
    if names then
        return names
    end
    ---@type table<string|integer, true>
    local found = {}
    for _, doc in ipairs(vm.getDocSets(uri)) do
        ---@type parser.object[]?
        local fields = doc.type == 'doc.class' and doc.fields or nil
        if fields then
            for i = 1, #fields do
                ---@type parser.object
                local field     = fields[i]
                ---@type string|integer?
                local fieldName = field.field and field.field[1]
                if fieldName ~= nil and field.readonly then
                    found[fieldName] = true
                end
            end
        end
    end
    cache[key] = found
    return found
end

--- The name a function is known by (`function new`, `function C.new`, `function C:new`, `C.new = function`).
---@param func parser.object
---@return string?
local function nameOf(func)
    local parent = func.parent
    if not parent then
        return nil
    end
    local t = parent.type
    if t == 'local' or t == 'setlocal' or t == 'setglobal' then
        return parent[1] --[[@as string?]]
    elseif t == 'setfield' or t == 'tablefield' then
        return parent.field and parent.field[1] --[[@as string?]]
    elseif t == 'setmethod' then
        return parent.method and parent.method[1] --[[@as string?]]
    end
    return nil
end

--- Whether a local was made from a table constructor or `setmetatable(...)`.
---@param loc parser.object
---@return boolean
local function isFresh(loc)
    ---@type parser.object?
    local value = loc.value
    if not value then
        return false
    end
    if value.type == 'select' and value.vararg then
        value = value.vararg
    end
    if value.type == 'table' then
        return true
    end
    return value.type == 'call' and value.node ~= nil and value.node.special == 'setmetatable'
end

--- Is the assignment part of building the object?
---@param source parser.object setfield / setindex
---@return boolean
local function isBuilding(source)
    ---@type parser.object?
    local func = guide.getParentFunction(source)
    if not func or func.type ~= 'function' then
        return false
    end
    local name = nameOf(func)
    if name and BUILDERS[name] then
        return true
    end
    ---@type parser.object?
    local base = source.node
    if base and base.type == 'getlocal' and base.node then
        local loc = base.node
        if isFresh(loc) and guide.getParentFunction(loc) == func then
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

    local readonlyNames = getReadonlyNames(uri)
    if next(readonlyNames) == nil then
        return
    end

    ---@async
    guide.eachSourceTypes(state.ast, { 'setfield', 'setindex' }, function (source)
        local key = vm.getKeyName(source)
        if key == nil or not readonlyNames[key] then
            return
        end
        await.delay()
        if isBuilding(source) then
            return
        end
        for _, def in ipairs(vm.getDefs(source)) do
            if def.type == 'doc.field' and def.readonly then
                ---@type parser.object
                local at = source.field or source.index or source
                callback {
                    start   = at.start,
                    finish  = at.finish,
                    message = MESSAGE:format(key),
                }
                return
            end
        end
    end)
end
