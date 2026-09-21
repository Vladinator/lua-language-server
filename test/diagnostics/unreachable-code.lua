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
