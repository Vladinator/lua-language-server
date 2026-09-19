local pub        = require 'pub'
local fs         = require 'bee.filesystem'
local furi       = require 'file-uri'
local files      = require 'files'
local config     = require 'config'
local glob       = require 'glob'
local platform   = require 'bee.platform'
local await      = require 'await'
local client     = require 'client'
local util       = require 'utility'
local fw         = require 'filewatch'
local scope      = require 'workspace.scope'
local loading    = require 'workspace.loading'
local inspect    = require 'inspect'
local lang       = require 'language'

---@class workspace
---@field folders scope[]
---@field rootUri? uri
local m = {}
m.type = 'workspace'
---@type (async fun(ev: string, uri: uri))[]
m.watchList = {}

--- 注册事件
---@param callback async fun(ev: string, uri: uri)
function m.watch(callback)
    m.watchList[#m.watchList+1] = callback
end

---@param ev  string
---@param uri uri
function m.onWatch(ev, uri)
    for _, callback in ipairs(m.watchList) do
        await.call(function () ---@async
            callback(ev, uri)
        end)
    end
end

---@param uri uri
function m.initRoot(uri)
    m.rootUri  = uri
    log.info('Workspace init root: ', uri)

    local logPath = fs.path(LOGPATH) / (uri:gsub('[/:]+', '_') .. '.log')
    client.logMessage('Log', 'Log path: ' .. furi.encode(logPath:string()))
    log.info('Log path: ', logPath)
    log.init(ROOT, logPath)
end

--- 初始化工作区
---@param uri        uri
---@param folderName? string
function m.create(uri, folderName)
    log.info('Workspace create: ', uri)
    local scp = scope.createFolder(uri, folderName)
    m.folders[#m.folders+1] = scp
    if uri == furi.encode '/'
    or uri == furi.encode(os.getenv 'HOME' or '') then
        if not FORCE_ACCEPT_WORKSPACE then
            client.showMessage('Error', lang.script('WORKSPACE_NOT_ALLOWED', furi.decode(uri)))
            scp:set('bad root', true)
        end
    end
end

---@param uri uri
function m.remove(uri)
    log.info('Workspace remove: ', uri)
    for i, scp in ipairs(m.folders) do
        if scp.uri == uri then
            scp:remove()
            table.remove(m.folders, i)
            scp:set('ready', false)
            scp:set('nativeMatcher', nil)
            scp:set('libraryMatcher', nil)
            scp:removeAllLinks()
            m.flushFiles(scp)
            return
        end
    end
end

function m.reset()
    m.folders = {}
    m.rootUri = nil
end
m.reset()

---@param uri uri
---@return uri?
function m.getRootUri(uri)
    local scp = scope.getScope(uri)
    return scp.uri
end

local globInteferFace = {
    ---@param path string
    ---@param data table<string, string|boolean>
    ---@return string?
    type = function (path, data)
        if data[path] then
            return data[path] --[[@as string?]]
        end
        ---@type string?
        local result
        pcall(function ()
            if fs.is_directory(fs.path(path)) then
                result = 'directory'
                data[path] = 'directory'
            else
                result = 'file'
                data[path] = 'file'
            end
        end)
        return result
    end,
    ---@param path string
    ---@param data table<string, string|boolean>
    ---@return string[]?
    list = function (path, data)
        if data[path] == 'file' then
            return nil
        end
        local fullPath = fs.path(path)
        if not fs.is_directory(fullPath) then
            data[path] = 'file'
            return nil
        end
        data[path] = true
        ---@type string[]
        local paths = {}
        pcall(function ()
            for fullpath, status in fs.pairs(fullPath) do
                local pathString = fullpath:string()
                paths[#paths+1] = pathString
                local st = status:type()
                if st == 'directory'
                or st == 'symlink'
                or st == 'junction' then
                    data[pathString] = 'directory'
                else
                    data[pathString] = 'file'
                end
            end
        end)
        return paths
    end
}

local addonRepositoryPathUpdated = false
--- 创建排除文件匹配器
---@param scp scope
---@return gitignore
function m.getNativeMatcher(scp)
    if scp:get 'nativeMatcher' then
        return scp:get 'nativeMatcher'
    end

    ---@type string[]
    local pattern = {}
    for path, ignore in pairs(config.get(scp.uri, 'files.exclude') --[[@as table<string, boolean>]]) do
        if ignore then
            log.debug('Ignore by exclude:', path)
            pattern[#pattern+1] = path
        end
    end
    if scp.uri and config.get(scp.uri, 'Lua.workspace.useGitIgnore') then
        local buf = util.loadFile(furi.decode(scp.uri) .. '/.gitignore')
        if buf then
            for line in buf:gmatch '[^\r\n]+' do
                if line:sub(1, 1) ~= '#' then
                    log.debug('Ignore by .gitignore:', line)
                    pattern[#pattern+1] = line
                end
            end
        end
        buf = util.loadFile(furi.decode(scp.uri).. '/.git/info/exclude')
        if buf then
            for line in buf:gmatch '[^\r\n]+' do
                if line:sub(1, 1) ~= '#' then
                    log.debug('Ignore by .git/info/exclude:', line)
                    pattern[#pattern+1] = line
                end
            end
        end
    end
    if scp.uri and config.get(scp.uri, 'Lua.workspace.ignoreSubmodules') then
        local buf = util.loadFile(furi.decode(scp.uri) .. '/.gitmodules')
        if buf then
            for path in buf:gmatch('path = ([^\r\n]+)') do
                log.debug('Ignore by .gitmodules:', path)
                pattern[#pattern+1] = path
            end
        end
    end
    for _, path in ipairs(config.get(scp.uri, 'Lua.workspace.library') --[[@as string[] ]]) do
        if not addonRepositoryPathUpdated then
            addonRepositoryPathUpdated = true
            local addonRepositoryPath = config.get(scp.uri, 'Lua.addonRepositoryPath')
            files.updateAddonsPath(addonRepositoryPath)
        end
        local apath = m.getAbsolutePath(scp.uri, path)
        if apath then
            log.debug('Ignore by library:', apath)
            pattern[#pattern+1] = apath
        end
    end
    for _, path in ipairs(config.get(scp.uri, 'Lua.workspace.ignoreDir') --[[@as string[] ]]) do
        log.debug('Ignore directory:', path)
        pattern[#pattern+1] = path
    end

    local matcher = glob.gitignore(pattern, {
        root       = scp.uri and furi.decode(scp.uri),
        ignoreCase = platform.os == 'windows',
    }, globInteferFace)

    scp:set('nativeMatcher', matcher)
    return matcher
end

---@class workspace.libraryMatcher
---@field uri      uri
---@field matcher  gitignore
---@field isDofile boolean

--- 创建代码库筛选器
---@param scp scope
---@return workspace.libraryMatcher[]
function m.getLibraryMatchers(scp)
    if scp:get 'libraryMatcher' then
        return scp:get 'libraryMatcher'
    end
    log.debug('Build library matchers:', scp)

    ---@type string[]
    local pattern = {}
    for path, ignore in pairs(config.get(scp.uri, 'files.exclude') --[[@as table<string, boolean>]]) do
        if ignore then
            log.debug('Ignore by exclude:', path)
            pattern[#pattern+1] = path
        end
    end
    for _, path in ipairs(config.get(scp.uri, 'Lua.workspace.ignoreDir') --[[@as string[] ]]) do
        log.debug('Ignore directory:', path)
        pattern[#pattern+1] = path
    end

    ---@type table<string, boolean>
    local librarys = {}
    ---@type table<string, boolean>
    local dofileRootsSet = {}
    for _, path in ipairs(config.get(scp.uri, 'Lua.workspace.library') --[[@as string[] ]]) do
        local apath = m.getAbsolutePath(scp.uri, path)
        if apath then
            librarys[files.normalize(apath)] = true
        end
    end
    for _, path in ipairs(config.get(scp.uri, 'Lua.workspace.dofileRoots') --[[@as string[] ]]) do
        local apath = m.getAbsolutePath(scp.uri, path)
        if apath then
            local norm = files.normalize(apath)
            librarys[norm] = true
            dofileRootsSet[norm] = true
        end
    end
    local metaPaths = scp:get 'metaPaths'
    log.debug('meta path:', inspect(metaPaths))
    if metaPaths then
        for _, metaPath in ipairs(metaPaths --[[@as string[] ]]) do
            librarys[files.normalize(metaPath)] = true
        end
    end

    ---@type workspace.libraryMatcher[]
    local matchers = {}
    for path in pairs(librarys) do
        if fs.exists(fs.path(path)) then
            local nPath = fs.absolute(fs.path(path)):string()
            local matcher = glob.gitignore(pattern, {
                root       = path,
                ignoreCase = platform.os == 'windows',
            }, globInteferFace)
            matchers[#matchers+1] = {
                uri     = furi.encode(nPath),
                matcher = matcher,
                isDofile = dofileRootsSet[path] or false
            }
        end
    end

    scp:set('libraryMatcher', matchers)
    --log.debug('library matcher:', inspect(matchers))

    return matchers
end

--- 文件是否被忽略
---@param uri uri
---@return boolean
function m.isIgnored(uri)
    local scp    = scope.getScope(uri)
    local path   = m.getRelativePath(uri)
    local ignore = m.getNativeMatcher(scp)
    if not ignore then
        return false
    end
    return ignore(path)
end

---@async
---@param uri uri
---@return boolean
function m.isValidLuaUri(uri)
    if not files.isLua(uri) then
        return false
    end
    if  m.isIgnored(uri)
    and not files.isLibrary(uri) then
        return false
    end
    return true
end

---@async
---@param uri uri
function m.awaitLoadFile(uri)
    m.awaitReady(uri)
    local scp = scope.getScope(uri)
    local ld <close> = loading.create(scp)
    local native = m.getNativeMatcher(scp)
    log.info('Scan files at:', uri)
    ---@async
    native:scan(furi.decode(uri), function (path)
        local uri = files.getRealUri(furi.encode(path))
        local cachedUris = scp:get('cachedUris') --[[@as table<any, any>]]
        cachedUris[uri] = true
        ld:loadFile(uri)
    end)
    ld:loadAll(uri)
end

---@param uri uri
function m.removeFile(uri)
    for _, scp in ipairs(m.folders) do
        if scp:isChildUri(uri)
        or scp:isLinkedUri(uri) then
            local cachedUris = scp:get 'cachedUris'
            if cachedUris and cachedUris[uri] then
                (cachedUris --[[@as table<any, any>]])[uri] = nil
                files.delRef(uri)
            end
        end
    end
end

--- 预读工作区内所有文件
---@async
---@param scp scope
function m.awaitPreload(scp)
    await.close('preload:' .. scp:getName())
    await.setID('preload:' .. scp:getName())
    await.sleep(0.1)

    scp:flushGC()

    if scp:isRemoved() then
        return
    end

    local ld <close> = loading.create(scp)
    scp:set('loading', ld)

    log.info('Preload start:', scp:getName())

    local native   = m.getNativeMatcher(scp)
    local librarys = m.getLibraryMatchers(scp)

    if scp.uri and not scp:get('bad root') then
        log.info('Scan files at:', scp:getName())
        scp:gc(fw.watch(files.normalize(furi.decode(scp.uri)), true, function (path)
            local rpath = m.getRelativePath(path)
            if native(rpath) then
                return false
            end
            return true
        end))
        local count = 0
        ---@async
        native:scan(furi.decode(scp.uri), function (path)
            local uri = files.getRealUri(furi.encode(path))
            local cachedUris = scp:get('cachedUris') --[[@as table<any, any>]]
            cachedUris[uri] = true
            ld:loadFile(uri)
        end, function (_) ---@async
            count = (count + 1) --[[@as integer]]
            if count == 100000 then
                client.showMessage('Warning', lang.script('WORKSPACE_SCAN_TOO_MUCH', count, furi.decode(scp.uri)))
            end
        end)
    end

    for _, libMatcher in ipairs(librarys) do
        log.info('Scan library at:', libMatcher.uri)
        local count = 0
        scp:gc(fw.watch(furi.decode(libMatcher.uri), true, function (path)
            local rpath = m.getRelativePath(path)
            if libMatcher.matcher(rpath) then
                return false
            end
            return true
        end))
        if not libMatcher.isDofile then
            scp:addLink(libMatcher.uri)
        end
        ---@async
        libMatcher.matcher:scan(furi.decode(libMatcher.uri), function (path)
            local uri = files.getRealUri(furi.encode(path))
            local cachedUris = scp:get('cachedUris') --[[@as table<any, any>]]
            cachedUris[uri] = true
            ld:loadFile(uri, libMatcher.uri)
        end, function () ---@async
            count = (count + 1) --[[@as integer]]
            if count == 100000 then
                client.showMessage('Warning', lang.script('WORKSPACE_SCAN_TOO_MUCH', count, furi.decode(libMatcher.uri)))
            end
        end)
    end

    -- must wait for other scopes to add library
    await.sleep(0.1)

    log.info(('Found %d files at:'):format(ld.max), scp:getName())
    ld:loadAll(scp:getName())
    log.info('Preload finish at:', scp:getName())
end

--- 查找符合指定file path的所有uri
---@param path string
---@return uri[]
function m.findUrisByFilePath(path)
    local uri = furi.encode(path)
    local vm    = require 'vm'
    local resultCache = vm.getCache 'findUrisByFilePath.result' --[[@as table<string, uri[]>]]
    if resultCache[path] then
        return resultCache[path]
    end
    ---@type uri[]
    local results = {}
    if files.exists(uri) then
        results = { uri }
    end
    resultCache[path] = results
    return results
end


---@param path string
---@param sourceUri? uri
---@return uri[]
function m.findUrisByDofile(path, sourceUri)
    if not fs.path(path):is_relative() then
        return m.findUrisByFilePath(path)
    end

    ---@type string[]
    local roots = config.get(sourceUri, 'Lua.workspace.dofileRoots')
    ---@type uri[]
    local results = {}

    ---@param absPath? string
    local function addResult(absPath)
        if not absPath then
            return
        end
        local uris = m.findUrisByFilePath(absPath)
        for _, uri in ipairs(uris) do
            results[#results+1] = uri
        end
    end

    for _, root in ipairs(roots) do
        local rootPath = m.getAbsolutePath(sourceUri or m.rootUri, root)
        if rootPath then
            local rootUri = furi.encode(rootPath)
            addResult(m.getAbsolutePath(rootUri, path))
        end
    end

    if  m.rootUri then
        addResult(m.getAbsolutePath(m.rootUri, path))
    end

    return results
end


---@param folderUri? uri
---@param path string
---@return string?
function m.getAbsolutePath(folderUri, path)
    path = files.normalize(path)
    if fs.path(path):is_relative() then
        if not folderUri then
            return nil
        end
        local folderPath = furi.decode(folderUri)
        path = files.normalize(folderPath .. '/' .. path)
    end
    return path
end

---@param uriOrPath uri|string
---@return string
---@return boolean suc
function m.getRelativePath(uriOrPath)
    ---@type string, string
    local path, uri
    if uriOrPath:sub(1, 5) == 'file:' then
        path = furi.decode(uriOrPath)
        uri  = uriOrPath
    else
        path = uriOrPath
        uri  = furi.encode(uriOrPath)
    end
    local scp = scope.getScope(uri)
    if not scp.uri then
        local relative = files.normalize(path)
        return relative:gsub('^[/\\]+', ''), false
    end
    local _, pos = files.normalize(path):find(furi.decode(scp.uri), 1, true)
    if pos then
        return files.normalize(path:sub(pos + 1)):gsub('^[/\\]+', ''), true
    else
        return files.normalize(path):gsub('^[/\\]+', ''), false
    end
end

---@param scp scope
function m.reload(scp)
    ---@async
    await.call(function ()
        m.awaitReload(scp)
    end)
end

function m.init()
    if m.rootUri then
        for _, folder in ipairs(scope.folders) do
            m.reload(folder)
        end
    end
    m.reload(scope.fallback)
end

---@param scp scope
function m.flushFiles(scp)
    local cachedUris = scp:get 'cachedUris'
    scp:set('cachedUris', {})
    if not cachedUris then
        return
    end
    for uri in pairs(cachedUris --[[@as table<any, any>]]) do
        files.delRef(uri)
    end
end

---@param scp scope
function m.resetFiles(scp)
    local cachedUris = scp:get 'cachedUris'
    if cachedUris then
        for uri in pairs(cachedUris --[[@as table<any, any>]]) do
            files.resetText(uri)
        end
    end
    for uri in pairs(files.openMap --[[@as table<any, any>]]) do
        if scope.getScope(uri) == scp then
            files.resetText(uri)
        end
    end
end

---@async
---@param scp scope
function m.awaitReload(scp)
    await.unique('workspace reload:' .. scp:getName())
    await.sleep(0.1)
    scp:set('ready', false)
    scp:set('nativeMatcher', nil)
    scp:set('libraryMatcher', nil)
    scp:removeAllLinks()
    m.flushFiles(scp)
    m.onWatch('startReload', scp.uri)
    m.awaitPreload(scp)
    scp:set('ready', true)
    local waiting = scp:get('waitingReady')
    if waiting then
        scp:set('waitingReady', nil)
        for _, waker in ipairs(waiting --[[@as function[] ]]) do
            waker()
        end
    end

    m.onWatch('reload', scp.uri)
end

---@return scope
function m.getFirstScope()
    return m.folders[1] or scope.fallback
end

---等待工作目录加载完成
---@async
---@param uri? uri
function m.awaitReady(uri)
    if m.isReady(uri) then
        return
    end
    local scp = scope.getScope(uri)
    local waitingReady = scp:get('waitingReady')
                    or   scp:set('waitingReady', {})
    await.wait(function (waker)
        (waitingReady --[[@as table<any, any>]])[#waitingReady+1] = waker
    end)
end

---@param uri? uri
---@return boolean
function m.isReady(uri)
    local scp = scope.getScope(uri)
    return scp:get('ready') == true
end

---@return boolean
function m.isAllReady()
    local scp = scope.fallback
    if not scp:get 'ready' then
        return false
    end
    for _, folder in ipairs(scope.folders) do
        if not folder:get 'ready' then
            return false
        end
    end
    return true
end

---@param uri uri
---@return integer read
---@return integer max
function m.getLoadingProcess(uri)
    local scp = scope.getScope(uri)
    ---@type workspace.loading
    local ld  = scp:get 'loading'
    if ld then
        return ld.read, ld.max
    else
        return 0, 0
    end
end

config.watch(function (uri, key, value, oldValue)
    if key:find '^Lua.runtime'
    or key:find '^Lua.workspace'
    or key:find '^Lua.type'
    or key:find '^files' then
        if value ~= oldValue then
            local scp = scope.getScope(uri)
            m.reload(scp)
            m.resetFiles(scp)
        end
    end
end)

fw.event(function (ev, path) ---@async
    local uri  = furi.encode(path)

    if     ev == 'create' then
        log.debug('FileChangeType.Created', uri)
        m.awaitLoadFile(uri)
    elseif ev == 'delete' then
        log.debug('FileChangeType.Deleted', uri)
        files.remove(uri)
        m.removeFile(uri)
        local childs = files.getChildFiles(uri)
        for _, curi in ipairs(childs) do
            log.debug('FileChangeType.Deleted.Child', curi)
            files.remove(curi)
            m.removeFile(uri)
        end
    elseif ev == 'change' then
        if m.isValidLuaUri(uri) then
            -- 如果文件处于关闭状态，则立即更新；否则等待didChange协议来更新
            if not files.isOpen(uri) then
                files.setText(uri, pub.awaitTask('loadFile', furi.decode(uri)), false)
            end
        end
    end

    local filename = fs.path(path):filename():string()
    -- 排除类文件发生更改需要重新扫描
    if filename == '.gitignore'
    or filename == '.gitmodules' then
        local scp = scope.getScope(uri)
        if scp.type ~= 'fallback' then
            m.reload(scp)
        end
    end
end)

return m
