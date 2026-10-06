-- The restriction tags of wowlua-ls's secret model, accepted as syntax only. wowlua-ls lets an API say under which conditions it returns a
-- secret (`@secret-unless`, `@secret-when`) and lets a function prove that a restriction is not active (`@secret-clears`,
-- `@secret-restriction-guard`, `@secret-precondition`, `@secret-satisfies`, `@secret-aspect`). This fork models "always tainted" and does not
-- read them: a file that carries them parses, they are offered by completion, shown by hover and coloured as tags, and the dialect lint knows
-- them as wowlua-ls's. When the semantics are taken on they have their place here. A feature plugin: it registers no diagnostic; deleting
-- this file removes the tags. Its tests are next to it.

local docTags = require 'parser.docTags'

--- name, what hover and completion say
local TAGS = {
    { 'secret-unless', 'wowlua-ls: calls that return ordinary values for the given literal arguments: `---@secret-unless unit "player"`. This fork accepts the tag and does not read it.' },
    { 'secret-when', 'wowlua-ls: the result is secret when a restriction predicate is active: `---@secret-when Predicate [description]`. This fork accepts the tag and does not read it.' },
    { 'secret-clears', 'wowlua-ls: a function that clears the secrecy of the listed predicates when it returns a value: `---@secret-clears Predicate[,Predicate...] [binding...] [== Value]`. This fork accepts the tag and does not read it.' },
    { 'secret-restriction-guard', 'wowlua-ls: a function that tells whether a restriction is active: `---@secret-restriction-guard param|Restriction [== Value]`. This fork accepts the tag and does not read it.' },
    { 'secret-precondition', 'wowlua-ls: a precondition of a call: `---@secret-precondition Name [FailureMode] [description]`. This fork accepts the tag and does not read it.' },
    { 'secret-satisfies', 'wowlua-ls: the function satisfies a named precondition: `---@secret-satisfies Name [binding...]`. This fork accepts the tag and does not read it.' },
    { 'secret-aspect', 'wowlua-ls: the widget aspect (text, value, ...) that receives secrets: `---@secret-aspect Aspect`. This fork accepts the tag and does not read it.' },
}

for _, tag in ipairs(TAGS) do
    local name, description = tag[1], tag[2]
    local docType = 'doc.' .. name
    docTags.registerMarkerTag(name, docType, description)
    docTags.registerBindRule(docType, function (_doc, source, _isParam)
        return source.type == 'function'
    end)
    docTags.setTagFlavors(name, { 'wowluals' })
end
