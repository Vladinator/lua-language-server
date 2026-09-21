-- Lives next to secret-return.lua: it only runs if the plugin is there.

-- a `nosecret` return slot: a secret value returned in it is reported, the other slots take anything
TEST [[
---@secret
---@return string
local function get() return '' end

---@return nosecret string, string
local function f()
    local s = get()
    return <!s!>, s
end

---@return string, nosecret string
local function g()
    return get(), <!get()!>
end
]]

-- `---@nosecret` above a function: every return of it
TEST [[
---@secret
---@return string
local function get() return '' end

---@nosecret
---@return string?
local function f(flag)
    if flag then
        return <!get()!>
    end
    return 'plain'
end

---@nosecret
---@return string
function G(flag)
    return <!get()!>
end

local M = {}

---@nosecret
---@return string
function M.field()
    return <!get()!>
end

---@nosecret
---@return string
function M:method()
    return <!get()!>
end

---@nosecret
---@return string
M.assigned = function ()
    return <!get()!>
end
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

---@nosecret
---@return string
local function f()
    local s = get()
    if issecretvalue(s) then
        return ''
    end
    return s
end

---@nosecret
---@return string
local function g()
    local s = get()
    return <!s!>
end
]]

-- a nested function is judged by its own declaration
TEST [[
---@secret
---@return string
local function get() return '' end

---@nosecret
---@return function
local function outer()
    return function ()
        return get()
    end
end
]]

-- not known to be secret: not reported (an unannotated callee is `any`, a plain value is plain)
TEST [[
local function unknown() return '' end

---@nosecret
---@return string
local function f()
    return unknown()
end

---@nosecret
---@return string, string
local function g()
    return 'a', 'b'
end
]]

-- a function without the tag or the keyword returns a secret freely
TEST [[
---@secret
---@return string
local function get() return '' end

---@return string
local function f()
    return get()
end
]]

-- a call result is not cleared by the tag: the coder unwraps it
TEST [[
---@nosecret
---@return string
local function f()
    ---@secret-unwrap
    local s = GetSecret()
    return s
end
]]

-- secret and nosecret on one function contradict each other: the tag is reported, nothing else
TEST [[
---@secret
---@<!nosecret!>
---@return string
local function f()
    return ''
end

---@<!nosecret!>
---@return secret string
local function g()
    return ''
end

---@secret
---@return nosecret <!string!>
local function h()
    return ''
end
]]
