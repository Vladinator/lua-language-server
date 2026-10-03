-- The diagnostics that plugins provide from script/core/diagnostics/extra/ (a plugin is
-- a `<name>.lua` there; `<name>.test.lua` is its test). Tests that check what every plugin has in
-- common use this list instead of naming one: with a plugin removed, the list is shorter and the
-- test still holds. A plugin that registers no diagnostic (a feature plugin: aliases, known globals) is
-- not in the list.
local fs    = require 'bee.filesystem'
local diagd = require 'proto.diagnostic'

---@return string[]
return function ()
    ---@type string[]
    local names = {}
    local dir = ROOT / 'script' / 'core' / 'diagnostics' / 'extra'
    if fs.exists(dir) then
        for path in fs.pairs(dir) do
            local fileName = path:filename():string()
            local name = fileName:match('^(.+)%.lua$')
            if name and not name:match('%.test$') and diagd.diagnosticDatas[name] then
                names[#names+1] = name
            end
        end
    end
    table.sort(names)
    return names
end
