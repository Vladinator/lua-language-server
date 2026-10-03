-- The two arguments the game passes to every file of a WoW addon: the addon's folder name and one table shared by all the
-- addon's files, so `local addonName, ns = ...` at the top of a file gets the folder name as a string literal and `ns`
-- becomes the class `<Folder>NS`, which accepts new keys like the class a `---@class` written on that line defines. A
-- feature plugin (it registers no diagnostic): it answers the core's `vm.registerMainVarargProvider`, and a built-in
-- `OnSetText` (`plugin.registerBuiltin`) writes that `---@class` for the user, for the files that have a `.toc` (found
-- by wow-toc.lua), when `Lua.workspace.tocFileArguments` is on. A `---@class` / `---@type` the user wrote on or above the
-- line is respected: nothing is added then. WoW-specific, so it is a plugin; deleting this file removes it. Its tests are
-- next to it.

local config = require 'config'
local vm     = require 'vm'
local plugin = require 'plugin'

---@class wow-file-varargs.toc
---@field findToc fun(uri: uri): table<string, true>?, string?

--- The `.toc` plugin, when the setting is on and the file has one: its module and the addon's folder name.
---@param uri uri
---@return wow-file-varargs.toc?
---@return string? folder
local function tocOf(uri)
    if not config.get(uri, 'Lua.workspace.tocFileArguments') then
        return nil
    end
    -- (looked up when asked, not required: the plugins are loaded in no particular order)
    ---@type wow-file-varargs.toc?
    local toc = package.loaded['core.diagnostics.extra.wow-toc']
    if not toc then
        return nil
    end
    local vars, dir = toc.findToc(uri)
    if not vars or not dir then
        return nil
    end
    return toc, dir:match('([^/\\]+)$')
end

vm.registerMainVarargProvider(function (uri, index)
    local _, folder = tocOf(uri)
    if not folder then
        return nil
    end
    if index == 1 then
        return '"' .. folder .. '"'
    elseif index == 2 then
        return 'table'
    end
    return nil
end)

--- The class name of the namespace: the setting's template with `{addon}` replaced by the folder name (letters, digits
--- and underscores only).
---@param uri    uri
---@param folder string
---@return string
local function className(uri, folder)
    local template = config.get(uri, 'Lua.workspace.tocNamespaceClass')
    if type(template) ~= 'string' or template == '' then
        template = '{addon}NS'
    end
    local addon = folder:gsub('[^%w_]', '_')
    return (template:gsub('{addon}', function () return addon end))
end

--- Whether `line` (or the one above it) already carries an annotation of the user's.
---@param line string
---@param above string
---@return boolean
local function annotated(line, above)
    return line:find('%-%-') ~= nil or above:match('^%s*%-%-%-%s*@class') ~= nil or above:match('^%s*%-%-%-%s*@type') ~= nil
end

plugin.registerBuiltin {
    ---@param uri  uri
    ---@param text string
    ---@return string.merger.diff[]?
    OnSetText = function (uri, text)
        local _, folder = tocOf(uri)
        if not folder then
            return nil
        end
        local class = className(uri, folder)
        local pos   = 1
        local above = ''
        for _ = 1, 400 do
            local lineEnd = text:find('\n', pos, true) or (#text + 1)
            local raw  = text:sub(pos, lineEnd - 1)
            local line = raw:gsub('\r$', '')
            -- the declaration of the file's arguments, at column 0 (the top level of the file)
            local a, b = line:match('^local%s+([%a_][%w_]*)%s*,%s*([%a_][%w_]*)%s*=%s*%.%.%.%s*$')
            if a and b and not annotated(line, above) then
                return {
                    {
                        start  = pos,
                        finish = pos + #line - 1,
                        -- (two lines: a trailing `---@class` belongs to the first local of its line)
                        text   = ('local %s = ...' .. string.char(10) .. 'local %s = select(2, ...) ---@class %s'):format(a, b, class),
                    },
                }
            end
            local single = line:match('^local%s+([%a_][%w_]*)%s*=%s*select%(%s*2%s*,%s*%.%.%.%s*%)%s*$')
            if single and not annotated(line, above) then
                local last = pos + #line - 1
                return {
                    {
                        start  = last,
                        finish = last,
                        text   = line:sub(-1) .. ' ---@class ' .. class,
                    },
                }
            end
            if lineEnd > #text then
                break
            end
            if line:match('%S') then
                above = line
            end
            pos = lineEnd + 1
        end
        return nil
    end,
}
