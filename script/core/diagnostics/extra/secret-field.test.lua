-- Lives next to secret-field.lua: it only runs if the plugin is there.

-- an assignment to the field, by name or by a literal key, and a table constructor of the class
TEST [[
---@class Foo
---@field name nosecret string
---@field other string

---@secret
---@return string
local function get() return '' end

---@type Foo
local foo = { name = <!get()!>, other = get() }
foo.name = <!get()!>
foo.other = get()
foo['name'] = <!get()!>
foo.name = 'plain'
]]

-- a value that was checked is not secret any more
TEST [[
---@class Foo
---@field name nosecret string

---@secret
---@return string
local function get() return '' end

---@secret-check
---@param v any
---@return boolean
local function issecretvalue(v) return false end

---@type Foo
local foo = {}
local id = get()
if not issecretvalue(id) then
    foo.name = id
end
foo.name = <!id!>
]]

-- inherited from the class the field is declared in
TEST [[
---@class Base
---@field name nosecret string

---@class Child: Base

---@secret
---@return string
local function get() return '' end

---@type Child
local child = {}
child.name = <!get()!>
]]

-- a field without the keyword, and a class without the field, take a secret
TEST [[
---@class Foo
---@field name string

---@secret
---@return string
local function get() return '' end

---@type Foo
local foo = {}
foo.name = get()
local plain = {}
plain.name = get()
]]
