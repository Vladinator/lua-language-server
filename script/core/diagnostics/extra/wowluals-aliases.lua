-- The names wowlua-ls gives to diagnostics this server has under their original LuaLS name: accepted in
-- `---@diagnostic`, `diagnostics.disable`, `severity` and `neededFileStatus` (the original names stay canonical).
-- A feature plugin: it registers no diagnostic of its own. The alias mechanism is generic
-- (proto/diagnostic.lua); only the names are wowlua-ls's, so they live here. Deleting this file removes them.
-- Its tests are next to it.

local protoDiagnostic = require 'proto.diagnostic'

for alias, canonical in pairs {
    ['type-mismatch']       = 'param-type-mismatch',
    ['return-mismatch']     = 'return-type-mismatch',
    -- one code here for what wowlua-ls splits into private and protected
    ['access-private']      = 'invisible',
    ['access-protected']    = 'invisible',
    -- and for its four "unknown type" codes
    ['unknown-param-type']  = 'no-unknown',
    ['unknown-return-type'] = 'no-unknown',
    ['unknown-local-type']  = 'no-unknown',
    ['unknown-field-type']  = 'no-unknown',
    -- wowlua-ls splits redefined-local (same scope) and shadowed-local (outer scope); here one diagnostic covers
    -- both, so disabling its `shadowed-local` silences both
    ['shadowed-local']      = 'redefined-local',
} do
    protoDiagnostic.registerAlias(alias, canonical)
end
