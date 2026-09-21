---@class vm
local vm = require 'vm.vm'

---@class vm.callNarrowRule
---@field match  fun(calleeNode: parser.object): boolean
---@field statement? boolean the rule also narrows what follows a call used as a statement (an assertion): the tracer then cannot skip the walk of a variable that is only passed to such calls. `match` of such a rule is asked while the tracer is built, so it must decide by name and compile nothing
---@field narrow fun(tracer: vm.tracer, action: parser.object, topNode: vm.node, outNode?: vm.node): vm.node, vm.node?

---@type vm.callNarrowRule[]
local callNarrowRules = {}

--- Register a rule that can narrow a call's arguments while the tracer
--- walks an `if`/`while`/`and`/`or` condition. Rules run in registration
--- order; each one's result feeds into the next.
---@param rule vm.callNarrowRule
function vm.registerCallNarrowing(rule)
    callNarrowRules[#callNarrowRules+1] = rule
end

--- Whether a rule that narrows after a call used as a statement (`statement`) matches this callee:
--- what the tracer needs to know before it may skip the walk of a variable that is only passed to calls.
---@param calleeNode parser.object
---@return boolean
function vm.matchCallNarrowing(calleeNode)
    for _, rule in ipairs(callNarrowRules) do
        if rule.statement and rule.match(calleeNode) then
            return true
        end
    end
    return false
end

---@param tracer   vm.tracer
---@param action   parser.object
---@param topNode  vm.node
---@param outNode? vm.node
---@return vm.node topNode
---@return vm.node? outNode
function vm.runCallNarrowing(tracer, action, topNode, outNode)
    for _, rule in ipairs(callNarrowRules) do
        if rule.match(action.node) then
            topNode, outNode = rule.narrow(tracer, action, topNode, outNode)
        end
    end
    return topNode, outNode
end

---@class vm.equalityNarrowRule
---@field match  fun(tracer: vm.tracer, handler: parser.object, checker: parser.object): boolean
---@field narrow fun(tracer: vm.tracer, action: parser.object, topNode: vm.node, outNode: vm.node?, handler: parser.object, checker: parser.object): vm.node, vm.node?

---@type vm.equalityNarrowRule[]
local equalityNarrowRules = {}

--- Register a rule that narrows `handler op checker` (an `==`/`~=` against
--- a literal, already split into the traced side and the literal side).
--- Rules are tried in registration order; the first whose `match` returns
--- true handles the comparison and no further rule runs — mirrors the
--- if/elseif chain this replaces, since the original patterns are meant to
--- be mutually exclusive.
---@param rule vm.equalityNarrowRule
function vm.registerEqualityNarrowing(rule)
    equalityNarrowRules[#equalityNarrowRules+1] = rule
end

---@param tracer   vm.tracer
---@param action   parser.object
---@param topNode  vm.node
---@param outNode? vm.node
---@param handler  parser.object
---@param checker  parser.object
---@return vm.node topNode
---@return vm.node? outNode
function vm.runEqualityNarrowing(tracer, action, topNode, outNode, handler, checker)
    for _, rule in ipairs(equalityNarrowRules) do
        if rule.match(tracer, handler, checker) then
            return rule.narrow(tracer, action, topNode, outNode, handler, checker)
        end
    end
    return topNode, outNode
end
