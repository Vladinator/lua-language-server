-- the diagnostic occurs: the expectation is fulfilled, nothing is reported
TEST [[
---@type string?
local x

---@diagnostic expect-next-line: need-check-nil
local s = x:upper()
]]

-- nothing to suppress: the stale expectation is reported on the code name
TEST [[
---@diagnostic expect-next-line: <!need-check-nil!>
local s = 1
]]

-- one of two codes is fulfilled, the other is stale
TEST [[
---@type string?
local x

---@diagnostic expect-next-line: need-check-nil, <!undefined-field!>
local s = x:upper()
]]

-- expect-line applies to its own line
TEST [[
---@type string?
local x

local s = x:upper() ---@diagnostic expect-line: need-check-nil
local t = 1 ---@diagnostic expect-line: <!need-check-nil!>
]]

-- other lines are not covered (their own diagnostic is not our business here)
TEST [[
---@type string?
local x

---@diagnostic expect-next-line: need-check-nil
local s = x:upper()
local t = x:upper()
]]

-- a name that is not a registered diagnostic can never fire: not reported, not a crash
TEST [[
---@diagnostic expect-next-line: no-such-diagnostic
local s = 1
]]
