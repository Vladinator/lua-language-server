-- Fully self-contained "secret value" plugin: everything the feature
-- needs -- diagnostic registration, LuaDoc tag parsing/binding, flow
-- narrowing, and secrecy propagation -- lives in this one file, wired in
-- purely through the registries in vm/narrow.lua, vm/genesis.lua,
-- vm/flags.lua, parser/docTags.lua and parser/specials.lua. No other
-- core file references "secret" at all, and none of this plugin's own
-- functions are exposed on the shared `vm`/`docTags` tables under a
-- secret-specific name -- everything they need to plug into is a
-- generic, string-keyed registry, so deleting this file (and its one
-- line in core/diagnostics/init.lua's eager-load list) removes the
-- feature completely, and no other diagnostic is affected.

local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'
local docTags         = require 'parser.docTags'
local specials        = require 'parser.specials'

--- Extends parser.object (defined in parser/luadoc.lua) with the field
--- this plugin's own `---@field name secret string` keyword sets -- see
--- the docTags.registerFieldKeyword call below. Written as ["secret"]
--- rather than a bare `secret?`: that registration makes `secret` itself
--- a reserved `@field` keyword (like the built-in public/private/etc.),
--- so a bare `---@field secret? boolean` here would parse as *using*
--- the keyword rather than naming a field called "secret".
---@class parser.object
---@field ["secret"]? boolean

local MESSAGE = 'Need check secret value.'

protoDiagnostic.register {
    'need-check-secret',
} {
    group    = 'secret',
    severity = 'Warning',
    status   = 'Opened',
}

-- LuaDoc tags: @secret, @secret-check, @secret-access-check.

docTags.registerMarkerTag('secret',              'doc.secret')
docTags.registerMarkerTag('secret-check',        'doc.secret-check')
docTags.registerMarkerTag('secret-access-check', 'doc.secret-access-check')

docTags.registerContinuesAfterClassGroup('doc.secret')
docTags.registerClassGroupDoc('doc.secret')

docTags.registerBindRule('doc.secret', function (doc, source, isParam)
    return not isParam
end)
docTags.registerBindRule('doc.secret-check', function (doc, source, isParam)
    return source.type == 'function'
end)
docTags.registerBindRule('doc.secret-access-check', function (doc, source, isParam)
    return source.type == 'function'
end)

-- `---@field name secret string` -- an additional bare keyword alongside
-- the built-in public/protected/private/package, consumed by the
-- 'doc.field' genesis rule below.
docTags.registerFieldKeyword('secret', 'secret')

-- Recognize `next` as an iteration entry point, alongside the parser's
-- own built-in pairs/ipairs, so `next(secretTable)` can be banned below.

specials.register('next')

-- Secrecy propagation: is `value` (or, if it's a reference, its resolved
-- definition) tagged @secret / @secret-check / @secret-access-check.

---@param value parser.object
---@param kind  'doc.secret' | 'doc.secret-check' | 'doc.secret-access-check'
---@return boolean
local function hasSecretDoc(value, kind)
    if not value.bindDocs then
        return false
    end
    for _, doc in ipairs(value.bindDocs) do
        if doc.type == kind then
            return true
        end
    end
    return false
end

---@param value parser.object
---@param kind  'doc.secret' | 'doc.secret-check' | 'doc.secret-access-check'
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
            ---@cast c vm.global
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
---@param calleeNode parser.object
---@param kind       'doc.secret-check' | 'doc.secret-access-check'
---@return boolean
local function isDirectOrAliasedSecretCheck(calleeNode, kind)
    if hasSecretDoc(calleeNode, kind) then
        return true
    end
    ---@type parser.object[]|false|nil
    local sets
    if calleeNode.type == 'getglobal' then
        local globalVar = vm.getGlobal('variable', calleeNode[1])
        sets = globalVar and globalVar:getSets(guide.getUri(calleeNode))
    else
        sets = vm.getVariableSets(calleeNode)
    end
    if not sets then
        return false
    end
    for _, set in ipairs(sets) do
        local target = set
        if set.value and set.value.type == 'function' then
            target = set.value
        end
        if hasSecretDoc(target, kind) then
            return true
        end
    end
    return false
end

vm.registerCallNarrowing {
    match = function (calleeNode)
        return isDirectOrAliasedSecretCheck(calleeNode, 'doc.secret-check')
            or isDirectOrAliasedSecretCheck(calleeNode, 'doc.secret-access-check')
    end,
    narrow = function (tracer, action, topNode, outNode)
        if not (action.args and action.args[1] and tracer.getMap[action.args[1]]) then
            return topNode, outNode
        end
        local isAccessCheck = not isSecretCheck(action.node) and isSecretAccessCheck(action.node)
        local value = action.args[1]
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

-- Genesis: where secrecy first gets attached to a compiled node.

for _, sourceType in ipairs { 'local', 'self' } do
    vm.registerGenesisRule(sourceType, function (source, node)
        -- only when `source` carries its own doc comment (e.g. `---@secret`
        -- directly on this declaration) -- isSecret(source)'s fallback
        -- resolves through vm.getDefs(), which is unsound to call on every
        -- plain local (it can match through an unrelated assigned value).
        if source.bindDocs and isSecret(source) then
            node:setFlag('secret')
        end
    end)
end

vm.registerGenesisRule('call', function (source, node)
    if isSecret(source.node) then
        node:setFlag('secret')
    end
end)

vm.registerGenesisRule('doc.type', function (source, node)
    if hasSecretType(node, guide.getUri(source)) then
        node:setFlag('secret')
    end
end)

vm.registerGenesisRule('doc.field', function (source, node)
    if source.secret then
        node:setFlag('secret')
    end
end)

vm.registerGenesisRule('function.return', function (source, node)
    if isSecret(source.parent) then
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
