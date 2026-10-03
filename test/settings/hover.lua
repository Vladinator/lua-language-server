-- The `Lua.hover.*` settings that decide what hovering a LITERAL shows: the decoded content of a string that
-- is written with escape characters (`viewString`, cut at `viewStringMax`), the decimal value of a number
-- that is not written in plain decimal (`viewNumber`). Each is checked with the setting off and on, and
-- with the case it must not touch (a string without an escape, a plain decimal number).
local files  = require 'files'
local config = require 'config'
local catch  = require 'catch'
local hover  = require 'core.hover'

---@diagnostic disable: await-in-sync

--- The whole hover text at the `<?` `?>` of `script` ('' when there is none).
---@param script string
---@return string
local function hoverAt(script)
    local text, catched = catch(script, '?')
    files.remove(TESTURI)
    files.setText(TESTURI, text)
    local result = hover.byUri(TESTURI, catched['?'][1][1], 1)
    files.remove(TESTURI)
    if not result then
        return ''
    end
    return (result:string():gsub('\r\n', '\n'))
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

local tab = string.char(9)
local bs  = string.char(92)

-- viewString: a string written with an escape character shows what it decodes to
local escaped = 'local s = <?"x' .. bs .. 'ty"?>'
with('hover.viewString', true, function ()
    assert(hoverAt(escaped):find('x' .. tab .. 'y', 1, true), 'decoded content shown: ' .. hoverAt(escaped))
end)
with('hover.viewString', false, function ()
    assert(not hoverAt(escaped):find('x' .. tab .. 'y', 1, true), 'nothing shown when off: ' .. hoverAt(escaped))
end)

-- ... and a string without an escape has nothing to decode, whatever the setting
for _, value in ipairs { false, true } do
    with('hover.viewString', value, function ()
        local shown = hoverAt('local s = <?"plain"?>')
        assert(not shown:find('plain', 1, true) or #shown < 40, 'no extra view for a plain string: ' .. shown)
    end)
end

-- viewStringMax: the decoded content is cut to that length (then `...`)
local long = 'local s = <?"abcdefghij' .. bs .. 'n"?>'
with('hover.viewString', true, function ()
    with('hover.viewStringMax', 5, function ()
        local shown = hoverAt(long)
        assert(shown:find('abcde...', 1, true), 'cut at 5: ' .. shown)
        assert(not shown:find('abcdefghij', 1, true), 'not whole: ' .. shown)
    end)
    with('hover.viewStringMax', 1000, function ()
        assert(hoverAt(long):find('abcdefghij', 1, true), 'whole under a large maximum')
    end)
end)

-- viewNumber: a hexadecimal (or exponent) literal shows its decimal value
with('hover.viewNumber', true, function ()
    assert(hoverAt('local n = <?0xFF?>'):find('255', 1, true), 'decimal shown: ' .. hoverAt('local n = <?0xFF?>'))
end)
with('hover.viewNumber', false, function ()
    assert(not hoverAt('local n = <?0xFF?>'):find('255', 1, true), 'nothing shown when off')
end)
-- ... a plain decimal literal has nothing to translate
for _, value in ipairs { false, true } do
    with('hover.viewNumber', value, function ()
        local shown = hoverAt('local n = <?255?>')
        assert(not shown:find('255.0', 1, true), 'no extra view for a decimal literal')
    end)
end
