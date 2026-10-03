local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local util            = require 'utility'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Annotations specify that return value #%s has a type of `%s`, returning value of type `%s` here instead.'
local CASES_MESSAGE = 'The returned values match none of the cases declared by the return annotation: %s.'

protoDiagnostic.register {
    'return-type-mismatch',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for return values whose type does not match the type declared in the corresponding return annotation.',
}

---@param func parser.object
---@return vm.node[]?
local function getDocReturns(func)
    ---@type table<integer, vm.node>
    local returns = util.defaultTable(function ()
        return vm.createNode()
    end)
    if func.bindDocs then
        for _, doc in ipairs(func.bindDocs) do
            if doc.type == 'doc.return' then
                for _, ret in ipairs(doc.returns) do
                    returns[ret.returnIndex]:merge(vm.compileNode(ret))
                end
            end
            if doc.type == 'doc.overload' then
                for i, ret in ipairs(doc.overload.returns) do
                    returns[i]:merge(vm.compileNode(ret))
                end
            end
        end
    end
    for nd in vm.compileNode(func):eachObject() do
        if nd.type == 'doc.type.function' then
            for i, ret in ipairs(nd.returns) do
                returns[i]:merge(vm.compileNode(ret))
            end
        end
    end
    setmetatable(returns, nil)
    if #returns == 0 then
        return nil
    end
    return returns
end
--- The cases of a tuple-union `---@return (A, B) | (C, D)` on `func`, if it has one.
---@param func parser.object
---@return parser.object[][]?
local function getDocCases(func)
    if not func.bindDocs then
        return nil
    end
    for _, doc in ipairs(func.bindDocs) do
        if doc.type == 'doc.return' and doc.cases then
            return doc.cases
        end
    end
    return nil
end

--- Serves two diagnostics: `return-type-mismatch` (each returned value against its slot) and
--- `grouped-return-mismatch` (grouped-return-mismatch.lua: the values together against the cases of a
--- tuple-union `---@return (A, B) | (C, D)`, once every value fits its own slot). `name` says which one runs.
---@async
return function (uri, callback, name)
    local state = files.getState(uri)
    if not state then
        return
    end
    local grouped = name == 'grouped-return-mismatch'
    ---@param result proto.diagnostic.result
    local function report(result)
        if not grouped then
            callback(result)
        end
    end

    --- Does `value` fit one slot of a case? `vm.canCastType` accepts anything for a `nil` target (so that
    --- `x = nil` works), but a case's `nil` slot is a real contract: only a nil value fits it.
    ---@param slot parser.object
    ---@param value vm.node
    ---@return boolean
    local function fitsSlot(slot, value)
        local slotNode = vm.compileNode(slot)
        -- (a `nil` slot compiles to an empty node that views as `unknown`: read it off the annotation)
        local member = slot.types and #slot.types == 1 and slot.types[1]
        if member and member.type == 'doc.type.name' and member[1] == 'nil' then
            local valueInfer = vm.getInfer(value)
            local view = valueInfer:viewIfUnknownOrNil(uri)
            return valueInfer:hasAny(uri) or view == 'unknown' or view == 'nil'
        end
        return vm.canCastType(uri, slotNode, value)
    end

    ---@param cases parser.object[][]
    ---@param rets parser.object
    local function checkCases(cases, rets)
        ---@type vm.node[]
        local retNodes = {}
        local width = #cases[1]
        for i = 1, width do
            local retNode, exp = vm.selectNode(rets, i)
            if not exp then
                return -- fewer values than slots: what is missing is not judged here
            end
            retNodes[i] = retNode
        end
        for _, case in ipairs(cases) do
            local fits = true
            for i = 1, width do
                if not fitsSlot(case[i], retNodes[i]) then
                    fits = false
                    break
                end
            end
            if fits then
                return
            end
        end
        ---@type string[]
        local views = {}
        for k, case in ipairs(cases) do
            ---@type string[]
            local slots = {}
            for i = 1, width do
                slots[i] = vm.getInfer(vm.compileNode(case[i])):view(uri)
            end
            views[k] = '(' .. table.concat(slots, ', ') .. ')'
        end
        callback {
            start   = rets.start,
            finish  = rets.finish,
            message = CASES_MESSAGE:format(table.concat(views, ' | ')),
        }
    end

    ---@param docReturns vm.node[]
    ---@param rets parser.object
    ---@return boolean
    local function checkReturn(docReturns, rets)
        local ok = true
        for i, docRet in ipairs(docReturns) do
            local retNode, exp = vm.selectNode(rets, i)
            if not exp then
                break
            end
            if retNode:hasName 'nil' then
                if exp.type == 'getfield'
                or exp.type == 'getindex' then
                    retNode = retNode:copy():removeOptional()
                end
            end
            local errs = {}
            if not vm.canCastType(uri, docRet, retNode, errs) then
                report {
                    start   = exp.start,
                    finish  = exp.finish,
                    message = MESSAGE:format(
                        i,
                        vm.getInfer(docRet):view(uri),
                        vm.getInfer(retNode):view(uri)
                    ) .. '\n' .. vm.viewTypeErrorMessage(uri, errs),
                }
                ok = false
            end
        end
        return ok
    end

    ---@async
    guide.eachSourceType(state.ast, 'function', function (source)
        if not source.returns then
            return
        end
        await.delay()
        local docReturns = getDocReturns(source)
        if not docReturns then
            return
        end
        local cases = getDocCases(source)
        if grouped and not cases then
            return
        end
        for _, ret in ipairs(source.returns) do
            -- the combination is only judged once every value fits its own slot
            if checkReturn(docReturns, ret) and grouped and cases then
                checkCases(cases, ret)
            end
            await.delay()
        end
    end)
end
