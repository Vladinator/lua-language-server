---@class vm
local vm = require 'vm.vm'

---@alias vm.genesisRule fun(source: parser.object, node: vm.node)

---@type table<string, vm.genesisRule[]>
local rulesByType = {}

--- Register a rule that inspects a just-compiled `source` node (e.g. its
--- `bindDocs`) and may add flags to its compiled `node`. Runs once per
--- source, right after `vm.compileNode` finishes building it (so it sees
--- the same fully-built node every other consumer sees), keyed by
--- `source.type` so unrelated node types pay nothing for rules that don't
--- apply to them.
---@param sourceType string
---@param rule       vm.genesisRule
function vm.registerGenesisRule(sourceType, rule)
    rulesByType[sourceType] = rulesByType[sourceType] or {}
    table.insert(rulesByType[sourceType], rule)
end

---@param source parser.object
---@param node   vm.node
function vm.runGenesisRules(source, node)
    local rules = rulesByType[source.type]
    if not rules then
        return
    end
    for _, rule in ipairs(rules) do
        rule(source, node)
    end
end
