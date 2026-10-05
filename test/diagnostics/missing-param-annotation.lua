-- A function that other files can reach (a global, a function of a global table, of an exported table) with a parameter that has
-- no `---@param` is reported on the parameter. Local functions, file-private tables, annotated parameters, `self` and `_` are
-- not (wowlua-ls's `missing-param-annotation`, a hint that is off by default).

-- global functions
TEST [[
function Global(<!a!>, <!b!>) end

---@param a number
function Partial(a, <!b!>) end

---@param a number
---@param b number
function Complete(a, b) end
]]

-- functions of a global table, methods included (`self` and `_` are never reported)
TEST [[
Shared = {}
function Shared.run(<!x!>) end
function Shared:method(<!y!>, _) end
Shared.field = function(<!z!>) end
Shared.nested = { handler = function(<!w!>) end }
]]

-- a local table that leaves the file: returned, annotated as a class, stored in a global or a field
TEST [[
local Returned = {}
function Returned.run(<!x!>) end

---@class Exported
local Exported = {}
function Exported:method(<!y!>) end

local Stored = {}
function Stored.run(<!z!>) end
Holder = Stored

local Constructed = { run = function(<!w!>) end }
return Returned, Constructed
]]

-- the addon's shared namespace taken from `...` is shared by every file
TEST [[
local addonName, ns = ...
function ns.Run(<!a!>) end
local ns2 = select(2, ...)
function ns2.Other(<!b!>) end
]]

-- not reachable: local functions, private tables, callbacks
TEST [[
local function private(a, b) end
local alsoPrivate = function(c) end

local Private = {}
function Private.run(d) end
function Private:method(e) end
Private.field = function(f) end

table.sort({}, function(g, h) return g < h end)
local handler = { onEvent = function(i) end }
]]

-- a function typed as a whole documents its parameters in that type
TEST [[
---@type fun(a: number)
function Typed(a) end

---@overload fun(a: string)
function Overloaded(a) end
]]

-- variadic parameters and no parameters
TEST [[
function NoParams() end

---@param ... number
function Varargs(...) end

function VarargsMissing(<!...!>) end
]]
