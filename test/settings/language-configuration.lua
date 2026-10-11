-- `Lua.language.completeAnnotation`: pressing Enter inside a `---` comment continues it with the same prefix; off, the editor gets no such rule.
local config   = require 'config'
local langConf = require 'provider.language-configuration'

--- The text the Enter rules of the configuration append, in order.
---@return string[]
local function appended()
    local result = langConf.make()
    ---@type string[]
    local texts = {}
    for _, rule in ipairs(result.configuration.onEnterRules or {}) do
        if rule.action and rule.action.appendText then
            texts[#texts+1] = rule.action.appendText
        end
    end
    return texts
end

---@param texts string[]
---@param text  string
---@return boolean
local function has(texts, text)
    for _, t in ipairs(texts) do
        if t == text then
            return true
        end
    end
    return false
end

local saved = config.get(nil, 'Lua.language.completeAnnotation')

config.set(nil, 'Lua.language.completeAnnotation', true)
local on = appended()
assert(has(on, '---@') and has(on, '--- @') and has(on, '--- ') and has(on, '---'), 'on: the comment is continued with its own prefix')

config.set(nil, 'Lua.language.completeAnnotation', false)
local off = appended()
assert(not has(off, '---@') and not has(off, '---'), 'off: no rule continues a comment')
assert(#on > #off, 'the rules of the other features stay either way')

config.set(nil, 'Lua.language.completeAnnotation', saved)
