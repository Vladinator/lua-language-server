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

-- writing with a key that is nil for certain is always the runtime error "index is nil"
TEST [[
local t = {}
t[<!nil!>] = 1
]]

-- fine: a key that is only possibly nil is need-check-nil's, a plain key is fine
TEST [[
local t = {}
---@type string?
local k
t[k] = 1
t['x'] = 1
]]

-- a table constructor with a key that is nil for certain: the runtime error "index is nil"
TEST [[
local t = { [<!nil!>] = 1, a = 2 }
]]

-- ... a possibly nil key, a plain key and a computed one are not judged here
TEST [[
---@type string?
local k
local a = { [k] = 1 }
local b = { ['x'] = 1, [1] = 2, [k or 'y'] = 3 }
]]
