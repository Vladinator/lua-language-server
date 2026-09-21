-- Lives next to secret-variable.lua: it only runs if the plugin is there.

-- `---@type nosecret T`: the initial value and every assignment
TEST [[
---@secret
---@return string
local function get() return '' end

---@type nosecret string
local a = <!get()!>

---@type nosecret string
local b = 'plain'
b = <!get()!>
b = 'plain again'

---@type nosecret string?
local c
c = <!get()!>
]]

-- `---@nosecret`: all the locals of the statement, or the named ones
TEST [[
---@secret
---@return string
local function get() return '' end

---@nosecret
local a, b = <!get()!>, 'x'

---@nosecret d
local c, d = get(), 'x'
c = get()
d = <!get()!>
]]

-- a value that was checked is not secret any more
TEST [[
---@secret
---@return string
local function get() return '' end

---@secret-check
---@param v any
---@return boolean
local function issecretvalue(v) return false end

---@type nosecret string
local a = ''
local s = get()
if not issecretvalue(s) then
    a = s
end
a = <!s!>
]]

-- a local without the declaration takes a secret; an unknown value is not reported
TEST [[
---@secret
---@return string
local function get() return '' end

local a = get()
a = get()

---@type nosecret string
local b = Unknown()
]]

-- a function tag is not a variable tag
TEST [[
---@secret
---@return string
local function get() return '' end

---@nosecret
local f = function ()
    return ''
end
f = get
]]

-- secret and nosecret on one local contradict each other: the tag is reported, nothing else
TEST [[
---@secret
---@<!nosecret!>
local a = 1

---@secret
---@type nosecret <!string!>
local b = ''

---@secret a2
---@<!nosecret a2!>
local a2, b2 = 1, 2
]]
