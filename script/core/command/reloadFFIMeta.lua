local config      = require 'config'
local ws          = require 'workspace'
local fs          = require 'bee.filesystem'
local scope       = require 'workspace.scope'
local SDBMHash    = require 'SDBMHash'
local searchCode  = require 'plugins.ffi.searchCode'
local cdefRerence = require 'plugins.ffi.cdefRerence'
local ffi         = require 'plugins.ffi'

local function createDir(uri)
    local dir     = scope.getScope(uri).uri or 'default'
    local fileDir = fs.path(METAPATH) / ('%08x'):format(SDBMHash():hash(dir))
    if fs.exists(fileDir) then
        return fileDir, true
    end
    fs.create_directories(fileDir)
    return fileDir
end

---@async
return function (uri)
    if config.get(uri, 'Lua.runtime.version') ~= 'LuaJIT' then
        return
    end

    ws.awaitReady(uri)

    local fileDir, exists = createDir(uri)

    local refs = cdefRerence()
    if not refs or #refs == 0 then
        return
    end

    for _, v in ipairs(refs) do
        local target_uri = v.uri
        if not target_uri then
            -- `jump-source.result.uri` is only populated when the reference's
            -- target could be traced to a bound `doc.source` node (see
            -- core/jump-source.lua); skip entries where that never happened
            -- rather than forwarding a nil uri into build_single/searchCode.
            goto continue
        end
        local codes = searchCode(refs, target_uri)
        if not codes then
            return
        end

        ffi.build_single(codes, fileDir, target_uri)
        ::continue::
    end

    if not exists then
        local client = require 'client'
        client.setConfig {
            {
                key    = 'Lua.workspace.library',
                action = 'add',
                value  = tostring(fileDir),
                uri    = uri,
            }
        }
    end
end
