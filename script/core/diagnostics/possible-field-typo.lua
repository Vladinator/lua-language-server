local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'The assignment declares a new field `%s` of `%s`, one edit away from the declared field `%s`: did you mean `%s`?'

-- names this short differ from many words by one letter without being a typo
local MIN_LENGTH = 4

protoDiagnostic.register {
    'possible-field-typo',
} {
    group    = 'type-check',
    severity = 'Information',
    status   = 'Opened',
    description = 'Enable diagnostics for a field a method of a `---@class` declares by assigning it (`self.totl = 1`) whose name is one edit (a letter added, dropped (not a plural `s`) or changed, two swapped, or another case) away from a field the class declares.',
}

--- Whether two different names are one edit apart (case folded: `Name` and `name` count).
---@param a string
---@param b string
---@return boolean
local function oneEditApart(a, b)
    if a == b then
        return false
    end
    -- (`client` next to `_client`: a public and a private name on purpose)
    if #a:match '^_*' ~= #b:match '^_*' then
        return false
    end
    local la, lb = a:lower(), b:lower()
    -- (`Event` and `Events`: a plural is a different name, not a typo)
    if la .. 's' == lb or lb .. 's' == la then
        return false
    end
    if la == lb then
        return true
    end
    local na, nb = #la, #lb
    if math.abs(na - nb) > 1 then
        return false
    end
    local i = 1
    while i <= na and i <= nb and la:sub(i, i) == lb:sub(i, i) do
        i = i + 1
    end
    -- the rest after the first difference must match with one edit
    local ra, rb = la:sub(i), lb:sub(i)
    if na == nb then
        -- one letter changed, or two neighbours swapped
        return ra:sub(2) == rb:sub(2)
            or (#ra >= 2 and ra:sub(1, 1) == rb:sub(2, 2) and ra:sub(2, 2) == rb:sub(1, 1) and ra:sub(3) == rb:sub(3))
    end
    if na > nb then
        return ra:sub(2) == rb
    end
    return ra == rb:sub(2)
end

--- The names of the fields the class and its parents declare with `---@field`.
---@param uri   uri
---@param class vm.global
---@return table<string, true>
local function declaredFields(uri, class)
    ---@type table<string, true>
    local names = {}
    vm.getClassFields(uri, class, vm.ANY, function (field)
        if field.type == 'doc.field' then
            local key = vm.getKeyName(field)
            if type(key) == 'string' then
                names[key] = true
            end
        end
    end)
    return names
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@type table<string, table<string, true>>
    local cache = {}

    ---@async
    guide.eachSourceType(state.ast, 'setfield', function (source)
        local key = guide.getKeyName(source)
        if type(key) ~= 'string' or #key < MIN_LENGTH then
            return
        end
        await.delay()
        local class = source.node and vm.getDefinedClass(uri, source.node)
        if not class then
            return
        end
        local declared = cache[class.name]
        if not declared then
            declared = declaredFields(uri, class)
            cache[class.name] = declared
        end
        if declared[key] then
            return
        end
        -- (the nearest name in alphabetical order, so that the message does not depend on `pairs`)
        ---@type string?
        local best
        for name in pairs(declared) do
            if #name >= MIN_LENGTH and oneEditApart(key, name) and (not best or name < best) then
                best = name
            end
        end
        if best then
            local field = source.field
            callback {
                start   = field and field.start or source.start,
                finish  = field and field.finish or source.finish,
                message = MESSAGE:format(key, class.name, best, best),
            }
        end
    end)
end
