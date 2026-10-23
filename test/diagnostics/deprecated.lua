TEST [[
local _ = <!unpack!>
]]

TEST [[
T = {}
---@deprecated # comment
T.x = 1

print(<!T.x!>)
]]

TEST [[
T = {}

---@deprecated
function T:ff()
end

<!T:ff!>()
]]

-- a deprecated LOCAL function or variable is reported where it is used
TEST [[
---@deprecated use newer
local function older() end
local function newer() end
<!older!>()
newer()
local alias = <!older!>

---@deprecated
local oldValue = 1
print(<!oldValue!>)
]]

-- ... another local of the same name is another thing; a local without the mark is fine
TEST [[
---@deprecated
local function older() end
do
    local older = function() end
    older()
end
local plain = 1
print(plain)
]]

-- a deprecated CLASS is reported where an annotation names it, not at its own declaration or for another class
TEST [[
---@deprecated use NewClass
---@class OldClass
local OldClass = {}

---@class NewClass
local NewClass = {}

---@type <!OldClass!>
local a
---@param p <!OldClass!>
---@return <!OldClass!>|nil
local function f(p) end
---@type NewClass
local b
---@type OldClassX
local c
print(a, b, c, f)
]]
