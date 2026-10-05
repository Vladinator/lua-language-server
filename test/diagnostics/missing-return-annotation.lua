-- A function that other files can reach (a global, a function of a global table, of an exported table) whose body returns a value
-- but has no `---@return` is reported on its `function` keyword. Local functions, file-private tables, documented returns, typed
-- functions and functions that return nothing are not (wowlua-ls's `missing-return-annotation`, a hint that is off by default).

-- global functions
TEST [[
<!function!> Global() return 1 end

---@return number
function Documented() return 1 end

function Nothing() return end
function NoReturn() end
]]

-- functions of a global table and of an exported table
TEST [[
Shared = {}
<!function!> Shared.run() return 'x' end
<!function!> Shared:method() return true end

---@class Exported
local Exported = {}
<!function!> Exported.make() return {} end

local Returned = {}
<!function!> Returned.run() return 1 end
return Returned
]]

-- the addon's shared namespace
TEST [[
local addonName, ns = ...
<!function!> ns.Run() return 1 end
]]

-- not reachable
TEST [[
local function private() return 1 end
local Private = {}
function Private.run() return 2 end
table.sort({}, function(a, b) return a < b end)
]]

-- the return of a nested function is not the return of the outer one
TEST [[
function Outer()
    local inner = function() return 1 end
    inner()
end

<!function!> OuterReturns()
    local inner = function() return 1 end
    return inner()
end
]]

-- a function typed as a whole
TEST [[
---@type fun(): number
function Typed() return 1 end
]]

-- a return in a branch counts
TEST [[
<!function!> Branch(x)
    if x then
        return 1
    end
end
]]
