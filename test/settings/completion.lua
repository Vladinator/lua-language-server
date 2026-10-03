-- The `Lua.completion.*` settings that were not covered anywhere: `showParams` (a function's label shows its
-- parameters), `maxSuggestCount` (the fields offered for `t.` are cut), `postfix` (the character that opens the
-- postfix snippets, empty = off). Each with the setting changed and the case it must not touch.
local files      = require 'files'
local config     = require 'config'
local catch      = require 'catch'
local completion = require 'core.completion'

---@diagnostic disable: await-in-sync

--- The labels completion offers at the `<?` `?>` of `script`, sorted.
---@param script string
---@return string[]
local function labelsAt(script)
    local text, catched = catch(script, '?')
    files.remove(TESTURI)
    files.setText(TESTURI, text)
    local items = completion.completion(TESTURI, catched['?'][1][2], nil) or {}
    files.remove(TESTURI)
    ---@type string[]
    local labels = {}
    for _, item in ipairs(items) do
        labels[#labels+1] = item.label
    end
    table.sort(labels)
    return labels
end

---@param labels string[]
---@param label  string
---@return boolean
local function has(labels, label)
    for _, l in ipairs(labels) do
        if l == label then
            return true
        end
    end
    return false
end

---@param key   string
---@param value any
---@param fn    fun()
local function with(key, value, fn)
    local full = 'Lua.' .. key
    local saved = config.get(nil, full)
    config.set(nil, full, value)
    fn()
    config.set(nil, full, saved)
end

-- showParams: `fooBar(a, b)` or just `fooBar`; a plain variable is the same either way
with('completion.showParams', true, function ()
    assert(has(labelsAt('local function fooBar(a, b) end\nfooB<??>'), 'fooBar(a, b)'))
    assert(has(labelsAt('local fooVar = 1\nfooV<??>'), 'fooVar'))
end)
with('completion.showParams', false, function ()
    local labels = labelsAt('local function fooBar(a, b) end\nfooB<??>')
    assert(has(labels, 'fooBar') and not has(labels, 'fooBar(a, b)'))
    assert(has(labelsAt('local fooVar = 1\nfooV<??>'), 'fooVar'))
end)

-- maxSuggestCount: the fields offered after `t.` stop after that many (a big limit offers all of them)
---@type string[]
local fields = {}
for i = 1, 30 do
    fields[#fields+1] = 't.f' .. i .. ' = ' .. i
end
local manyFields = 'local t = {}\n' .. table.concat(fields, '\n') .. '\nt.f<??>'
with('completion.maxSuggestCount', 5, function ()
    local count = #labelsAt(manyFields)
    assert(count < 30 and count >= 5, 'cut: ' .. count)
end)
with('completion.maxSuggestCount', 1000, function ()
    assert(#labelsAt(manyFields) == 30, 'all of them')
end)

-- postfix: `t@` offers the snippets for the value in front of it; the character is the setting, and an empty
-- one switches the snippets off. The other character then is plain text.
local atScript = 'local t = {}\nt@<??>'
local hashScript = 'local t = {}\nt#<??>'
with('completion.postfix', '@', function ()
    assert(has(labelsAt(atScript), 'ipairs'), 'postfix after @')
    assert(not has(labelsAt(hashScript), 'ipairs'), 'not after #')
end)
with('completion.postfix', '#', function ()
    assert(has(labelsAt(hashScript), 'ipairs'), 'postfix after #')
    assert(not has(labelsAt(atScript), 'ipairs'), 'not after @')
end)
with('completion.postfix', '', function ()
    assert(not has(labelsAt(atScript), 'ipairs'), 'off')
    assert(not has(labelsAt(hashScript), 'ipairs'), 'off')
end)
