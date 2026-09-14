local files           = require 'files'
local vm              = require 'vm'
local lang            = require 'language'
local guide           = require 'parser.guide'
local config          = require 'config'
local define          = require 'proto.define'
local await           = require 'await'
local util             = require 'utility'
local protoDiagnostic = require 'proto.diagnostic'
local docTags         = require 'parser.docTags'

local MESSAGE = 'Deprecated.'

protoDiagnostic.register {
    'deprecated',
} {
    group    = 'strict',
    severity = 'Warning',
    status   = 'Any',
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

        await.delay()

        local deprecated = vm.getDeprecated(src, true)
        if not deprecated then
            return
        end

        await.delay()

        local message = MESSAGE
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
