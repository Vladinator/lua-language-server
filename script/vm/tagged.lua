local files = require 'files'
local guide = require 'parser.guide'
---@class vm
local vm = require 'vm.vm'
local scope = require 'workspace.scope'

-- An index of the functions that carry a LuaDoc tag, for a plugin that has to look at EVERY call of a workspace but only cares about the
-- callees with that tag. The names of the tagged functions are collected once per file (dropped with the file's cache when it changes) and
-- once per scope (dropped with `vm.getCache`), so `match` answers a call of any other function from a table lookup and compiles nothing.
-- That is what a rule asked about every call (`vm.registerFlowNarrowing { statement = true }`, a genesis rule of `call`) needs; resolving the
-- callee through `vm.getDefs` is what `docsOf` does, and only for the calls `match` let through.

---@class vm.taggedDoc
---@field doc  parser.object the tag
---@field func parser.object the function it is bound to

---@class vm.taggedIndex
---@field any    fun(uri: uri): boolean   does the file, or its workspace, have a function with such a tag at all?
---@field match  fun(callee: parser.object): boolean   could a function with such a tag be called here (by name)?
---@field docsOf fun(callee: parser.object): vm.taggedDoc[]   the tags of the functions the callee can be

--- The name a function is known by: `local function f`, `function M.f`, `function M:f`, `M.f = function`, `{ f = function ... }`.
---@param source parser.object?
---@return string?
local function nameOf(source)
    if not source then
        return nil
    end
    if source.type == 'function' then
        source = source.parent
        if not source then
            return nil
        end
    end
    local t = source.type
    if t == 'local' or t == 'setlocal' or t == 'setglobal' then
        return source[1]
    elseif t == 'setfield' or t == 'tablefield' then
        return source.field and source.field[1] --[[@as string?]]
    elseif t == 'setmethod' then
        return source.method and source.method[1] --[[@as string?]]
    end
    return nil
end

---@param callee parser.object
---@return string?
local function calleeName(callee)
    local t = callee.type
    if t == 'getlocal' or t == 'getglobal' then
        return callee[1]
    elseif t == 'getfield' then
        return callee.field and callee.field[1]
    elseif t == 'getmethod' then
        return callee.method and callee.method[1]
    end
    return nil
end

--- The function a tag is bound to (the docs are bound to the function and to what it is assigned to).
---@param def parser.object
---@return parser.object?
local function functionOf(def)
    if def.type == 'function' then
        return def
    end
    if def.value and def.value.type == 'function' then
        return def.value
    end
    return nil
end

---@param key      string unique name of the index
---@param isTagged fun(doc: parser.object): boolean
---@return vm.taggedIndex
function vm.createTaggedIndex(key, isTagged)
    local fileKey  = 'tagged.' .. key
    local scopeKey = 'tagged.' .. key

    ---@param uri uri
    ---@return table<string, true>|false
    local function getFileNames(uri)
        local cache = files.getCache(uri) --[[@as table<string, table<string, true>|false>?]]
        if not cache then
            return false
        end
        ---@type table<string, true>|false|nil
        local names = cache[fileKey]
        if names ~= nil then
            return names
        end
        ---@type table<string, true>
        local found = {}
        local state = files.getState(uri)
        for _, doc in ipairs(state and state.ast.docs or {}) do
            if isTagged(doc) then
                -- a name that cannot be found matches every callee (the price is only the lookup)
                found[nameOf(doc.bindSource) or '*'] = true
            end
        end
        names = next(found) ~= nil and found
        cache[fileKey] = names
        return names
    end

    ---@param uri uri
    ---@return table<string, true>
    local function getNames(uri)
        local cache = vm.getCache(scopeKey) --[[@as table<string, table<string, true>>]]
        local name  = scope.getScope(uri):getName()
        local names = cache[name]
        if names then
            return names
        end
        ---@type table<string, true>
        names = {}
        for fileUri in files.eachFile(uri) do
            local fileNames = getFileNames(fileUri)
            if fileNames then
                for found in pairs(fileNames) do
                    names[found] = true
                end
            end
        end
        cache[name] = names
        return names
    end

    ---@type vm.taggedIndex
    local index = {
        any = function (uri)
            return getFileNames(uri) ~= false or next(getNames(uri)) ~= nil
        end,
        match = function (callee)
            local name = calleeName(callee)
            if not name then
                return false
            end
            local uri = guide.getUri(callee)
            -- (the file itself first: a file that is not part of a workspace is in no scope's list of files)
            local own = getFileNames(uri)
            if own and (own[name] or own['*']) then
                return true
            end
            local names = getNames(uri)
            return names[name] == true or names['*'] == true
        end,
        docsOf = function (callee)
            ---@type vm.taggedDoc[]
            local found = {}
            ---@type table<parser.object, true>
            local seen = {}
            for _, def in ipairs(vm.getDefs(callee)) do
                local func = functionOf(def)
                if func then
                    for _, holder in ipairs(func == def and { func } or { func, def }) do
                        for _, doc in ipairs(holder.bindDocs or {}) do
                            if isTagged(doc) and not seen[doc] then
                                seen[doc] = true
                                found[#found+1] = { doc = doc, func = func }
                            end
                        end
                    end
                end
            end
            return found
        end,
    }
    return index
end
