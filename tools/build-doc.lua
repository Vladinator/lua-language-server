package.path = package.path .. ';script/?.lua;script/?/init.lua;tools/?.lua;tools/?/init.lua'

log = require 'log'
local fs       = require 'bee.filesystem'
---@type table<string, tools.configuration.schema>
local config   = require 'configuration'
local markdown = require 'provider.markdown'
local util     = require 'utility'
local lloader  = require 'locale-loader'
local json     = require 'json-beautify'
local diagd    = require 'proto.diagnostic'

---@param locale table<string, any>
local function mergeDiagnosticGroupLocale(locale)
    for groupName, names in pairs(diagd.diagnosticGroups) do
        local key = ('config.diagnostics.%s'):format(groupName)
        ---@type string[]
        local list = {}
        for name in util.sortPairs(names) do
            list[#list+1] = ('* %s'):format(name)
        end
        local desc = table.concat(list, '\n')
        locale[key] = desc
    end
end

---@return table<string, table<string, any>>
local function getLocale()
    ---@type table<string, table<string, any>>
    local locale = {}

    for dirPath in fs.pairs(fs.path 'locale') do
        local lang = dirPath:filename():string()
        local text = util.loadFile((dirPath / 'setting.lua'):string())
        if text then
            locale[lang] = lloader(text, lang)
            -- add `config.diagnostics.XXX`
            mergeDiagnosticGroupLocale(locale[lang])
        end
    end

    return locale
end

local localeMap = getLocale()

---@param lang string
---@param desc string?
---@return string?
local function getDesc(lang, desc)
    if not desc then
        return nil
    end
    if desc:sub(1, 1) ~= '%' or desc:sub(-1, -1) ~= '%' then
        return desc
    end
    local locale = localeMap[lang]
    if not locale then
        return desc
    end
    local id = desc:sub(2, -2)
    return locale[id]
end

---@param conf tools.configuration.schema
---@return string
local function view(conf)
    if type(conf.type) == 'table' then
        ---@type string[]
        local subViews = {}
        for i = 1, #conf.type do
            subViews[i] = conf.type[i] --[[@as string]]
        end
        return table.concat(subViews, ' | ')
    elseif conf.type == 'array' then
        return ('Array<%s>'):format(view(assert(conf.items)))
    elseif conf.type == 'object' then
        if conf.properties then
            local _, first = next(conf.properties)
            assert(first)
            return ('object<string, %s>'):format(view(first))
        elseif conf.patternProperties then
            local _, first = next(conf.patternProperties)
            assert(first)
            return ('Object<string, %s>'):format(view(first))
        else
            return '**Unknown object type!!**'
        end
    else
        return tostring(conf.type)
    end
end

---@param md markdown
---@param lang string
---@param conf tools.configuration.schema
local function buildType(md, lang, conf)
    md:add('md', '## type')
    md:add('ts', view(conf))
end

---@param md markdown
---@param lang string
---@param conf tools.configuration.schema
local function buildDesc(md, lang, conf)
    local desc = conf.markdownDescription or conf.description
    desc = getDesc(lang, desc)
    if desc then
        md:add('md', desc)
    else
        md:add('md', '**Missing description!!**')
    end
    md:emptyLine()
end

---@param md markdown
---@param lang string
---@param conf tools.configuration.schema
local function buildDefault(md, lang, conf)
    local default = conf.default
    if default == json.null then
        default = nil
    end
    md:add('md', '## default')
    if conf.type == 'object' then
        if not default then
            ---@type table<string, any>
            local newDefault = {}
            for k, v in pairs(assert(conf.properties)) do
                newDefault[k] = v.default
            end
            default = newDefault
        end
        local list = util.getTableKeys(default, true)
        if #list == 0 then
            md:add('jsonc', '{}')
            return
        end
        md:add('jsonc', '{')
        for i, k in ipairs(list) do
            local desc = getDesc(lang, assert(conf.properties)[k].description)
            if desc then
                md:add('jsonc', '    /*')
                md:add('jsonc', ('    %s'):format(desc:gsub('\n', '\n    ')))
                md:add('jsonc', '    */')
            end
            if i == #list then
                md:add('jsonc',('    %s: %s'):format(json.encode(k), json.encode(default[k])))
            else
                md:add('jsonc',('    %s: %s,'):format(json.encode(k), json.encode(default[k])))
            end
        end
        md:add('jsonc', '}')
    else
        md:add('jsonc', ('%s'):format(json.encode(default)))
    end
end

---@param enum any[]|fun(): any[]
---@return any[]
local function resolveEnum(enum)
    if type(enum) == 'function' then
        return enum()
    end
    return enum
end

---@param md markdown
---@param lang string
---@param conf tools.configuration.schema
local function buildEnum(md, lang, conf)
    if conf.enum then
        md:add('md', '## enum')
        md:emptyLine()
        for i, enum in ipairs(resolveEnum(conf.enum)) do
            local desc = getDesc(lang, conf.markdownEnumDescriptions and conf.markdownEnumDescriptions[i])
            if desc then
                md:add('md', ('* ``%s``: %s'):format(json.encode(enum), desc))
            else
                md:add('md', ('* ``%s``'):format(json.encode(enum)))
            end
        end
        md:emptyLine()
        return
    end

    if conf.type == 'object' and conf.properties then
        local _, first = next(conf.properties)
        if first and first.enum then
            md:add('md', '## enum')
            md:emptyLine()
            for i, enum in ipairs(resolveEnum(first.enum)) do
                local desc = getDesc(lang, conf.markdownEnumDescriptions and conf.markdownEnumDescriptions[i])
                if desc then
                    md:add('md', ('* ``%s``: %s'):format(json.encode(enum), desc))
                else
                    md:add('md', ('* ``%s``'):format(json.encode(enum)))
                end
            end
            md:emptyLine()
            return
        end
    end

    if conf.type == 'array' and conf.items and conf.items.enum then
        md:add('md', '## enum')
        md:emptyLine()
        local markdownEnumDescriptions = conf.markdownEnumDescriptions
        for i, enum in ipairs(resolveEnum(assert(conf.items).enum)) do
            local desc = getDesc(lang, markdownEnumDescriptions and markdownEnumDescriptions[i])
            if desc then
                md:add('md', ('* ``%s``: %s'):format(json.encode(enum), desc))
            else
                md:add('md', ('* ``%s``'):format(json.encode(enum)))
            end
        end
        md:emptyLine()
        return
    end
end

---@param lang string
local function buildMarkdown(lang)
    local dir = fs.path 'doc' / lang
    fs.create_directories(dir)
    local configDoc = markdown()

    for name, conf in util.sortPairs(config) do
        configDoc:add('md', '# ' .. name:gsub('^Lua%.', ''))
        configDoc:emptyLine()
        buildDesc(configDoc, lang, conf)
        buildType(configDoc, lang, conf)
        buildEnum(configDoc, lang, conf)
        buildDefault(configDoc, lang, conf)
    end

    util.saveFile((dir / 'config.md'):string(), configDoc:string())
end

for lang in pairs(localeMap) do
    buildMarkdown(lang)
end
