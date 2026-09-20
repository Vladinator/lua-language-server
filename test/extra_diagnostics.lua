-- The diagnostics that plugins provide from script/core/diagnostics/extra/ (a plugin is
-- a `<name>.lua` there; `<name>.test.lua` is its test). Tests that check what every plugin has in
-- common use this list instead of naming one: with a plugin removed, the list is shorter and the
-- test still holds.
local fs = require 'bee.filesystem'

---@return string[]
return function ()
    ---@type string[]
    local names = {}
    local dir = ROOT / 'script' / 'core' / 'diagnostics' / 'extra'
    if fs.exists(dir) then
        for path in fs.pairs(dir) do
            local fileName = path:filename():string()
            local name = fileName:match('^(.+)%.lua$')
            if name and not name:match('%.test$') then
                names[#names+1] = name
            end
        end
    end
    table.sort(names)
    return names
end
