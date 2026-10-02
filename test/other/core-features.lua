-- Editor features that no other test group touched: folding ranges and colour swatches.
---@diagnostic disable: await-in-sync
local files   = require 'files'
local folding = require 'core.folding'
local color   = require 'core.color'
local guide   = require 'parser.guide'

--- The folding ranges of `script` as `kind@startRow-finishRow` strings (rows are 0-based).
---@param script string
---@return string[]
local function foldsOf(script)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    local regions = assert(folding(TESTURI))
    files.remove(TESTURI)
    ---@type string[]
    local list = {}
    for _, region in ipairs(regions) do
        local startRow = guide.rowColOf(region.start)
        local finishRow = guide.rowColOf(region.finish)
        list[#list+1] = ('%s@%d-%d'):format(region.kind, startRow, finishRow)
    end
    table.sort(list)
    return list
end

---@param list string[]
---@param item string
---@return boolean
local function has(list, item)
    for _, v in ipairs(list) do
        if v == item then
            return true
        end
    end
    return false
end

do
    local folds = foldsOf([=[
local function f()
    if true then
        print(1)
    end
end

--[[ long
comment ]]

local t = {
    1,
    2,
}

for i = 1, 3 do
    print(i)
end

-- #region mark
local x = 1
-- #endregion
]=])
    assert(has(folds, 'region@0-4'), 'a function body: ' .. table.concat(folds, ' '))
    assert(has(folds, 'region@1-3'), 'an if block')
    assert(has(folds, 'comment@6-7'), 'a long comment')
    assert(has(folds, 'region@9-12'), 'a table constructor')
    assert(has(folds, 'region@14-16'), 'a for loop')
    assert(has(folds, 'region@18-20'), 'a #region / #endregion pair')
end

-- a class annotation group folds as a comment block
do
    local folds = foldsOf('---@class FoldA\n---@field a number\n---@field b string\nlocal A = {}\n')
    local found = false
    for _, fold in ipairs(folds) do
        if fold:find('^comment@0%-') then
            found = true
        end
    end
    assert(found, 'class doc group: ' .. table.concat(folds, ' '))
end

-- nothing to fold in a flat file
do
    local folds = foldsOf('local a = 1\nlocal b = 2\nprint(a, b)\n')
    assert(#folds == 0, table.concat(folds, ' '))
end

-- colours: an 8-digit `AARRGGBB` string and a 6-digit `#RRGGBB` one are swatches; anything else is not
local function colorsOf(script)
    files.remove(TESTURI)
    files.setText(TESTURI, script)
    local values = assert(color.colors(TESTURI))
    files.remove(TESTURI)
    return values
end

do
    local values = colorsOf('local a = "#ff8000"\nlocal b = "80ff0000"\nlocal c = "nocolor"\nlocal d = "#ff80"\nlocal e = 12345678\n')
    assert(#values == 2, #values)
    local hex6, hex8 = values[1], values[2]
    -- 6 digits: opaque (LSP colours are 0..1, the alpha used to be 255)
    assert(hex6.color.alpha == 1, hex6.color.alpha)
    assert(hex6.color.red == 1 and hex6.color.blue == 0)
    assert(math.abs(hex6.color.green - 128 / 255) < 1e-9)
    -- 8 digits: alpha first
    assert(math.abs(hex8.color.alpha - 128 / 255) < 1e-9)
    assert(hex8.color.red == 1 and hex8.color.green == 0 and hex8.color.blue == 0)
    -- the range excludes the quotes
    assert(hex6.finish - hex6.start == #'#ff8000', hex6.finish - hex6.start)
end

-- the text a colour picker result is written back as: `AARRGGBB`
assert(color.colorToText { alpha = 1, red = 1, green = 0.5, blue = 0 } == 'FFFF7F00')
assert(color.colorToText { alpha = 0, red = 0, green = 0, blue = 0 } == '00000000')
-- ... and a 6-digit swatch survives a round trip through the picker as an opaque colour
do
    local values = colorsOf('local a = "#336699"\n')
    assert(color.colorToText(values[1].color) == 'FF336699', color.colorToText(values[1].color))
end
