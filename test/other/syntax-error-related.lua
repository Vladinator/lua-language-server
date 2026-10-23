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
