-- `name-style-check` and `Lua.nameStyle.config`: a name that breaks the configured rule is reported, and the rule decides which names do.
-- (The formatter library that does the check has default rules of its own, so every case sets the rule it relies on. A rule is the
-- name of a style as a string: `snake_case`, `camel_case`, `pascal_case`, `upper_snake_case`.)
local config = require 'config'
local timer  = require 'timer'

--- A change of a setting reaches its watchers on the next tick of the timer (the formatter library is told then).
---@param rule table
local function setRule(rule)
    config.set(nil, 'Lua.nameStyle.config', rule)
    timer.update()
end

setRule({ local_name_style = 'snake_case' })

-- a module-level local has to be snake_case
TEST [[
local <!camelCaseName!> = 1
local snake_case_name = 2
print(camelCaseName, snake_case_name)
]]

-- the other rule turns the verdict around
setRule({ local_name_style = 'camel_case' })
TEST [[
local camelCaseName = 1
local <!snake_case_name!> = 2
print(camelCaseName, snake_case_name)
]]

-- the rule for local functions is its own key
setRule({ local_function_name_style = 'pascal_case' })
TEST [[
local function <!lowerName!>() end
local function UpperName() end
lowerName()
UpperName()
]]

setRule({})
