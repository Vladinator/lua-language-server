TEST [[
---@diagnostic disable-next-line: <!xxx!>
]]

-- wowlua-ls spellings of our codes are known names, no unknown-diag-code
TEST [[
---@diagnostic disable-next-line: type-mismatch, return-mismatch, access-private, access-protected
---@diagnostic disable-next-line: unknown-param-type, unknown-return-type, unknown-local-type, unknown-field-type
]]

-- a near miss of an alias is still unknown
TEST [[
---@diagnostic disable-next-line: <!type-mismatches!>
]]
