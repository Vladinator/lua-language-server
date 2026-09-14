local suc, codeFormat = pcall(require, 'code_format')
if not suc then
    return
end

local config = require 'config'

local m = {}

m.loaded = false

---@class provider.nameStyle.diagnosticInfo
---@field range   { start: position, ["end"]: position }
---@field message string
---@field data?    any

---@param uri  uri
---@param text string?
---@return boolean status
---@return provider.nameStyle.diagnosticInfo[]|string|nil diagnosticInfos # a list of findings when status is true, an error message (or nothing) when false
function m.nameStyleCheck(uri, text)
    if not m.loaded then
        local value = config.get(uri, "Lua.nameStyle.config")
        codeFormat.update_name_style_config(value)
        m.loaded = true
    end

    return codeFormat.name_style_analysis(uri, text)
end

config.watch(function (_uri, key, value)
    if key == "Lua.nameStyle.config" then
        codeFormat.update_name_style_config(value)
    end
end)

return m
