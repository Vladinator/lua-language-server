---@class vm
local vm = require 'vm.vm'

--- Generic, plugin-registrable vm.node boolean flags (see vm.node:setFlag/
--- hasFlag/clearFlag in vm/node.lua). vm.node:merge() already carries every
--- flag through automatically, but a few compilation paths rebuild or
--- resolve a node without going through merge() -- pruning a multi-return
--- into a fresh node, resolving a self-generic clone, etc. -- so those
--- spots need to know which flags exist at all in order to copy them
--- across by hand. Registering a flag name here is how a plugin opts in,
--- without those core paths ever naming the flag themselves.
---@type table<string, true>
local propagatingFlags = {}

---@param name string
function vm.registerPropagatingFlag(name)
    propagatingFlags[name] = true
end

--- Copy every registered flag that `from` has onto `to`.
---@param from vm.node
---@param to   vm.node
function vm.propagateFlags(from, to)
    for name in pairs(propagatingFlags) do
        if from:hasFlag(name) then
            to:setFlag(name)
        end
    end
end

--- Does `node` carry any registered propagating flag at all? Lets a
--- caller skip narrowing machinery entirely for a node with nothing a
--- guard could possibly clear (e.g. vm/compiler.lua only traces a field
--- access when there's a falsy type or a flag like 'secret' actually on
--- it -- most fields are neither, so this keeps that common case cheap
--- and avoids kicking off a field tracer where nothing could change).
---@param node vm.node
---@return boolean
function vm.hasAnyPropagatingFlag(node)
    for name in pairs(propagatingFlags) do
        if node:hasFlag(name) then
            return true
        end
    end
    return false
end

--- Apply every true entry of a raw `{[name] = boolean}` table (e.g. one
--- saved on a not-yet-resolved vm.generic placeholder) onto a node.
---@param flags table<string, boolean>?
---@param to    vm.node
function vm.applyFlagsTable(flags, to)
    if not flags then
        return
    end
    for name, value in pairs(flags) do
        if value then
            to:setFlag(name)
        end
    end
end

--- Deriving the same flags directly from a raw parser.object (typically a
--- function definition) rather than from an already-compiled vm.node --
--- for spots where the node that would carry the flag isn't compiled yet,
--- e.g. binding the not-yet-resolved return type of a generic function.
---@type table<string, fun(source: parser.object): boolean>
local flagDerivers = {}

---@param name    string
---@param deriver fun(source: parser.object): boolean
function vm.registerFlagDeriver(name, deriver)
    flagDerivers[name] = deriver
end

--- Run every registered deriver against `source` and collect the ones that
--- matched into a `{[name] = true}` table, or nil if none matched.
---@param source parser.object
---@return table<string, boolean>?
function vm.deriveFlags(source)
    local flags
    for name, deriver in pairs(flagDerivers) do
        if deriver(source) then
            flags = flags or {}
            flags[name] = true
        end
    end
    return flags
end

--- Run every registered deriver against `source` and set whichever flags
--- matched directly onto `node`.
---@param source parser.object
---@param node   vm.node
function vm.applyDerivedFlags(source, node)
    for name, deriver in pairs(flagDerivers) do
        if deriver(source) then
            node:setFlag(name)
        end
    end
end
