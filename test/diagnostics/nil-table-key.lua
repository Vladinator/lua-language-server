TEST [[
---@type table<<!string?!>, number>
local a

---@type table<<!string | nil!>, number>
local b

---@param t table<<!integer?!>, string>
local function f(t) end
]]

-- a plain key, a nilable value, a union without nil, `false` and a different generic are fine
TEST [[
---@type table<string, number?>
local a

---@type table<string | number, number>
local b

---@type table<boolean, number>
local c

---@type table<string, table<number, string?>>
local d

---@type Foo<string?, number>
local e
]]
