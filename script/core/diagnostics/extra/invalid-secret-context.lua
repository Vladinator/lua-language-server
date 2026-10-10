-- Secret values by CONTEXT (wowlua-ls's model): an API can say under which restriction its results are secret, and a guard function can prove
-- that the restriction is not in effect, so the code it guards sees ordinary values:
--
--     ---@secret-when AurasRestricted          the results of this API are secret when the predicate holds (still typed `secret<T>`)
--     ---@secret-when AurasRestricted          ... above a `---@class`: its `secret` fields are, wherever they are read
--     ---@secret-unless unit player pet         ... but not for these literal arguments of the parameter `unit`
--     ---@secret-clears AurasRestricted unit    a guard: where its result is falsy the predicate (for the same `unit`) does not hold
--     ---@secret-clears *                       ... every secret is cleared
--     ---@secret-restriction-guard Combat       a guard: where its result is falsy the restriction `Combat` is not active
--     ---@secret-precondition Name              a call that needs it, and returns nothing when it fails
--     ---@secret-satisfies Name unit            a guard: where its result is truthy the precondition holds (the call keeps no `nil`)
--
-- How: a pass over the syntax of each function works out, for every call, the facts that hold at it (the body of an `if` whose condition
-- is a guard, the rest of a block after an early exit or an `assert`, the right operand of `and` / `or`, a `while` body). A late genesis rule
-- on the call then clears the secret flag of its result when the facts cover every predicate the callee names. It is a region pass, as
-- wowlua-ls does it: it never touches the flow engine. A function written inside a guarded region runs later and starts again with nothing.
--
-- Everything is here: the tags, the pass and the diagnostic `invalid-secret-context` that reports a tag that cannot be read. Deleting this
-- file removes the feature. Its tests are next to it.

local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'
local docTags         = require 'parser.docTags'
local scope           = require 'workspace.scope'

protoDiagnostic.register {
    'invalid-secret-context',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for a secret-context tag (`---@secret-when`, `---@secret-unless`, `---@secret-clears`, `---@secret-restriction-guard`, `---@secret-precondition`, `---@secret-satisfies`) that is not of its form, is not above a function, or names a parameter the function does not have.',
}

-- The tags --------------------------------------------------------------------------------------------

---@type table<string, string>
local TAGS = {
    ['secret-unless'] = 'wowlua-ls: a call passing one of these literals for a parameter returns ordinary values: `---@secret-unless unit player pet`.',
    ['secret-when'] = 'wowlua-ls: the restriction predicate under which the results are secret: `---@secret-when Predicate [description]`. A guard that clears the predicate makes them ordinary.',
    ['secret-clears'] = 'wowlua-ls: a guard that clears predicates where its result is falsy: `---@secret-clears Predicate[,Predicate...] [binding...] [== Value]`; `*` clears every secret; a binding is a parameter, optionally `=` the names the cleared APIs give that value (`unit=unit,unitToken`).',
    ['secret-restriction-guard'] = 'wowlua-ls: a guard that proves a restriction inactive where its result is falsy: `---@secret-restriction-guard param|Restriction [== Value]`.',
    ['secret-precondition'] = 'wowlua-ls: a precondition the call needs: `---@secret-precondition Name [ReturnNothing|ReturnWithError|Error] [description]`.',
    ['secret-satisfies'] = 'wowlua-ls: a guard that proves the precondition holds where its result is truthy: `---@secret-satisfies Name [binding...]`.',
}
--- The line a hover of the function shows for each tag (the restriction under which the results are secret, what a guard clears, ...).
---@type table<string, fun(tag: secretContext.tag): string?>
local NOTES = {
    ['secret-when'] = function (tag) return ('**Secret when** `%s` holds. A guard that clears it makes the results ordinary.'):format(tag.predicate) end,
    ['secret-unless'] = function (tag)
        return ('**Ordinary results** when `%s` is `%s`.'):format(tag.param, table.concat(tag.literals or {}, '`, `'))
    end,
    ['secret-clears'] = function (tag)
        local what = tag.all and 'every secret' or ('`' .. table.concat(tag.predicates or {}, '`, `') .. '`')
        return ('**Guard:** where its result is %s, %s is cleared.'):format(tag.value and ('`' .. tag.value .. '`') or 'falsy', what)
    end,
    ['secret-restriction-guard'] = function (tag)
        return ('**Guard:** where its result is %s, the restriction `%s` is not active.'):format(
            tag.value and ('`' .. tag.value .. '`') or 'falsy', tag.restriction or tag.param or '?')
    end,
    ['secret-precondition'] = function (tag) return ('**Needs** `%s` to hold.'):format(tag.name) end,
    ['secret-satisfies'] = function (tag) return ('**Guard:** where its result is truthy, `%s` holds.'):format(tag.name) end,
}

for name, description in pairs(TAGS) do
    local docType = 'doc.' .. name
    docTags.registerMarkerTag(name, docType, description)
    docTags.registerBindRule(docType, function (_doc, source, _isParam)
        return source.type == 'function'
    end)
    docTags.setTagFlavors(name, { 'luals', 'wowluals' })
end

--- The restrictions an addon can be under (`Enum.AddOnRestrictionType`).
---@type table<string, true>
local RESTRICTIONS = { Combat = true, Encounter = true, ChallengeMode = true, PvPMatch = true, Map = true, Chat = true }

--- The restrictions a secrecy predicate depends on: it is cleared once every one of them is inactive. A predicate that is not here depends
--- on more than a restriction (a unit, a spell) and only its own guard clears it.
---@type table<string, string[]>
local PREDICATE_RESTRICTIONS = {
    SecretWhenInCombat                  = { 'Combat' },
    SecretWhenAurasRestricted           = { 'Combat', 'Encounter', 'ChallengeMode', 'PvPMatch' },
    SecretWhenUnitAuraRestricted        = { 'Combat', 'Encounter', 'ChallengeMode', 'PvPMatch' },
    SecretWhenCooldownsRestricted       = { 'Combat', 'Encounter', 'ChallengeMode', 'PvPMatch' },
    SecretWhenTotemSlotSecret           = { 'Combat', 'Encounter', 'ChallengeMode', 'PvPMatch' },
    SecretInChatMessagingLockdown       = { 'Encounter', 'ChallengeMode', 'PvPMatch', 'Chat' },
    SecretOnRestrictedMaps              = { 'Map' },
    SecretWhenUnitComparisonRestricted  = { 'Map' },
    SecretInActivePvPMatch              = { 'PvPMatch' },
    SecretWhenEncounterEvent            = { 'Encounter' },
}

-- Reading a tag ---------------------------------------------------------------------------------------

---@class secretContext.binding
---@field param string  the parameter of the guard
---@field names string[] the names the cleared APIs give that value (the parameter's own name when none is written)

---@class secretContext.tag
---@field kind        string   the doc type
---@field predicate?  string   secret-when
---@field param?      string   secret-unless; secret-restriction-guard when it names a parameter
---@field literals?   string[] secret-unless
---@field all?        boolean  secret-clears *
---@field predicates? string[] secret-clears
---@field bindings?   secretContext.binding[] secret-clears, secret-satisfies
---@field value?      string   the text after `==` of a guard
---@field restriction? string  secret-restriction-guard with a fixed restriction
---@field name?       string   secret-precondition, secret-satisfies

--- `a=b,c` or `a`
---@param word string
---@return secretContext.binding?
local function parseBinding(word)
    ---@type string?, string?
    local param, names = word:match '^([%w_]+)=([%w_,]+)$'
    if param and names then
        ---@type string[]
        local list = {}
        for name in names:gmatch '[%w_]+' do
            list[#list+1] = name
        end
        return { param = param, names = list }
    end
    if word:match '^[%w_]+$' then
        return { param = word, names = { word } }
    end
    return nil
end

---@param words string[]
---@param from   integer
---@return secretContext.binding[]?
local function parseBindings(words, from)
    ---@type secretContext.binding[]
    local list = {}
    for i = from, #words do
        local binding = parseBinding(words[i])
        if not binding then
            return nil
        end
        list[#list+1] = binding
    end
    return list
end

--- Reads the text after the tag name. Returns nil and what is wrong when it does not read.
---@param doc parser.object
---@return secretContext.tag?
---@return string? problem
local function readTag(doc)
    local text = doc.comment and doc.comment.text or ''
    local kind = doc.type
    ---@type secretContext.tag
    local tag = { kind = kind }
    -- `== Value` ends a guard
    local head, value = text, nil
    if kind == 'doc.secret-clears' or kind == 'doc.secret-restriction-guard' then
        local before, after = text:match '^(.-)%s*==%s*(.-)%s*$'
        if before then
            head, value = before, after
            if value == '' then
                return nil, 'Expected a value after `==`.'
            end
            tag.value = value
        end
    end
    ---@type string[]
    local words = {}
    for word in head:gsub(',%s+', ','):gmatch '%S+' do
        words[#words+1] = word
    end
    if kind == 'doc.secret-when' then
        if not words[1] or not words[1]:match '^[%w_]+$' then
            return nil, 'Expected the predicate: `---@secret-when Predicate [description]`.'
        end
        tag.predicate = words[1]
    elseif kind == 'doc.secret-unless' then
        if #words < 2 then
            return nil, 'Expected a parameter and the literals it is exempt for: `---@secret-unless unit player pet`.'
        end
        tag.param    = words[1]
        tag.literals = { table.unpack(words, 2) }
    elseif kind == 'doc.secret-clears' then
        if not words[1] then
            return nil, 'Expected the predicates (or `*`): `---@secret-clears Predicate[,Predicate...] [binding...] [== Value]`.'
        end
        if words[1] == '*' then
            if #words > 1 then
                return nil, '`*` clears every secret and takes no bindings.'
            end
            tag.all = true
            return tag
        end
        ---@type string[]
        local predicates = {}
        for predicate in words[1]:gmatch '[^,]+' do
            if not predicate:match '^[%w_]+$' then
                return nil, ('`%s` is not a predicate name.'):format(predicate)
            end
            predicates[#predicates+1] = predicate
        end
        tag.predicates = predicates
        tag.bindings   = parseBindings(words, 2)
        if not tag.bindings then
            return nil, 'A binding is a parameter, optionally followed by `=` and the names the cleared APIs give it: `unit=unit,unitToken`.'
        end
    elseif kind == 'doc.secret-restriction-guard' then
        if not words[1] or #words > 1 then
            return nil, 'Expected a restriction or the parameter that names it: `---@secret-restriction-guard Combat`.'
        end
        if RESTRICTIONS[words[1]] then
            tag.restriction = words[1]
        else
            tag.param = words[1]
        end
    elseif kind == 'doc.secret-precondition' then
        if not words[1] or not words[1]:match '^[%w_]+$' then
            return nil, 'Expected the name of the precondition: `---@secret-precondition Name`.'
        end
        tag.name = words[1]
    elseif kind == 'doc.secret-satisfies' then
        if not words[1] or not words[1]:match '^[%w_]+$' then
            return nil, 'Expected the name of the precondition: `---@secret-satisfies Name [binding...]`.'
        end
        tag.name     = words[1]
        tag.bindings = parseBindings(words, 2)
        if not tag.bindings then
            return nil, 'A binding is a parameter, optionally followed by `=` and the names the cleared APIs give it: `unit=unit,unitToken`.'
        end
    end
    return tag
end

---@type table<parser.object, secretContext.tag|false>
local readCache = setmetatable({}, { __mode = 'k' })

---@param doc parser.object
---@return secretContext.tag?
local function tagOf(doc)
    local cached = readCache[doc]
    if cached == nil then
        cached = readTag(doc) or false
        readCache[doc] = cached
    end
    return cached or nil
end

--- The `---@class` right below a tag (only comments and other tags between): the tag is the class's.
---@param docs parser.object[]
---@param i    integer
---@return parser.object?
local function classAfter(docs, i)
    for j = i + 1, #docs do
        local doc = docs[j]
        if doc.type == 'doc.class' then
            return doc
        elseif doc.type ~= 'doc.comment' and not doc.type:find '^doc%.secret' then
            return nil
        end
    end
    return nil
end

---@param doc parser.object
---@return boolean
local function isContextDoc(doc)
    return TAGS[doc.type:sub(5)] ~= nil
end

local index = vm.createTaggedIndex('secret-context', isContextDoc)

-- Facts -----------------------------------------------------------------------------------------------

--- A binding of a guard, worked out for one call of it: the names the cleared APIs give the value, and what the call passed for it.
---@class secretContext.bound
---@field names string[]
---@field value string|false

--- What a guard proved, for the code it guards.
---@class secretContext.fact
---@field key          string
---@field all?         boolean            every secret is cleared
---@field predicates?  table<string, true> these predicates do not hold ...
---@field bindings?    secretContext.bound[]  ... for calls whose argument for one of the names is this value
---@field restriction? string             this restriction is inactive
---@field satisfies?   string             this precondition holds (for the bound arguments)

---@alias secretContext.facts secretContext.fact[]

---@type secretContext.facts
local NONE = {}

local nextLocalID = 0
---@type table<parser.object, integer>
local localIDs = setmetatable({}, { __mode = 'k' })

--- Whether two expressions stand for the same local, field path or literal.
---@param expr parser.object?
---@return string?
local function valueKey(expr)
    if not expr then
        return nil
    end
    local t = expr.type
    if t == 'getlocal' and expr.node then
        local id = localIDs[expr.node]
        if not id then
            nextLocalID = nextLocalID + 1
            id = nextLocalID
            localIDs[expr.node] = id
        end
        return 'L' .. id
    elseif t == 'getglobal' then
        return 'G' .. tostring(expr[1])
    elseif t == 'getfield' then
        local base = valueKey(expr.node)
        local field = expr.field and expr.field[1]
        return base and field and (base .. '.' .. tostring(field)) or nil
    elseif t == 'string' or t == 'integer' or t == 'number' or t == 'boolean' then
        return t:sub(1, 1) .. tostring(expr[1])
    end
    return nil
end

--- The text of a path (`Enum.AddOnRestrictionType.Combat`), or of a literal.
---@param expr parser.object?
---@return string?
local function pathText(expr)
    if not expr then
        return nil
    end
    local t = expr.type
    if t == 'getglobal' or t == 'getlocal' then
        return tostring(expr[1])
    elseif t == 'getfield' then
        local base = pathText(expr.node)
        local field = expr.field and expr.field[1]
        return base and field and (base .. '.' .. tostring(field)) or nil
    elseif t == 'boolean' or t == 'nil' then
        return tostring(expr[1])
    elseif t == 'string' then
        return ('%q'):format(expr[1])
    elseif t == 'integer' or t == 'number' then
        return tostring(expr[1])
    end
    return nil
end

--- The argument a call passes for the parameter `name` of the function `func` (the arguments of a colon call start with the implicit `self`).
---@param call parser.object
---@param func parser.object
---@param name string
---@return parser.object?
local function argFor(call, func, name)
    for i, param in ipairs(func.args or {}) do
        if param[1] == name then
            local arg = call.args and call.args[i]
            if arg and arg.type == 'self' and call.node.type == 'getmethod' then
                return call.node.node
            end
            return arg
        end
    end
    return nil
end

--- `Enum.AddOnRestrictionType.Combat`, directly or through a local alias of the enum.
---@param expr parser.object?
---@return string?
local function restrictionOf(expr)
    if not expr or expr.type ~= 'getfield' or not expr.field then
        return nil
    end
    local name = expr.field[1]
    if type(name) ~= 'string' or not RESTRICTIONS[name] then
        return nil
    end
    local base = expr.node
    if pathText(base) == 'Enum.AddOnRestrictionType' then
        return name
    end
    local decl = base and base.type == 'getlocal' and base.node
    if decl and decl.type == 'local' and decl.value and pathText(decl.value) == 'Enum.AddOnRestrictionType' then
        return name
    end
    return nil
end

---@param bindings secretContext.binding[]?
---@param call     parser.object
---@param func     parser.object
---@return secretContext.bound[]
local function bindingsOf(bindings, call, func)
    ---@type secretContext.bound[]
    local result = {}
    for _, binding in ipairs(bindings or {}) do
        result[#result+1] = { names = binding.names, value = valueKey(argFor(call, func, binding.param)) or false }
    end
    return result
end

---@param bindings secretContext.bound[]
---@return string
local function bindingsKey(bindings)
    ---@type string[]
    local parts = {}
    for _, binding in ipairs(bindings) do
        parts[#parts+1] = table.concat(binding.names, ',') .. '=' .. tostring(binding.value)
    end
    return table.concat(parts, ';')
end

--- The facts of one tag of a guard called here.
---@param tag  secretContext.tag
---@param call parser.object
---@param func parser.object
---@return secretContext.fact?
local function factOf(tag, call, func)
    if tag.kind == 'doc.secret-clears' then
        if tag.all then
            return { key = 'all', all = true }
        end
        ---@type table<string, true>
        local predicates = {}
        for _, predicate in ipairs(tag.predicates or {}) do
            predicates[predicate] = true
        end
        local bindings = bindingsOf(tag.bindings, call, func)
        ---@type string[]
        local names = {}
        for predicate in pairs(predicates) do
            names[#names+1] = predicate
        end
        table.sort(names)
        return { key = 'p:' .. table.concat(names, ',') .. '|' .. bindingsKey(bindings), predicates = predicates, bindings = bindings }
    elseif tag.kind == 'doc.secret-restriction-guard' then
        local restriction = tag.restriction or restrictionOf(argFor(call, func, tag.param or ''))
        if restriction then
            return { key = 'r:' .. restriction, restriction = restriction }
        end
    elseif tag.kind == 'doc.secret-satisfies' then
        local bindings = bindingsOf(tag.bindings, call, func)
        return { key = 's:' .. tostring(tag.name) .. '|' .. bindingsKey(bindings), satisfies = tag.name, bindings = bindings }
    end
    return nil
end

---@param a secretContext.facts
---@param b secretContext.facts
---@return secretContext.facts
local function union(a, b)
    if #a == 0 then
        return b
    elseif #b == 0 then
        return a
    end
    ---@type secretContext.facts
    local result = { table.unpack(a) }
    ---@type table<string, true>
    local seen = {}
    for _, fact in ipairs(a) do
        seen[fact.key] = true
    end
    for _, fact in ipairs(b) do
        if not seen[fact.key] then
            seen[fact.key] = true
            result[#result+1] = fact
        end
    end
    return result
end

--- What holds on both of two paths.
---@param a secretContext.facts
---@param b secretContext.facts
---@return secretContext.facts
local function intersect(a, b)
    if #a == 0 or #b == 0 then
        return NONE
    end
    ---@type table<string, true>
    local inB = {}
    for _, fact in ipairs(b) do
        inB[fact.key] = true
    end
    ---@type secretContext.facts
    local result = {}
    for _, fact in ipairs(a) do
        if inB[fact.key] then
            result[#result+1] = fact
        end
    end
    return result
end

--- The guards a call is one of: the facts it proves where its result is falsy / truthy / equal to the value of the tag.
---@param call parser.object
---@return secretContext.facts whenFalsy
---@return secretContext.facts whenTruthy
---@return table<string, secretContext.facts> whenEqual by the text after `==`
local function guardFacts(call)
    ---@type secretContext.facts, secretContext.facts
    local falsy, truthy = NONE, NONE
    ---@type table<string, secretContext.facts>
    local equal = {}
    local callee = call.node
    if not callee or not index.match(callee) then
        return falsy, truthy, equal
    end
    for _, found in ipairs(index.docsOf(callee)) do
        local tag = tagOf(found.doc)
        if tag then
            local fact = factOf(tag, call, found.func)
            if fact then
                if tag.value then
                    equal[tag.value] = union(equal[tag.value] or NONE, { fact })
                elseif tag.kind == 'doc.secret-satisfies' then
                    truthy = union(truthy, { fact })
                else
                    falsy = union(falsy, { fact })
                end
            end
        end
    end
    return falsy, truthy, equal
end

--- Is `expr` the name of a table whose member is called on the right (`C_Secrets and C_Secrets.Should()`)? Then a falsy left side means the API
--- does not exist, which is a client without secrets at all.
---@param left  parser.object
---@param right parser.object
---@return boolean
local function isNamespaceCheck(left, right)
    local namespace = pathText(left)
    if not namespace then
        return false
    end
    ---@type string?
    local callee = right.type == 'call' and pathText(right.node) or nil
    return callee ~= nil and callee:sub(1, #namespace + 1) == namespace .. '.'
end

---@param expr  parser.object?
---@param depth integer
---@return secretContext.facts whenTruthy
---@return secretContext.facts whenFalsy
local function conditionFacts(expr, depth)
    if not expr or depth > 8 then
        return NONE, NONE
    end
    local t = expr.type
    if t == 'select' and expr.vararg then
        -- (`local ok = f()` holds the first of the results of the call)
        return conditionFacts(expr.vararg, depth + 1)
    elseif t == 'paren' then
        return conditionFacts(expr.exp, depth + 1)
    elseif t == 'unary' and expr.op and expr.op.type == 'not' then
        local truthy, falsy = conditionFacts(expr[1], depth + 1)
        return falsy, truthy
    elseif t == 'binary' and expr.op then
        local op = expr.op.type
        local left, right = expr[1], expr[2]
        if op == 'and' and left and right then
            local leftTruthy, leftFalsy = conditionFacts(left, depth + 1)
            local rightTruthy, rightFalsy = conditionFacts(right, depth + 1)
            if isNamespaceCheck(left, right) then
                -- (a falsy left side means no such API, a client without secrets: nothing is lost by the check)
                return union(leftTruthy, rightTruthy), rightFalsy
            end
            return union(leftTruthy, rightTruthy), intersect(leftFalsy, rightFalsy)
        elseif op == 'or' and left and right then
            local leftTruthy, leftFalsy = conditionFacts(left, depth + 1)
            local rightTruthy, rightFalsy = conditionFacts(right, depth + 1)
            return intersect(leftTruthy, rightTruthy), union(leftFalsy, rightFalsy)
        elseif (op == '==' or op == '~=') and left and right then
            local call, other = left, right
            if right.type == 'call' then
                call, other = right, left
            end
            if call.type == 'call' then
                local _, _, equal = guardFacts(call)
                local proven = equal[pathText(other) or '']
                if proven then
                    if op == '==' then
                        return proven, NONE
                    end
                    return NONE, proven
                end
            end
        end
    elseif t == 'call' then
        local falsy, truthy = guardFacts(expr)
        return truthy, falsy
    elseif t == 'getlocal' and expr.node and expr.node.type == 'local' then
        -- a boolean holding the result of a guard, until it is written again
        local decl = expr.node
        for _, ref in ipairs(decl.ref or {}) do
            if ref.type == 'setlocal' and ref.start < expr.start then
                return NONE, NONE
            end
        end
        if decl.value then
            return conditionFacts(decl.value, depth + 1)
        end
    end
    return NONE, NONE
end

-- The pass --------------------------------------------------------------------------------------------

--- Does a block end in a statement that leaves it?
---@param block parser.object
---@return boolean
local function leaves(block)
    local last = block[#block]
    if not last then
        return false
    end
    local t = last.type
    if t == 'return' or t == 'break' or t == 'goto' then
        return true
    end
    return t == 'call' and last.node ~= nil and last.node.type == 'getglobal' and last.node[1] == 'error'
end

---@type fun(stmt: parser.object, facts: secretContext.facts, record: table<parser.object, secretContext.facts>): secretContext.facts
local walkStatement

---@param block  parser.object
---@param facts  secretContext.facts
---@param record table<parser.object, secretContext.facts>
local function walkBlock(block, facts, record)
    for _, stmt in ipairs(block) do
        facts = walkStatement(stmt, facts, record)
    end
end

---@param expr   parser.object?
---@param facts  secretContext.facts
---@param record table<parser.object, secretContext.facts>
local function scan(expr, facts, record)
    if not expr or expr.type == 'function' then
        -- (a function written here runs later: it is a pass of its own)
        return
    end
    if expr.type == 'binary' and expr.op and (expr.op.type == 'and' or expr.op.type == 'or') then
        scan(expr[1], facts, record)
        local truthy, falsy = conditionFacts(expr[1], 0)
        scan(expr[2], union(facts, expr.op.type == 'and' and truthy or falsy), record)
        return
    end
    if (expr.type == 'call' or expr.type == 'getfield') and #facts > 0 then
        record[expr] = facts
    end
    guide.eachChild(expr, function (child)
        scan(child, facts, record)
    end)
end

walkStatement = function (stmt, facts, record)
    local t = stmt.type
    if t == 'if' then
        local running = facts
        ---@type secretContext.facts[]
        local exits = {}
        local hasElse = false
        for _, sub in ipairs(stmt) do
            if sub.filter then
                scan(sub.filter, running, record)
                local truthy, falsy = conditionFacts(sub.filter, 0)
                local inside = union(running, truthy)
                walkBlock(sub, inside, record)
                if not leaves(sub) then
                    exits[#exits+1] = inside
                end
                running = union(running, falsy)
            else
                hasElse = true
                walkBlock(sub, running, record)
                if not leaves(sub) then
                    exits[#exits+1] = running
                end
            end
        end
        if not hasElse then
            exits[#exits+1] = running
        end
        -- after the statement: what holds on every way out of it
        local after = exits[1]
        for i = 2, #exits do
            after = intersect(after, exits[i])
        end
        return after or facts
    elseif t == 'while' then
        scan(stmt.filter, facts, record)
        local truthy = conditionFacts(stmt.filter, 0)
        walkBlock(stmt, union(facts, truthy), record)
        return facts
    elseif t == 'do' then
        walkBlock(stmt, facts, record)
        return facts
    elseif t == 'repeat' then
        walkBlock(stmt, facts, record)
        scan(stmt.filter, facts, record)
        return facts
    elseif t == 'loop' then
        scan(stmt.init, facts, record)
        scan(stmt.max, facts, record)
        scan(stmt.step, facts, record)
        walkBlock(stmt, facts, record)
        return facts
    elseif t == 'in' then
        for _, exp in ipairs(stmt.exps or {}) do
            scan(exp, facts, record)
        end
        walkBlock(stmt, facts, record)
        return facts
    elseif t == 'call' and stmt.node and stmt.node.special == 'assert' and stmt.args and stmt.args[1] then
        scan(stmt, facts, record)
        local truthy = conditionFacts(stmt.args[1], 0)
        return union(facts, truthy)
    end
    scan(stmt, facts, record)
    return facts
end

--- The facts at each call of a function (calls with none are absent).
---@param root parser.object a function or the main chunk
---@return table<parser.object, secretContext.facts>
local function factsOfFunction(root)
    local uri   = guide.getUri(root)
    local cache = files.getCache(uri)
    ---@type table<parser.object, table<parser.object, secretContext.facts>>
    local byRoot
    if cache then
        byRoot = cache['secret-context.facts']
        if not byRoot then
            byRoot = {}
            cache['secret-context.facts'] = byRoot
        end
    else
        byRoot = {}
    end
    local record = byRoot[root]
    if not record then
        record = {}
        byRoot[root] = record
        walkBlock(root, NONE, record)
    end
    return record
end

-- The effect on a call ----------------------------------------------------------------------------------

---@param fact secretContext.fact
---@param call parser.object
---@param func parser.object
---@return boolean
local function bindingsMatch(fact, call, func)
    ---@type secretContext.bound[]
    local bindings = fact.bindings or {}
    for _, binding in ipairs(bindings) do
        local matched = false
        ---@type string[]
        local names = binding.names
        for _, name in ipairs(names) do
            local key = binding.value and valueKey(argFor(call, func, name))
            if key and key == binding.value then
                matched = true
                break
            end
        end
        if not matched then
            return false
        end
    end
    return true
end

---@param predicate string
---@param facts     secretContext.facts
---@param call?     parser.object the call, nil for a field read: a structure does not depend on the unit it describes, so bindings are not asked
---@param func?     parser.object
---@return boolean
local function isCleared(predicate, facts, call, func)
    ---@type table<string, true>
    local inactive = {}
    for _, fact in ipairs(facts) do
        if fact.all or (fact.predicates and fact.predicates[predicate]
            and (not call or not func or bindingsMatch(fact, call, func))) then
            return true
        end
        if fact.restriction then
            inactive[fact.restriction] = true
        end
    end
    local needed = PREDICATE_RESTRICTIONS[predicate]
    if not needed then
        return false
    end
    for _, restriction in ipairs(needed) do
        if not inactive[restriction] then
            return false
        end
    end
    return true
end

--- What the context does to the result of a call: its secrecy is cleared, its `nil` (the precondition failed) is dropped.
---@param call parser.object
---@return boolean clearsSecret
---@return boolean dropsNil
local function effectOf(call)
    local callee = call.node
    if not callee or not index.any(guide.getUri(call)) then
        return false, false
    end
    local root = guide.getParentFunction(call) or guide.getRoot(call)
    local facts = factsOfFunction(root)[call]
    -- `---@secret-clears *` clears every secret in the code it guards, the results of calls that name no predicate too
    ---@type boolean
    local clears = false
    for _, fact in ipairs(facts or NONE) do
        if fact.all then
            clears = true
        end
    end
    if not index.match(callee) then
        return clears, false
    end
    ---@type { tag: secretContext.tag, func: parser.object }[]
    local mine = {}
    for _, found in ipairs(index.docsOf(callee)) do
        local tag = tagOf(found.doc)
        if tag then
            mine[#mine+1] = { tag = tag, func = found.func }
        end
    end
    local dropsNil = false
    ---@type { name: string, func: parser.object }[]
    local predicates = {}
    ---@type { name: string, func: parser.object }[]
    local preconditions = {}
    for _, entry in ipairs(mine) do
        local tag = entry.tag
        if tag.kind == 'doc.secret-unless' then
            local arg = argFor(call, entry.func, tag.param or '')
            if arg and arg.type == 'string' then
                for _, literal in ipairs(tag.literals or {}) do
                    if arg[1] == literal then
                        clears = true
                    end
                end
            end
        elseif tag.kind == 'doc.secret-when' then
            predicates[#predicates+1] = { name = tag.predicate or '', func = entry.func }
        elseif tag.kind == 'doc.secret-precondition' then
            preconditions[#preconditions+1] = { name = tag.name or '', func = entry.func }
        end
    end
    if (#predicates == 0 or clears) and #preconditions == 0 then
        return clears, false
    end
    if not facts then
        return clears, false
    end
    if not clears and #predicates > 0 then
        clears = true
        for _, predicate in ipairs(predicates) do
            if not isCleared(predicate.name, facts, call, predicate.func) then
                clears = false
                break
            end
        end
    end
    for _, precondition in ipairs(preconditions) do
        for _, fact in ipairs(facts) do
            if fact.satisfies == precondition.name and bindingsMatch(fact, call, precondition.func) then
                dropsNil = true
            end
        end
    end
    return clears, dropsNil
end

--- Late, so the rules that make the result secret (secret-access.lua) have run, whatever the order the plugins were loaded in.
vm.registerGenesisRule('call', function (source, node)
    local clears, dropsNil = effectOf(source)
    if clears then
        node:clearFlag('secret')
    end
    if dropsNil then
        node:removeOptional()
    end
end, true)

-- the hover of a function shows what its tags say (read with `readTag`, so it shows only a tag that reads)
for name in pairs(TAGS) do
    docTags.registerHoverNote('doc.' .. name, function (doc)
        local tag = readTag(doc)
        return tag and NOTES[name](tag) or nil
    end)
end

--- The predicates a class declares (`---@secret-when` right above its `---@class`), by class name, for the workspace of `uri`.
---@param uri uri
---@return table<string, string[]>
local function classPredicates(uri)
    local cache = vm.getCache('secret-context.classes') --[[@as table<string, table<string, string[]>>]]
    local key   = scope.getScope(uri):getName()
    local found = cache[key]
    if found then
        return found
    end
    ---@type table<string, string[]>
    found = {}
    for fileUri in files.eachFile(uri) do
        local state = files.getState(fileUri)
        local docs = state and state.ast.docs or {}
        for i, doc in ipairs(docs) do
            if doc.type == 'doc.secret-when' then
                local class = classAfter(docs, i)
                local tag = tagOf(doc)
                if class and tag and tag.predicate then
                    local name = class.class and class.class[1]
                    if type(name) == 'string' then
                        found[name] = found[name] or {}
                        table.insert(found[name], tag.predicate)
                    end
                end
            end
        end
    end
    cache[key] = found
    return found
end

--- A read of a field that a `---@secret-when` class declares secret: ordinary where the facts there clear every predicate of the class,
--- however the structure was obtained.
vm.registerGenesisRule('getfield', function (source, node)
    if not node:hasFlag('secret') or not source.node then
        return
    end
    local uri = guide.getUri(source)
    if not index.any(uri) then
        return
    end
    local root = guide.getParentFunction(source) or guide.getRoot(source)
    local facts = factsOfFunction(root)[source]
    if not facts then
        return
    end
    local byClass = classPredicates(uri)
    local base = vm.getNode(source.node)
    if not base then
        return
    end
    for object in base:eachObject() do
        ---@type string[]?
        local predicates
        if object.type == 'global' and object.cate == 'type' then
            predicates = byClass[object.name]
        end
        if predicates then
            for _, predicate in ipairs(predicates) do
                if not isCleared(predicate, facts) then
                    return
                end
            end
            node:clearFlag('secret')
            return
        end
    end
end, true)

-- (`local x = f()` reads a `select` of the results of the call)
vm.registerGenesisRule('select', function (source, node)
    local call = source.vararg
    if call and call.type == 'call' then
        local clears, dropsNil = effectOf(call)
        if clears then
            node:clearFlag('secret')
        end
        if dropsNil then
            node:removeOptional()
        end
    end
end, true)

-- Editor support -------------------------------------------------------------------------------------

---@class secretContext.word
---@field text   string
---@field start  integer absolute position
---@field finish integer

---@param doc parser.object
---@return secretContext.word[]
local function wordsOf(doc)
    local text = doc.comment and doc.comment.text or ''
    local base = doc.comment and doc.comment.start or 0
    ---@type secretContext.word[]
    local words = {}
    local from = 1
    while true do
        local first, last = text:find('%S+', from)
        if not first or not last then
            break
        end
        words[#words+1] = { text = text:sub(first, last), start = base + first - 1, finish = base + last }
        from = last + 1
    end
    return words
end

---@type table<string, true>
local FAILURE_MODES = { ReturnNothing = true, ReturnWithError = true, Error = true }

---@param tokens parser.docTags.tailToken[]
---@param word   secretContext.word
---@param first  integer offset in the word, 1-based
---@param last   integer
---@param role   string
local function push(tokens, word, first, last, role)
    tokens[#tokens+1] = { start = word.start + first - 1, finish = word.start + last, role = role }
end

--- `a,b,c`: every name a token of `role`, the commas operators.
---@param tokens parser.docTags.tailToken[]
---@param word   secretContext.word
---@param offset integer where in the word the list starts, 1-based
---@param role   string
local function pushList(tokens, word, offset, role)
    local from = offset
    while from <= #word.text do
        local first, last = word.text:find('[%w_]+', from)
        local comma = word.text:find(',', from, true)
        if comma and (not first or comma < first) then
            push(tokens, word, comma, comma, 'operator')
            from = comma + 1
        elseif first and last then
            push(tokens, word, first, last, role)
            from = last + 1
        else
            break
        end
    end
end

--- `param` or `param=name,name`
---@param tokens parser.docTags.tailToken[]
---@param word   secretContext.word
local function pushBinding(tokens, word)
    local param = word.text:match '^[%w_]+'
    if not param then
        return
    end
    push(tokens, word, 1, #param, 'parameter')
    if word.text:sub(#param + 1, #param + 1) == '=' then
        push(tokens, word, #param + 1, #param + 1, 'operator')
        pushList(tokens, word, #param + 2, 'parameter')
    end
end

--- `== Value` at the end of a guard: the operator, and the value as one token.
---@param tokens parser.docTags.tailToken[]
---@param words  secretContext.word[]
---@param i      integer the index of the `==`
local function pushValue(tokens, words, i)
    local operator = words[i]
    if not operator or operator.text ~= '==' then
        return
    end
    push(tokens, operator, 1, 2, 'operator')
    local first, last = words[i + 1], words[#words]
    if first and last then
        tokens[#tokens+1] = { start = first.start, finish = last.finish, role = 'variable' }
    end
end

---@param doc parser.object
---@return parser.docTags.tailToken[]
local function tailTokens(doc)
    ---@type parser.docTags.tailToken[]
    local tokens = {}
    local words = wordsOf(doc)
    local kind = doc.type
    local first = words[1]
    if not first then
        return tokens
    end
    if kind == 'doc.secret-when' then
        push(tokens, first, 1, #first.text, 'typeParameter')
    elseif kind == 'doc.secret-unless' then
        push(tokens, first, 1, #first.text, 'parameter')
        for i = 2, #words do
            push(tokens, words[i], 1, #words[i].text, 'string')
        end
    elseif kind == 'doc.secret-clears' then
        local i = 2
        if first.text == '*' then
            push(tokens, first, 1, 1, 'operator')
        else
            pushList(tokens, first, 1, 'typeParameter')
            -- (a comma at the end of a word continues the list in the next one)
            while words[i - 1].text:sub(-1) == ',' and words[i] do
                pushList(tokens, words[i], 1, 'typeParameter')
                i = i + 1
            end
            while words[i] and words[i].text ~= '==' do
                pushBinding(tokens, words[i])
                i = i + 1
            end
        end
        pushValue(tokens, words, i)
    elseif kind == 'doc.secret-restriction-guard' then
        push(tokens, first, 1, #first.text, RESTRICTIONS[first.text] and 'enumMember' or 'parameter')
        pushValue(tokens, words, 2)
    elseif kind == 'doc.secret-precondition' then
        push(tokens, first, 1, #first.text, 'typeParameter')
        local mode = words[2]
        if mode and FAILURE_MODES[mode.text] then
            push(tokens, mode, 1, #mode.text, 'enumMember')
        end
    elseif kind == 'doc.secret-satisfies' then
        push(tokens, first, 1, #first.text, 'typeParameter')
        for i = 2, #words do
            pushBinding(tokens, words[i])
        end
    end
    return tokens
end

--- What hover says about a part of the text of a tag.
---@type table<string, string>
local OPERATOR_HELP = {
    ['*']  = 'Clears every secret in the code this guard guards, whatever predicate it depends on.',
    ['=']  = 'The names the cleared APIs give this value: a later call is cleared only where its argument for one of them is the same local, field path or literal.',
    ['==']  = 'The guard clears when its result is equal to the value, not when it is falsy.',
}

---@type table<string, string>
local FAILURE_MODE_HELP = {
    ReturnNothing   = 'The call returns nothing when the precondition fails: every return is nilable.',
    ReturnWithError = 'The call returns nothing, with an error, when the precondition fails: every return is nilable.',
    Error           = 'The call raises an error when the precondition fails.',
}

---@param doc      parser.object
---@param position integer
---@return string? markdown
---@return integer? start
---@return integer? finish
local function tailHover(doc, position)
    for _, token in ipairs(tailTokens(doc)) do
        if position >= token.start and position <= token.finish then
            local text = (doc.comment.text):sub(token.start - doc.comment.start + 1, token.finish - doc.comment.start)
            ---@type string?
            local help
            if token.role == 'typeParameter' then
                if doc.type == 'doc.secret-precondition' or doc.type == 'doc.secret-satisfies' then
                    help = 'A precondition of a call, proven by a `---@secret-satisfies` guard.'
                else
                    local needed = PREDICATE_RESTRICTIONS[text]
                    help = needed
                        and ('A secrecy predicate. It depends on the restrictions %s: it is cleared by its own guard, or once all of them are proven inactive.')
                            :format('`' .. table.concat(needed, '`, `') .. '`')
                        or 'A secrecy predicate. It depends on more than a restriction (a unit, a spell): only its own guard clears it.'
                end
            elseif token.role == 'enumMember' then
                help = FAILURE_MODE_HELP[text]
                    or (RESTRICTIONS[text] and ('The addon restriction `Enum.AddOnRestrictionType.%s`.'):format(text))
            elseif token.role == 'parameter' then
                help = 'A parameter of the function the tag is above.'
            elseif token.role == 'operator' then
                help = OPERATOR_HELP[text]
            elseif token.role == 'string' then
                help = 'A literal argument that returns ordinary values.'
            elseif token.role == 'variable' then
                help = 'The value the result of the guard is compared with.'
            end
            if help then
                return ('`%s`\n\n%s'):format(text, help), token.start, token.finish
            end
            return nil
        end
    end
    return nil
end

---@param func parser.object?
---@param used table<string, true>
---@param into parser.docTags.tailCandidate[]
local function addParams(func, used, into)
    for _, param in ipairs(func and func.args or {}) do
        local name = param[1]
        if type(name) == 'string' and name ~= '...' and not used[name] then
            into[#into+1] = { label = name, role = 'parameter' }
        end
    end
end

--- The known predicates that the list being typed does not name yet.
---@param at parser.docTags.tailPosition
---@return parser.docTags.tailCandidate[]
local function unlistedPredicates(at)
    ---@type table<string, true>
    local listed = {}
    for _, word in ipairs(at.words) do
        for predicate in word:gmatch '[%w_]+' do
            listed[predicate] = true
        end
    end
    for predicate in at.partial:gmatch '[%w_]+' do
        listed[predicate] = true
    end
    ---@type parser.docTags.tailCandidate[]
    local found = {}
    for predicate in pairs(PREDICATE_RESTRICTIONS) do
        if not listed[predicate] then
            found[#found+1] = { label = predicate, role = 'typeParameter' }
        end
    end
    table.sort(found, function (a, b) return a.label < b.label end)
    return found
end

---@param kind string a doc type
---@return parser.docTags.tailCompleter
local function completerOf(kind)
    return function (at)
        local index = #at.words + 1
        ---@type parser.docTags.tailCandidate[]
        local found = {}
        for _, word in ipairs(at.words) do
            if word == '==' then
                -- (after the operator comes the value of the guard)
                return found
            end
        end
        -- the parts of one word: `A,B,part` (a list of predicates), `unit=name,part` (a binding)
        ---@type string?
        local typed
        local inPredicateList = false
        if kind == 'doc.secret-clears' and at.words[1] ~= '*' then
            inPredicateList = index == 1
            if index > 1 then
                -- (a comma at the end of a word continues the list in the next one)
                inPredicateList = true
                for _, word in ipairs(at.words) do
                    if word:sub(-1) ~= ',' then
                        inPredicateList = false
                    end
                end
            end
        end
        if inPredicateList then
            typed = at.partial:match '[^,]*$'
        elseif at.partial:find '[=,]' then
            typed = at.partial:match '[^=,]*$'
        end
        if typed and typed ~= at.partial then
            -- a part after a separator: what is offered depends on the separator, not on the position of the word
            if inPredicateList then
                found = unlistedPredicates(at)
            else
                -- (the names the cleared APIs give the value: the parameters of this function are the likeliest)
                addParams(at.func, {}, found)
            end
            return found, typed
        end
        if inPredicateList and index > 1 then
            -- (the next word of a list that went on after a comma)
            return unlistedPredicates(at)
        end
        local function predicates()
            for predicate in pairs(PREDICATE_RESTRICTIONS) do
                found[#found+1] = { label = predicate, role = 'typeParameter' }
            end
            table.sort(found, function (a, b) return a.label < b.label end)
        end
        ---@type table<string, true>
        local used = {}
        for _, word in ipairs(at.words) do
            used[word:match '^[%w_]+' or word] = true
        end
        if kind == 'doc.secret-when' then
            if index == 1 then
                predicates()
            end
        elseif kind == 'doc.secret-unless' then
            if index == 1 then
                addParams(at.func, {}, found)
            end
        elseif kind == 'doc.secret-clears' then
            if index == 1 then
                predicates()
                found[#found+1] = { label = '*', role = 'enumMember' }
            elseif at.words[1] ~= '*' then
                addParams(at.func, used, found)
            end
        elseif kind == 'doc.secret-restriction-guard' then
            if index == 1 then
                for restriction in pairs(RESTRICTIONS) do
                    found[#found+1] = { label = restriction, role = 'enumMember' }
                end
                table.sort(found, function (a, b) return a.label < b.label end)
                addParams(at.func, {}, found)
            end
        elseif kind == 'doc.secret-precondition' then
            if index == 2 then
                for mode in pairs(FAILURE_MODES) do
                    found[#found+1] = { label = mode, role = 'enumMember' }
                end
                table.sort(found, function (a, b) return a.label < b.label end)
            end
        elseif kind == 'doc.secret-satisfies' then
            if index >= 2 then
                addParams(at.func, used, found)
            end
        end
        return found
    end
end

for name in pairs(TAGS) do
    docTags.registerTailTokens('doc.' .. name, tailTokens)
    docTags.registerTailCompletion('doc.' .. name, completerOf('doc.' .. name))
    docTags.registerTailHover('doc.' .. name, tailHover)
end

-- The diagnostic --------------------------------------------------------------------------------------

---@param func parser.object
---@param name string
---@return boolean
local function hasParam(func, name)
    for _, param in ipairs(func.args or {}) do
        if param[1] == name then
            return true
        end
    end
    return false
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state or not state.ast.docs then
        return
    end
    for i, doc in ipairs(state.ast.docs) do
        if not isContextDoc(doc) then
            goto CONTINUE
        end
        await.delay()
        do
            -- (a tag without arguments ends where its name does)
            local nameRange = { start = doc.finish - #doc.type:sub(5), finish = doc.finish }
            local at = doc.comment or nameRange
            local tag, problem = readTag(doc)
            if not tag then
                callback { start = at.start, finish = at.finish, message = problem or 'This tag cannot be read.' }
                goto CONTINUE
            end
            ---@type parser.object?
            local source = doc.bindSource
            ---@type parser.object?
            local func = source and (source.type == 'function' and source
                or (source.value and source.value.type == 'function' and source.value)
                or nil) or nil
            if not func then
                if not (tag.kind == 'doc.secret-when' and classAfter(state.ast.docs, i)) then
                    callback { start = nameRange.start, finish = nameRange.finish, message = 'This tag has to be above a function (`---@secret-when` also above a class).' }
                end
                goto CONTINUE
            end
            ---@type string[]
            local params = {}
            if tag.kind == 'doc.secret-unless' or tag.kind == 'doc.secret-restriction-guard' then
                params[#params+1] = tag.param
            end
            for _, binding in ipairs(tag.bindings or {}) do
                params[#params+1] = binding.param
            end
            for _, param in ipairs(params) do
                if not hasParam(func, param) then
                    callback {
                        start   = at.start,
                        finish  = at.finish,
                        message = ('`%s` is not a parameter of this function.'):format(param),
                    }
                end
            end
        end
        ::CONTINUE::
    end
end
