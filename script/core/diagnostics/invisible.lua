local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm.vm'
local await           = require 'await'
local scope           = require 'workspace.scope'
local protoDiagnostic = require 'proto.diagnostic'

local PRIVATE_MESSAGE   = 'Field `%s` is private, it can only be accessed in class `%s`.'
local PROTECTED_MESSAGE = 'Field `%s` is protected, it can only be accessed in class `%s` and its subclasses.'
local PACKAGE_MESSAGE   = 'Field `%s` can only be accessed in same file `%s`.'

protoDiagnostic.register {
    'invisible',
} {
    group    = 'strict',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for accesses to fields which are invisible.',
}

local checkTypes      = {'getfield', 'setfield', 'getmethod', 'setmethod', 'getindex', 'setindex'}
local markSourceTypes = {'setfield', 'tablefield', 'setmethod'}

---@type table<string, true>
local BARE_MARKER_TYPES = { ['doc.private'] = true, ['doc.protected'] = true, ['doc.package'] = true }

--- Does `src` itself carry a bare `---@private`/`---@protected`/`---@package`? Cheap: an attribute
--- lookup, no compile.
---@param src parser.object?
---@return boolean
local function hasBareMark(src)
    if not src or not src.bindDocs then
        return false
    end
    for _, doc in ipairs(src.bindDocs) do
        if BARE_MARKER_TYPES[doc.type] then
            return true
        end
    end
    return false
end

---@class invisible.fileNames
---@field names               table<string, true>
---@field hasNumericFieldMark boolean

--- Every STRING field name this file could ever make `invisible` report on: an explicit
--- `---@field <name> private/protected/package`, or a bare marker bound to a `setfield`/
--- `tablefield`/`setmethod` definition of that name -- the only definition shapes `vm.getDefs`
--- returns for the access types `invisible` checks (`checkTypes` above never includes
--- getlocal/setlocal/getglobal/setglobal, so a `local`/global def is never relevant here). A rare
--- `---@field [1] private ...` (a numeric field declaration) can't be indexed by name, so it only
--- sets `hasNumericFieldMark` -- see `mightBeInvisible` below. Structural, AST-only, same as
--- `secret-access.lua`'s own name index: never `vm.compileNode`/`vm.getDefs`.
---@param uri uri
---@return invisible.fileNames?
local function getFileNames(uri)
    local cache = files.getCache(uri)
    if not cache then
        return nil
    end
    ---@type invisible.fileNames|false|nil
    local found = cache['invisible.names']
    if found ~= nil then
        return found or nil
    end
    local state = files.getState(uri)
    if not state then
        cache['invisible.names'] = false
        return nil
    end
    ---@type table<string, true>
    local names = {}
    local hasNumericFieldMark = false
    local any = false
    guide.eachSourceType(state.ast, 'doc.field', function (f)
        if f.visible and f.visible ~= 'public' then
            any = true
            local name = f.field and f.field[1]
            if type(name) == 'string' then
                names[name] = true
            else
                hasNumericFieldMark = true
            end
        end
    end)
    guide.eachSourceTypes(state.ast, markSourceTypes, function (src)
        if hasBareMark(src) then
            any = true
            local name = guide.getKeyName(src)
            if type(name) == 'string' then
                names[name] = true
            end
        end
    end)
    found = any and { names = names, hasNumericFieldMark = hasNumericFieldMark } or false
    cache['invisible.names'] = found
    return found or nil
end

---@class invisible.workspaceNames
---@field names               table<string, true>
---@field hasNumericFieldMark boolean

--- The above, folded across the whole workspace (a mark in another file can still make an access
--- here invisible); dropped with the rest of `vm.getCache` when a file changes.
---@param uri uri
---@return invisible.workspaceNames
local function getWorkspaceNames(uri)
    local cache = vm.getCache('invisible.names')
    local key   = scope.getScope(uri):getName()
    local found = cache[key]
    if found then
        return found
    end
    ---@type table<string, true>
    local names = {}
    local hasNumericFieldMark = false
    for fileUri in files.eachFile(uri) do
        local fileNames = getFileNames(fileUri)
        if fileNames then
            for name in pairs(fileNames.names) do
                names[name] = true
            end
            if fileNames.hasNumericFieldMark then
                hasNumericFieldMark = true
            end
        end
    end
    found = { names = names, hasNumericFieldMark = hasNumericFieldMark }
    cache[key] = found
    return found
end

--- Could `src` (a checked access whose key is `key`) possibly resolve to a non-public definition,
--- so the expensive `vm.getDefs` below is actually needed? A "maybe" here changes nothing (falls
--- through to the exact same check this diagnostic always ran); only a confident "no" skips it. A
--- loose file (`scope.fallback`) can't reliably fold its siblings' names the way a real workspace
--- does (`files.eachFile` doesn't enumerate them the same way), so it always answers "maybe" --
--- identical to never reaching this fast path, which only matters for a real workspace anyway.
---@param uri uri
---@param src parser.object
---@param key string|number
---@return boolean
local function mightBeInvisible(uri, src, key)
    if scope.getScope(uri).type == 'fallback' then
        return true
    end
    if type(key) == 'string' then
        if vm.matchConfiguredVisibility(uri, key) then
            return true
        end
        return getWorkspaceNames(uri).names[key] == true
    end
    -- A numeric/computed key can never match a name pattern (Lua.doc.*Name only ever matches a
    -- string field name) and a numeric `---@field [n] private ...` is per-declaration, not
    -- name-indexable workspace-wide -- so this only needs to rule out a mark directly on this
    -- access or on whatever it structurally, cheaply resolves to (vm.getVariableSets: the same
    -- compound-ID system secret-access.lua's own safe path uses -- never vm.compileNode).
    if getWorkspaceNames(uri).hasNumericFieldMark then
        return true
    end
    if hasBareMark(src) then
        return true
    end
    local sets = vm.getVariableSets(src)
    if sets then
        for _, set in ipairs(sets) do
            if hasBareMark(set) then
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
    guide.eachSourceTypes(state.ast, checkTypes, function (src)
        local child = src.field or src.method or src.index
        if not child then
            return
        end
        local key = guide.getKeyName(src)
        if not key then
            return
        end
        await.delay()
        if not mightBeInvisible(uri, src, key) then
            return
        end
        local defs = vm.getDefs(src)
        for _, def in ipairs(defs) do
            if not vm.isVisible(src.node, def) then
                if vm.getVisibleType(def) == 'private' then
                    callback {
                        start   = child.start,
                        finish  = child.finish,
                        uri     = uri,
                        message = PRIVATE_MESSAGE:format(key, vm.getParentClass(def):getName()),
                    }
                elseif vm.getVisibleType(def) == 'protected' then
                    callback {
                        start   = child.start,
                        finish  = child.finish,
                        uri     = uri,
                        message = PROTECTED_MESSAGE:format(key, vm.getParentClass(def):getName()),
                    }
                elseif vm.getVisibleType(def) == 'package' then
                    callback {
                        start   = child.start,
                        finish  = child.finish,
                        uri     = uri,
                        message = PACKAGE_MESSAGE:format(key, guide.getUri(def)),
                    }
                else
                    error('Unknown visible type: ' .. vm.getVisibleType(def))
                end
                break
            end
        end
    end)
end
