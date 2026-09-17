package.path = package.path .. ';script/?.lua;tools/?.lua'

local fs   = require 'bee.filesystem'
local util = require 'utility'

---@class locale.entry
---@field key     string
---@field line    integer
---@field space   string
---@field comment? string
---@field content string[]

---@class locale.data
---@field map  table<string, locale.entry>
---@field list locale.entry[]

---@param text string
---@return string?
local function getLongStringMark(text)
    return text:match '^%[[=]*%['
end

---@param text string
---@param mark string
---@return boolean
local function isLongStringFinish(text, mark)
    local emark = mark:gsub('%[', ']')
    return util.stringEndWith(text, emark)
end

---@param filePath fs.path
---@return locale.data
local function loadLocaleFile(filePath)
    local fileContent = util.loadFile(filePath:string())
    ---@type locale.data
    local data = {
        map  = {},
        list = {},
    }
    if not fileContent then
        return data
    end
    ---@type locale.entry?
    local current
    ---@type string|false?
    local inLongString
    for lineVal, lineCount in util.eachLine(fileContent) do
        if inLongString then
            local curEntry = current --[[@as locale.entry]]
            curEntry.content[#curEntry.content+1] = lineVal
            if isLongStringFinish(lineVal, inLongString) then
                inLongString = nil
            end
            goto CONTINUE
        end
        local line = lineVal
        local comment = line:match '%s*%-%- TODO.+$'
        if comment then
            line = line:sub(1, - #comment - 1)
        end
        local key, space = line:match '^(.-)(%s*)=%s*$'
        if key then
            current = {
                key     = key,
                line    = lineCount --[[@as integer]],
                space   = space,
                comment = comment,
                content = {},
            }
            if not data.map[key] then
                data.map[key] = current
                data.list[#data.list+1] = current
            end
        elseif current then
            if line:find '^%s*$' then
                current = nil
            else
                current.content[#current.content+1] = line
                inLongString = getLongStringMark(line)
                if inLongString and isLongStringFinish(line, inLongString) then
                    inLongString = false
                end
            end
        end
        ::CONTINUE::
    end
    return data
end

---@type string[]
local localeNames = {}
for fullPath in fs.pairs(fs.path('locale')) do
    localeNames[#localeNames+1] = fullPath:filename():string()
end

---@param allKeys string[]
---@param list locale.entry[]
local function mergeList(allKeys, list)
    ---@type table<string, boolean>
    local keyMap = {}
    local leftFix = 0

    for i, data in ipairs(list) do
        local key = data.key
        local leftIndex = i + leftFix
        local left = allKeys[leftIndex]
        if not left then
            if not keyMap[key] then
                keyMap[key] = true
                allKeys[#allKeys+1] = key
            end
            goto CONTINUE
        end
        if left == key then
            goto CONTINUE
        end
        for j = leftIndex + 1, #allKeys do
            if allKeys[j] == key then
                leftFix = j - i
                goto CONTINUE
            end
        end
        for j = i + 1, #list do
            if list[j] == key then
                leftFix = j - i
                goto CONTINUE
            end
        end
        if not keyMap[key] then
            keyMap[key] = true
            table.insert(allKeys, leftIndex, key)
        end
        ::CONTINUE::
    end
end

---@param key string
---@param lastKey string?
---@return boolean
local function needSplit(key, lastKey)
    if not lastKey then
        return false
    end
    return key:match '%w+' ~= lastKey:match '%w+'
end

---@param localeName string
---@param allKeys string[]
---@param localeMap table<string, locale.data>
---@param fileName string
---@return string
local function buildLocaleFile(localeName, allKeys, localeMap, fileName)
    ---@type string[]
    local lines = {}
    ---@type string?
    local lastKey
    ---@type string[][]
    local blocks = {}
    ---@type string[]
    local currentBlock = {}
    ---@type table<string, boolean>
    local usedKeys = {}
    blocks[#blocks+1] = currentBlock
    for _, key in ipairs(allKeys) do
        if needSplit(key, lastKey) then
            currentBlock = {}
            blocks[#blocks+1] = currentBlock
        end
        lastKey = key
        if not usedKeys[key] then
            currentBlock[#currentBlock+1] = key
            usedKeys[key] = true
        end
    end

    if fileName == 'meta' then
        lines[#lines+1] = '---@diagnostic disable: undefined-global, lowercase-global'
        lines[#lines+1] = ''
    end
    if fileName == 'setting' then
        lines[#lines+1] = '---@diagnostic disable: undefined-global'
        lines[#lines+1] = ''
    end

    for _, block in ipairs(blocks) do
        for _, key in ipairs(block) do
            local data = localeMap[localeName].map[key]
            ---@type string?
            local comment
            if data then
                local needTranslate = false
                if localeName == 'en-us' then
                    local utfLen  = 0
                    local charLen = 0
                    for _, line in ipairs(data.content) do
                        utfLen  = (utfLen  + util.utf8Len(line)) --[[@as integer]]
                        charLen = (charLen + #line) --[[@as integer]]
                    end
                    if charLen > 0 and utfLen / charLen < 0.8 then
                        needTranslate = true
                    end
                else
                    --if #data.content > 1 or #data.content[1] > 2 then
                    --    local enContent = localeMap['en-us'].map[key] and localeMap['en-us'].map[key].content
                    --    if enContent then
                    --        needTranslate = #data.content == #enContent
                    --        for i, line in ipairs(data.content) do
                    --            if line ~= enContent[i] then
                    --                needTranslate = false
                    --            end
                    --        end
                    --    end
                    --end
                end
                if needTranslate then
                    comment = ' -- TODO: need translate!'
                end
            else
                data = localeMap['en-us'].map[key] or localeMap['zh-cn'].map[key]
                if not data then
                    for _, map in util.sortPairs(localeMap) do
                        if map.map[key] then
                            data = map.map[key]
                            break
                        end
                    end
                end
                comment = ' -- TODO: need translate!'
            end
            lines[#lines+1] = key .. data.space .. '=' .. (comment or data.comment or '')
            for _, line in ipairs(data.content) do
                lines[#lines+1] = line
            end
        end
        lines[#lines+1] = ''
    end
    return table.concat(lines, '\n')
end

---@param fileName string
local function processFile(fileName)
    ---@type string[]
    local allKeys = {}
    ---@type table<string, locale.data>
    local localeMap = {}
    for _, localeName in ipairs(localeNames) do
        local localeData = loadLocaleFile(fs.path('locale') / localeName / (fileName .. '.lua'))
        localeMap[localeName] = localeData
        mergeList(allKeys, localeData.list)
    end
    for _, localeName in ipairs(localeNames) do
        local newContent = buildLocaleFile(localeName, allKeys, localeMap, fileName)
        util.saveFile((fs.path('locale') / localeName / (fileName .. '.lua')):string(), newContent)
    end
end

for _, fileName in ipairs { 'script', 'meta', 'setting' } do
    processFile(fileName)
end
