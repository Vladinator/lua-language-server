-- The wowlua-ls tag of the secret model that this fork accepts as syntax only: `@secret-aspect` (the widget aspect a method makes secret or reads).
-- The context tags (`@secret-when`, `@secret-unless`, `@secret-clears`, `@secret-restriction-guard`, `@secret-precondition`, `@secret-satisfies`)
-- are read by invalid-secret-context.lua. A file that carries this tag parses, it is offered by completion, shown by hover and coloured as a tag,
-- and the dialect lint knows it as wowlua-ls's. A feature plugin: it registers no diagnostic; deleting this file removes the tag. Its tests are next to it.

local docTags = require 'parser.docTags'

--- name, what hover and completion say
local TAGS = {
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
