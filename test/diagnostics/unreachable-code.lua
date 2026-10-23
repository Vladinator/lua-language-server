TEST [[
if X then
    return false
elseif X then
    return false
else
    return false
end
<!return true!>
]]

TEST [[
function X()
    if X then
        return false
    elseif X then
        return false
    else
        return false
    end
    <!return true!>
end
]]

TEST [[
while true do
end

<!print(1)!>
]]

TEST [[
while true do
end

<!print(1)!>
]]

TEST [[
while X do
    X = 1
end

print(1)
]]

TEST [[
while true do
    if not X then
        break
    end
end

print(1)

do return end
]]

TEST [[
local done = false

local function set_done()
    done = true
end

while not done do
    set_done()
end

print(1)
]]

-- both branches end in a call of a `never` function
TEST [[
---@return never
local function fail() error('x') end

local function f(x)
    if x then
        fail()
    else
        fail()
    end
    <!print(1)!>
end
]]

TEST [[
---@return never
local function fail() error('x') end

local function f(x)
    if x then
        fail()
    end
    print(1)
end
]]

-- code after a call that never returns, in the same block (`error` ends the function there)
TEST [[
local function f()
    error('stop')
    <!print(1)
    print(2)!>
end
]]

-- ... and after a function declared `---@return never`, and `os.exit`
TEST [[
---@return never
local function fail() error('x') end

local function f()
    fail()
    <!print(1)!>
end
local function g()
    os.exit()
    <!print(2)!>
end
]]

-- ... not when the call may not run (a branch, a loop), or when it is the last statement
TEST [[
local function f(x)
    if x then error('x') end
    print(1)
    for _ = 1, 2 do error('y') end
    print(2)
    while x do error('z') end
    print(3)
    error('last')
end
]]

-- `do return end` (the debugging idiom) ends what follows it in the block
TEST [[
local function f()
    do return 1 end
    <!print(1)!>
end
local function g()
    do error('x') end
    <!print(2)!>
end
]]

-- ... a `do` block without a return, or with it behind a condition, does not
TEST [[
local function f(x)
    do print(1) end
    print(2)
    do
        if x then return 1 end
    end
    print(3)
end
]]

-- a label after it can be reached by a `goto`: nothing is judged
TEST [[
local function f(x)
    for _ = 1, 2 do
        if x then goto continue end
        do return false end
        ::continue::
        print(1)
    end
    return true
end
local function g()
    error('x')
    ::again::
    print(1)
end
]]

-- the code after a `goto` in the same block, up to the next label (a label can be the target of another goto)
TEST [[
for i = 1, 3 do
    goto continue
    <!print(i)
    print(i + 1)!>
    ::continue::
end
]]

-- ... a goto last in its block, or followed by a label at once, leaves nothing; a goto behind a condition judges nothing
TEST [[
for i = 1, 3 do
    if i == 2 then goto continue end
    print(i)
    ::continue::
end
do
    goto skip
    ::skip::
    print(1)
end
]]

-- ... inside any block, not only a function body
TEST [[
local x = ...
if x then
    goto done
    <!print(1)!>
end
while x do
    goto done
    <!x = nil!>
end
::done::
]]
