local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local scope           = require 'workspace.scope'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'The return values of this function cannot be discarded.'

protoDiagnostic.register {
    'discard-returns',
} {
    group    = 'strict',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for calls of functions annotated with `---@nodiscard` where the return values are ignored.',
}

-- The definition shapes `vm.isNoDiscard`'s own `deep` search (via `vm.getDefs`) can ever find a
-- `doc.nodiscard` on: setglobal/setfield/setmethod/tablefield/setindex/tableindex directly, or (a
-- bare function def) a `function` node, keyed by its parent's name -- same shape as
-- `deprecated.lua`'s own fast-path index, since both are single-marker-type, `deep`-`vm.getDefs`-
-- based checks.
local markDefTypes = {'setglobal', 'setfield', 'setmethod', 'tablefield', 'setindex', 'tableindex'}

---@param src parser.object?
---@return boolean
local function hasNoDiscardMark(src)
    if not src or not src.bindDocs then
        return false
    end
    for _, doc in ipairs(src.bindDocs) do
        if doc.type == 'doc.nodiscard' then
            return true
        end
    end
    return false
end

---@class discardReturns.fileNames
---@field names          table<string, true>
---@field hasNumericMark boolean

---@param uri uri
---@return discardReturns.fileNames?
local function getFileNames(uri)
    local cache = files.getCache(uri)
    if not cache then
        return nil
    end
    ---@type discardReturns.fileNames|false|nil
    local found = cache['discard-returns.names']
    if found ~= nil then
        return found or nil
    end
    local state = files.getState(uri)
    if not state then
        cache['discard-returns.names'] = false
        return nil
    end
    ---@type table<string, true>
    local names = {}
    local hasNumericMark = false
    local any = false
    ---@param name string|number|nil
    local function record(name)
        any = true
        if type(name) == 'string' then
            names[name] = true
        else
            hasNumericMark = true
        end
    end
    guide.eachSourceTypes(state.ast, markDefTypes, function (src)
        if hasNoDiscardMark(src) then
            record(guide.getKeyName(src))
        end
    end)
    guide.eachSourceType(state.ast, 'function', function (f)
        if hasNoDiscardMark(f) then
            record(guide.getKeyName(f.parent))
        end
    end)
    found = any and { names = names, hasNumericMark = hasNumericMark } or false
    cache['discard-returns.names'] = found
    return found or nil
end

---@class discardReturns.workspaceNames
---@field names          table<string, true>
---@field hasNumericMark boolean

---@param uri uri
---@return discardReturns.workspaceNames
local function getWorkspaceNames(uri)
    local cache = vm.getCache('discard-returns.names')
    local key   = scope.getScope(uri):getName()
    local found = cache[key]
    if found then
        return found
    end
    ---@type table<string, true>
    local names = {}
    local hasNumericMark = false
    for fileUri in files.eachFile(uri) do
        local fileNames = getFileNames(fileUri)
        if fileNames then
            for name in pairs(fileNames.names) do
                names[name] = true
            end
            if fileNames.hasNumericMark then
                hasNumericMark = true
            end
        end
    end
    found = { names = names, hasNumericMark = hasNumericMark }
    cache[key] = found
    return found
end

--- Could `calleeNode` possibly be `---@nodiscard`, so the expensive `vm.isNoDiscard`/`vm.getDefs`
--- call is actually needed? A "maybe" changes nothing (falls through to the exact same check this
--- diagnostic always ran); only a confident "no" skips it. `vm.isNoDiscard`'s own cheap first check
--- (a mark directly on `calleeNode` itself, e.g. `(function() end --[[@nodiscard]])()`) doesn't need
--- a name at all, so a keyless callee (no `guide.getKeyName` result -- an IIFE, the result of
--- another call, ...) always answers "maybe": there is no name to rule it out by, and this shape is
--- rare enough that it isn't worth a bespoke structural check. A loose file (`scope.fallback`) can't
--- reliably fold its siblings' names through `files.eachFile` either, so it also always answers
--- "maybe".
---@param uri        uri
---@param calleeNode parser.object
---@param key        string|number|nil
---@return boolean
local function mightBeNoDiscard(uri, calleeNode, key)
    if hasNoDiscardMark(calleeNode) then
        return true
    end
    if not key then
        return true
    end
    if scope.getScope(uri).type == 'fallback' then
        return true
    end
    if type(key) == 'string' then
        return getWorkspaceNames(uri).names[key] == true
    end
    if getWorkspaceNames(uri).hasNumericMark then
        return true
    end
    local sets = vm.getVariableSets(calleeNode)
    if sets then
        for _, set in ipairs(sets) do
            if hasNoDiscardMark(set) then
                return true
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
    ---@async
    guide.eachSourceType(state.ast, 'call', function (source)
        if not guide.isBlockType(source.parent) then
            return
        end
        if source.parent.filter == source then
            return
        end
        await.delay()
        local key = guide.getKeyName(source.node)
        if not mightBeNoDiscard(uri, source.node, key) then
            return
        end
        if vm.isNoDiscard(source.node, true) then
            callback {
                start   = source.start,
                finish  = source.finish,
                message = MESSAGE,
            }
        end
    end)
end
