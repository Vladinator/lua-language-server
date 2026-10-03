-- Fully self-contained "secret value" plugin: everything the feature
-- needs -- diagnostic registration, LuaDoc tag parsing/binding, flow
-- narrowing, and secrecy propagation -- lives in this one file, wired in
-- purely through the registries in vm/narrow.lua, vm/genesis.lua,
-- vm/flags.lua, parser/docTags.lua and parser/specials.lua. No other
-- core file references "secret" at all, and none of this plugin's own
-- functions are exposed on the shared `vm`/`docTags` tables under a
-- secret-specific name -- everything they need to plug into is a
-- generic, string-keyed registry, so deleting this file removes the
-- feature completely (core/diagnostics/custom-plugins.lua finds the
-- files in this folder by itself: no line to remove anywhere), and no
-- other diagnostic is affected. Its tests are next to it.

local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'
local docTags         = require 'parser.docTags'
local specials        = require 'parser.specials'
local scope           = require 'workspace.scope'

--- Extends parser.object (defined in parser/luadoc.lua) with the field
--- this plugin's own `---@field name secret string` keyword sets -- see
--- the docTags.registerFieldKeyword call below. Written as ["secret"]
--- rather than a bare `secret?`: that registration makes `secret` itself
--- a reserved `@field` keyword (like the built-in public/private/etc.),
--- so a bare `---@field secret? boolean` here would parse as *using*
--- the keyword rather than naming a field called "secret".
---@class parser.object
---@field ["secret"]? boolean
---@field ["nosecret"]? boolean -- the `nosecret` type keyword below: a slot that cannot take a secret value (checked by secret-argument.lua and secret-field.lua)
---@field ["secretCheck"]? boolean -- the `secretcheck` type keyword below: which parameter(s) of a @secret-check/@secret-access-check function actually narrow (read by checkedIndicesOf)
---@field ["secretUnwrapUsed"]? boolean -- on a `doc.secret-unwrap`: it cleared an inherited flag at least once

local MESSAGE = 'Need check secret value.'

protoDiagnostic.register {
    'need-check-secret',
} {
    group    = 'secret',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for using a secret value (tagged `---@secret`, or of a `@secret` class) before it is checked with a `---@secret-check` / `---@secret-access-check` function.',
}

-- LuaDoc tags: @secret [names], @secret-unwrap [names], @secret-check,
-- @secret-access-check. `@secret` and `@secret-unwrap` take an optional
-- comma separated list of local names (`---@secret b, c` before
-- `local a, b, c`): only those locals are affected. No list means every
-- local of the statement, as before.

docTags.registerNameListTag('secret', 'doc.secret',
    'Marks a value as secret: reading it before it is checked raises `need-check-secret`.\n\n'
    .. '`---@secret` marks everything it is bound to; `---@secret a, b` only the named locals.')
docTags.registerNameListTag('secret-unwrap', 'doc.secret-unwrap',
    'Clears the secret flag a local would inherit from its value, e.g. from a call returning a secret.\n\n'
    ..'`---@secret-unwrap a, b` limits it to the named locals.')
docTags.registerNameListTag('nosecret', 'doc.nosecret',
    'The other way round from `@secret`: a function above which it stands must not return a secret value, a local it names (`---@nosecret a, b`, or all of the statement) must not hold one. Reported by `secret-return` / `secret-variable`.')
docTags.registerMarkerTag('secret-check', 'doc.secret-check',
    'Marks a function that tells whether a value is secret: on the branch where it reports not secret, the value may be used.')
docTags.registerMarkerTag('secret-access-check', 'doc.secret-access-check',
    'Like `---@secret-check`, but the function returns true when the value is safe to access.')
-- wowlua-ls's spelling of the same two tags, naming the checked parameter in the tag itself:
-- `---@secret-guard value is-secret` (= @secret-check on `value`), `---@secret-guard value accessible`
-- (= @secret-access-check on `value`), `any-secret` (true: the argument is secret, one argument; the
-- shape of `hasanysecretvalues` = @secret-check), `...` for a vararg.
docTags.registerParamKindTag('secret-guard', 'doc.secret-guard', { 'is-secret', 'accessible', 'any-secret' },
    'Declares a function that tells whether a parameter is secret, naming the parameter: `---@secret-guard value is-secret` (true = secret, like `@secret-check`), `accessible` (true = safe, like `@secret-access-check`), `any-secret` (true = secret).')

docTags.registerContinuesAfterClassGroup('doc.secret')
docTags.registerClassGroupDoc('doc.secret')

docTags.registerBindRule('doc.secret', function (doc, source, isParam)
    return not isParam
end)
docTags.registerBindRule('doc.secret-unwrap', function (doc, source, isParam)
    return not isParam
end)
docTags.registerBindRule('doc.nosecret', function (doc, source, isParam)
    return not isParam
end)
docTags.registerBindRule('doc.secret-check', function (doc, source, isParam)
    return source.type == 'function'
end)
docTags.registerBindRule('doc.secret-access-check', function (doc, source, isParam)
    return source.type == 'function'
end)
docTags.registerBindRule('doc.secret-guard', function (doc, source, isParam)
    return source.type == 'function'
end)

-- `---@field name secret string` -- an additional bare keyword alongside
-- the built-in public/protected/private/package, consumed by the
-- 'doc.field' genesis rule below.
docTags.registerFieldKeyword('secret', 'secret',
    'The field holds a secret value: `---@field secret token string`.')

-- `secret` in front of a type item: `---@type number, secret string`,
-- `---@param token secret string`, `---@return secret string`. Marks exactly that
-- item, so the type and the secrecy live in one annotation.
docTags.registerTypeKeyword('secret', 'secret',
    'Marks this type item as secret: `---@param token secret string`.')

-- `nosecret` is the other way round: the slot cannot take a secret value (`---@param str nosecret string`,
-- `---@field name nosecret string`). Nothing here reads it; the companions secret-argument.lua and
-- secret-field.lua report a secret that is passed or assigned to such a slot.
docTags.registerTypeKeyword('nosecret', 'nosecret',
    'This slot cannot take a secret value: `---@param str nosecret string`, `---@field name nosecret string`. Passing or assigning one is reported by `secret-argument` / `secret-field`.')

-- `secretcheck` marks which parameter(s) of a `---@secret-check`/`---@secret-access-check`
-- function the narrowing actually applies to (default: the first parameter, unchanged from
-- before this existed). Several parameters may each carry it, narrowing all of them together
-- on the same call -- the equivalent of a multi-value check like `canaccessallvalues(a, b)`.
-- `secretguard` is the same keyword under its earlier spelling, kept as an alias (wowlua-ls calls these
-- functions guards: `@secret-guard`).
docTags.registerTypeKeyword('secretcheck', 'secretCheck',
    'Marks the parameter a `---@secret-check`/`---@secret-access-check` function narrows: `---@param b secretcheck any`. Default (no parameter marked): the first parameter. Mark several to narrow them together.')
docTags.registerTypeKeywordAlias('secretguard', 'secretcheck')

-- Recognize `next` as an iteration entry point, alongside the parser's
-- own built-in pairs/ipairs, so `next(secretTable)` can be banned below.

specials.register('next')

-- Secrecy propagation: is `value` (or, if it's a reference, its resolved
-- definition) tagged @secret / @secret-check / @secret-access-check.

--- A `---@secret a, b` / `---@secret-unwrap a, b` only concerns the locals it names;
--- without a list it concerns everything it is bound to. (For anything that is not
--- a local, e.g. a function, a list has no meaning and is ignored.)
---@param doc   parser.object
---@param value parser.object
---@return boolean
local function docAppliesTo(doc, value)
    local names = doc.names
    if not names then
        return true
    end
    if value.type ~= 'local' and value.type ~= 'self' then
        return true
    end
    for _, name in ipairs(names) do
        if name[1] == value[1] then
            return true
        end
    end
    return false
end

---@alias secret.docKind 'doc.secret' | 'doc.secret-unwrap' | 'doc.secret-check' | 'doc.secret-access-check'

--- What each `---@secret-guard <param> <kind>` kind stands for.
---@type table<string, 'doc.secret-check'|'doc.secret-access-check'>
local GUARD_KIND = {
    ['is-secret']  = 'doc.secret-check',
    ['any-secret'] = 'doc.secret-check',
    ['accessible'] = 'doc.secret-access-check',
}

--- The check tag `doc` amounts to: `@secret-check` / `@secret-access-check` themselves, or the kind a
--- `@secret-guard` maps to; nil for any other doc.
---@param doc parser.object
---@return 'doc.secret-check'|'doc.secret-access-check'?
local function checkKindOf(doc)
    if doc.type == 'doc.secret-check' or doc.type == 'doc.secret-access-check' then
        return doc.type --[[@as 'doc.secret-check'|'doc.secret-access-check']]
    end
    if doc.type == 'doc.secret-guard' and doc.kind then
        return GUARD_KIND[doc.kind]
    end
    return nil
end

---@param value parser.object
---@param kind  secret.docKind
---@return boolean
local function hasSecretDoc(value, kind)
    if not value.bindDocs then
        return false
    end
    for _, doc in ipairs(value.bindDocs) do
        if (doc.type == kind or checkKindOf(doc) == kind) and docAppliesTo(doc, value) then
            return true
        end
    end
    return false
end

---@param value parser.object
---@param kind  secret.docKind
---@return boolean
local function checkSecretDoc(value, kind)
    if hasSecretDoc(value, kind) then
        return true
    end
    if value.type == 'function' then
        return false
    end
    local defs = vm.getDefs(value)
    for _, def in ipairs(defs) do
        local target = def
        if def.value and def.value.type == 'function' then
            target = def.value
        end
        if hasSecretDoc(target, kind) then
            return true
        end
    end
    return false
end

---@param value parser.object
---@return boolean
local function isSecret(value)
    return checkSecretDoc(value, 'doc.secret')
end

--- `---@secret-unwrap`: declassifies inherited secrecy here (see the genesis rules).
---@param value parser.object
---@return boolean
local function isUnwrap(value)
    return checkSecretDoc(value, 'doc.secret-unwrap')
end

---@param value parser.object
---@return boolean
local function isSecretCheck(value)
    return checkSecretDoc(value, 'doc.secret-check')
end

---@param value parser.object
---@return boolean
local function isSecretAccessCheck(value)
    return checkSecretDoc(value, 'doc.secret-access-check')
end

--- Does `node`'s type resolve to a @secret-tagged class, so secrecy
--- "follows" a table type wherever that type is used.
---@param node vm.node
---@param uri  uri
---@return boolean
local function hasSecretType(node, uri)
    for c in node:eachObject() do
        if c.type == 'global' and c.cate == 'type' then
            for _, set in ipairs(c:getSets(uri)) do
                if hasSecretDoc(set, 'doc.secret') then
                    return true
                end
            end
        end
    end
    return false
end

-- Flow narrowing: a @secret-check/@secret-access-check call clears the
-- secret flag on the branch where the value is confirmed safe.
-- @secret-access-check has inverted truthiness (canaccessvalue(x) being
-- *true* means x is safe), handled by clearing on the opposite branch.

-- match() below runs for every call expression the tracer's general
-- sequential flow-narrowing visits -- not just calls inside explicit
-- if/while conditions, virtually every call anywhere in the codebase --
-- so it needs to answer "is this callee tagged @secret-check /
-- @secret-access-check, directly or via a local-variable alias" without
-- ever calling vm.compileNode/vm.getDefs on the callee: match() runs
-- before the tracer's own lookIntoChild(action.node, ...) visits that
-- same node (see the 'call' case in vm/tracer.lua), so calling
-- vm.compileNode on it here would be re-entrant -- vm.compileNode caches
-- a fresh empty node *before* populating it precisely to break cycles
-- like this, so the re-entrant call gets back an incomplete node, and
-- (confirmed by bisecting) that was corrupting unrelated method
-- resolution elsewhere in the same compilation pass, regressing
-- undefined-field's ability to detect an undefined method. Traced back
-- to the original "secret values" commit that introduced this rule.
--
-- isDirectOrAliasedSecretCheck resolves the same "direct reference, a
-- local variable assigned from one, or a global function declared as
-- one" shapes vm.getDefs would, but only through vm.getVariableSets and
-- vm.getGlobal/:getSets -- ID/name-keyed cache lookups, neither ever
-- calls vm.compileNode -- so both are safe to call here. What this
-- doesn't (and safely can't) resolve: secrecy of a field/upvalue read
-- whose own resolution would itself require a fresh vm.compileNode.
--
-- A field read (`ns.GameAPI.f`) is itself variable-ID tracked the same
-- way a local is (script/vm/variable.lua's compileVariables has cases
-- for getfield/setfield/getmethod/setmethod/getindex/setindex, building
-- a compound ID off the parent's), so a local alias of a field
-- (`local f = ns.GameAPI.f`) can be chased one more hop through the same
-- safe primitives instead of stopping at the alias's own declaration:
-- recurse into `set.value` when it is itself one of those variable-ID
-- read types. `seen` guards a variable that (pathologically) aliases
-- itself; ordinary code never nests this more than one or two hops deep.
---@type table<string, true>
local VARIABLE_READ_TYPES = {
    getlocal  = true,
    getfield  = true,
    getmethod = true,
    getindex  = true,
    getglobal = true,
}

-- Name-based fallback for shapes the safe variable-ID/global system above can't reach (a field
-- chain rooted in a global, or one that only resolves through a merged `---@class`, the common
-- cross-file namespace-table idiom -- `local ns = select(2, ...) ---@class NS`). Mirrors
-- invalid-guard.lua's own strategy (find the callee by its bare name first, so every other call
-- in the codebase costs nothing), but stricter: invalid-guard.lua's own narrow() still calls
-- vm.getDefs/vm.compileNode for the (smaller) set of calls whose name already matched -- a real,
-- just rarer, exposure to the same reentrancy hazard this file's own history already hit once
-- (263dfdf5e). Tried reintroducing that call as a fallback here on 2026-09-26 and it corrupted
-- unrelated, order-dependent no-unknown findings under --seeds even though it passed every
-- targeted test including a reconstruction of the original regression -- see TODO.md. So neither
-- match() nor this fallback call vm.compileNode/vm.getDefs anywhere, ever: a name is trusted only
-- when every occurrence of it, anywhere in the workspace, is tagged the same way. One untagged or
-- differently-tagged function sharing the name anywhere makes it unsafe to trust and this falls
-- back to not narrowing (a possible false positive elsewhere, never a missed secret here).

--- A bare global (`issecretvalue`) and a field of the same name (`ns.GameAPI.issecretvalue`) can
--- never resolve to each other -- Lua's own syntax guarantees a field access is never a global
--- lookup, whatever the bare word means elsewhere -- so they get separate namespaces here instead
--- of being folded into one: a stock, untagged WoW API global sharing a name with a workspace's own
--- tagged wrapper field must not poison the field's name (found from a real user report,
--- 2026-09-26: `ns.GameAPI.issecretvalue`, its own body calling the real, untagged global
--- `issecretvalue` it wraps). What genuinely stays ambiguous: two *different* fields (on unrelated
--- tables) sharing a name, one tagged and one not -- there is no way to structurally tell those
--- apart by name alone, so that case is still refused. A `local`/`self` declaration is never
--- entered here at all: it is never what this fallback is trying to identify (a local is always
--- resolved precisely by the safe variable-ID system within its own file; a same-named local in
--- another file has no relationship to it whatsoever and must not be allowed to poison anything).
---@alias secret.nameKind 'global'|'field'

---@param source parser.object?
---@return string? name
---@return secret.nameKind? kind
local function nameOf(source)
    if not source then
        return nil
    end
    local t = source.type
    if t == 'setglobal' then
        return source[1], 'global'
    elseif t == 'setfield' or t == 'tablefield' then
        return source.field and source.field[1], 'field'
    elseif t == 'setmethod' then
        return source.method and source.method[1], 'field'
    end
    return nil
end

--- Every function declared in this file, by kind and name: `false` when the name is also used by
--- an untagged function (of the same kind), or by both tags, in this same file (`getNames` below
--- folds this across files the same way, so any one bad occurrence anywhere in the workspace makes
--- the name unsafe).
---@param uri uri
---@return table<secret.nameKind, table<string, 'doc.secret-check'|'doc.secret-access-check'|false>>?
local function getFileNames(uri)
    local cache = files.getCache(uri)
    if not cache then
        return nil
    end
    ---@type table<secret.nameKind, table<string, 'doc.secret-check'|'doc.secret-access-check'|false>>|false|nil
    local names = cache['secret-check.names']
    if names ~= nil then
        return names or nil
    end
    local state = files.getState(uri)
    if not state then
        cache['secret-check.names'] = false
        return nil
    end
    ---@type table<secret.nameKind, table<string, 'doc.secret-check'|'doc.secret-access-check'|false>>
    local found = { global = {}, field = {} }
    local any = false
    guide.eachSourceType(state.ast, 'function', function (func)
        local name, kind = nameOf(func.parent)
        if not name or not kind then
            return
        end
        any = true
        ---@type 'doc.secret-check'|'doc.secret-access-check'|false
        local tag = false
        for _, holder in ipairs { func, func.parent } do
            for _, doc in ipairs(holder and holder.bindDocs or {}) do
                local checkKind = checkKindOf(doc)
                if checkKind then
                    tag = checkKind
                end
            end
        end
        local bucket  = found[kind]
        local existing = bucket[name]
        if existing == nil then
            bucket[name] = tag
        elseif existing ~= tag then
            bucket[name] = false
        end
    end)
    names = any and found or false
    cache['secret-check.names'] = names
    return names or nil
end

--- The names above, folded across every file of `uri`'s workspace; dropped with the rest of
--- `vm.getCache` when a file changes.
---@param uri uri
---@return table<secret.nameKind, table<string, 'doc.secret-check'|'doc.secret-access-check'|false>>
local function getNames(uri)
    local cache = vm.getCache('secret-check.names') --[[@as table<string, table<secret.nameKind, table<string, 'doc.secret-check'|'doc.secret-access-check'|false>>>]]
    local key   = scope.getScope(uri):getName()
    local names = cache[key]
    if names then
        return names
    end
    ---@type table<secret.nameKind, table<string, 'doc.secret-check'|'doc.secret-access-check'|false>>
    names = { global = {}, field = {} }
    for fileUri in files.eachFile(uri) do
        local fileNames = getFileNames(fileUri)
        if fileNames then
            for kind, bucket in pairs(fileNames) do
                local target = names[kind]
                for name, tag in pairs(bucket) do
                    local existing = target[name]
                    if existing == nil then
                        target[name] = tag
                    elseif existing ~= tag then
                        target[name] = false
                    end
                end
            end
        end
    end
    cache[key] = names
    return names
end

---@param callee parser.object
---@return string? name
---@return secret.nameKind? kind
local function calleeName(callee)
    local t = callee.type
    if t == 'getglobal' then
        return callee[1], 'global'
    elseif t == 'getfield' then
        return callee.field and callee.field[1], 'field'
    elseif t == 'getmethod' then
        return callee.method and callee.method[1], 'field'
    elseif t == 'getindex' then
        return guide.getKeyName(callee), 'field'
    end
    return nil
end

--- Is `calleeNode`'s bare name known, workspace-wide, as `kind` and nothing else?
---@param calleeNode parser.object
---@param kind       'doc.secret-check' | 'doc.secret-access-check'
---@return boolean
local function isNamedSecretCheck(calleeNode, kind)
    local name, nameKind = calleeName(calleeNode)
    if not name or not nameKind then
        return false
    end
    local uri = guide.getUri(calleeNode)
    return getNames(uri)[nameKind][name] == kind
end

---@param calleeNode parser.object
---@param kind       'doc.secret-check' | 'doc.secret-access-check'
---@param seen?      table<parser.object, true>
---@return boolean
local function isDirectOrAliasedSecretCheck(calleeNode, kind, seen)
    if hasSecretDoc(calleeNode, kind) then
        return true
    end
    if seen and seen[calleeNode] then
        return false
    end
    ---@type parser.object[]|false|nil
    local sets
    if calleeNode.type == 'getglobal' then
        local globalVar = vm.getGlobal('variable', calleeNode[1])
        sets = globalVar and globalVar:getSets(guide.getUri(calleeNode))
    else
        sets = vm.getVariableSets(calleeNode)
    end
    if not sets or #sets == 0 then
        -- `sets` can be a *present but empty* table, not nil: the compound variable-ID for this
        -- exact field path exists (created on first read, script/vm/variable.lua's
        -- insertVariableID via `util.multiTable`), but nothing in this file ever assigned it --
        -- exactly the cross-file case (the assignment is a different file's own `ns` local).
        -- An empty result here is "nothing precise to check", not "definitely not a match", so
        -- fall back to the name-based check the same as a nil result.
        return isNamedSecretCheck(calleeNode, kind)
    end
    ---@type table<parser.object, true>
    local visited = seen or {}
    visited[calleeNode] = true
    for _, set in ipairs(sets) do
        local target = set
        if set.value and set.value.type == 'function' then
            target = set.value
        end
        if hasSecretDoc(target, kind) then
            return true
        end
        if  set.value
        and set.value ~= calleeNode
        and VARIABLE_READ_TYPES[set.value.type]
        and isDirectOrAliasedSecretCheck(set.value, kind, visited) then
            return true
        end
    end
    return false
end

--- Which parameter(s) of `funcNode` (a real `function` AST node) are marked `secretcheck`, by
--- position. No marked parameter means "the first one", the default before this existed.
---@param funcNode parser.object
---@return integer[]
local function checkedIndicesOf(funcNode)
    local args = funcNode.args
    if not args then
        return {1}
    end
    ---@type integer[]
    local indices = {}
    -- `---@secret-guard <param> <kind>` names the checked parameter itself (`...`: the vararg)
    for _, holder in ipairs { funcNode, funcNode.parent } do
        for _, doc in ipairs(holder and holder.bindDocs or {}) do
            if doc.type == 'doc.secret-guard' and doc.param then
                for i, param in ipairs(args) do
                    if param[1] == doc.param[1] then
                        indices[#indices+1] = i
                    end
                end
            end
        end
    end
    for i, param in ipairs(args) do
        local docs = param.bindDocs
        if docs then
            for j = 1, #docs do
                local doc = docs[j]
                if  doc.type == 'doc.param'
                and doc.param
                and doc.param[1] == param[1]
                and doc.extends
                and doc.extends.secretCheck then
                    indices[#indices+1] = i
                end
            end
        end
    end
    if #indices == 0 then
        indices[1] = 1
    end
    return indices
end

--- Same safe traversal as isDirectOrAliasedSecretCheck (never vm.compileNode/vm.getDefs, see its
--- own comment above), but returns the resolved `function` AST node instead of a boolean, so
--- checkedIndicesOf can read its actual parameter list. Returns nil for anything the safe
--- primitives can't resolve to a real function node (the name-based fallback below covers that).
---@param calleeNode parser.object
---@param seen?      table<parser.object, true>
---@return parser.object?
local function resolveSecretCheckFunction(calleeNode, seen)
    if calleeNode.type == 'function' then
        return calleeNode
    end
    if seen and seen[calleeNode] then
        return nil
    end
    ---@type parser.object[]|false|nil
    local sets
    if calleeNode.type == 'getglobal' then
        local globalVar = vm.getGlobal('variable', calleeNode[1])
        sets = globalVar and globalVar:getSets(guide.getUri(calleeNode))
    else
        sets = vm.getVariableSets(calleeNode)
    end
    if not sets or #sets == 0 then
        return nil
    end
    ---@type table<parser.object, true>
    local visited = seen or {}
    visited[calleeNode] = true
    for _, set in ipairs(sets) do
        if set.value and set.value.type == 'function' then
            return set.value
        end
        if  set.value
        and set.value ~= calleeNode
        and VARIABLE_READ_TYPES[set.value.type] then
            local found = resolveSecretCheckFunction(set.value, visited)
            if found then
                return found
            end
        end
    end
    return nil
end

--- Guarded indices by name, workspace-wide -- the checkedIndicesOf counterpart to
--- getFileNames/getNames above, kept as a fully separate cache so nothing here can affect
--- match()'s own tag resolution. Only consulted when resolveSecretCheckFunction can't reach a
--- real function node directly (the same shapes isNamedSecretCheck's name-based fallback covers).
---@param uri uri
---@return table<secret.nameKind, table<string, integer[]>>?
local function getFileCheckedIndices(uri)
    local cache = files.getCache(uri)
    if not cache then
        return nil
    end
    ---@type table<secret.nameKind, table<string, integer[]>>|false|nil
    local indices = cache['secret-check.checkedIndices']
    if indices ~= nil then
        return indices or nil
    end
    local state = files.getState(uri)
    if not state then
        cache['secret-check.checkedIndices'] = false
        return nil
    end
    ---@type table<secret.nameKind, table<string, integer[]>>
    local found = { global = {}, field = {} }
    local any = false
    guide.eachSourceType(state.ast, 'function', function (func)
        local name, kind = nameOf(func.parent)
        if not name or not kind then
            return
        end
        any = true
        found[kind][name] = checkedIndicesOf(func)
    end)
    indices = any and found or false
    cache['secret-check.checkedIndices'] = indices
    return indices or nil
end

---@param uri uri
---@return table<secret.nameKind, table<string, integer[]>>
local function getCheckedIndices(uri)
    local cache = vm.getCache('secret-check.checkedIndices') --[[@as table<string, table<secret.nameKind, table<string, integer[]>>>]]
    local key = scope.getScope(uri):getName()
    local indices = cache[key]
    if indices then
        return indices
    end
    ---@type table<secret.nameKind, table<string, integer[]>>
    indices = { global = {}, field = {} }
    for fileUri in files.eachFile(uri) do
        local fileIndices = getFileCheckedIndices(fileUri)
        if fileIndices then
            for kind, bucket in pairs(fileIndices) do
                local target = indices[kind]
                for name, idxList in pairs(bucket) do
                    -- last file wins across a shared name; isNamedSecretCheck's own tag lookup
                    -- (not this) is what decides whether the name is trusted at all
                    target[name] = idxList
                end
            end
        end
    end
    cache[key] = indices
    return indices
end

--- Which argument position(s) a matched secret-check call narrows. Tries the safe direct/aliased
--- resolution first (an exact function node to read `secretcheck` params off of), then the same
--- name-based fallback match() itself uses. Always returns at least `{1}`.
---@param calleeNode parser.object
---@return integer[]
local function getCheckedParamIndices(calleeNode)
    local funcNode = resolveSecretCheckFunction(calleeNode)
    if funcNode then
        return checkedIndicesOf(funcNode)
    end
    local name, kind = calleeName(calleeNode)
    if not name or not kind then
        return {1}
    end
    local uri = guide.getUri(calleeNode)
    local idx = getCheckedIndices(uri)[kind][name]
    return idx or {1}
end

vm.registerCallNarrowing {
    match = function (calleeNode)
        return isDirectOrAliasedSecretCheck(calleeNode, 'doc.secret-check')
            or isDirectOrAliasedSecretCheck(calleeNode, 'doc.secret-access-check')
    end,
    ---@param tracer vm.tracer
    ---@param action parser.object
    ---@param topNode vm.node
    ---@param outNode? vm.node
    ---@return vm.node
    ---@return vm.node?
    narrow = function (tracer, action, topNode, outNode)
        if not action.args then
            return topNode, outNode
        end
        -- the traced variable can be read at any checked position, not just the first
        -- argument (secretcheck, see above); find the one that matches, if any
        ---@type parser.object?
        local value
        for _, i in ipairs(getCheckedParamIndices(action.node)) do
            local arg = action.args[i]
            if arg and tracer.getMap[arg] then
                value = arg
                break
            end
        end
        if not value then
            return topNode, outNode
        end
        local isAccessCheck = not isSecretCheck(action.node) and isSecretAccessCheck(action.node)
        tracer:lookIntoChild(value, topNode, outNode)
        if isAccessCheck then
            topNode = topNode:copy():clearFlag('secret')
            if outNode then
                outNode = outNode:copy()
            end
        else
            topNode = topNode:copy()
            if outNode then
                outNode = outNode:copy():clearFlag('secret')
            end
        end
        return topNode, outNode
    end,
}

--- The same rule for the flow analysis (vm/flow.lua): every checked argument is narrowed, not only
--- the one the old tracer happened to be following.
vm.registerFlowNarrowing {
    match = function (calleeNode)
        return isDirectOrAliasedSecretCheck(calleeNode, 'doc.secret-check')
            or isDirectOrAliasedSecretCheck(calleeNode, 'doc.secret-access-check')
    end,
    ---@param call parser.object
    ---@return vm.flow.narrowing[]
    narrowings = function (call)
        ---@type vm.flow.narrowing[]
        local result = {}
        if not call.args then
            return result
        end
        local isAccessCheck = not isSecretCheck(call.node) and isSecretAccessCheck(call.node)
        ---@type fun(node: vm.node): vm.node
        local declassify = function (node) return node:copy():clearFlag('secret') end
        for _, i in ipairs(getCheckedParamIndices(call.node)) do
            local arg = call.args[i]
            if arg then
                if isAccessCheck then
                    result[#result+1] = { target = arg, whenTrue = declassify }
                else
                    result[#result+1] = { target = arg, whenFalse = declassify }
                end
            end
        end
        return result
    end,
}

-- Genesis: where secrecy first gets attached to a compiled node.

for _, sourceType in ipairs { 'local', 'self' } do
    vm.registerGenesisRule(sourceType, function (source, node)
        -- only when `source` carries its own doc comment (e.g. `---@secret`
        -- directly on this declaration) -- isSecret(source)'s fallback
        -- resolves through vm.getDefs(), which is unsound to call on every
        -- plain local (it can match through an unrelated assigned value).
        if not source.bindDocs then
            return
        end
        -- `---@secret-unwrap` declassifies whatever secrecy this local inherited
        -- (a secret class type, a secret call result, an assignment from a secret
        -- value); when it actually did something the doc is marked as used, so
        -- redundant-secret-unwrap can tell.
        if hasSecretDoc(source, 'doc.secret-unwrap') then
            if node:hasFlag('secret') then
                node:clearFlag('secret')
                for _, doc in ipairs(source.bindDocs) do
                    if doc.type == 'doc.secret-unwrap' and docAppliesTo(doc, source) then
                        doc.secretUnwrapUsed = true
                    end
                end
            end
            return
        end
        if isSecret(source) then
            node:setFlag('secret')
        end
    end)
end

vm.registerGenesisRule('call', function (source, node)
    local secret = isSecret(source.node)
    if secret or node:hasFlag('secret') then
        -- a `---@secret-unwrap` function is a sanitizer: its results are plain
        if isUnwrap(source.node) then
            node:clearFlag('secret')
        elseif secret then
            node:setFlag('secret')
        end
    end
end)

-- `local s = f()` does not read the call node itself but a `select` of its results, so
-- a `---@secret-unwrap` function has to clear the flag there too.
vm.registerGenesisRule('select', function (source, node)
    local call = source.vararg
    if call and call.type == 'call' and node:hasFlag('secret') and isUnwrap(call.node) then
        node:clearFlag('secret')
    end
end)

vm.registerGenesisRule('doc.type', function (source, node)
    if source.secret or hasSecretType(node, guide.getUri(source)) then
        node:setFlag('secret')
    end
end)

vm.registerGenesisRule('doc.field', function (source, node)
    if source.secret then
        node:setFlag('secret')
    end
end)

vm.registerGenesisRule('function.return', function (source, node)
    if isSecret(source.parent) and not hasSecretDoc(source.parent, 'doc.secret-unwrap') then
        node:setFlag('secret')
    end
end)

-- Node-reconstruction paths in vm/compiler.lua and vm/generic.lua that
-- don't go through vm.node:merge() (which already carries every flag
-- automatically) ask these two generic registries instead of ever naming
-- "secret" themselves -- see vm/flags.lua.
vm.registerPropagatingFlag('secret')
vm.registerFlagDeriver('secret', isSecret)

-- The diagnostic itself.

local ALLOWED_BINARY_OPS = {
    ['..']  = true,
    ['and'] = true,
    ['or']  = true,
}

---@param t string
---@return boolean
local function isIndexNode(t)
    return t == 'getfield' or t == 'getmethod' or t == 'getindex'
        or t == 'setfield' or t == 'setmethod' or t == 'setindex'
end

---@param node vm.node
---@return boolean
local function isBooleanNode(node)
    for c in node:eachObject() do
        if c.type == 'boolean'
        or c.type == 'doc.type.boolean'
        or (c.type == 'global' and c.cate == 'type'
            and (c.name == 'boolean' or c.name == 'true' or c.name == 'false')) then
            return true
        end
    end
    return false
end

---@param parent parser.object
---@param src    parser.object
---@return boolean
local function isDirectCondition(parent, src)
    if parent.filter == src then
        return true
    end
    if parent.type == 'unary' and parent.op and parent.op.type == 'not' then
        return true
    end
    if parent.type == 'binary' and parent.op
    and (parent.op.type == 'and' or parent.op.type == 'or')
    and (parent[1] == src or parent[2] == src) then
        return true
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
    ---@param src parser.object
    guide.eachSourceTypes(state.ast, {'getlocal', 'getglobal', 'getfield', 'getindex', 'getmethod'}, function (src)
        delayer:delay()

        local parent = src.parent
        if not parent then
            return
        end

        local node = vm.compileNode(src)
        if not node:hasFlag('secret') then
            return
        end

        if isDirectCondition(parent, src) then
            if isBooleanNode(node) then
                callback {
                    start   = src.start,
                    finish  = src.finish,
                    message = MESSAGE,
                }
            end
            return
        end

        if isIndexNode(parent.type) and parent.node == src then
            callback {
                start   = src.start,
                finish  = src.finish,
                message = MESSAGE,
            }
            return
        end

        if (parent.type == 'getindex' or parent.type == 'setindex' or parent.type == 'tableindex')
        and parent.index == src then
            callback {
                start   = src.start,
                finish  = src.finish,
                message = MESSAGE,
            }
            return
        end

        if parent.type == 'call' and parent.node == src then
            callback {
                start   = src.start,
                finish  = src.finish,
                message = MESSAGE,
            }
            return
        end

        if parent.type == 'callargs' and parent[1] == src
        and parent.parent and parent.parent.type == 'call'
        and (parent.parent.node.special == 'pairs'
            or parent.parent.node.special == 'ipairs'
            or parent.parent.node.special == 'next') then
            callback {
                start   = src.start,
                finish  = src.finish,
                message = MESSAGE,
            }
            return
        end

        if parent.type == 'unary' and parent.op and parent.op.type ~= 'not' then
            callback {
                start   = src.start,
                finish  = src.finish,
                message = MESSAGE,
            }
            return
        end

        if parent.type == 'binary' then
            ---@type string|false
            local op = parent.op and parent.op.type
            if not ALLOWED_BINARY_OPS[op] then
                callback {
                    start   = src.start,
                    finish  = src.finish,
                    message = MESSAGE,
                }
            end
        end
    end)
end
