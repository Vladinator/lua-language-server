---@class vm
local vm        = require 'vm.vm'
local util      = require 'utility'
local guide     = require 'parser.guide'

local simpleSwitch

simpleSwitch = util.switch()
    : case 'goto'
    : call(function (source, pushResult)
        if source.node then
            pushResult(source.node)
        end
    end)
    : case 'doc.cast.name'
    : call(function (source, pushResult)
        local loc = guide.getLocal(source, source[1], source.start)
        if loc then
            pushResult(loc)
        end
    end)
    : case 'doc.field'
    : call(function (source, pushResult)
        pushResult(source)
    end)

---@param source  parser.object
---@param pushResult fun(src: parser.object)
local function searchBySimple(source, pushResult)
    simpleSwitch(source.type, source, pushResult)
end

---@param source  parser.object
---@param pushResult fun(src: parser.object)
local function searchByLocalID(source, pushResult)
    local idSources = vm.getVariableSets(source)
    if not idSources then
        return
    end
    for _, src in ipairs(idSources) do
        pushResult(src)
    end
end

--- A node holds more than sources: also `vm.variable`s and `vm.generic`s. Neither is an assignment or a literal, so neither was ever a result
--- (measured on a real project: every `variable` that reached `getDefs` was dropped by the `isAssign` / `isLiteral` test, none was returned).
---@guard obj is parser.object
---@param obj vm.object|vm.variable
---@return boolean
local function isSource(obj)
    return obj.type ~= nil and obj.type ~= 'variable'
end

---@param source     parser.object
---@param pushResult fun(src: vm.object|vm.variable)
local function searchByNode(source, pushResult)
    local node = vm.compileNode(source)
    local suri = guide.getUri(source)
    for n in node:eachObject() do
        if n.type == 'global' then
            for _, set in ipairs(n:getSets(suri)) do
                pushResult(set)
            end
        else
            pushResult(n)
        end
    end
end

---@param source parser.object
---@return       parser.object[]
function vm.getDefs(source)
    ---@type parser.object[]
    local results = {}
    ---@type table<parser.object, boolean>
    local mark    = {}

    ---@type boolean?
    local hasLocal
    ---@param src vm.object|vm.variable
    local function pushResult(src)
        if not isSource(src) then
            return
        end
        -- (a field of `Pick<T, K>` / `A & B` stands for the field of `T` / `A` it was made from)
        while src.utilityOrigin do
            src = src.utilityOrigin
        end
        if src.type == 'local' then
            if hasLocal then
                return
            end
            hasLocal = true
            if  source.type ~= 'local'
            and source.type ~= 'getlocal'
            and source.type ~= 'setlocal'
            and source.type ~= 'doc.cast.name' then
                return
            end
        end
        if not mark[src] then
            mark[src] = true
            if guide.isAssign(src)
            or guide.isLiteral(src) then
                results[#results+1] = src
            end
        end
    end

    searchBySimple(source, pushResult)
    searchByLocalID(source, pushResult)
    vm.compileByNodeChain(source, pushResult)
    searchByNode(source, pushResult)

    return results
end

local HAS_DEF_ERR = false  -- the error object for comparing
---@param checkFunc  fun(source: parser.object, pushResult: fun(src: vm.object|vm.variable))
---@param source     parser.object
---@param pushResult fun(src: vm.object|vm.variable)
---@return boolean
local function checkHasDef(checkFunc, source, pushResult)
    local _, err = pcall(checkFunc, source, pushResult)
    return err == HAS_DEF_ERR
end

---@param source parser.object
---@return boolean
function vm.hasDef(source)
    ---@type table<parser.object, boolean>
    local mark = {}
    ---@type boolean?
    local hasLocal
    ---@param src vm.object|vm.variable
    local function pushResult(src)
        if not isSource(src) then
            return
        end
        -- (a field of `Pick<T, K>` / `A & B` stands for the field of `T` / `A` it was made from)
        while src.utilityOrigin do
            src = src.utilityOrigin
        end
        if src.type == 'local' then
            if hasLocal then
                return
            end
            hasLocal = true
            if  source.type ~= 'local'
            and source.type ~= 'getlocal'
            and source.type ~= 'setlocal'
            and source.type ~= 'doc.cast.name' then
                return
            end
        end
        if not mark[src] then
            mark[src] = true
            if guide.isAssign(src)
            or guide.isLiteral(src) then
                -- break out on 1st result using error() with a unique error object
                error(HAS_DEF_ERR)
            end
        end
    end

    return checkHasDef(searchBySimple, source, pushResult)
        or checkHasDef(searchByLocalID, source, pushResult)
        or checkHasDef(vm.compileByNodeChain, source, pushResult)
        or checkHasDef(searchByNode, source, pushResult)
end
