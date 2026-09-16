--- Self-defined shapes matching the `lovr-api` data this script reads
--- (from the `3rd/lovr-api` submodule, an external project this repo
--- doesn't control) -- not a full reproduction of LÖVR's API schema,
--- just the fields this generator actually touches.
---@class lovr-api.param
---@field name string
---@field type? string
---@field description? string
---@field default? any
---@field table? lovr-api.param[] -- for `type == 'table'` params, the nested field list

---@class lovr-api.variant
---@field arguments? lovr-api.param[]
---@field returns? lovr-api.param[]

---@class lovr-api.func
---@field name string
---@field key string -- full dotted/colon syntax to declare the function under, e.g. `lovr.graphics.newMesh`
---@field description? string
---@field notes? string
---@field variants lovr-api.variant[]

---@class lovr-api.object
---@field name string
---@field description? string
---@field notes? string
---@field supertypes? string[]
---@field methods? lovr-api.func[]

---@class lovr-api.constant
---@field name string
---@field description? string
---@field notes? string

---@class lovr-api.enum
---@field name string
---@field description? string
---@field notes? string
---@field values lovr-api.constant[]

---@class lovr-api.callback: lovr-api.func

---@class lovr-api.def
---@field key string
---@field description? string
---@field notes? string
---@field version? string
---@field functions? lovr-api.func[]
---@field objects? lovr-api.object[]
---@field callbacks? lovr-api.callback[]
---@field enums? lovr-api.enum[]
---@field modules? lovr-api.def[]

local fs    = require 'bee.filesystem'
local fsu   = require 'fs-utility'

---@type lovr-api.def
local api = dofile('3rd/lovr-api/api/init.lua')

local metaPath    = fs.path 'meta/3rd/lovr'
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
    if names == '*' then
        return 'any'
    end
    ---@type string[]
    local types = {}
    names = (names:gsub('%sor%s', '|'))
    for nameVal in names:gmatch '[^|]+' do
        local name = nameVal
        name = trim(name)
        types[#types+1] = knownTypes[name] or ('lovr.' .. name)
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

---@param param lovr-api.param
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

---@type fun(param: lovr-api.param): string
local buildType

---@param tbl lovr-api.param[]
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
    if param.type then
        return getTypeName(param.type)
    end
    return 'any'
end

---@param tp lovr-api.object
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
---@return string
local function buildDescription(desc, notes)
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
    return table.concat(lines, '\n')
end

---@param variant lovr-api.variant
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
                params[#params+1] = ('%s%s: %s|%s'):format(param.name:sub(2, -2), getOptional(param), getTypeName(param.type --[[@as string]]), param.name)
            else
                params[#params+1] = ('%s%s: %s'):format(param.name, getOptional(param), getTypeName(param.type --[[@as string]]))
            end
        end
    end
    for _, rtn in ipairs(variant.returns or {}) do
        returns[#returns+1] = ('%s'):format(getTypeName(rtn.type --[[@as string]]))
    end
    return ('fun(%s)%s'):format(
        table.concat(params, ', '),
        #returns > 0 and (':' .. table.concat(returns, ', ')) or ''
    )
end

---@param tp lovr-api.callback
---@return string
local function buildMultiDocFunc(tp)
    ---@type string[]
    local cbs = {}
    for _, variant in ipairs(tp.variants) do
        cbs[#cbs+1] = buildDocFunc(variant)
    end
    return table.concat(cbs, '|')
end

---@param func lovr-api.func
---@param typeName? string
---@return string
local function buildFunction(func, typeName)
    ---@type string[]
    local text = {}
    text[#text+1] = buildDescription(func.description, func.notes)
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
    text[#text+1] = ('function %s(%s) end'):format(
        func.key,
        table.concat(params, ', ')
    )
    return table.concat(text, '\n')
end

---@param defs lovr-api.def
local function buildFile(defs)
    local class = defs.key
    local filePath = libraryPath / (class:gsub('%.', '/') .. '.lua')
    ---@type string[]
    local text = {}

    text[#text+1] = '---@meta'
    text[#text+1] = ''
    text[#text+1] = buildDescription(defs.description, defs.notes)
    text[#text+1] = ('---@class %s'):format(class)
    text[#text+1] = ('%s = {}'):format(class)

    for _, func in ipairs(defs.functions or {}) do
        text[#text+1] = ''
        text[#text+1] = buildFunction(func)
    end

    for _, obj in ipairs(defs.objects or {}) do
        ---@type table<string, boolean>
        local mark = {}
        text[#text+1] = ''
        text[#text+1] = buildDescription(obj.description, obj.notes)
        text[#text+1] = ('---@class %s%s'):format(getTypeName(obj.name), buildSuper(obj))
        text[#text+1] = ('local %s = {}'):format(obj.name)
        for _, func in ipairs(obj.methods or {}) do
            if not mark[func.name] then
                mark[func.name] = true
                text[#text+1] = ''
                text[#text+1] = buildFunction(func, getTypeName(obj.name))
            end
        end
    end

    for _, enum in ipairs(defs.enums or {}) do
        text[#text+1] = ''
        text[#text+1] = buildDescription(enum.description, enum.notes)
        text[#text+1] = ('---@alias %s'):format(getTypeName(enum.name))
        for _, constant in ipairs(enum.values) do
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

---@param defs lovr-api.def
local function buildCallback(defs)
    local filePath = libraryPath / ('callback.lua')
    ---@type string[]
    local text = {}

    text[#text+1] = '---@meta'

    for _, cb in ipairs(defs.callbacks or {}) do
        text[#text+1] = ''
        text[#text+1] = buildDescription(cb.description, cb.notes)
        text[#text+1] = ('---@type %s'):format(buildMultiDocFunc(cb))
        text[#text+1] = ('%s = nil'):format(cb.key)
    end

    text[#text+1] = ''

    fsu.saveFile(filePath, table.concat(text, '\n'))
end

buildCallback(api)

for _, module in ipairs(api.modules or {}) do
    buildFile(module)
end
