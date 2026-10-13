local files      = require 'files'
local findSource = require 'core.find-source'

---@class core.linked-editing.range
---@field start  integer
---@field finish integer

local accept = {
    ['local']    = true,
    ['getlocal'] = true,
    ['setlocal'] = true,
}

--- The ranges that are edited together when the name at the cursor is typed over: every use of a local variable (parameter,
--- loop variable, local function) in its file, and the `---@param` line of a parameter. Fields, globals and anything defined in
--- another file are left to rename (their uses live in other files, where an edit made while typing would not follow).
---@param uri      uri
---@param position integer
---@return core.linked-editing.range[]?
return function (uri, position)
    local state = files.getState(uri)
    if not state then
        return nil
    end
    local source = findSource(state, position, accept)
    if not source then
        return nil
    end
    ---@type parser.object?
    local var = source
    if source.type == 'getlocal' or source.type == 'setlocal' then
        var = source.node
    end
    if not var or var.type ~= 'local' or var[1] == 'self' or var[1] == '_ENV' then
        return nil
    end
    ---@type core.linked-editing.range[]
    local ranges = {}
    ---@param src parser.object
    local function add(src)
        ranges[#ranges+1] = { start = src.start, finish = src.finish }
    end
    add(var)
    for _, ref in ipairs(var.ref or {}) do
        add(ref)
    end
    if var.parent and var.parent.type == 'funcargs' then
        for _, doc in ipairs(var.bindDocs or {}) do
            if doc.type == 'doc.param' and doc.param and doc.param[1] == var[1] then
                add(doc.param)
            end
        end
    end
    table.sort(ranges, function (a, b)
        return a.start < b.start
    end)
    return ranges
end
