package.path = package.path .. ';3rd/love-api/?.lua'

--- Self-defined shapes matching the `love_api.lua` data this script reads
--- (from the `3rd/love-api` submodule, an external project this repo
--- doesn't control) -- not a full reproduction of LÖVE's API schema,
--- just the fields this generator actually touches.
---@class love-api.param
---@field name string
---@field type? string
---@field description? string
---@field default? any
---@field table? love-api.param[] -- for `type == 'table'` params, the nested field list
---@field arraytype? string

---@class love-api.variant
---@field arguments? love-api.param[]
---@field returns? love-api.param[]

---@class love-api.func
---@field name string
---@field description? string
---@field notes? string
---@field variants love-api.variant[]

---@class love-api.type
---@field name string
---@field description? string
---@field notes? string
---@field supertypes? string[]
---@field functions? love-api.func[]

---@class love-api.constant
---@field name string
---@field description? string
---@field notes? string

---@class love-api.enum
---@field name string
---@field description? string
---@field notes? string
---@field constants love-api.constant[]

---@class love-api.callback
---@field name string
---@field description? string
---@field notes? string
---@field variants love-api.variant[]

---@class love-api.def
---@field name? string -- present on module/type entries, absent on the top-level api root
---@field description? string
---@field notes? string
---@field version? string
---@field functions? love-api.func[]
---@field types? love-api.type[]
---@field callbacks? love-api.callback[]
---@field enums? love-api.enum[]

---@class love-api.root: love-api.def
---@field modules love-api.def[]

-- `tools/` isn't on the configured runtime.path (only script/ and test/ are,
-- with pathStrict set), so `require` can't statically resolve a sibling
-- tools/ module by name -- cast to the class declared in tools/lua51.lua
local lua51 = require 'lua51' --[[@as lua51]]
---@type love-api.root
local api   = lua51.require 'love_api'
local fs    = require 'bee.filesystem'
local fsu   = require 'fs-utility'

local metaPath    = fs.path 'meta/3rd/love2d'
local libraryPath = metaPath / 'library'
fs.create_directories(libraryPath)

local knownTypes = {
    ['nil']            = 'nil',
    ['any']            = 'any',
    ['boolean']        = 'boolean',
    ['number']         = 'number',
    ['integer']        = 'integer',
    ['string']         = 'string',
    ['table']          = 'table',
    ['function']       = 'function',
    ['userdata']       = 'userdata',
    ['lightuserdata']  = 'lightuserdata',
    ['thread']         = 'thread',
    ['cdata']          = 'ffi.cdata*',
    ['light userdata'] = 'lightuserdata',
    ['Variant']        = 'any',
}

---@param name string
---@return string
local function trim(name)
    name = (name:gsub('^%s+', ''))
    name = (name:gsub('%s+$', ''))
    return name
end

---@param names string
---@return string
local function getTypeName(names)
    ---@type string[]
    local types = {}
    names = (names:gsub('%sor%s', '|'))
    for nameVal in names:gmatch '[^|]+' do
        local name = nameVal
        name = trim(name)
        types[#types+1] = knownTypes[name] or ('love.' .. name)
    end
    return table.concat(types, '|')
end

---@param key string
---@return string
local function formatIndex(key)
    if key:match '^[%a_][%w_]*$' then
        return key
    end
    return ('[%q]'):format(key)
end

---@param param love-api.param
---@return string
local function getOptional(param)
    if param.type == 'table' then
        if not param.table then
            return ''
        end
        for _, field in ipairs(param.table) do
            if field.default == nil then
                return ''
            end
        end
        return '?'
    else
        return (param.default ~= nil) and '?' or ''
    end
end

---@type fun(param: love-api.param): string
local buildType

---@param tbl love-api.param[]
---@return string
local function buildDocTable(tbl)
    ---@type string[]
    local fields = {}
    for _, field in ipairs(tbl) do
        if field.name ~= '...' then
            fields[#fields+1] = ('%s: %s'):format(formatIndex(field.name), buildType(field))
        end
    end
    return ('{%s}'):format(table.concat(fields, ', '))
end

function buildType(param)
    if param.table then
        return buildDocTable(param.table)
    end
    if param.arraytype then
        return ('%s[]'):format(getTypeName(param.arraytype))
    end
    return getTypeName(param.type)
end

---@param tp love-api.type
---@return string
local function buildSuper(tp)
    if not tp.supertypes then
        return ''
    end
    ---@type string[]
    local parents = {}
    for _, parent in ipairs(tp.supertypes) do
        parents[#parents+1] = getTypeName(parent)
    end
    return (': %s'):format(table.concat(parents, ', '))
end

---@param desc string
---@return string
local function buildMD(desc)
    return (desc:gsub('([\r\n])', '%1---')
               :gsub('%.  ', '.\n---\n---'))
end

---@param desc? string
---@param notes? string
---@param wikiPage string?
---@return string
local function buildDescription(desc, notes, wikiPage)
    ---@type string[]
    local lines = {}
    if desc then
        lines[#lines+1] = '---'
        lines[#lines+1] = '---' .. buildMD(desc)
        lines[#lines+1] = '---'
    end
    if notes then
        lines[#lines+1] = '---'
        lines[#lines+1] = '---### NOTE:'
        lines[#lines+1] = '---' .. buildMD(notes)
        lines[#lines+1] = '---'
    end
    if wikiPage then
        lines[#lines+1] = '---'
        lines[#lines+1] = ("---[Open in Browser](https://love2d.org/wiki/%s)"):format(wikiPage)
        lines[#lines+1] = '---'
    end
    return table.concat(lines, '\n')
end

---@param variant love-api.variant
---@param overload? string
---@return string
local function buildDocFunc(variant, overload)
    ---@type string[]
    local params  = {}
    ---@type string[]
    local returns = {}
    if overload then
        params[1] = ('self: %s'):format(overload)
    end
    for _, param in ipairs(variant.arguments or {}) do
        if param.name == '...' then
            params[#params+1] = '...'
        else
            if param.name:find '^[\'"]' then
                params[#params+1] = ('%s%s: %s|%s'):format(param.name:sub(2, -2), getOptional(param), getTypeName(param.type), param.name)
            else
                params[#params+1] = ('%s%s: %s'):format(param.name, getOptional(param), getTypeName(param.type))
            end
        end
    end
    for _, rtn in ipairs(variant.returns or {}) do
        returns[#returns+1] = ('%s'):format(getTypeName(rtn.type))
    end
    return ('fun(%s)%s'):format(
        table.concat(params, ', '),
        #returns > 0 and (':' .. table.concat(returns, ', ')) or ''
    )
end

---@param tp love-api.callback
---@return string
local function buildMultiDocFunc(tp)
    ---@type string[]
    local cbs = {}
    for _, variant in ipairs(tp.variants) do
        cbs[#cbs+1] = buildDocFunc(variant)
    end
    return table.concat(cbs, '|')
end

---@param func love-api.func
---@param node string
---@param typeName? string
---@return string
local function buildFunction(func, node, typeName)
    ---@type string[]
    local text = {}
    text[#text+1] = buildDescription(func.description, func.notes, node..func.name)
    for i = 2, #func.variants do
        local variant = func.variants[i]
        text[#text+1] = ('---@overload %s'):format(buildDocFunc(variant, typeName))
    end
    ---@type string[]
    local params = {}
    for _, param in ipairs(func.variants[1].arguments or {}) do
        for paramName in param.name:gmatch '[%a_][%w_]*' do
            params[#params+1] = paramName
            text[#text+1] = ('---@param %s%s %s # %s'):format(
                paramName,
                getOptional(param),
                buildType(param),
                param.description
            )
        end

        if param.name == "..." then
            params[#params+1] = param.name
            text[#text+1] = ('---@vararg %s # %s'):format(
                buildType(param),
                param.description
            )
        end
    end
    for _, rtn in ipairs(func.variants[1].returns or {}) do
        for returnName in rtn.name:gmatch '[%a_][%w_]*' do
            text[#text+1] = ('---@return %s %s # %s'):format(
                buildType(rtn),
                returnName,
                rtn.description
            )
        end
    end
    text[#text+1] = ('function %s%s(%s) end'):format(
        node,
        func.name,
        table.concat(params, ', ')
    )
    return table.concat(text, '\n')
end

---@param class string
---@param defs  love-api.def
local function buildFile(class, defs)
    local filePath = libraryPath / (class:gsub('%.', '/') .. '.lua')
    ---@type string[]
    local text = {}

    text[#text+1] = '---@meta'
    text[#text+1] = ''
    if defs.version then
        text[#text+1] = ('-- version: %s'):format(defs.version)
    end
    text[#text+1] = buildDescription(defs.description, defs.notes, class)
    text[#text+1] = ('---@class %s'):format(class)
    text[#text+1] = ('%s = {}'):format(class)

    for _, func in ipairs(defs.functions or {}) do
        text[#text+1] = ''
        text[#text+1] = buildFunction(func, class .. '.')
    end

    for _, tp in ipairs(defs.types or {}) do
        ---@type table<string, boolean>
        local mark = {}
        text[#text+1] = ''
        text[#text+1] = buildDescription(tp.description, tp.notes, class)
        text[#text+1] = ('---@class %s%s'):format(getTypeName(tp.name), buildSuper(tp))
        text[#text+1] = ('local %s = {}'):format(tp.name)
        for _, func in ipairs(tp.functions or {}) do
            if not mark[func.name] then
                mark[func.name] = true
                text[#text+1] = ''
                text[#text+1] = buildFunction(func, tp.name .. ':', getTypeName(tp.name))
            end
        end
    end

    for _, cb in ipairs(defs.callbacks or {}) do
        text[#text+1] = ''
        text[#text+1] = buildDescription(cb.description, cb.notes)
        text[#text+1] = ('---@alias %s %s'):format(getTypeName(cb.name), buildMultiDocFunc(cb))
    end

    for _, enum in ipairs(defs.enums or {}) do
        text[#text+1] = ''
        text[#text+1] = buildDescription(enum.description, enum.notes, enum.name)
        text[#text+1] = ('---@alias %s'):format(getTypeName(enum.name))
        for _, constant in ipairs(enum.constants) do
            text[#text+1] = buildDescription(constant.description, constant.notes)
            text[#text+1] = ([[---| %q]]):format(constant.name)
        end
    end

    if defs.version then
        text[#text+1] = ''
        text[#text+1] = ('return %s'):format(class)
    end

    text[#text+1] = ''

    fs.create_directories(filePath:parent_path())
    fsu.saveFile(filePath, table.concat(text, '\n'))
end

buildFile('love', api)

for _, module in ipairs(api.modules) do
    buildFile('love.' .. (module.name --[[@as string]]), module)
end
