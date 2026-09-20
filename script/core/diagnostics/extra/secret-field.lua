-- Companion of need-check-secret.lua (which owns the flag that says a value is secret).
-- `---@field name nosecret string` says a field cannot hold a secret value: an assignment
-- `obj.name = value`, `obj['name'] = value` or a table constructor `{ name = value }` typed as the
-- class that passes a value known to be secret is reported on the value. A value that was checked
-- with a `---@secret-check` function is not secret any more, and a field without the keyword
-- takes anything. The `nosecret` keyword belongs to the secret vocabulary and is registered next to
-- `secret` in need-check-secret.lua; this file only reads it.

local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'
local scope           = require 'workspace.scope'

local MESSAGE = 'Field `%s` cannot hold a secret value.'

protoDiagnostic.register {
    'secret-field',
} {
    group    = 'secret',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for assigning a secret value to a field that is declared `nosecret` (`---@field name nosecret string`).',
}

--- The names of the fields that some class declares `nosecret`. Worked out once per scope until a
--- file changes: most workspaces have none, and then no assignment needs a second look (a check that
--- compiled the value of every field assignment for that would change what the other checks meet
--- first: it once made an unrelated file infer differently in the editor).
---@param uri uri
---@return table<string|integer, true>
local function getNoSecretFieldNames(uri)
    local cache = vm.getCache('secret-field.names') --[[@as table<string, table<string|integer, true>>]]
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
                if fieldName ~= nil and field.extends and field.extends.nosecret then
                    found[fieldName] = true
                end
            end
        end
    end
    cache[key] = found
    return found
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local noSecretNames = getNoSecretFieldNames(uri)
    if next(noSecretNames) == nil then
        return
    end

    ---@async
    guide.eachSourceTypes(state.ast, { 'setfield', 'setindex', 'tablefield', 'tableindex' }, function (source)
        local value = source.value
        if not value then
            return
        end
        local key = vm.getKeyName(source)
        if key == nil or not noSecretNames[key] then
            return
        end
        await.delay()
        -- (the cheap question first: most values are not secret, and what the field is declared as
        -- is only looked up for the ones that are)
        if not vm.compileNode(value):hasFlag('secret') then
            return
        end
        -- the declarations of the field the class (or the classes it inherits from) has
        ---@type string?
        local name
        for _, def in ipairs(vm.getDefs(source)) do
            if def.type == 'doc.field' and def.extends and def.extends.nosecret then
                name = name or (def.field and def.field[1] --[[@as string?]])
            end
        end
        if name then
            callback {
                start   = value.start,
                finish  = value.finish,
                message = MESSAGE:format(name),
            }
        end
    end)
end
