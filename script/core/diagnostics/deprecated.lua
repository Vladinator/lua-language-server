local files           = require 'files'
local vm              = require 'vm'
local lang            = require 'language'
local guide           = require 'parser.guide'
local config          = require 'config'
local define          = require 'proto.define'
local await           = require 'await'
local util             = require 'utility'
local scope           = require 'workspace.scope'
local protoDiagnostic = require 'proto.diagnostic'
local docTags         = require 'parser.docTags'

local MESSAGE = 'Deprecated.'

protoDiagnostic.register {
    'deprecated',
} {
    group    = 'strict',
    narrowSettings = { 'Lua.diagnostics.globals', 'Lua.diagnostics.globalsRegex' },
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics to highlight deprecated API.',
}

-- The @deprecated LuaDoc tag itself (a bare marker, like @secret). Its
-- *recognition* by vm.getDeprecated stays shared in vm/doc.lua, since
-- that function also recognizes the unrelated, more widely-used @version
-- tag (semantic-tokens.lua, provider.lua and guide.lua all read it too) --
-- only the tag's parsing and binding are exclusive to this diagnostic.

docTags.registerMarkerTag('deprecated', 'doc.deprecated')

docTags.registerBindRule('doc.deprecated', function (doc, source, isParam)
    return not (source.type == 'function' or isParam)
end)

local types = {'getglobal', 'getfield', 'getindex', 'getmethod'}

-- The definition shapes `vm.getDeprecated`'s own `deep` search can ever find a `doc.deprecated`/
-- `doc.version` on: setglobal/setfield/setmethod/tablefield/setindex/tableindex directly, or (its
-- own fallback for a bare function def) a `function` node, keyed by its parent's name.
local markDefTypes = {'setglobal', 'setfield', 'setmethod', 'tablefield', 'setindex', 'tableindex'}

---@param src parser.object?
---@return boolean
local function hasDeprecatedMark(src)
    if not src or not src.bindDocs then
        return false
    end
    for _, doc in ipairs(src.bindDocs) do
        if doc.type == 'doc.deprecated' or doc.type == 'doc.version' then
            return true
        end
    end
    return false
end

---@class deprecated.fileNames
---@field names          table<string, true>
---@field hasNumericMark boolean

--- Every STRING name (global, field, or method) this file could ever make `deprecated` report on.
--- A rare numeric `SPELLS[1] = ... ---@deprecated` can't be indexed by name, so it only sets
--- `hasNumericMark` -- see `mightBeDeprecated` below. Structural, AST-only, same pattern as
--- `secret-access.lua`'s own name index and `invisible.lua`'s own follow-up: never
--- `vm.compileNode`/`vm.getDefs`.
---@param uri uri
---@return deprecated.fileNames?
local function getFileNames(uri)
    local cache = files.getCache(uri)
    if not cache then
        return nil
    end
    ---@type deprecated.fileNames|false|nil
    local found = cache['deprecated.names']
    if found ~= nil then
        return found or nil
    end
    local state = files.getState(uri)
    if not state then
        cache['deprecated.names'] = false
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
        if hasDeprecatedMark(src) then
            record(guide.getKeyName(src))
        end
    end)
    guide.eachSourceType(state.ast, 'function', function (f)
        if hasDeprecatedMark(f) then
            record(guide.getKeyName(f.parent))
        end
    end)
    found = any and { names = names, hasNumericMark = hasNumericMark } or false
    cache['deprecated.names'] = found
    return found or nil
end

---@class deprecated.workspaceNames
---@field names          table<string, true>
---@field hasNumericMark boolean

--- The above, folded across the whole workspace; dropped with the rest of `vm.getCache` when a file
--- changes.
---@param uri uri
---@return deprecated.workspaceNames
local function getWorkspaceNames(uri)
    local cache = vm.getCache('deprecated.names')
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

--- Could `src` (a checked access whose key is `key`) possibly be deprecated, so the expensive
--- `vm.getDeprecated`/`vm.getDefs` below is actually needed? A "maybe" changes nothing (falls
--- through to the exact same check this diagnostic always ran); only a confident "no" skips it. A
--- loose file (`scope.fallback`) can't reliably fold its siblings' names through `files.eachFile`
--- the way a real workspace does, so it always answers "maybe".
---@param uri uri
---@param src parser.object
---@param key string|number
---@return boolean
local function mightBeDeprecated(uri, src, key)
    if scope.getScope(uri).type == 'fallback' then
        return true
    end
    if type(key) == 'string' then
        return getWorkspaceNames(uri).names[key] == true
    end
    -- Only `getindex` can have a numeric/computed key here (getglobal/getfield/getmethod are
    -- always string-keyed): can't match a name index, so only a mark directly on this access or on
    -- whatever `vm.getVariableSets` (cheap, never `vm.compileNode`) resolves it to can matter.
    if getWorkspaceNames(uri).hasNumericMark then
        return true
    end
    if hasDeprecatedMark(src) then
        return true
    end
    local sets = vm.getVariableSets(src)
    if sets then
        for _, set in ipairs(sets) do
            if hasDeprecatedMark(set) then
                return true
            end
        end
    end
    return false
end

---@async
return function (uri, callback)
    local ast = files.getState(uri)
    if not ast then
        return
    end

    local dglobals = util.arrayToHash(config.get(uri, 'Lua.diagnostics.globals'))
    local rspecial = config.get(uri, 'Lua.runtime.special')

    guide.eachSourceTypes(ast.ast, types, function (src) ---@async
        if src.type == 'getglobal' then
            local key = src[1]
            if not key then
                return
            end
            if dglobals[key] then
                return
            end
            if rspecial[key] then
                return
            end
        end

        local key = guide.getKeyName(src)
        if not key then
            return
        end

        await.delay()

        if not mightBeDeprecated(uri, src, key) then
            return
        end

        local deprecated = vm.getDeprecated(src, true)
        if not deprecated then
            return
        end

        await.delay()

        local message = MESSAGE
        ---@type string[]?
        local versions
        if deprecated.type == 'doc.version' then
            local validVersions = vm.getValidVersions(deprecated)
            if not validVersions then
                return
            end
            versions = {}
            for version, valid in pairs(validVersions) do
                if valid then
                    versions[#versions+1] = version
                end
            end
            table.sort(versions)
            if #versions > 0 then
                message = ('%s(%s)'):format(message
                    , lang.script('DIAG_DEFINED_VERSION'
                    , table.concat(versions, '/')
                    , config.get(uri, 'Lua.runtime.version'))
                )
            end
        end
        if deprecated.type == 'doc.deprecated' then
            if deprecated.comment then
                message = ('%s(%s)'):format(message, util.trim(deprecated.comment.text))
            end
        end

        callback {
            start   = src.start,
            finish  = src.finish,
            tags    = { define.DiagnosticTag.Deprecated },
            message = message,
            data    = {
                versions = versions,
            }
        }
    end)
end
