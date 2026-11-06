-- The colours of a `.toc` file, as LSP semantic tokens: the directive names, the game types, locales, numbers and flags of their values, the inline
-- directives and variables of a file line. The editor's own grammar for `.toc` (a separate extension) does not know every directive (`ExcludeLoadGameType`,
-- `AllowLoadTextLocale` come out half red, half blue); a token from here replaces it for the word it covers, and what no token covers keeps the grammar's
-- colour (comments, file names, free text). Everything that is wanted from the server is data of the other files here (directives.lua, games.lua); this file
-- only decides which word gets which token type. Off with `Lua.semantic.enable`.
local syntax     = require 'core.diagnostics.extra.wow-toc.syntax'
local directives = require 'core.diagnostics.extra.wow-toc.directives'
local games      = require 'core.diagnostics.extra.wow-toc.games'
local fileKinds  = require 'file-kinds'

---@type table<string, true>   lowercase locale names
local localeNames = {}
for _, locale in ipairs(games.locales) do
    localeNames[locale:lower()] = true
end

---@type table<string, wowToc.inline>
local inlineByName = {}
for _, inline in ipairs(directives.inlines) do
    inlineByName[inline.name:lower()] = inline
end

local m = {}

--- Adds a token for the bytes `first`..`last` (1-based, inclusive) of a line.
---@param tokens fileKind.token[]
---@param line   wowToc.line
---@param first  integer
---@param last   integer
---@param type   string
local function push(tokens, line, first, last, type)
    if last < first then
        return
    end
    local start = fileKinds.toCharacter(line.text, first - 1)
    local length = fileKinds.toCharacter(line.text, last) - start
    tokens[#tokens+1] = { line = line.row, start = start, length = length, type = type }
end

--- The token type of a word of a value of the kind `kind` (`gametypes`, `locales`, `interface`, `boolean01`, `enum`), nil for a word that is not known:
--- an unknown word keeps the grammar's colour, so a typo is not coloured like a real name.
---@param kind      string?
---@param word      string
---@param directive { values?: string[] }
---@return string?
local function typeOfWord(kind, word, directive)
    if kind == 'gametypes' then
        return syntax.resolveGameWord(word) and 'enumMember' or nil
    elseif kind == 'locales' then
        return localeNames[word:lower()] and 'enumMember' or nil
    elseif kind == 'interface' then
        return word:match('^%d+$') and 'number' or nil
    elseif kind == 'boolean01' then
        return (word == '0' or word == '1') and 'number' or nil
    elseif kind == 'enum' then
        for _, allowed in ipairs(directive.values or {}) do
            if allowed:lower() == word:lower() then
                return 'enumMember'
            end
        end
    end
    return nil
end

--- The words of a value (separated by commas and blanks) as tokens.
---@param tokens    fileKind.token[]
---@param line      wowToc.line
---@param value     string
---@param valueStart integer  1-based byte of the first character of `value`
---@param kind      string?
---@param directive { values?: string[] }
local function pushValue(tokens, line, value, valueStart, kind, directive)
    if not kind then
        return
    end
    for first, word, last in value:gmatch('()([^,%s]+)()') --[==[@as fun(): (integer, string, integer)]==] do
        local type = typeOfWord(kind, word, directive)
        if type then
            push(tokens, line, valueStart + first - 1, valueStart + last - 2, type)
        end
    end
end

--- The tokens of a text.
---@param text string
---@return fileKind.token[]
function m.tokensOf(text)
    ---@type fileKind.token[]
    local tokens = {}
    for _, line in ipairs(syntax.parse(text)) do
        if line.kind == 'header' and line.key and line.keyStart and line.keyFinish then
            if line.directive then
                push(tokens, line, line.keyStart, line.keyFinish, 'keyword')
                if line.value and line.valueStart then
                    pushValue(tokens, line, line.value, line.valueStart, line.directive.value, line.directive)
                end
            elseif line.custom then
                push(tokens, line, line.keyStart, line.keyFinish, 'property')
            end
        elseif line.kind == 'file' then
            for _, bracket in ipairs(line.brackets) do
                local lower = bracket.name:lower()
                local inline = inlineByName[lower]
                if inline then
                    push(tokens, line, bracket.nameStart, bracket.nameFinish, 'keyword')
                    if bracket.value ~= '' then
                        pushValue(tokens, line, bracket.value, bracket.valueStart, inline.value, inline)
                    end
                elseif syntax.variableByName[lower] then
                    push(tokens, line, bracket.nameStart, bracket.nameFinish, 'variable')
                end
            end
        end
    end
    return tokens
end

syntax.kind.semanticTokens = function (_, text)
    return m.tokensOf(text)
end

return m
