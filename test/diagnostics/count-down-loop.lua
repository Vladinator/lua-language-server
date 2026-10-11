TEST [[
for i = <!10, 1!> do
    print(i)
end
]]

TEST [[
for i = <!10, 1, 5!> do
    print(i)
end
]]

TEST [[
for i = <!100, 10, 1!> do
    print(i)
end
]]

TEST [[
for i = <!1, -10!> do
    print(i)
end
]]

TEST [[
for i = 1, 1 do
    print(i)
end
]]

-- a step of zero never ends (Lua raises an error), whatever the bounds are
TEST [[
for i = 1, 10, <!0!> do
    print(i)
end
for i = 10, 1, <!0!> do
    print(i)
end
for i = 5, 5, <!0!> do
    print(i)
end
local a, b = 1, 2
for i = a, b, <!0!> do
    print(i)
end
]]

-- a negative step on a loop that counts up never runs
TEST [[
for i = <!1, 10, -1!> do
    print(i)
end
for i = <!1, 10, -2!> do
    print(i)
end
]]

-- ... and the right ways round stay quiet
TEST [[
for i = 10, 1, -1 do
    print(i)
end
for i = 1, 10, 2 do
    print(i)
end
for i = 5, 5, -1 do
    print(i)
end
local a, b = 1, 10
for i = a, b, -1 do
    print(i)
end
]]
