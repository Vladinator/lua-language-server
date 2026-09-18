local m = {}

---@param t any
---@param len integer
---@return boolean
local function tableLenEqual(t, len)
    for _, _ in pairs(t --[[@as table<any, any>]]) do
        len = (len - 1) --[[@as integer]]
        if len < 0 then
            return false
        end
    end
    return true
end

---@param ast any
local function isSingleNode(ast)
    if type(ast) ~= 'table' then
        return false
    end
    local len = #ast
    return len == 1 and tableLenEqual(ast, len)
end

---@param ast any
---@return any
function m.expandSingle(ast)
    if isSingleNode(ast) then
        return ast[1]
    end
    return ast
end

return m
