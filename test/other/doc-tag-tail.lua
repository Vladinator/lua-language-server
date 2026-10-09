-- What a plugin can add to a marker tag, whose text it reads itself (`docTags.registerTailTokens`, `docTags.registerTailCompletion`): the
-- parts of the text get semantic tokens and the words complete. Tested with a fixture tag (test/docfixture.lua), so the test passes with the
-- whole extra/ folder removed.
local files      = require 'files'
local define     = require 'proto.define'
local semantic   = require 'core.semantic-tokens'
local completion = require 'core.completion'
local catch      = require 'catch'
require 'docfixture'

---@diagnostic disable: await-in-sync

local nl = string.char(10)

---@param line string
---@return table<string, string> tokens text -> token type name
local function tokensOf(line)
    files.setText(TESTURI, line .. nl .. 'local function f() end' .. nl)
    local data = semantic(TESTURI, 0, math.huge) --[[@as integer[] ]]
    ---@type table<string, string>
    local found = {}
    ---@type table<integer, string>
    local names = {}
    for name, id in pairs(define.TokenTypes) do
        names[id] = name
    end
    local char = 0
    for i = 1, #data, 5 do
        if data[i] ~= 0 then
            break
        end
        char = char + data[i + 1]
        found[line:sub(char + 1, char + data[i + 2])] = names[data[i + 3]]
    end
    files.remove(TESTURI)
    return found
end

-- the tokens of the parts
local tokens = tokensOf('---@fixture-tail alpha beta = gamma')
assert(tokens['alpha'] == 'parameter', 'the first word: ' .. tostring(tokens['alpha']))
assert(tokens['beta'] == 'enumMember', 'the second word: ' .. tostring(tokens['beta']))
assert(tokens['='] == 'operator', 'the operator: ' .. tostring(tokens['=']))
assert(tokens['gamma'] == nil, 'a third word is a comment')

-- nothing after the tag: nothing to colour, no failure
tokens = tokensOf('---@fixture-tail')
assert(tokens['alpha'] == nil, 'no words')

-- a tag nobody registered tokens for is not touched
tokens = tokensOf('---@fixture-marker alpha beta')
assert(tokens['alpha'] == nil and tokens['beta'] == nil, 'a marker tag without a tokenizer')

-- hover over the parts: only what the tag's hoverer answers
local hover = require 'core.hover'
---@param script string a script with one `<?word?>`
---@return string? markdown
local function hoverOf(script)
    local text, catched = catch(script, '?')
    files.setText(TESTURI, text)
    local shown = hover.byUri(TESTURI, catched['?'][1][1], 1)
    files.remove(TESTURI)
    return shown and shown:string() or nil
end
local fn = nl .. 'local function f() end' .. nl
assert((hoverOf('---@fixture-tail <?alpha?> beta' .. fn) or ''):find('the first word: alpha', 1, true), 'the first word answers')
assert(not (hoverOf('---@fixture-tail alpha <?beta?>' .. fn) or ''):find('the first word', 1, true), 'another word does not')
assert((hoverOf('---@<?fixture-tail?> alpha' .. fn) or ''):find('fixture-tail', 1, true), 'the tag word keeps the tag help')
assert(not (hoverOf('---@<?fixture-marker?> alpha' .. fn) or ''):find('the first word', 1, true), 'another tag has no hoverer')

-- completion of the words
---@param script string a script with one `<??>`
---@return table<string, integer> labels with their kinds
local function offered(script)
    local text, catched = catch(script, '?')
    files.setText(TESTURI, text)
    local items = completion.completion(TESTURI, catched['?'][1][2], nil) or {}
    ---@type table<string, integer>
    local labels = {}
    for _, item in ipairs(items) do
        labels[item.label] = item.kind
    end
    files.remove(TESTURI)
    return labels
end
local kinds = define.CompletionItemKind
local labels = offered('---@fixture-tail <??>' .. nl .. 'local function f() end' .. nl)
assert(labels['one-choice'] == kinds.Variable and labels['two-choice'] == kinds.EnumMember, 'the first word')
labels = offered('---@fixture-tail tw<??>' .. nl .. 'local function f() end' .. nl)
assert(labels['two-choice'] and not labels['one-choice'], 'a half typed word keeps the matching candidates')
labels = offered('---@fixture-tail kept <??>' .. nl .. 'local function f() end' .. nl)
assert(labels['kept-then'] == kinds.TypeParameter and not labels['one-choice'], 'the second word depends on the first')
labels = offered('---@fixture-tail a b <??>' .. nl .. 'local function f() end' .. nl)
assert(not labels['one-choice'] and not labels['a-then'], 'nothing after that')
-- a completer may name the part of the word being typed: only that part is matched and replaced
---@param script string a script with one `<??>`
---@return table<string, integer> labels with the length of the text each one replaces
local function replaced(script)
    local text, catched = catch(script, '?')
    files.setText(TESTURI, text)
    local items = completion.completion(TESTURI, catched['?'][1][2], nil) or {}
    ---@type table<string, integer>
    local lengths = {}
    for _, item in ipairs(items) do
        local edit = item.textEdit
        lengths[item.label] = edit and (edit.finish - edit.start) or -1
    end
    files.remove(TESTURI)
    return lengths
end
labels = replaced('---@fixture-tail a+<??>' .. nl .. 'local function f() end' .. nl)
assert(labels['plus-choice'] == 0, 'after the separator nothing is typed yet')
labels = replaced('---@fixture-tail a+pl<??>' .. nl .. 'local function f() end' .. nl)
assert(labels['plus-choice'] == 2, 'the part after the separator is replaced, not the word')
labels = replaced('---@fixture-tail a+zz<??>' .. nl .. 'local function f() end' .. nl)
assert(not labels['plus-choice'], 'and it is what is matched')
labels = replaced('---@fixture-tail on<??>' .. nl .. 'local function f() end' .. nl)
assert(labels['one-choice'] ~= nil and not labels['plus-choice'], 'a word without the separator completes as before')
-- text after the cursor is not part of what is typed (the line is read up to the cursor, not one character further)
labels = replaced('---@fixture-tail on<??> rest of the line' .. nl .. 'local function f() end' .. nl)
assert(labels['one-choice'] == 2 and not labels['two-choice'], 'a word followed by text')
labels = replaced('---@fixture-tail <??> rest' .. nl .. 'local function f() end' .. nl)
assert(labels['one-choice'] == 0 and labels['two-choice'] == 0, 'the first word, text after the cursor')
-- a marker tag without a completer offers no candidates of its own
labels = offered('---@fixture-marker <??>' .. nl .. 'local function f() end' .. nl)
assert(not labels['one-choice'], 'another tag')
