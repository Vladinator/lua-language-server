-- An `---@enum` whose literal values are not all of one kind: a value of another kind than the first literal one is reported
-- (a number after a string, a string after a number, a boolean among either). Values that are not literals say nothing.

-- strings, then a number
TEST [[
---@enum Mode
local Mode = {
    A = 'a',
    B = 'b',
    C = <!3!>,
}
]]

-- numbers, then a string (integers and floats are one kind)
TEST [[
---@enum Level
local Level = {
    Low = 1,
    Mid = 2.5,
    High = <!'high'!>,
}
]]

-- a value that is neither a number nor a string: reported, whatever the other values are
TEST [[
---@enum Flag
local Flag = {
    Off = 0,
    On = <!true!>,
}
]]

TEST [[
---@enum Booleans
local Booleans = { Yes = <!true!>, No = <!false!> }
---@enum Tables
local Tables = { Empty = <!{}!>, Full = <!{ 1 }!> }
---@enum Functions
local Functions = { Run = <!function() end!> }
]]

-- every value of another kind than the first one is reported, a boolean as unsupported
TEST [[
---@enum Mixed
local Mixed = {
    A = 'a',
    B = <!1!>,
    C = <!true!>,
    D = 'd',
    E = <!2!>,
}
]]

-- one kind: nothing, whatever the kind
TEST [[
---@enum Strings
local Strings = { A = 'a', B = 'b' }
---@enum Numbers
local Numbers = { A = 1, B = 2, C = 3.5 }
]]

-- values that are not literals are not judged (they could be anything), and the first literal one sets the kind
TEST [[
local function one() return 1 end
local named = 'x'
---@enum Dynamic
local Dynamic = {
    A = one(),
    B = named,
    C = 'c',
    D = <!2!>,
}
]]

-- a table that is not an enum is not looked at
TEST [[
local Plain = { A = 'a', B = 1, C = true }
]]

-- the enum table written right after the tag without a local
TEST [[
---@enum Direct
local Direct = {
    N = 'n',
    S = <!4!>,
}
local copy = Direct
]]

-- indexed fields count as well
TEST [[
---@enum Indexed
local Indexed = {
    ['a'] = 'a',
    ['b'] = <!2!>,
}
]]
