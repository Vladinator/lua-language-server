local files     = require 'files'
local guide     = require 'parser.guide'
local vm        = require 'vm'
local reference = require 'core.reference'
local find      = string.find
local remove    = table.remove

---@param ffi_state parser.state
---@return integer?
local function getCdefSourcePosition(ffi_state)
    if not ffi_state.ast.returns then
        return
    end
    local cdef_position = ffi_state.ast.returns[1][1]
    local source = vm.getFields(cdef_position)
    for _, value in ipairs(source) do
        local name = guide.getKeyName(value)
        if name == 'cdef' then
            return value.field.start
        end
    end
end

---@async
---@return core.reference.result[]?
return function ()
    ---@type parser.state?
    local ffi_state
    for uri in files.eachFile() do
        if find(uri, "ffi.lua", 0, true) and find(uri, "meta", 0, true) then
            ffi_state = files.getState(uri)
            break
        end
    end
    if ffi_state then
        local cdefPos = getCdefSourcePosition(ffi_state)
        if not cdefPos then
            return
        end
        local res = reference(ffi_state.uri, cdefPos, true)
        if res then
            if res[1].uri == ffi_state.uri then
                remove(res, 1)
            end
            return res
        end
    end
end
