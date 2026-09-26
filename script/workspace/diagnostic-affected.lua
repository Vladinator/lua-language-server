-- Safe, structural approximation of "which files could a change to this file affect",
-- for narrowing a workspace-wide re-diagnosis pass (provider/diagnostic.lua) to less than
-- every file. Never calls vm.compileNode/vm.getDefs -- purely an AST scan, like
-- core/diagnostics/extra/need-check-secret.lua's own name index -- so it is always safe to
-- call from anywhere, including before the changed file's own diagnostics have re-run.
--
-- Only ever asked to *narrow*, never to *decide correctness*: every path that cannot prove a
-- file is unaffected must include it. A missed re-diagnosis (stale diagnostics, silently) is a
-- new and worse bug class than the current always-diagnose-everything behavior, so uncertainty
-- always resolves to "diagnose it".
--
-- Two safe reachability edges:
--  1. `require` graph, literal-argument calls only (workspace.require-path, the same resolver
--     vm/compiler.lua's own `require` handling uses) -- a changed file's transitive requirers are
--     always affected, at file granularity (never asks which export a requirer actually reads).
--  2. Global-name reachability: a file whose `getglobal` references intersect a changed file's
--     `setglobal` declarations is affected. A pure superset of any real relationship a shared name
--     could cause, so it can only over-include.
-- A file with a *dynamic* (non-literal-argument) `require` call is always affected, workspace-wide,
-- whenever this module is asked at all: its true require target is unknown, so it can't be proven
-- unrelated to the change.

local files = require 'files'
local guide = require 'parser.guide'
local rpath = require 'workspace.require-path'
local scope = require 'workspace.scope'
local vm    = require 'vm'

---@class workspace.diagnostic-affected
local m = {}

---@class diagnostic-affected.fileInfo
---@field declaresGlobal table<string, true>
---@field refsGlobal     table<string, true>
---@field requires       uri[]
---@field dynamic        boolean -- has a require() call whose target could not be resolved statically

---@type table<uri, table<string, true>>
-- Last-seen declared-global set per file, kept outside files.getCache/vm.getCache (which are
-- dropped on the very edit this is meant to remember *through*): a renamed global (a file that
-- used to declare `Foo`, now declares `Bar` instead) must still be matched against `Foo` for one
-- more pass, or a file that only referenced the old name would wrongly look unaffected.
m.lastDeclares = {}

---@param uri uri
---@return diagnostic-affected.fileInfo?
local function getFileInfo(uri)
    local cache = files.getCache(uri)
    if not cache then
        return nil
    end
    ---@type diagnostic-affected.fileInfo|false|nil
    local info = cache['diagnostic-affected.info']
    if info ~= nil then
        return info or nil
    end
    local state = files.getState(uri)
    if not state then
        cache['diagnostic-affected.info'] = false
        return nil
    end
    ---@type diagnostic-affected.fileInfo
    local found = { declaresGlobal = {}, refsGlobal = {}, requires = {}, dynamic = false }
    guide.eachSourceType(state.ast, 'setglobal', function (src)
        local name = src[1]
        if type(name) == 'string' then
            found.declaresGlobal[name] = true
        end
    end)
    guide.eachSourceType(state.ast, 'getglobal', function (src)
        local name = src[1]
        if type(name) == 'string' then
            found.refsGlobal[name] = true
        end
    end)
    guide.eachSourceType(state.ast, 'call', function (call)
        local callee = call.node
        if not callee or callee.special ~= 'require' then
            return
        end
        local nameArg = call.args and call.args[1]
        if not nameArg or nameArg.type ~= 'string' or type(nameArg[1]) ~= 'string' then
            found.dynamic = true
            return
        end
        local target = rpath.findUrisByRequireName(uri, nameArg[1])[1]
        if target then
            found.requires[#found.requires+1] = target
        end
    end)
    cache['diagnostic-affected.info'] = found
    return found
end

---@class diagnostic-affected.workspaceIndex
---@field requiredBy table<uri, uri[]> -- targetUri -> uris that require it (literal, resolved)
---@field dynamicUris table<uri, true>

---@param suri uri
---@return diagnostic-affected.workspaceIndex
local function getWorkspaceIndex(suri)
    local cache = vm.getCache('diagnostic-affected.index') --[[@as table<string, diagnostic-affected.workspaceIndex>]]
    local key   = scope.getScope(suri):getName()
    ---@type diagnostic-affected.workspaceIndex
    local index = cache[key]
    if index then
        return index
    end
    ---@type table<uri, uri[]>
    local requiredBy = {}
    ---@type table<uri, true>
    local dynamicUris = {}
    for fileUri in files.eachFile(suri) do
        local info = getFileInfo(fileUri)
        if info then
            if info.dynamic then
                dynamicUris[fileUri] = true
            end
            for _, target in ipairs(info.requires) do
                local list = requiredBy[target]
                if not list then
                    list = {}
                    requiredBy[target] = list
                end
                list[#list+1] = fileUri
            end
        end
    end
    index = { requiredBy = requiredBy, dynamicUris = dynamicUris }
    cache[key] = index
    return index
end

--- Every uri that must be re-diagnosed because of a change to one of `changedUris`, or `nil`
--- meaning "could not narrow safely, diagnose the whole scope".
---@param suri        uri
---@param changedUris uri[]
---@return table<uri, true>?
function m.getAffectedUris(suri, changedUris)
    if #changedUris == 0 then
        return nil
    end
    local index = getWorkspaceIndex(suri)
    ---@type table<uri, true>
    local affected = {}
    for _, u in ipairs(changedUris) do
        affected[u] = true
    end
    for u in pairs(index.dynamicUris) do
        affected[u] = true
    end
    for _, u in ipairs(changedUris) do
        local info = getFileInfo(u)
        if not info then
            return nil
        end
        ---@type table<string, true>
        local declares = info.declaresGlobal
        local previous = m.lastDeclares[u]
        m.lastDeclares[u] = declares
        for fileUri in files.eachFile(suri) do
            if not affected[fileUri] then
                local finfo = getFileInfo(fileUri)
                if finfo then
                    local hit = false
                    for name in pairs(declares) do
                        if finfo.refsGlobal[name] then
                            hit = true
                            break
                        end
                    end
                    if not hit and previous then
                        for name in pairs(previous) do
                            if finfo.refsGlobal[name] then
                                hit = true
                                break
                            end
                        end
                    end
                    if hit then
                        affected[fileUri] = true
                    end
                end
            end
        end
    end
    ---@type uri[]
    local queue = {}
    for u in pairs(affected) do
        queue[#queue+1] = u
    end
    local qi = 1
    while qi <= #queue do
        local u = queue[qi]
        qi = qi + 1
        local requirers = index.requiredBy[u]
        if requirers then
            for _, ru in ipairs(requirers) do
                if not affected[ru] then
                    affected[ru] = true
                    queue[#queue+1] = ru
                end
            end
        end
    end
    return affected
end

return m
