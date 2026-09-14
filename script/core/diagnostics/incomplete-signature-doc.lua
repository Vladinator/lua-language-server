-- incomplete-signature-doc
local files           = require 'files'
local guide           = require "parser.guide"
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local PARAM_MESSAGE  = 'Incomplete signature. Missing @param annotation for parameter `%s`.'
local RETURN_MESSAGE = 'Incomplete signature. Missing @return annotation at index `%s`.'

protoDiagnostic.register {
    'incomplete-signature-doc',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'None',
}

---@param docs  parser.object[]?
---@param param string
---@return boolean
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

---@param docs  parser.object[]?
---@param index integer
---@return boolean
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

--- check if there's any signature doc (@param or @return), or just comments, @async, ...
---@param docs parser.object[]?
---@return boolean
local function findSignatureDoc(docs)
    if not docs then
        return false
    end
    for _, doc in ipairs(docs) do
        if doc.type == 'doc.return' or doc.type == 'doc.param' then
            return true
        end
    end
    return false
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    if not state.ast then
        return
    end

    ---@async
    guide.eachSourceType(state.ast, 'function', function (source)
        await.delay()

        if not source.bindDocs then
            return
        end

        --- don't apply rule if there is no @param or @return annotation yet
        --- so comments and @async can be applied without the need for a full documentation
        if(not findSignatureDoc(source.bindDocs)) then
            return
        end

        if source.args and #source.args > 0 then
            for _, arg in ipairs(source.args) do
                local argName = arg[1]
                if  argName ~= 'self'
                and argName ~= '_' then
                    if not findParam(source.bindDocs, argName) then
                        callback {
                            start   = arg.start,
                            finish  = arg.finish,
                            message = PARAM_MESSAGE:format(argName),
                        }
                    end
                end
            end
        end

        if  source.returns then
            for _, ret in ipairs(source.returns) do
                for index, expr in ipairs(ret) do
                    if not findReturn(source.bindDocs, index) then
                        callback {
                            start   = expr.start,
                            finish  = expr.finish,
                            message = RETURN_MESSAGE:format(index),
                        }
                    end
                end
            end
        end
    end)
end
