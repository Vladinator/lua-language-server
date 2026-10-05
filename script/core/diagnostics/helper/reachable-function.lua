--- Is a function reachable from outside its file: a global function, a function stored in a global table, or in a local
--- table that leaves the file (returned from the main chunk, annotated `---@class`, assigned to a global or a field, or a local
--- a registered rule says is shared, see `registerExportedLocalRule`). Local functions and the functions of a file-private
--- table are not.
local guide = require 'parser.guide'

local m = {}

local exportedBase, exportedLocal, exportedTable

---@type (fun(loc: parser.object): boolean)[]
local exportedLocalRules = {}

--- A rule that says a local table is shared with other files although nothing in its own file shows it (a host that hands
--- every file the same table, for example): the functions of such a local are reachable. A plugin registers it.
---@param rule fun(loc: parser.object): boolean `loc` is a `local` declaration
function m.registerExportedLocalRule(rule)
    exportedLocalRules[#exportedLocalRules+1] = rule
end

---@param loc parser.object a `local` declaration
---@return boolean
function exportedLocal(loc)
    if loc.bindDocs then
        for _, doc in ipairs(loc.bindDocs) do
            if doc.type == 'doc.class' then
                return true
            end
        end
    end
    for _, rule in ipairs(exportedLocalRules) do
        if rule(loc) then
            return true
        end
    end
    for _, ref in ipairs(loc.ref or {}) do
        local parent = ref.parent
        if parent then
            if parent.type == 'return' then
                local func = guide.getParentFunction(parent)
                if func and func.type == 'main' then
                    return true
                end
            elseif (parent.type == 'setglobal' or parent.type == 'setfield' or parent.type == 'setindex')
            and parent.value == ref then
                return true
            end
        end
    end
    return false
end

---@param node parser.object? the left side of a field write, `M` in `M.f = function` / `function M:m()`
---@return boolean
function exportedBase(node)
    if not node then
        return false
    end
    local t = node.type
    if t == 'getglobal' then
        return true
    end
    if t == 'getlocal' then
        return node.node ~= nil and exportedLocal(node.node)
    end
    if t == 'getfield' or t == 'getindex' or t == 'getmethod' then
        return exportedBase(node.node)
    end
    return false
end

---@param tbl parser.object a table constructor
---@return boolean
function exportedTable(tbl)
    local parent = tbl.parent
    if not parent then
        return false
    end
    local t = parent.type
    if t == 'local' then
        return exportedLocal(parent)
    end
    if t == 'setglobal' then
        return true
    end
    if t == 'setfield' or t == 'setindex' or t == 'setmethod' then
        return exportedBase(parent.node)
    end
    if t == 'return' then
        local func = guide.getParentFunction(parent)
        return func ~= nil and func.type == 'main'
    end
    return false
end

---@param func parser.object a `function`
---@return boolean
function m.isReachable(func)
    local parent = func.parent
    if not parent then
        return false
    end
    local t = parent.type
    if t == 'setglobal' then
        return true
    end
    if t == 'setfield' or t == 'setmethod' or t == 'setindex' then
        return exportedBase(parent.node)
    end
    if t == 'tablefield' or t == 'tableindex' then
        local tbl = parent.parent
        return tbl ~= nil and tbl.type == 'table' and exportedTable(tbl)
    end
    return false
end

return m
