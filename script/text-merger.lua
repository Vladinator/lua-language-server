local util    = require 'utility'
local encoder = require 'encoder'
local client  = require 'client'

---@type encoder.encoding?
local offsetEncoding
---@return encoder.encoding
local function getOffsetEncoding()
    if not offsetEncoding then
        offsetEncoding = (client.getOffsetEncoding():lower():gsub('%-', ''))
    end
    return offsetEncoding
end

---@param text string
---@return string[]
local function splitRows(text)
    ---@type string[]
    local rows = {}
    for line in util.eachLine(text, true) do
        rows[#rows+1] = line
    end
    return rows
end

---@param text? string
---@param char  integer
---@return string
local function getLeft(text, char)
    if not text then
        return ''
    end
    local encoding = getOffsetEncoding()
    ---@type string
    local left
    local length = encoder.len(encoding, text)

    if char == 0 then
        left = ''
    elseif char >= length then
        left = text
    else
        left = text:sub(1, encoder.offset(encoding, text, char + 1) - 1)
    end

    return left
end

---@param text? string
---@param char  integer
---@return string
local function getRight(text, char)
    if not text then
        return ''
    end
    local encoding = getOffsetEncoding()
    ---@type string
    local right
    local length = encoder.len(encoding, text)

    if char == 0 then
        right = text
    elseif char >= length then
        right = ''
    else
        right = text:sub(encoder.offset(encoding, text, char + 1))
    end

    return right
end

---@param rows   string[]
---@param change core.fix-indent.change
local function mergeRows(rows, change)
    local range = change.range --[[@as range]]
    local startLine = range['start'].line + 1
    local startChar = range['start'].character
    local endLine   = range['end'].line + 1
    local endChar   = range['end'].character

    local insertRows = splitRows(change.text)
    local newEndLine = startLine + #insertRows - 1
    local left       = getLeft(rows[startLine], startChar)
    local right      = getRight(rows[endLine],  endChar)
    -- 先把双方的行数调整成一致
    if endLine > #rows then
        log.error('NMD, WSM `endLine > #rows` ?')
        for i = #rows + 1, endLine do
            rows[i] = ''
        end
    end
    local delta = #insertRows - (endLine - startLine + 1)
    if delta ~= 0 then
        table.move(rows, endLine, #rows, endLine + delta)
        -- 如果行数变少了，要清除多余的行
        if delta < 0 then
            for i = #rows, #rows + delta + 1, -1 do
                rows[i] = nil
            end
        end
    end
    -- 先处理第一行和最后一行
    if startLine == newEndLine then
        rows[startLine]  = left .. insertRows[1] .. right
    else
        rows[startLine]  = left .. insertRows[1]
        rows[newEndLine] = insertRows[#insertRows] .. right
    end
    -- 修改中间的每一行
    for i = 2, #insertRows - 1 do
        local currentLine = startLine + i - 1
        local insertText  = insertRows[i] or ''
        rows[currentLine] = insertText
    end
end

---@param text    string
---@param rows?   string[]
---@param changes core.fix-indent.change[]
---@return string text
---@return string[]? rows
return function (text, rows, changes)
    for _, change in ipairs(changes) do
        if change.range then
            rows = rows or splitRows(text)
            mergeRows(rows, change)
        else
            rows = nil
            text = change.text
        end
    end
    if rows then
        text = table.concat(rows)
    end
    return text, rows
end
