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
-- Only tags are checked so far (not type syntax such as `nosecret`, `?T`, `params<F>`).
-- Deleting this file removes the setting's effect and the lint. Its tests are next to it.

local files           = require 'files'
local config          = require 'config'
local await           = require 'await'
local util            = require 'utility'
local docTags         = require 'parser.docTags'
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
    'event', 'callback-event-arg', 'flavor-narrows', 'secret-args', 'secret-unless', 'secret-when',
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
        local known = knownBy(tag)
        if not known then
            -- a tag no dialect knows: a typo, or a plugin's own
            callback {
                start   = comm.start + 2 + #dashes,
                finish  = comm.start + 2 + #dashes + #tag,
                message = ('`@%s` is not a known annotation of any dialect: it is ignored.'):format(tag),
            }
            goto CONTINUE
        end
        for _, flavor in ipairs(known) do
            if util.arrayHas(dialects, flavor) then
                goto CONTINUE
            end
        end
        callback {
            start   = comm.start + 2 + #dashes,
            finish  = comm.start + 2 + #dashes + #tag,
            message = ('`@%s` is only known to %s: the dialects listed in `Lua.annotations.dialects` ignore it.'):format(tag, table.concat(known, ', ')),
        }
        ::CONTINUE::
    end
end
