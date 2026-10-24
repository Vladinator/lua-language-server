-- The related information of a syntax error that names a piece of the text (the `function` of a missing `end`) must quote it wherever
-- it is in the file: its positions are row and column, not byte offsets.
local files = require 'files'
local furi  = require 'file-uri'
local diag  = require 'provider.diagnostic'

local uri = furi.encode(TESTROOT .. 'syntax-error-related.lua')

---@param pad integer
---@return string[]
local function related(pad)
    files.setText(uri, ('local x = 1\n'):rep(pad) .. 'local function f()\n  if x then\n    print(x)\nend\n')
    local state = files.getState(uri)
    assert(state)
    ---@type string[]
    local texts = {}
    local errors = diag.syntaxErrors(uri, state)
    if not errors then
        return texts
    end
    for _, err in ipairs(errors) do
        local list = err.relatedInformation
        if list then
            for _, rel in ipairs(list) do
                texts[#texts+1] = rel.message
            end
        end
    end
    return texts
end

for _, pad in ipairs { 0, 1, 40 } do
    local texts = related(pad)
    assert(#texts == 1, ('%d lines above: %d related texts'):format(pad, #texts))
    assert(texts[1] == 'function', ('%d lines above: related text is %q'):format(pad, texts[1]))
end

files.remove(uri)

-- ... and the related text a diagnostic of the checks quotes (`duplicate-index`: the other key), also in a file with multibyte characters
-- (cut at a byte offset it was a piece of a character: invalid UTF-8 in the message, which the client refuses)
local multibyteUri = furi.encode(TESTROOT .. 'diagnostic-related-multibyte.lua')
---@type string[]
local lines = {}
for i = 1, 30 do
    lines[#lines+1] = ('local value%d = "%s"'):format(i, string.char(0xe5, 0x8d, 0x83):rep(i))
end
lines[#lines+1] = 'local t = { alpha = 1, alpha = 2 }'
files.setText(multibyteUri, table.concat(lines, string.char(10)) .. string.char(10))
local multibyteState = files.getState(multibyteUri)
assert(multibyteState)
local row = #lines - 1
local first  = ('local t = { '):len()
local built = diag.buildDiagnostic(multibyteUri, {
    start   = row * 10000 + first + #'alpha = 1, ',
    finish  = row * 10000 + first + #'alpha = 1, alpha',
    message = 'Duplicate index `alpha`.',
    related = {
        { uri = multibyteUri, start = row * 10000 + first, finish = row * 10000 + first + #'alpha' },
    },
})
assert(built and built.relatedInformation and #built.relatedInformation == 1)
assert(built.relatedInformation[1].message == 'alpha', ('the related text is %q'):format(built.relatedInformation[1].message))
files.remove(multibyteUri)
