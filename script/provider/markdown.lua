local wssymbol = require("core.workspace-symbol")
local guide = require("parser.guide")

---@alias markdown.item
---| { type: 'markdown', markdown: markdown }
---| { type: 'text', language: string, text: string }
---| { type: 'splitline' }
---| { type: 'emptyline' }

---@class markdown
---@field [integer] markdown.item
---@field _cacheResult? string
local mt = {}
mt.__index = mt
mt.__name = 'markdown'

mt._splitLine = false

---Converts `[mySymbol](lua://mySymbol)` into a link that points to the origin of `mySymbol`.
---@param txt string
---@return string
local function processSymbolReferences(txt)
	---@param linkText string
	---@param symbol string
	---@return string?
	local function replacer(linkText, symbol)
		local source ---@type parser.object?

		for _, match in ipairs(wssymbol(symbol)) do
			if match.name == symbol then
				source = match.source
				break
			end
		end

		if not source then
			log.warn(string.format("Failed to find source of %q symbol in markdown comment", symbol))
			return
		end

		local row, _ = guide.rowColOf(source.start)
		local uri = string.format("%s#%i", guide.getUri(source), row + 1)

		return string.format("[%s](%s)", linkText, uri)
	end

	local result = string.gsub(txt, "%[([^]]*)%]%(lua://([^)]+)%)", replacer)
	return result
end

function mt:__tostring()
    return self:string()
end

---@param language string
---@param text? string|markdown
---@return markdown
function mt:add(language, text)
    if not text then
        return self
    end
    self._cacheResult = nil
    if type(text) == 'table' then
        self[#self+1] = {
            type     = 'markdown',
            markdown = text,
        }
    else
        text = tostring(text)
        self[#self+1] = {
            type     = 'text',
            language = language,
            text     = text,
        }
    end
    return self
end

---@return markdown
function mt:splitLine()
    self._cacheResult = nil
    self[#self+1] = {
        type = 'splitline',
    }
    return self
end

---@return markdown
function mt:emptyLine()
    self._cacheResult = nil
    self[#self+1] = {
        type = 'emptyline',
    }
    return self
end

---@param nl? string
---@return string
function mt:string(nl)
    if self._cacheResult then
        return self._cacheResult
    end
    ---@type string[]
    local lines = {}
    local language = 'md'

    ---@param markdown markdown
    local function concat(markdown)
        for _, obj in ipairs(markdown) do
            if obj.type == 'splitline' then
                if language ~= 'md' then
                    lines[#lines+1] = '```'
                    language = 'md'
                end
                if #lines > 0
                and lines[#lines] ~= '---' then
                    lines[#lines+1] = ''
                    lines[#lines+1] = '---'
                end
            elseif obj.type == 'emptyline' then
                if  #lines > 0
                and lines[#lines] ~= '' then
                    if language ~= 'md' then
                        language = 'md'
                        lines[#lines+1] = '```'
                    end
                    lines[#lines+1] = ''
                end
            elseif obj.type == 'markdown' then
                concat(obj.markdown)
            else
                if obj.language ~= language then
                    if language ~= 'md' then
                        lines[#lines+1] = '```'
                    end
                    if #lines > 0 then
                        lines[#lines+1] = ''
                    end
                    if obj.language ~= 'md' then
                        lines[#lines+1] = '```' .. obj.language
                    end
                end
                if obj.language == 'md' and #lines > 0 then
                    local last = lines[#lines]
                    if obj.text:sub(1, 1) == '@'
                    or last:sub(1, 1) == '@' then
                        if lines[#lines] ~= '' then
                            lines[#lines+1] = ''
                        end
                    elseif last == '---' then
                        if lines[#lines] ~= '' then
                            lines[#lines+1] = ''
                        end
                    end
                end
                lines[#lines + 1] = processSymbolReferences(obj.text)
                language = obj.language
            end
        end
    end

    concat(self)
    if language ~= 'md' then
        lines[#lines+1] = '```'
    end
    while true do
        if lines[#lines] == '---'
        or lines[#lines] == '' then
            lines[#lines] = nil
        else
            break
        end
    end

    local result = table.concat(lines, nl or '\n')
    self._cacheResult = result
    return result
end

---@return markdown
return function ()
    return setmetatable({}, mt)
end
