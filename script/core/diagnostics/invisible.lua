local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm.vm'
local await           = require 'await'
local config          = require 'config'
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

local checkTypes = {'getfield', 'setfield', 'getmethod', 'setmethod', 'getindex', 'setindex'}
local visibleMarkerTypes = {'doc.private', 'doc.protected', 'doc.package'}

--- Nothing can ever be reported for a file unless SOMETHING, somewhere in its workspace, actually
--- marks a field non-public -- an explicit `---@field private/protected/package`, a bare
--- `---@private`/`---@protected`/`---@package`, or a `Lua.doc.*Name` pattern configured for the
--- file. Checking that first is much cheaper than the alternative: `vm.getDefs` per access node is
--- the majority of this diagnostic's cost on any file with a lot of field/index accesses (a large
--- literal-heavy data table can have hundreds of thousands), almost always for nothing -- most Lua
--- code, WoW addons especially, never uses these annotations at all.
---@param uri uri
---@return boolean
local function fileHasVisibilityMarker(uri)
    local cache = files.getCache(uri)
    if not cache then
        return false
    end
    ---@type boolean?
    local has = cache['invisible.hasMarker']
    if has ~= nil then
        return has
    end
    local state = files.getState(uri)
    if not state then
        cache['invisible.hasMarker'] = false
        return false
    end
    has = false
    guide.eachSourceType(state.ast, 'doc.field', function (f)
        if f.visible and f.visible ~= 'public' then
            has = true
        end
    end)
    if not has then
        guide.eachSourceTypes(state.ast, visibleMarkerTypes, function ()
            has = true
        end)
    end
    cache['invisible.hasMarker'] = has
    return has
end

--- The above, folded across the whole workspace (a marker in another file can still make an access
--- here invisible); dropped with the rest of `vm.getCache` when a file changes. A loose file with no
--- real workspace (`scope.fallback`) never reliably enumerates its siblings through `files.eachFile`
--- the way a real workspace folder does (`awaitDiagnosticsScope` itself treats that scope specially,
--- skipping workspace-wide diagnosis for it) -- so this always assumes "yes" there, the same as
--- never having reached this fast path at all: skips nothing, changes nothing about what a loose
--- file reports, only about a real workspace, which is the only place the saved cost matters anyway.
---@param uri uri
---@return boolean
local function workspaceHasVisibilityMarker(uri)
    if scope.getScope(uri).type == 'fallback' then
        return true
    end
    local cache = vm.getCache('invisible.anyMarker') --[[@as table<string, boolean>]]
    local key   = scope.getScope(uri):getName()
    local any   = cache[key]
    if any ~= nil then
        return any
    end
    any = false
    for fileUri in files.eachFile(uri) do
        if fileHasVisibilityMarker(fileUri) then
            any = true
            break
        end
    end
    cache[key] = any
    return any
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    if  #(config.get(uri, 'Lua.doc.privateName') --[[@as string[] ]]) == 0
    and #(config.get(uri, 'Lua.doc.protectedName') --[[@as string[] ]]) == 0
    and #(config.get(uri, 'Lua.doc.packageName') --[[@as string[] ]]) == 0
    and not workspaceHasVisibilityMarker(uri) then
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
