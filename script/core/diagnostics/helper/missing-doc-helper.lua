local m = {}

---@param docs parser.object[]?
---@param param string|integer
local function findParam(docs, param)
    if not docs then
        return false
    end

    for _, doc in ipairs(docs) do
        if doc.type == 'doc.param' then
            if doc.param[1] == param then
                return true
            end
        end
    end

    return false
end

---@param docs parser.object[]?
---@param index integer
local function findReturn(docs, index)
    if not docs then
        return false
    end

    for _, doc in ipairs(docs) do
        if doc.type == 'doc.return' then
            for _, ret in ipairs(doc.returns) do
                if ret.returnIndex == index then
                    return true
                end
            end
        end
    end

    return false
end

-- commentMessage/paramMessage/returnMessage are Lua string:format templates:
--   commentMessage: format(functionName)
--   paramMessage:   format(argName, functionName)
--   returnMessage:  format(index, functionName)
---@param source parser.object
---@param callback fun(result: { start: integer, finish: integer, message: string })
---@param commentMessage string
---@param paramMessage string
---@param returnMessage string
local function checkFunction(source, callback, commentMessage, paramMessage, returnMessage)
    local functionName = source.parent[1]
    local argCount = source.args and #source.args or 0

    if argCount == 0 and not source.returns and not source.bindDocs then
        callback {
            start   = source.start,
            finish  = source.finish,
            message = commentMessage:format(functionName),
        }
    end

    if argCount > 0 then
        for _, arg in ipairs(source.args) do
            local argName = arg[1]
            if  argName ~= 'self'
            and argName ~= '_' then
                if not findParam(source.bindDocs, argName) then
                    callback {
                        start   = arg.start,
                        finish  = arg.finish,
                        message = paramMessage:format(argName, functionName),
                    }
                end
            end
        end
    end

    if source.returns then
        for _, ret in ipairs(source.returns) do
            for index, expr in ipairs(ret) do
                if not findReturn(source.bindDocs, index) then
                    callback {
                        start   = expr.start,
                        finish  = expr.finish,
                        message = returnMessage:format(index, functionName),
                    }
                end
            end
        end
    end
end

m.CheckFunction = checkFunction
return m
