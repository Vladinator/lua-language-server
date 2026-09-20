local fs      = require 'bee.filesystem'
local util    = require 'utility'
local lloader = require 'locale-loader'

---@return table<any, any>
local function supportLanguage()
    ---@type table<any, any>
    local list = {}
    for path in fs.pairs(ROOT / 'locale') do
        if fs.is_directory(path) then
            local id = path:filename():string():lower()
            list[#list+1] = id
            list[id] = true
        end
    end
    return list
end

local function getLanguage(id)
    local support = supportLanguage()
    -- 检查是否支持语言
    if support[id] then
        return id
    end
    if not id then
        return 'en-us'
    end
    -- 根据语言的前2个字母来找近似语言
    for _, lang in ipairs(support) do
        if lang:sub(1, 2) == id:sub(1, 2) then
            return lang
        end
    end
    -- 使用英文
    return 'en-us'
end

local function loadFileByLanguage(name, language)
    local path = ROOT / 'locale' / language / (name .. '.lua')
    local buf = util.loadFile(path:string())
    if not buf then
        return {}
    end
    local suc, tbl = xpcall(lloader, log.error, buf, path:string())
    if not suc then
        return {}
    end
    return tbl
end

local function formatAsArray(str, ...)
    local index = 0
    local args = {...}
    ---@param pat string
    ---@return string
    return str:gsub('%{(.-)%}', function (pat)
        ---@type any, any
        local id, fmt
        local pos = pat:find(':', 1, true)
        if pos then
            id = pat:sub(1, pos-1)
            fmt = pat:sub(pos+1)
        else
            id = pat
            fmt = 's'
        end
        id = tonumber(id)
        if not id then
            index = (index + 1)
            id = index
        end
        return ('%'..fmt):format(args[id])
    end)
end

local function formatAsTable(str, ...)
    ---@type any
    local args = ...
    ---@param pat string
    ---@return string?
    return str:gsub('%{(.-)%}', function (pat)
        ---@type any, any
        local id, fmt
        local pos = pat:find(':', 1, true)
        if pos then
            id = pat:sub(1, pos-1)
            fmt = pat:sub(pos+1)
        else
            id = pat
            fmt = 's'
        end
        if not id then
            return
        end
        return ('%'..fmt):format(args[id])
    end)
end

local function loadLang(name, language)
    local tbl = loadFileByLanguage(name, 'en-us')
    if language ~= 'en-us' then
        local other = loadFileByLanguage(name, language)
        for k, v in pairs(other) do
            tbl[k] = v
        end
    end
    return setmetatable(tbl, {
        ---@param self any
        ---@param key  any
        ---@return any
        __index = function (self, key)
            local selfMap = self --[[@as table<any, any>]]
            selfMap[key] = key
            return key
        end,
        ---@param self any
        ---@param key  any
        ---@param ... any
        ---@return string
        __call = function (self, key, ...)
            local str = (self --[[@as table<any, any>]])[key]
            if not ... then
                return str
            end
            ---@type boolean, any
            local suc, res
            if type(...) == 'table' then
                ---@type boolean, any
                local s, r = pcall(formatAsTable, str, ...)
                suc, res = s, r
            else
                ---@type boolean, any
                local s, r = pcall(formatAsArray, str, ...)
                suc, res = s, r
            end
            if suc then
                return res
            else
                -- 这里不能使用翻译，以免死循环
                log.warn(('[%s][%s-%s] formated error: %s'):format(
                    language, name, key, str
                ))
                return str
            end
        end,
    })
end

--- One of these per locale/<lang>/<name>.lua file: a table of message
--- keys to template strings, also callable to format one in place
--- (see loadLang's __call/__index below).
---@class lang.messages
---@field [string] string
---@overload fun(key: string, ...: any): string

---@class lang
---@field id     string
---@field script lang.messages

---@type lang
local m = setmetatable({
    id = 'en-us',
}, {
    ---@param self any
    ---@param name string
    ---@return table|table<string, any>
    __index = function (self, name)
        local tbl = loadLang(name, self.id)
        local selfMap = self --[[@as table<any, any>]]
        selfMap[name] = tbl
        return tbl
    end,
    ---@param self any
    ---@param id   any
    __call = function (self, id)
        local language = getLanguage(id)
        log.info(('VSC language: %s'):format(id))
        log.info(('LS  language: %s'):format(language))
        local selfMap = self --[[@as table<any, any>]]
        for k in pairs(selfMap) do
            selfMap[k] = nil
        end
        self.id = language
    end,
})
return m
