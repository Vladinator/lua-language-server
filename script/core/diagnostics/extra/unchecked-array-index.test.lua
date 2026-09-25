-- Lives next to unchecked-array-index.lua: it only runs if the plugin is there.
-- (status = 'None': off by default, but the test harness force-enables every diagnostic under test.)

-- the danger contexts: arithmetic, a comparison, further indexing, being called, a numeric `for` bound
-- (the whole `arr[i]` read is the range, like need-check-nil marks the whole chain up to the access)
TEST [[
---@param arr integer[]
local function f(arr)
    local a = <!arr[1]!> + 1
    local b = <!arr[2]!> < 5
    local c = <!arr[3]!>.x
    <!arr[4]!>()
    for i = 1, <!arr[5]!> do
    end
end
]]

-- reading it plainly, passing it to an ordinary call, or a boolean/narrowing context, is not reported:
-- only the unsafe contexts are (print(nil), unlike `nil + 1`, does not error)
TEST [[
---@param arr integer[]
local function f(arr)
    local a = arr[1]
    print(arr[2])
    if arr[3] then
        print('ok')
    end
    print(arr[4] == nil)
end
]]

-- a tuple (fixed length, part of the type) and a `table<K, V>` map (no key ever claimed to exist) do
-- not trigger this
TEST [[
---@type [integer, string]
local tuple

---@type table<integer, integer>
local map

local a = tuple[1] + 1
local b = map[1] + 1
]]

-- safe navigation already handles the nil itself
TEST [[
---@param arr integer[]?
local function f(arr)
    local a = arr?.[1] + 1
end
]]

-- silenced where wanted
TEST [[
---@param arr integer[]
local function f(arr)
    ---@diagnostic disable-next-line: unchecked-array-index
    local a = arr[1] + 1
end
]]
