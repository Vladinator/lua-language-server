local guide = require 'parser.guide'
local furi  = require 'file-uri'
local ws    = require 'workspace'

---@param doc parser.object
---@return uri
local function parseUri(doc)
    local uri
    local scheme = furi.split(doc.path)
    if scheme and #scheme >= 2 then
        uri = doc.path
    else
        local suri = guide.getUri(doc):gsub('[/\\][^/\\]*$', '')
        local path = ws.getAbsolutePath(suri, doc.path)
        if path then
            uri = furi.encode(path)
        else
            uri = doc.path
        end
    end
    ---@cast uri uri
    return uri
end

---@class jump-source.result
---@field uri? uri
---@field target parser.object|{uri: uri, start: integer, finish: integer}

---@param results jump-source.result[]
return function (results)
    for _, result in ipairs(results) do
        if result.target.type == 'doc.field.name'
        or result.target.type == 'doc.class.name' then
            local doc = result.target.parent.source
            if doc then
                local uri = parseUri(doc)
                -- always set together on a 'doc.source' node (see parser/luadoc.lua)
                local line = doc.line --[[@as integer]]
                local char = doc.char --[[@as integer]]
                result.uri    = uri
                result.target = {
                    uri    = uri,
                    start  = guide.positionOf(line - 1, char),
                    finish = guide.positionOf(line - 1, char),
                }
            end
        else
            local target = result.target
            if target.type == 'method'
            or target.type == 'field' then
                target = target.parent
            end
            if target.bindDocs then
                for _, doc in ipairs(target.bindDocs) do
                    if  doc.type == 'doc.source'
                    and doc.bindSource == target then
                        local uri = parseUri(doc)
                        -- always set together on a 'doc.source' node (see parser/luadoc.lua)
                        local line = doc.line --[[@as integer]]
                        local char = doc.char --[[@as integer]]
                        result.uri    = uri
                        result.target = {
                            uri    = uri,
                            start  = guide.positionOf(line - 1, char),
                            finish = guide.positionOf(line - 1, char),
                        }
                    end
                end
            end
        end
    end
end
