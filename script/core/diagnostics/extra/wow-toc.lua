-- A feature plugin (it registers no diagnostic): the variables a WoW addon's `.toc` file declares with `## SavedVariables:` (and the per-character / machine
-- variants): the game creates those globals before the addon's Lua runs, so they are defined without any Lua
-- assignment. With `Lua.workspace.tocSavedVariables` on, the global checks (undefined-global, lowercase-global,
-- global-element) treat them as known, through `vm.registerGlobalProvider`. WoW-specific, so it is a plugin; deleting
-- this file removes it. Its tests are next to it. The `.toc` of a Lua file is the one in its own folder, or in the nearest
-- folder above it that has one, up to the workspace folder.
local fs    = require 'bee.filesystem'
local furi  = require 'file-uri'
local scope = require 'workspace.scope'
local config = require 'config'
local vm    = require 'vm'

local m = {}

---@alias workspace.toc.vars table<string, true>

--- How long what was read from the disk is trusted (seconds): the global checks ask for every global they see.
m.TTL = 3

local KEYS = {
    ['savedvariables']             = true,
    ['savedvariablespercharacter'] = true,
    ['savedvariablesmachine']      = true,
}

--- The variables a `.toc` text declares.
---@param text string
---@return workspace.toc.vars
function m.parse(text)
    ---@type workspace.toc.vars
    local vars = {}
    for line in text:gmatch('[^\r\n]+') do
        ---@type string?, string?
        local key, rest = line:match('^##%s*([%w_%-]+)%s*:%s*(.*)$')
        if key and rest and KEYS[key:lower()] then
            for name in rest:gmatch('[^,%s]+') do
                vars[name] = true
            end
        end
    end
    return vars
end

---@type table<string, {time: number, vars: workspace.toc.vars}>  folder path -> the variables of its `.toc` files
local dirCache = {}

function m.clearCache()
    dirCache = {}
end

--- The variables the `.toc` files directly in `dir` declare (nil: no `.toc` there).
---@param dir string
---@return workspace.toc.vars?
local function readDir(dir)
    local cached = dirCache[dir]
    local now = os.clock()
    if cached and now - cached.time < m.TTL then
        return next(cached.vars) ~= nil and cached.vars or nil
    end
    ---@type workspace.toc.vars
    local vars = {}
    local ok = pcall(function ()
        for entry in fs.pairs(fs.path(dir)) do
            if entry:filename():string():lower():match('%.toc$') then
                local file = io.open(entry:string(), 'rb')
                if file then
                    local text = file:read('a')
                    file:close()
                    for name in pairs(m.parse(text)) do
                        vars[name] = true
                    end
                end
            end
        end
    end)
    dirCache[dir] = { time = now, vars = ok and vars or {} }
    return next(vars) ~= nil and vars or nil
end

--- Whether the `.toc` of the file `uri` declares `name` as a saved variable.
---@param uri  uri
---@param name string
---@return boolean
function m.isSavedVariable(uri, name)
    local path = furi.decode(uri)
    if not path then
        return false
    end
    local scp  = scope.getFolder(uri)
    local root = scp and scp.uri and furi.decode(scp.uri) or nil
    local dir  = path:match('^(.*)[/\\][^/\\]*$')
    -- upward to the workspace folder (without one: the file's own folder only)
    for _ = 1, 16 do
        if not dir then
            break
        end
        local vars = readDir(dir)
        if vars then
            return vars[name] == true
        end
        if not root or dir == root or #dir <= #root then
            break
        end
        dir = dir:match('^(.*)[/\\][^/\\]*$')
    end
    return false
end

-- (the plugin file is not `require`d, so its tests reach it through package.loaded)
package.loaded['core.diagnostics.extra.wow-toc'] = m

vm.registerGlobalProvider(function (uri, name)
    return config.get(uri, 'Lua.workspace.tocSavedVariables') and m.isSavedVariable(uri, name)
end)
