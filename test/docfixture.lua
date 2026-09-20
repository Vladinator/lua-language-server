-- Scaffolding for the tests of what the LuaDoc tag registry (parser.docTags) lets plugins add: a
-- tag, a tag with a list of names, a field keyword and a type keyword, registered here under
-- names of their own. The tests of completion / hover / semantic tokens use these, so they check
-- the generic machinery and do not depend on any plugin being present. What a real plugin adds is
-- tested next to that plugin (script/core/diagnostics/extra/<plugin>.test.lua).
local docTags = require 'parser.docTags'

docTags.registerMarkerTag('fixture-marker', 'doc.fixture-marker',
    'A tag without arguments, registered by the tests.')
docTags.registerNameListTag('fixture-names', 'doc.fixture-names',
    'A tag with a list of names, registered by the tests.')
docTags.registerBindRule('doc.fixture-names', function (_doc, _source, isParam)
    return not isParam
end)
docTags.registerFieldKeyword('fixturefield', 'fixtureField',
    'A field keyword, registered by the tests.')
docTags.registerTypeKeyword('fixturetype', 'fixtureType',
    'A type keyword, registered by the tests.')
