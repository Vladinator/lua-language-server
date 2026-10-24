TEST [[
---@class Class
local m = {}

m.xx = 1 -- OK

---@type Class
local m

m.xx = 1 -- OK
m.<!yy!> = 1 -- Warning
]]

TEST [[
---@class Class
local m = {}

m.xx = 1 -- OK

---@class Class
local m

m.xx = 1 -- OK
m.yy = 1 -- OK
]]

TEST [[
---@type { xx: number }
local m

m.xx = 1 -- OK
m.<!yy!> = 1 -- Warning
]]

TEST [[
---@type { xx: number, [any]: any }
local m

m.xx = 1 -- OK
m.yy = 1 -- OK
]]

TEST [[
---@class Class
---@field x number

---@type Class
local t

t.x = 1 -- OK
t.<!y!> = 2 -- Warning
]]

TEST [[
---@class Class
---@field x number
---@field [any] any

---@type Class
local t

t.x = 1 -- OK
t.y = 2 -- OK
]]


TEST [[
---@class (exact) Class
---@field x number
local m = {
    x = 1, -- OK
    <!y!> = 2, -- Warning
}

m.x = 1 -- OK
m.<!y!> = 2 -- Warning

function m:init() -- OK
    self.x = 1 -- OK
    self.<!y!> = 2 -- Warning
    function self:<!xx!>() -- Warning
    end
end
]]

TEST [[
---@class Class
local m = {
    xx = 1, -- OK
}

---@type Class
local m

m.xx = 1 -- OK
m.<!yy!> = 1 -- Warning
]]

-- a class that inherits from table<string, V> takes any string key
TEST [[
---@class Dict : table<string, number>

---@type Dict
local d = {}
d.newKey = 5
d['other'] = 6
]]

TEST [[
---@class Plain
---@field a number

---@type Plain
local p = {}
p.<!injected!> = 1
]]

TEST [[
---@class Numbered : table<integer, number>

---@type Numbered
local n = {}
n.<!foo!> = 1
]]

-- a narrowing cuts a union down to one member (`if not x.specs`: only the member without `specs` can be here), but another member of what
-- the variable can hold declares the field: the code is building that member, not injecting a stray field
TEST [[
---@class Info
---@field itemID number
---@field name string?

---@class Cache
---@field public items table<number, Info | { everyone: boolean, specs: table<number, number> }>
local cache = { items = {} } ---@class Cache

---@return Info?
local function getInfo(i) return nil end

local function fill(specID, classID)
    for i = 1, 3 do
        local itemInfo = getInfo(i)
        if itemInfo and itemInfo.itemID then
            local itemCache = cache.items[itemInfo.itemID]
            if not itemCache then
                itemCache = itemInfo
                cache.items[itemInfo.itemID] = itemCache
            end
            if not itemCache.specs then
                itemCache.specs = {}
            end
            itemCache.specs[specID] = classID
        end
    end
end
fill(1, 2)
]]

-- ... a field that no member declares is still an injection
TEST [[
---@class Info
---@field itemID number
---@field name string?

---@class Cache
---@field public items table<number, Info | { everyone: boolean, specs: table<number, number> }>
local cache = { items = {} } ---@class Cache

---@return Info?
local function getInfo(i) return nil end

local function fill()
    for i = 1, 3 do
        local itemInfo = getInfo(i)
        if itemInfo and itemInfo.itemID then
            local itemCache = cache.items[itemInfo.itemID]
            if not itemCache then
                itemCache = itemInfo
            end
            if not itemCache.specs then
                itemCache.<!other!> = {}
            end
        end
    end
end
fill()
]]

-- the bracket form with a string literal is the dotted form: a key the declared table type does not have
TEST [[
---@type table<'a'|'b', number>
local t = {}
t.a = 1
t['b'] = 2
t[<!'c'!>] = 3
]]

-- fine: a string key of a table that takes any string, a non-literal key
TEST [[
---@type table<string, number>
local t = {}
---@param s string
local function f(s)
    t['c'] = 1
    t[s] = 1
end
]]

-- the same with the bracket form: a member of the union declares the field, so `['specs'] = ...` is not a stray key either
TEST [[
---@class Info
---@field itemID number
---@field name string?

---@class Cache
---@field public items table<number, Info | { everyone: boolean, specs: table<number, number> }>
local cache = { items = {} } ---@class Cache

---@return Info?
local function getInfo(i) return nil end

local function fill()
    local itemInfo = getInfo(1)
    if itemInfo and itemInfo.itemID then
        local itemCache = cache.items[itemInfo.itemID]
        if not itemCache then
            itemCache = itemInfo
            cache.items[itemInfo.itemID] = itemCache
        end
        if not itemCache.specs then
            itemCache['specs'] = {}
        end
    end
end
fill()
]]

-- a type nothing declares has unknown fields: injecting one is not reported (the name is, by undefined-doc-name)
TEST [[
---@type GhostObject
local ghost = {}
ghost.field = 1
---@class FullClass
---@param full FullClass
local function inject(full)
    full.<!field!> = 1
end
]]
