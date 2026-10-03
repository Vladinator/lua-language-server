-- reading with a possibly-nil key
TEST [[
local t = {}

---@type string?
local k

local _ = t[<!k!>]
]]

-- a non-nil key, a literal, a narrowed key and an `any` key are fine
TEST [[
local t = {}

---@type string
local a
---@type string?
local b
---@type any
local c

local _ = t[a]
local _ = t['x']
local _ = t[1]
local _ = t[c]
if b then
    local _ = t[b]
end
]]

-- writing is need-check-nil's, not this one's
TEST [[
local t = {}

---@type string?
local k

t[k] = 1
]]

-- a parameter of an optional type, and a call result that may be nil
TEST [[
local t = {}

---@param k? string
local function f(k)
    return t[<!k!>]
end

---@return string?
local function g() end

local _ = t[<!g()!>]
]]
