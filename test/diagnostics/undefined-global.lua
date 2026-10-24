TEST [[
local print, _G
print(<!x!>)
print(<!log!>)
print(<!X!>)
print(<!Log!>)
print(<!y!>)
print(Z)
print(_G)
Z = 1
]]

TEST [[
X = table[<!x!>]
]]
TEST [[
T1 = 1
_ENV.T2 = 1
_G.T3 = 1
_ENV._G.T4 = 1
_G._G._G.T5 = 1
rawset(_G, 'T6', 1)
rawset(_ENV, 'T7', 1)
print(T1)
print(T2)
print(T3)
print(T4)
print(T5)
print(T6)
print(T7)
]]

TEST [[
---@class c
c = {}
]]

-- a line longer than the 10000 columns of a position (generated data): the code on the lines after it still sees what the line declares,
-- and still reports what is not declared
TEST("local long = '" .. ('x'):rep(12000) .. "'\nprint(long)\nprint(<!notDeclared!>)\n")
TEST("local first = {" .. ('1,'):rep(6000) .. "} local second = 2\nprint(first, second)\nprint(<!notDeclared!>)\n")
TEST("local a = 1" .. (' '):rep(10050) .. "local b = 2; print(b)\nprint(a, b, <!notDeclared!>)\n")
