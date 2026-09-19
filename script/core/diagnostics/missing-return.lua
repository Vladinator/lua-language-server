local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Annotations specify that a return value is required here.'

protoDiagnostic.register {
    'missing-return',
} {
    group    = 'unbalanced',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for functions with return annotations which have no return statement.',
}

---@param block parser.object
---@return boolean
local function hasReturn(block)
    if block.hasReturn or block.hasExit then
        return true
    end
    if block.type == 'if' then
        ---@type boolean?
        local hasElse
        for _, subBlock in ipairs(block) do
            if not hasReturn(subBlock) then
                return false
            end
            if subBlock.type == 'elseblock' then
                hasElse = true
            end
        end
        return hasElse == true
    else
        if block.type == 'while' then
            if vm.testCondition(block.filter) then
                return true
            end
        end
        for _, action in ipairs(block) do
            if guide.isBlockType(action) then
                if hasReturn(action) then
                    return true
                end
            end
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

    local isMeta = vm.isMetaFile(uri)

    ---@async
    guide.eachSourceType(state.ast, 'function', function (source)
        -- check declare only
        if isMeta and vm.isEmptyFunction(source) then
            return
        end
        await.delay()
        if vm.countReturnsOfSource(source) == 0 then
            return
        end
        if hasReturn(source) then
            return
        end
        local lastAction = source[#source]
        ---@type integer
        local pos
        if lastAction then
            pos = lastAction.range or lastAction.finish
        else
            pos = source.keyword[3] or source.finish
        end
        callback {
            start   = pos,
            finish  = pos,
            message = MESSAGE,
        }
    end)
end
