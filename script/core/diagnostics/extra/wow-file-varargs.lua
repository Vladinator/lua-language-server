-- The two arguments the game passes to every file of a WoW addon: the addon's folder name and one table shared by all the
-- addon's files, so `local addonName, ns = ...` at the top of a file gets `string` and `table`. A feature plugin (it
-- registers no diagnostic): it answers the core's `vm.registerMainVarargProvider` for the files that have a `.toc`
-- (found by wow-toc.lua), when `Lua.workspace.tocFileArguments` is on. WoW-specific, so it is a plugin; deleting this file
-- removes it. Its tests are next to it.

local config = require 'config'
local vm     = require 'vm'

vm.registerMainVarargProvider(function (uri, index)
    if not config.get(uri, 'Lua.workspace.tocFileArguments') then
        return nil
    end
    -- (looked up when asked, not required: the plugins are loaded in no particular order)
    ---@type {findToc: fun(uri: uri): table<string, true>?}?
    local toc = package.loaded['core.diagnostics.extra.wow-toc']
    if not toc or not toc.findToc(uri) then
        return nil
    end
    if index == 1 then
        return 'string'
    elseif index == 2 then
        return 'table'
    end
    return nil
end)
