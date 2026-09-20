---@class vm
local vm        = require 'vm.vm'
local util      = require 'utility'
local guide     = require 'parser.guide'

local searchByNodeSwitch = util.switch()
    : case 'global'
    ---@param suri uri
    ---@param globalVar vm.global
    ---@param pushResult fun(res: parser.object)
    : call(function (suri, globalVar, pushResult)
        for _, set in ipairs(globalVar:getSets(suri)) do
            pushResult(set)
        end
    end)
    : default(function (_suri, source, pushResult)
        pushResult(source)
    end)

---@param source parser.object
---@param pushResult fun(src: parser.object)
local function searchByLocalID(source, pushResult)
    local fields = vm.getVariableFields(source, true)
    if fields then
        for _, field in ipairs(fields) do
            pushResult(field)
        end
    end
end

---@param source parser.object
---@param pushResult fun(src: parser.object)
---@param mark? table<parser.object, boolean>
local function searchByNode(source, pushResult, mark)
    mark = mark or {}
    if mark[source] then
        return
    end
    mark[source] = true
    local uri = guide.getUri(source)
    vm.compileByParentNode(source, vm.ANY, function (field)
        searchByNodeSwitch(field.type, uri, field, pushResult)
    end)
    vm.compileByNodeChain(source, function (src)
        searchByNode(src, pushResult, mark)
    end)
end

---@param source parser.object
---@return       parser.object[]
function vm.getFields(source)
    ---@type parser.object[]
    local results = {}
    ---@type table<parser.object, boolean>
    local mark    = {}

    ---@param src parser.object
    local function pushResult(src)
        if not mark[src] then
            mark[src] = true
            results[#results+1] = src
        end
    end

    searchByLocalID(source, pushResult)
    searchByNode(source, pushResult)

    return results
end
