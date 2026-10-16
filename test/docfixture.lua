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
docTags.registerParamKindTag('fixture-param-kind', 'doc.fixture-param-kind', { 'alpha', 'beta' },
    'A tag with a parameter and a kind, registered by the tests.')
docTags.registerKindParamsTag('fixture-kind-params', 'doc.fixture-kind-params', { 'alpha', 'beta', 'kind-with-hyphen' },
    'A tag with a kind and parameter names, registered by the tests.')
docTags.registerNameTypeTag('fixture-nametype', 'doc.fixture-nametype',
    'A tag with a name and a type, registered by the tests.')
docTags.registerGuardTag('fixture-isguard', 'doc.fixture-isguard',
    'A tag that says `x is T` / `x is not T`, registered by the tests.')
docTags.registerMarkerTag('fixture-tail', 'doc.fixture-tail',
    'A marker tag whose text is read by whoever registered it, registered by the tests.')
docTags.registerBindRule('doc.fixture-tail', function (_doc, source, _isParam)
    return source.type == 'function'
end)
-- the first word is coloured as a parameter, the second as an enum member, a `=` anywhere as an operator
-- a line in the hover of the function the tag is bound to
docTags.registerHoverNote('doc.fixture-tail', function (doc)
    return 'fixture hover note: ' .. (doc.comment and doc.comment.text or '')
end)
docTags.registerTailTokens('doc.fixture-tail', function (doc)
    local comment = doc.comment
    local text = comment and comment.text or ''
    local base = comment and comment.start or 0
    ---@type parser.docTags.tailToken[]
    local tokens = {}
    local index = 0
    local from = 1
    while true do
        local first, last = text:find('%S+', from)
        if not first or not last then
            break
        end
        index = index + 1
        ---@type string?
        local role
        if text:sub(first, last) == '=' then
            role = 'operator'
        elseif index == 1 then
            role = 'parameter'
        elseif index == 2 then
            role = 'enumMember'
        end
        if role then
            tokens[#tokens+1] = { start = base + first - 1, finish = base + last, role = role }
        end
        from = last + 1
    end
    return tokens
end)
-- hover: the first word says what it is
docTags.registerTailHover('doc.fixture-tail', function (doc, position)
    local comment = doc.comment
    local text = comment and comment.text or ''
    local first, last = text:find('%S+')
    if comment and first and last then
        local start = comment.start + first - 1
        if position >= start and position <= start + (last - first + 1) then
            return 'the first word: ' .. text:sub(first, last), start, start + (last - first + 1)
        end
    end
    return nil
end)
-- the first word: two choices; the second: one (given the first); then nothing
docTags.registerTailCompletion('doc.fixture-tail', function (at)
    if at.partial:find('+', 1, true) then
        -- a part of the word after a `+`: that part is what is matched and replaced
        return { { label = 'plus-choice', role = 'parameter' } }, at.partial:match('[^+]*$')
    end
    if #at.words == 0 then
        return { { label = 'one-choice', role = 'parameter' }, { label = 'two-choice', role = 'enumMember' } }
    elseif #at.words == 1 then
        return { { label = at.words[1] .. '-then', role = 'typeParameter' } }
    end
    return {}
end)
docTags.registerIntegersOrNameTag('fixture-slots', 'doc.fixture-slots', 2,
    'A tag with up to two integers or one name, registered by the tests.')
docTags.registerBindRule('doc.fixture-nametype', function (_doc, source, _isParam)
    return source.type == 'function'
end)
docTags.registerBindRule('doc.fixture-param-kind', function (_doc, source, _isParam)
    return source.type == 'function'
end)
docTags.registerBindRule('doc.fixture-kind-params', function (_doc, source, _isParam)
    return source.type == 'function'
end)
docTags.registerFieldKeyword('fixturefield', 'fixtureField',
    'A field keyword, registered by the tests.')
docTags.registerTypeKeyword('fixturetype', 'fixtureType',
    'A type keyword, registered by the tests.')
