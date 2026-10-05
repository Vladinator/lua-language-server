-- `Lua.annotations.dialects` and the lint behind it. A project that has to be read by more than one
-- language server (the original LuaLS, this fork, wowlua-ls) lists the dialects it targets; every `---@tag`
-- that none of them knows gets a hint, instead of being silently ignored like an unknown tag is.
--
--     "legacyluals"  the original LuaLS (3.19.1, the base of this fork)
--     "luals"        this fork: the original plus what it added
--     "wowluals"     wowlua-ls (from its documentation; there is no binary here to measure)
--     "mixed"        all three, nothing is reported (the default)
--
-- Allow-list semantics: a tag is fine when at least one listed dialect knows it. The tables below are the
-- tags the parser itself handles (measured against the base commit and this fork's parser) and the tags only
-- wowlua-ls documents; the tags of this fork's own features say where they come from through
-- `docTags.setTagFlavors` in their own files. Parsing is not affected: every spelling is always read.
-- Checked: the tags, and the field / type keywords of the registries (`secret`, `readonly`, ...). Not yet
-- checked: the other type syntax (`?T`, `T!`, `never`, `params<F>`, ...).
-- Deleting this file removes the setting's effect and the lint. Its tests are next to it.

local files           = require 'files'
local config          = require 'config'
local await           = require 'await'
local util            = require 'utility'
local docTags         = require 'parser.docTags'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local protoDiagnostic = require 'proto.diagnostic'

protoDiagnostic.register {
    'non-portable-annotation',
} {
    group    = 'luadoc',
    severity = 'Hint',
    status   = 'Any',
    narrowSettings = { 'Lua.annotations.dialects' },
    description = 'Enable diagnostics for a `---@tag` that none of the dialects listed in `Lua.annotations.dialects` knows (it is otherwise silently ignored).',
}

local ALL = { 'legacyluals', 'luals', 'wowluals' }

--- Tags every dialect knows.
local COMMON = {
    'class', 'type', 'alias', 'param', 'return', 'field', 'generic', 'overload', 'deprecated', 'meta',
    'see', 'diagnostic', 'nodiscard', 'as', 'cast', 'enum', 'private', 'protected', 'public', 'package',
}
--- Tags of the original LuaLS that wowlua-ls does not document.
local LEGACY_AND_LUALS = { 'vararg', 'version', 'module', 'async', 'operator', 'source' }
--- Tags that wowlua-ls documents and the original and this fork do not.
local WOWLUALS_ONLY = {
    'type-narrows', 'narrows-arg', 'defclass', 'builds-field', 'built-name', 'built-extends', 'constructor',
    'accessor', 'creates-global', 'generates-events', 'returns-enum', 'returns-class-name', 'requires',
    'event', 'callback-event-arg', 'flavor-narrows', 'secret-unless', 'secret-when',
    'secret-clears', 'secret-restriction-guard', 'secret-precondition', 'secret-satisfies', 'secret-aspect',
}

---@type table<string, string[]>
local flavorsOf = {}
for _, name in ipairs(COMMON) do
    flavorsOf[name] = ALL
end
for _, name in ipairs(LEGACY_AND_LUALS) do
    flavorsOf[name] = { 'legacyluals', 'luals' }
end
for _, name in ipairs(WOWLUALS_ONLY) do
    flavorsOf[name] = { 'wowluals' }
end
flavorsOf['correlated'] = { 'luals', 'wowluals' }

--- The dialects that know the tag, nil for a tag nobody knows.
---@param name string
---@return string[]?
local function knownBy(name)
    return flavorsOf[name] or (docTags.getMarkerTagType(name) and docTags.getTagFlavors(name)) or nil
end

--- Report `what` (a tag or keyword at start..finish) when none of `dialects` knows it.
---@param dialects string[]
---@param known    string[]?
---@param what     string
---@param start    integer
---@param finish   integer
---@param callback fun(result: proto.diagnostic.result)
local function report(dialects, known, what, start, finish, callback)
    if not known then
        -- nobody knows it: a typo, or a plugin's own
        callback {
            start   = start,
            finish  = finish,
            message = ('`%s` is not a known annotation of any dialect: it is ignored.'):format(what),
        }
        return
    end
    for _, flavor in ipairs(known) do
        if util.arrayHas(dialects, flavor) then
            return
        end
    end
    callback {
        start   = start,
        finish  = finish,
        message = ('`%s` is only known to %s: the dialects listed in `Lua.annotations.dialects` ignore it.'):format(what, table.concat(known, ', ')),
    }
end

--- Where the last word `keyword` stands in `text` between the positions `from` and `to`, when it is there.
---@param text    string
---@param from    integer
---@param to      integer
---@param keyword string
---@return integer?
---@return integer?
local function findWord(text, from, to, keyword)
    local head = text:sub(from, to)
    ---@type integer?
    local foundStart
    ---@type integer?
    local foundEnd
    local pos = 1
    while true do
        local s, e = head:find(keyword, pos, true)
        if not s or not e then
            break
        end
        local before = head:sub(s - 1, s - 1)
        local after  = head:sub(e + 1, e + 1)
        if not before:find('[%w_]') and not after:find('[%w_]') then
            foundStart, foundEnd = from + s - 1, from + e - 1
        end
        pos = e + 1
    end
    return foundStart, foundEnd
end

--- Type syntax (not tags, not keywords) and who reads it. The original LuaLS has none of these nodes: its parser
--- has no `doc.type.keyof` / `.intersection` / `.indexed` / `.conditional` (checked in the base commit's
--- luadoc.lua), and `never`, the utility types and `?T` / `T!` mean nothing to it.
---@type table<string, {label: string, flavors: string[]}>
local TYPE_NODES = {
    ['doc.type.keyof']        = { label = 'keyof T',            flavors = { 'luals', 'wowluals' } },
    ['doc.type.intersection'] = { label = 'A & B',              flavors = { 'luals', 'wowluals' } },
    ['doc.type.indexed']      = { label = 'T[K]',               flavors = { 'luals', 'wowluals' } },
    ['doc.type.conditional']  = { label = 'conditional type',   flavors = { 'luals' } },
}
--- Generic names in `Name<...>` that only some dialects know.
---@type table<string, string[]>
local SIGN_NAMES = {
    returns    = { 'luals', 'wowluals' },
    params     = { 'wowluals' },
    expression = { 'wowluals' },
}

---@async
return function (uri, callback)
    ---@type string[]
    local dialects = config.get(uri, 'Lua.annotations.dialects')
    if #dialects == 0 or util.arrayHas(dialects, 'mixed') then
        return
    end
    local state = files.getState(uri)
    if not state then
        return
    end
    for _, comm in ipairs(state.comms) do
        if comm.type ~= 'comment.short' then
            goto CONTINUE
        end
        local dashes, tag = comm.text:match('^(%-%s*@)([%w_%-]+)')
        if not tag then
            goto CONTINUE
        end
        await.delay()
        report(dialects, knownBy(tag), '@' .. tag, comm.start + 2 + #dashes, comm.start + 2 + #dashes + #tag, callback)
        ::CONTINUE::
    end

    -- the keywords of the annotations (`secret string`, `---@field x readonly number`)
    if not state.ast.docs then
        return
    end
    local text = files.getText(uri) or ''
    ---@type table<string, true>
    local fieldKeywords = {}
    for keyword in docTags.eachFieldKeyword() do
        fieldKeywords[keyword] = true
    end
    guide.eachSource(state.ast.docs, function (source)
        local node = TYPE_NODES[source.type]
        if node then
            report(dialects, node.flavors, node.label, source.start, source.finish, callback)
        elseif source.type == 'doc.param' then
            -- `---@param a ?string`: the parser takes the `?` for the optional marker and sets the flag here
            local extends = source.extends
            if source.prefixOptional and extends then
                report(dialects, { 'luals', 'wowluals' }, '?T', extends.start, extends.finish, callback)
            end
        elseif source.type == 'doc.type' then
            if source.prefixOptional then
                report(dialects, { 'luals', 'wowluals' }, '?T', source.start, source.finish, callback)
            end
            if source.lateinit then
                report(dialects, { 'luals', 'wowluals' }, 'T!', source.start, source.finish, callback)
            end
        elseif source.type == 'doc.type.name' then
            if source[1] == 'never' then
                report(dialects, { 'luals' }, 'never', source.start, source.finish, callback)
            end
        elseif source.type == 'doc.type.sign' then
            local name = source.node and source.node[1]
            if type(name) == 'string' then
                if vm.isUtilityTypeName(name) then
                    report(dialects, { 'luals' }, name .. '<...>', source.start, source.finish, callback)
                elseif SIGN_NAMES[name] then
                    report(dialects, SIGN_NAMES[name], name .. '<...>', source.start, source.finish, callback)
                end
            end
        end
        ---@type string[]
        local words = {}
        if source.type == 'doc.type' then
            words = docTags.getTypeKeywordsOf(source)
        elseif source.type == 'doc.field' then
            for keyword in pairs(fieldKeywords) do
                if source[docTags.getFieldKeyword(keyword)] then
                    words[#words+1] = keyword
                end
            end
            table.sort(words)
        end
        for _, keyword in ipairs(words) do
            -- the keyword of a type stands in front of the type node, the one of a field inside the field
            local first = guide.positionToOffset(state, source.start + 1)
            local last  = guide.positionToOffset(state, source.finish)
            local from  = source.type == 'doc.type' and math.max(1, first - 64) or first
            local to    = source.type == 'doc.type' and first - 1 or last
            local start, finish = findWord(text, from, to, keyword)
            if start and finish then
                report(dialects, docTags.getKeywordFlavors(keyword), keyword,
                    guide.offsetToPosition(state, start - 1), guide.offsetToPosition(state, finish), callback)
            else
                report(dialects, docTags.getKeywordFlavors(keyword), keyword, source.start, source.finish, callback)
            end
        end
    end)
end
