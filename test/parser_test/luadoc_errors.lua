-- The syntax warnings of malformed LuaDoc comments: which error a truncated or broken annotation
-- reports (a regression here silently turns a helpful "missing type name" into nothing, or into a
-- different error). Each sample is the comment alone followed by one plain statement; `nil` means
-- the comment is well formed (a bare flag tag, or a form that needs nothing after it).
local files = require 'files'

---@type table<string, string[]>
local samples = {
    -- types
    ['---@type']                        = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@type |']                      = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@type fun(']                   = { 'LUADOC_MISS_ARG_NAME' },
    ['---@type fun(a b']                = { 'LUADOC_MISS_SYMBOL' },
    ['---@type fun(:number)']           = { 'LUADOC_MISS_ARG_NAME' },
    ['---@type {a: }']                  = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@type {a number}']             = { 'LUADOC_MISS_SYMBOL' },
    ['---@type A<']                     = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@type A<B']                    = { 'LUADOC_MISS_SYMBOL' },
    ['---@type A<B,>']                  = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@type (string']                = { 'LUADOC_MISS_SYMBOL' },
    ['---@type string[']                = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@type keyof']                  = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@type A &']                    = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@type (A extends B ? C)']      = { 'LUADOC_MISS_SYMBOL' },
    -- the tags that name something
    ['---@param']                      = { 'LUADOC_MISS_PARAM_NAME' },
    ['---@param x']                    = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@param 1']                    = { 'LUADOC_MISS_PARAM_NAME' },
    ['---@class']                      = { 'LUADOC_MISS_CLASS_NAME' },
    ['---@class A :']                  = { 'LUADOC_MISS_CLASS_EXTENDS_NAME' },
    ['---@class (']                    = { 'LUADOC_MISS_SYMBOL' },
    ['---@field']                      = { 'LUADOC_MISS_FIELD_NAME' },
    ['---@field x']                    = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@alias']                      = { 'LUADOC_MISS_ALIAS_NAME' },
    ['---@alias X']                    = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@generic']                    = { 'LUADOC_MISS_GENERIC_NAME' },
    ['---@generic T :']                = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@generic T,']                 = { 'LUADOC_MISS_GENERIC_NAME' },
    ['---@version']                    = { 'LUADOC_MISS_VERSION' },
    ['---@version >']                  = { 'LUADOC_MISS_VERSION' },
    ['---@diagnostic']                 = { 'LUADOC_MISS_DIAG_MODE' },
    ['---@diagnostic foo']             = { 'LUADOC_ERROR_DIAG_MODE' },
    ['---@diagnostic disable:']        = { 'LUADOC_MISS_DIAG_NAME' },
    ['---@see']                        = { 'LUADOC_MISS_SEE_NAME' },
    ['---@module']                     = { 'LUADOC_MISS_MODULE_NAME' },
    ['---@operator']                   = { 'LUADOC_MISS_OPERATOR_NAME' },
    ['---@operator add']               = { 'LUADOC_MISS_SYMBOL' },
    ['---@overload']                   = { 'LUADOC_MISS_FUN_AFTER_OVERLOAD' },
    ['---@vararg']                     = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@return']                     = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@return (']                   = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@return (A, B) |']            = { 'LUADOC_MISS_SYMBOL' },
    ['---@cast']                       = { 'LUADOC_MISS_LOCAL_NAME' },
    ['---@cast x']                     = { 'LUADOC_MISS_TYPE_NAME' },
    ['---@as']                         = { 'LUADOC_MISS_TYPE_NAME' },
    -- well formed: nothing to report
    ['---@version 5.x']                = {},
    ['---@enum']                       = {},
    ['---@source']                     = {},
    ['---@async']                      = {},
    ['---@nodiscard']                  = {},
    ['---@type string']                = {},
    ['---@param x Partial<T>']         = {},
    ['---@return (string, nil) | (nil, number)'] = {},
}

for text, expected in pairs(samples) do
    files.remove(TESTURI)
    files.setText(TESTURI, text .. '\nlocal x = 1\n')
    local state = assert(files.getState(TESTURI))
    ---@type string[]
    local got = {}
    for _, err in ipairs(state.errs) do
        got[#got+1] = err.type
    end
    assert(table.concat(got, ',') == table.concat(expected, ','),
        ('%s: expected [%s], got [%s]'):format(text, table.concat(expected, ','), table.concat(got, ',')))
end
files.remove(TESTURI)
