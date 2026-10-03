-- Lives next to invalid-secret-guard.lua: it only runs if the plugin does too.

-- well formed: nothing reported (every kind, a local function, a field function, a vararg)
TEST [[
---@secret-guard value is-secret
---@param value any
---@return boolean
local function a(value) return true end

---@secret-guard value accessible
---@param value any
---@return boolean
local function b(value) return true end

---@secret-guard value any-secret
---@param value any
---@return boolean
local function c(value) return true end

local M = {}

---@secret-guard second accessible
---@param first any
---@param second any
---@return boolean
function M.d(first, second) return true end

---@secret-guard ... accessible
---@return boolean
local function e(...) return true end
]]

-- not of the form: a word that is no kind, no word at all, no parameter, extra words
TEST [[
---@<!secret-guard!> value bogus
---@param value any
local function a(value) end

---@<!secret-guard!>
local function b(value) end

---@<!secret-guard!> value
---@param value any
local function c(value) end

---@<!secret-guard!> value accessible and more
---@param value any
local function d(value) end
]]

-- names something that is not a parameter
TEST [[
---@secret-guard <!other!> is-secret
---@param value any
local function a(value) end
]]

-- `...` needs a vararg: a function without one has no `...` parameter
TEST [[
---@secret-guard <!...!> accessible
---@param value any
local function a(value) end
]]

-- not above a function
TEST [[
---@<!secret-guard value is-secret!>
local value = 1
]]
