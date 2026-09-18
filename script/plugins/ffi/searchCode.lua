local vm = require 'vm'

---@param arg vm.object?
---@return string[]
local function getLiterals(arg)
    local literals = vm.getLiterals(arg)
    ---@type string[]
    local res = {}
    if not literals then
        return res
    end
    for k in pairs(literals) do
        if type(k) == 'string' then
            res[#res+1] = k
        end
    end
    return res
end

---@param CdefReference core.reference.result
---@return string[]?
local function getCode(CdefReference)
    local target = CdefReference.target --[[@as parser.object]]
    if not (target.type == 'field' and target.parent.type == 'getfield') then
        return
    end
    target = target.parent.parent --[[@as parser.object]]
    if target.type == 'call' then
        return getLiterals(target.args and target.args[1])
    elseif target.type == 'local' then
        ---@type string[]
        local res = {}
        for _, o in ipairs(target.ref) do
            if o.parent.type ~= 'call' then
                goto CONTINUE
            end
            local target = o.parent
            local literals = vm.getLiterals(target.args and target.args[1])
            if not literals then
                goto CONTINUE
            end
            for k in pairs(literals) do
                if type(k) == 'string' then
                    res[#res+1] = k
                end
            end
            ::CONTINUE::
        end
        return res
    end
end

---@async
---@param CdefReference core.reference.result[]?
---@param target_uri uri
---@return string[]?
return function (CdefReference, target_uri)
    if not CdefReference then
        return nil
    end
    ---@type string[]?
    local codeResults
    for _, v in ipairs(CdefReference) do
        if v.uri ~= target_uri then
            goto continue
        end
        local codes = getCode(v)
        if not codes then
            goto continue
        end
        for _, v0 in ipairs(codes) do
            codeResults = codeResults or {}
            codeResults[#codeResults+1] = v0
        end
        ::continue::
    end
    return codeResults
end
