---@class vm
local vm = require 'vm.vm'

---@alias vm.genesisRule fun(source: parser.object, node: vm.node)

---@type table<string, vm.genesisRule[]>
local rulesByType = {}
---@type table<string, vm.genesisRule[]>
local lateRulesByType = {}

--- Register a rule that inspects a just-compiled `source` node (e.g. its
--- `bindDocs`) and may add flags to its compiled `node`. Runs once per
--- source, right after `vm.compileNode` finishes building it (so it sees
--- the same fully-built node every other consumer sees), keyed by
--- `source.type` so unrelated node types pay nothing for rules that don't
--- apply to them.
--- A `late` rule runs after every ordinary rule of the type, whatever the order the rules were registered in (which is the order the
--- plugin files were loaded in): for a rule that undoes what another one may have added (a context that makes a result ordinary again).
---@param sourceType string
---@param rule       vm.genesisRule
---@param late?      boolean
function vm.registerGenesisRule(sourceType, rule, late)
    local registry = late and lateRulesByType or rulesByType
    registry[sourceType] = registry[sourceType] or {}
    table.insert(registry[sourceType], rule)
end

---@param source parser.object
---@param node   vm.node
function vm.runGenesisRules(source, node)
    local rules = rulesByType[source.type]
    if rules then
        for _, rule in ipairs(rules) do
            rule(source, node)
        end
    end
    local late = lateRulesByType[source.type]
    if late then
        for _, rule in ipairs(late) do
            rule(source, node)
        end
    end
end
