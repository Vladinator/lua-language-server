-- Lives next to assign-readonly.lua: it only runs if the plugin is there.

-- an assignment after the object is built, by name and by a literal key
TEST [[
---@class Config
---@field readonly name string
---@field other string

---@param c Config
local function f(c)
    c.<!name!> = 'x'
    c[<!'name'!>] = 'y'
    c.other = 'z'
    print(c.name)
end
]]

-- the table constructor builds it
TEST [[
---@class Config
---@field readonly name string

---@type Config
local c = { name = 'x' }
return c
]]

-- functions that build objects, by name
TEST [[
---@class Config
---@field readonly name string
local Config = {}

---@param name string
---@return Config
function Config.new(name)
    local self = setmetatable({}, { __index = Config })
    self.name = name
    return self
end

---@param name string
function Config:init(name)
    self.name = name
end

Config.ctor = function (self, name)
    self.name = name
end

function Config:rename(name)
    self.<!name!> = name
end
]]

-- a local the function made itself from a constructor or setmetatable
TEST [[
---@class Config
---@field readonly name string
local Config = {}

---@return Config
local function make()
    ---@type Config
    local o = setmetatable({}, { __index = Config })
    o.name = 'x'
    return o
end

---@param other Config
local function change(other)
    local copy = other
    copy.<!name!> = 'y'
end
]]

-- inherited fields
TEST [[
---@class Base
---@field readonly id integer

---@class Child: Base

---@param c Child
local function f(c)
    c.<!id!> = 1
end
]]

-- a field without the keyword, and a class without the field, take assignments
TEST [[
---@class Config
---@field name string

---@param c Config
local function f(c)
    c.name = 'x'
end

local plain = {}
plain.name = 'y'
]]

-- silenced where the style is not covered
TEST [[
---@class Config
---@field readonly name string

---@param c Config
local function reset(c)
    ---@diagnostic disable-next-line: assign-readonly
    c.name = 'x'
end
]]
