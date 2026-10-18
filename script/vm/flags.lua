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

--- A flag that a narrowing can set only for the branch that proved it. `proofFlag` marks a node whose `flag` holds ONLY because of such a
--- proof (a guard that said "this value is secret" about a value whose type said it was not): where two paths join, the proof does not
--- survive unless every path had it, so it never leaks past the `if` that established it, and a `flag` the value really had stays.
---@type table<string, string>
local branchLocalFlags = {}

---@param flag      string
---@param proofFlag string
function vm.registerBranchLocalFlag(flag, proofFlag)
    branchLocalFlags[flag] = proofFlag
end

--- The node a join of `a` and `b` gives, `joined` being their merge: the flags registered with `registerBranchLocalFlag` keep only what
--- does not rest on a proof of one path alone.
---@param joined vm.node the merge of `a` and `b`, changed in place
---@param a      vm.node
---@param b      vm.node
---@return vm.node
function vm.joinBranchLocalFlags(joined, a, b)
    for flag, proof in pairs(branchLocalFlags) do
        local bothProven = a:hasFlag(proof) and b:hasFlag(proof)
        local own = (a:hasFlag(flag) and not a:hasFlag(proof)) or (b:hasFlag(flag) and not b:hasFlag(proof))
        if not (own or bothProven) then
            joined:clearFlag(flag)
        end
        if not bothProven then
            joined:clearFlag(proof)
        end
    end
    return joined
end

--- How a flag shows in a hover: the type is written inside the keyword of the flag (`secret<number>`), the way the type syntax spells it.
---@type table<string, string>
local flagViews = {}

---@param flag    string  a registered propagating flag
---@param keyword string  the type keyword that shows it (`secret`)
function vm.registerFlagView(flag, keyword)
    flagViews[flag] = keyword
end

---@type (fun(param: parser.object, value: vm.node): boolean)[]
local slotRefusals = {}

--- A plugin's rule that a parameter refuses a value (a slot that cannot take it, for example a value with a flag the slot is declared
--- without). Only the editor asks, to rank the values that would be reported last in the completion of an argument; the diagnostics keep
--- their own checks. `rule(param, value)`: `param` is the parameter (`local` of a function or `doc.type.arg` of a `fun(...)` type).
---@param rule fun(param: parser.object, value: vm.node): boolean
function vm.registerSlotRefusal(rule)
    slotRefusals[#slotRefusals+1] = rule
end

--- Does a registered rule say that `param` refuses `value`?
---@param param parser.object
---@param value vm.node
---@return boolean
function vm.slotRefuses(param, value)
    for _, rule in ipairs(slotRefusals) do
        if rule(param, value) then
            return true
        end
    end
    return false
end

--- `view` (the text of a type) with the flags of `node` written around it (`secret<number>`, `secret<number>?`).
---@param node vm.node
---@param view string
---@return string
function vm.viewWithFlags(node, view)
    ---@type string[]
    local names = {}
    for flag in pairs(flagViews) do
        names[#names+1] = flag
    end
    table.sort(names)
    for _, flag in ipairs(names) do
        local keyword = flagViews[flag]
        if node:hasFlag(flag) and view ~= 'unknown' and view ~= 'any' and not view:find('^' .. keyword .. '<') then
            local optional = view:sub(-1) == '?'
            local base = optional and view:sub(1, -2) or view
            if base:sub(1, 1) == '(' and base:sub(-1) == ')' then
                base = base:sub(2, -2)
            end
            view = ('%s<%s>'):format(keyword, base) .. (optional and '?' or '')
        end
    end
    return view
end

--- A flag a parameter type can absorb when a generic is bound to the argument: `fn(v: secret<T>)` accepts a secret and binds `T` to the
--- argument's type WITHOUT the secrecy (wowlua-ls: "secret unwrap"). Registering a propagating flag here makes `vm.propagateFlagsBound` leave it
--- behind whenever the parameter's own type carries the flag.
---@type table<string, true>
local bindAbsorbedFlags = {}

---@param name string
function vm.registerBindAbsorbedFlag(name)
    bindAbsorbedFlags[name] = true
end

--- `vm.propagateFlags` for the binding of a generic to an argument (`from`) of the parameter whose type node is `param`: a flag registered
--- with `registerBindAbsorbedFlag` that `param` carries does not come out through the generic.
---@param from  vm.node
---@param to    vm.node
---@param param vm.node?
function vm.propagateFlagsBound(from, to, param)
    for name in pairs(propagatingFlags) do
        if from:hasFlag(name) and not (param and bindAbsorbedFlags[name] and param:hasFlag(name)) then
            to:setFlag(name)
        end
    end
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
    ---@type table<string, boolean>?
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

--- Make the registered flags of `node` what `value` carries (a value that was assigned), plus what `declaration` stands
--- for by itself (a plugin's flag derived from the declaration's own docs, see `vm.registerFlagDeriver`). For a node
--- that was rebuilt from a variable's own node: that one holds the flags of every value the variable was ever given.
---@param node        vm.node
---@param value       vm.node
---@param declaration parser.object?
function vm.resetFlags(node, value, declaration)
    local declared = declaration and vm.deriveFlags(declaration)
    for name in pairs(propagatingFlags) do
        if value:hasFlag(name) or (declared and declared[name]) then
            node:setFlag(name)
        else
            node:clearFlag(name)
        end
    end
end
