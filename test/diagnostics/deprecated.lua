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
