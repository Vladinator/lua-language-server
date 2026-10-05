-- Every `Lua.*` setting of the template has an English text, and so has each value of an enumerated setting that the
-- schema describes: the VS Code extension shows these in the settings UI and the completion of `.vscode/settings.json`
-- (`tools/sync_dev_extension.py` copies them, the release build reads them), a missing one shows the raw key.
local template = require 'config.template'
local loader   = require 'locale-loader'
local util     = require 'utility'

local text = util.loadFile('locale/en-us/setting.lua')
assert(text, 'locale/en-us/setting.lua')
---@type table<string, any>
local texts = {}
loader(text, 'locale/en-us/setting.lua', texts)

---@type string[]
local missing = {}
for name, unit in pairs(template) do
    if name:sub(1, 4) == 'Lua.' then
        local key = 'config.' .. name:sub(5)
        if not texts[key] then
            missing[#missing+1] = key
        end
        -- the values of a plain string enum (`Lua.annotations.dialects` items, `Lua.runtime.version`, ...)
        local sub = unit.sub or unit
        local enums = sub.enums
        if type(enums) == 'table' and name == 'Lua.annotations.dialects' then
            for _, value in ipairs(enums) do
                if not texts[key .. '.' .. value] then
                    missing[#missing+1] = key .. '.' .. value
                end
            end
        end
    end
end
table.sort(missing)
assert(#missing == 0, 'settings without an English text: ' .. table.concat(missing, ', '))
