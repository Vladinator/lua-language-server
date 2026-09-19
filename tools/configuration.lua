local json     = require 'json'
local template = require 'config.template'
local util     = require 'utility'
-- Diagnostics that self-register (core/diagnostics/init.lua's eager list,
-- core/diagnostics/extra/ plugins) only exist in the registry once their file
-- ran; load them all before anything below reads the diagnostic names or defaults.
-- (the extras scan needs the server root; a normal server start has set it, a
-- standalone `bin/lua-language-server tools/build-doc.lua` run has not.)
if not ROOT then
    local fs  = require 'bee.filesystem'
    local sys = require 'bee.sys'
    ---@diagnostic disable-next-line: lowercase-global, inject-field, undefined-global
    ROOT = fs.path(sys.exe_path():parent_path():parent_path():string())
end
require 'core.diagnostics'
local diagd    = require 'proto.diagnostic'

--- The template's diagnostic key sets are computed from the live registry (functions),
--- and its `default` tables are a snapshot taken before the plugins registered. Use the
--- live registry for both so the schema lists every diagnostic, plugins included.
---@type table<string, table<string, string>>
local liveDefaults = {
    ['Lua.diagnostics.severity']        = diagd.getDefaultSeverity(),
    ['Lua.diagnostics.neededFileStatus'] = diagd.getDefaultStatus(),
    ['Lua.diagnostics.groupSeverity']   = diagd.getGroupSeverity(),
    ['Lua.diagnostics.groupFileStatus'] = diagd.getGroupStatus(),
}

--- `enums` can be a list or a function that computes it (see the diagnostics entries in
--- config/template.lua); the schema needs the list.
---@param enums (any[]|fun(): any[])?
---@return any[]?
local function resolveEnums(enums)
    if type(enums) == 'function' then
        return (enums --[[@as fun(): any[] ]])()
    end
    return enums --[[@as any[]?]]
end

---@alias tools.configuration.type string|tools.configuration.type[]

---@param temp config.unit
---@return tools.configuration.type
local function getType(temp)
    if temp.name == 'Boolean' then
        return 'boolean'
    end
    if temp.name == 'String' then
        return 'string'
    end
    if temp.name == 'Integer' then
        return 'integer'
    end
    if temp.name == 'Nil' then
        return 'null'
    end
    if temp.name == 'Array' then
        return 'array'
    end
    if temp.name == 'Hash' then
        return 'object'
    end
    if temp.name == 'Or' then
        local subs = assert(temp.subs)
        return { getType(subs[1]), getType(subs[2]) }
    end
    error('Unknown type: ' .. temp.name)
end

---@param temp config.unit
---@return any
local function getDefault(temp)
    local default = temp.default
    if default == nil and temp.hasDefault then
        default = json.null
    end
    if  type(default) == 'table'
    and not next(default)
    and getType(temp) == 'object' then
        default = json.createEmptyObject()
    end
    return default
end

---@param temp config.unit
---@return any[]?
local function getEnum(temp)
    return resolveEnums(temp.enums)
end

---@param name string
---@param temp config.unit
---@return string[]?
local function getEnumDesc(name, temp)
    -- Array 类型的枚举挂在子单元 sub.enums 上（如 Lua.runtime.nonstandardSymbol）
    local enums = resolveEnums(temp.enums or (temp.sub and temp.sub.enums))
    if not enums then
        return nil
    end
    ---@type string[]
    local descs = {}
    -- Lua.diagnostics.disable 的枚举（诊断名）复用 locale 中已有的
    -- config.diagnostics.<诊断名> 描述，避免为 disable 单独维护一份文案
    local head = (name == 'Lua.diagnostics.disable' and '%config.diagnostics')
              or name:gsub('^Lua', '%%config')

    -- 生成的 locale 键名必须与 script/locale-loader.lua 的 mergeKey 规则一致：
    -- 字母开头的枚举用 `.` 连接，非字母开头（如 ?.、~=、->）不加点
    for _, enum in ipairs(enums) do
        if enum:sub(1, 1):match '%w' then
            descs[#descs+1] = head .. '.' .. enum .. '%'
        else
            descs[#descs+1] = head .. enum .. '%'
        end
    end

    return descs
end

---@class tools.configuration.schema
---@field scope? string
---@field type? tools.configuration.type
---@field default any
---@field enum? any[]
---@field markdownDescription? string
---@field description? string
---@field markdownEnumDescriptions? string[]
---@field items? tools.configuration.schema
---@field title? string
---@field additionalProperties? boolean
---@field properties? table<string, tools.configuration.schema>
---@field patternProperties? table<string, tools.configuration.schema>

---@param conf tools.configuration.schema
---@param temp config.unit
local function insertArray(conf, temp)
    local sub = assert(temp.sub)
    conf.items = {
        type = getType(sub),
        enum = getEnum(sub),
    }
end

---@param name string
---@param conf tools.configuration.schema
---@param temp config.unit
local function insertHash(name, conf, temp)
    conf.title = name:match '[^%.]+$'
    conf.additionalProperties = false

    local subvalue = assert(temp.subvalue)
    if liveDefaults[name] then
        conf.default = liveDefaults[name]
    end
    if type(conf.default) == 'table' and next(conf.default) then
        local default = conf.default
        conf.default = nil
        conf.properties = {}
        local descHead = name:gsub('^Lua', '%%config')
        if util.stringStartWith(descHead, '%config.diagnostics') then
            descHead = '%config.diagnostics'
        end
        for key, value in pairs(default --[[@as table<string, any>]]) do
            conf.properties[key] = {
                type    = getType(subvalue),
                default = value,
                enum    = getEnum(subvalue),
                description = descHead .. '.' .. key .. '%',
            }
        end
    else
        conf.patternProperties = {
            ['.*'] = {
                type    = getType(subvalue),
                default = getDefault(subvalue),
                enum    = getEnum(subvalue),
            }
        }
    end
end

---@type table<string, tools.configuration.schema>
local config = {}

for name, temp in pairs(template) do
    if not util.stringStartWith(name, 'Lua.') then
        goto CONTINUE
    end
    config[name] = {
        scope   = 'resource',
        type    = getType(temp),
        default = getDefault(temp),
        enum    = getEnum(temp),

        markdownDescription      = name:gsub('^Lua', '%%config') .. '%',
        markdownEnumDescriptions = getEnumDesc(name, temp),
    }

    if temp.name == 'Array' then
        insertArray(config[name], temp)
    end

    if temp.name == 'Hash' then
        insertHash(name, config[name], temp)
    end

    ::CONTINUE::
end

return config
