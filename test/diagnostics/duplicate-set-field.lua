TEST [[
local m = {}

function <!m:fff!>()
end

function <!m:fff!>()
end

return m
]]

TEST [[
local m = {}

function <!m:fff!>()
end

do
    function <!m:fff!>()
    end
end

return m
]]

TEST [[
local m = {}

m.x = true
m.x = false

return m
]]

TEST [[
local m = {}

m.x = io.open('')
m.x = nil

return m
]]

TEST [[
---@class A
X = {}

function <!X.f!>() end

function <!X.f!>() end
]]

TEST [[
---@meta

---@class A
X = {}

function X.f() end

function X.f() end
]]

TEST [[
---@class A
X = {}

if true then
    function X.f() end
else
    function X.f() end
end
]]

TEST [[
---@class A
X = {}

function X:f() end

---@type x
local x

function x:f() end
]]

TEST [[
---@class A
X = {}

function X:f() end

---@type x
local x

function <!x:f!>() end

function <!x:f!>() end
]]

-- a subclass built with a metatable link overrides the name of its parent: not the same field set twice
TEST [[
local Animal = {}
Animal.__index = Animal
function Animal.new() return setmetatable({}, Animal) end
function Animal:speak() return 'a' end

local Dog = setmetatable({}, { __index = Animal })
Dog.__index = Dog
function Dog.new() return setmetatable({}, Dog) end
function Dog:speak() return 'woof' end
]]

-- ... the same name set twice on the SAME table is still reported, parent or not
TEST [[
local Animal = {}
function Animal:speak() return 'a' end

local Dog = setmetatable({}, { __index = Animal })
function <!Dog:speak!>() return 'woof' end
function <!Dog:speak!>() return 'bark' end
]]
