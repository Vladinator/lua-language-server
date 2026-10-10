-- Completion, hover and definition for WoW `.toc` files (see syntax.lua for the parser, the scope rules and the diagnostics; games.lua and
-- directives.lua for the data). Adds the three features to the `toc` file kind that syntax.lua registered.

local fs         = require 'bee.filesystem'
local furi       = require 'file-uri'
local fileKinds  = require 'file-kinds'
local games      = require 'core.diagnostics.extra.wow-toc.games'
local directives = require 'core.diagnostics.extra.wow-toc.directives'
local syntax     = require 'core.diagnostics.extra.wow-toc.syntax'

---@alias wowToc.completionItem table<string, any>

local CompletionItemKind = { Text = 1, Value = 12, Enum = 13, Keyword = 14, File = 17, Variable = 6, Property = 10, Folder = 19, Constant = 21, Function = 3 }

---@class wowToc.cursor
---@field lines  wowToc.line[]
---@field line   wowToc.line
---@field text   string   the whole line (not cut at 1024)
---@field col    integer  bytes before the cursor
---@field prefix string   the text before the cursor
---@field suffix string   the text after the cursor

--- The line and the byte column of an LSP position.
---@param text     string
---@param position fileKind.position
---@return wowToc.cursor
local function cursorAt(text, position)
    local lines = syntax.parse(text)
    local line = lines[position.line + 1]
    if not line then
        line = { row = position.line, text = '', tooLong = false, length = 0, kind = 'blank', brackets = {} }
    end
    local col = fileKinds.fromCharacter(line.text, position.character)
    return {
        lines = lines, line = line, text = line.text, col = col,
        prefix = line.text:sub(1, col), suffix = line.text:sub(col + 1),
    }
end

---@param row   integer
---@param lineText string
---@param first integer 1-based byte
---@param last  integer 1-based byte, inclusive (first - 1: an empty range)
---@return fileKind.range
local function rangeOf(row, lineText, first, last)
    return {
        start   = { line = row, character = fileKinds.toCharacter(lineText, first - 1) },
        ['end'] = { line = row, character = fileKinds.toCharacter(lineText, last) },
    }
end

---@param cursor wowToc.cursor
---@param first  integer 1-based byte where the replaced word starts
---@return fileKind.range
local function replaceFrom(cursor, first)
    local last = cursor.col
    -- the word goes on after the cursor: replace it too
    local rest = cursor.suffix:match('^[%w_%-]*') or ''
    return rangeOf(cursor.line.row, cursor.text, first, last + #rest)
end

---@param label    string
---@param kind     integer
---@param cursor   wowToc.cursor
---@param first    integer
---@param extra?   table<string, any>
---@return wowToc.completionItem
local function item(label, kind, cursor, first, extra)
    ---@type wowToc.completionItem
    local result = {
        label    = label,
        kind     = kind,
        textEdit = { range = replaceFrom(cursor, first), newText = label },
    }
    for key, value in pairs(extra or {}) do
        result[key] = value
    end
    return result
end

--- The directory of a `.toc` uri.
---@param uri uri
---@return string?
local function directoryOf(uri)
    return furi.decode(uri):match('^(.*)[/\\][^/\\]*$')
end

-- Hover text --------------------------------------------------------------------------------------------

---@param number integer
---@return string
local function readInterface(number)
    return ('%d.%d.%d'):format(number // 10000, number // 100 % 100, number % 100)
end

---@param game wowToc.game
---@return string
local function describeGame(game)
    local parts = { ('**%s** (`%s`)'):format(game.display, game.id) }
    if game.aliases and #game.aliases > 0 then
        parts[#parts+1] = 'Also spelled: ' .. table.concat(game.aliases, ', ') .. '.'
    end
    parts[#parts+1] = 'Families: ' .. table.concat(game.families, ', ') .. '. File name suffix: `_' .. table.concat(game.suffixes, '`, `_') .. '`.'
    if game.interface then
        parts[#parts+1] = ('Interface numbers `%d`-`%d` (today at least `%d`).'):format(game.interface.first, game.interface.last, game.interface.minimum)
    else
        parts[#parts+1] = 'No Interface range is known for it.'
    end
    if game.note then
        parts[#parts+1] = game.note
    end
    return table.concat(parts, '\n\n')
end

--- What a game type word means (a game, an alias or a family).
---@param word string
---@return string?
local function describeGameWord(word)
    local ids = syntax.resolveGameWord(word)
    if not ids then
        return nil
    end
    local lower = word:lower()
    if syntax.familyGames[lower] and not syntax.gameById[lower] then
        ---@type string[]
        local names = {}
        for _, id in ipairs(ids) do
            names[#names+1] = syntax.gameById[id].display
        end
        return ('**%s** (family): %s.'):format(word, table.concat(names, ', '))
    end
    return describeGame(syntax.gameById[ids[1]])
end

--- The category a `## Category` line is about: by its English name, or (a localized line) by its translation.
---@param line wowToc.line
---@return wowToc.category?
local function categoryOf(line)
    if not line.value or line.value == '' then
        return nil
    end
    local wanted = syntax.normalizeName(line.value)
    local found = syntax.categoryByName[wanted]
    if found or not line.locale then
        return found
    end
    for _, category in ipairs(syntax.categories) do
        for _, text in pairs(category.names) do
            if syntax.normalizeName(text) == wanted then
                return category
            end
        end
    end
    return nil
end

--- Markdown for a category: what fits it and its translations.
---@param category wowToc.category
---@return string
local function describeCategory(category)
    local parts = { ('**%s** (an Addon Categories name)'):format(category.name) }
    if category.description then
        parts[#parts+1] = category.description
    end
    ---@type string[]
    local rows = {}
    for _, locale in ipairs(games.locales) do
        if category.names[locale] then
            rows[#rows+1] = ('`%s` %s'):format(locale, category.names[locale])
        end
    end
    if #rows > 0 then
        parts[#parts+1] = table.concat(rows, ' · ')
    end
    return table.concat(parts, '\n\n')
end

--- "Loads on ..." for a line.
---@param uri    uri
---@param cursor wowToc.cursor
---@return string
local function loadScope(uri, cursor)
    local fileScope, suffix = syntax.fileScope(uri)
    local scope = syntax.lineScope(fileScope, cursor.lines, cursor.line)
    local everything = true
    for _, id in ipairs(syntax.gameOrder) do
        if not scope[id] then
            everything = false
        end
    end
    ---@type string
    local text
    if everything then
        text = 'Loads on every game type.'
    else
        text = 'Loads on: ' .. syntax.describeGames(scope) .. '.'
    end
    if suffix then
        text = text .. (' The file name suffix `_%s` restricts the whole file.'):format(suffix)
    end
    return text
end

-- Tokens ------------------------------------------------------------------------------------------------

--- The word of `text` (separated by commas and blanks) around a 1-based byte.
---@param text string
---@param at   integer
---@return string? word, integer? first, integer? last
local function wordAt(text, at)
    local first = at
    while first > 1 and not text:sub(first - 1, first - 1):match('[%s,%[%]]') do
        first = first - 1
    end
    local last = at - 1
    while last < #text and not text:sub(last + 1, last + 1):match('[%s,%[%]]') do
        last = last + 1
    end
    if last < first then
        return nil
    end
    return text:sub(first, last), first, last
end

-- Hover -------------------------------------------------------------------------------------------------

---@param uri      uri
---@param text     string
---@param position fileKind.position
---@return fileKind.hover?
local function hover(uri, text, position)
    local cursor = cursorAt(text, position)
    local line = cursor.line
    local at = cursor.col + 1
    ---@param first integer
    ---@param last  integer
    ---@return fileKind.range
    local function range(first, last)
        return rangeOf(line.row, cursor.text, first, last)
    end

    -- inside a bracket (on a header or on a file line)
    for _, bracket in ipairs(line.brackets) do
        if at >= bracket.start and at <= bracket.finish then
            if at >= bracket.nameStart and at <= bracket.nameFinish + 1 then
                local lower = bracket.name:lower()
                for _, inline in ipairs(directives.inlines) do
                    if inline.name:lower() == lower then
                        local parts = { ('`[%s]` %s'):format(inline.name, inline.description) }
                        if inline.value == 'enum' then
                            parts[#parts+1] = 'Values: ' .. table.concat(inline.values or {}, ', ') .. '.'
                        end
                        if inline.since then
                            parts[#parts+1] = inline.since
                        end
                        return { value = table.concat(parts, '\n\n'), range = range(bracket.nameStart, bracket.nameFinish) }
                    end
                end
                local variable = syntax.variableByName[lower]
                if variable then
                    return { value = ('`[%s]` %s'):format(variable.name, variable.description), range = range(bracket.nameStart, bracket.nameFinish) }
                end
            elseif bracket.value ~= '' and at >= bracket.valueStart and at <= bracket.valueFinish then
                local lower = bracket.name:lower()
                local word, first, last = wordAt(cursor.text, at)
                if word and first and last and (lower == 'allowloadgametype' or lower == 'excludeloadgametype') then
                    local described = describeGameWord(word)
                    if described then
                        return { value = described, range = range(first, last) }
                    end
                end
            end
            return nil
        end
    end

    if line.kind == 'header' and line.key and line.keyStart and line.keyFinish then
        if at >= line.keyStart and at <= line.keyFinish + 1 and at <= line.keyFinish then
            local directive, locale, custom = syntax.directiveOf(line.key)
            if directive then
                local parts = { ('**%s**%s'):format(directive.name, locale and (' (localized for ' .. locale .. ')') or '') }
                parts[#parts+1] = directive.description
                ---@type string[]
                local flags = {}
                if directive.appends then flags[#flags+1] = 'a repeated line adds to the list' end
                if directive.firstWins then flags[#flags+1] = 'only the first line counts' end
                if directive.irreversible then flags[#flags+1] = 'once `1` it stays `1`' end
                if directive.restricted then flags[#flags+1] = 'not available to third-party addons' end
                if directive.only then flags[#flags+1] = 'only on ' .. table.concat(directive.only, ', ') end
                if directive.localizable and not locale then flags[#flags+1] = 'localizable: `' .. directive.name .. '-<locale>`' end
                if directive.aliases then flags[#flags+1] = 'also: ' .. table.concat(directive.aliases, ', ') end
                if #flags > 0 then
                    parts[#parts+1] = table.concat(flags, '; ') .. '.'
                end
                if directive.since then
                    parts[#parts+1] = directive.since
                end
                return { value = table.concat(parts, '\n\n'), range = range(line.keyStart, line.keyFinish) }
            elseif custom then
                return {
                    value = ('**%s**\n\nA custom key: the client keeps every `X-` key, `C_AddOns.GetAddOnMetadata` reads it.'):format(line.key),
                    range = range(line.keyStart, line.keyFinish),
                }
            end
            return nil
        end
        if line.directive and line.directive.name == 'Category' and line.valueStart and line.valueFinish
            and at >= line.valueStart and at <= line.valueFinish then
            local category = categoryOf(line)
            if category then
                return { value = describeCategory(category), range = range(line.valueStart, line.valueFinish) }
            end
            return nil
        end
        if line.directive and line.value and line.valueStart and line.valueFinish and at >= line.valueStart and at <= line.valueFinish then
            local word, first, last = wordAt(cursor.text, at)
            if word and first and last then
                local kind = line.directive.value
                if kind == 'interface' then
                    ---@type integer?
                    local number
                    if word:match('^%d+$') then
                        number = tonumber(word) --[[@as integer]]
                    end
                    if number and number > 0 then
                        local parts = { ('`%d` reads as **%s**.'):format(number, readInterface(number)) }
                        for _, id in ipairs(syntax.gameOrder) do
                            local game = syntax.gameById[id]
                            if game.interface and number >= game.interface.first and number <= game.interface.last then
                                parts[#parts+1] = ('A number of %s (today at least `%d`).'):format(game.display, game.interface.minimum)
                            end
                        end
                        return { value = table.concat(parts, '\n\n'), range = range(first, last) }
                    end
                elseif kind == 'gametypes' then
                    local described = describeGameWord(word)
                    if described then
                        return { value = described, range = range(first, last) }
                    end
                end
            end
        end
        return nil
    end

    if line.kind == 'file' and line.path and line.pathStart and line.pathFinish and at >= line.pathStart and at <= line.pathFinish then
        -- a variable inside the path
        for first, name, last in line.text:gmatch('()%[(%a+)%]()') --[==[@as fun(): (integer, string, integer)]==] do
            local variable = syntax.variableByName[name:lower()]
            if variable and at >= first and at < last then
                return { value = ('`[%s]` %s'):format(variable.name, variable.description), range = range(first, last - 1) }
            end
        end
    end
    if line.kind == 'file' and line.path and line.path ~= '' and line.pathStart and line.pathFinish
        and at >= line.pathStart and at <= line.pathFinish then
        return { value = loadScope(uri, cursor), range = range(line.pathStart, line.pathFinish) }
    end
    return nil
end

-- Definition --------------------------------------------------------------------------------------------

---@param uri      uri
---@param text     string
---@param position fileKind.position
---@return table[]?
local function definition(uri, text, position)
    local cursor = cursorAt(text, position)
    local line = cursor.line
    local at = cursor.col + 1
    if line.kind ~= 'file' or not line.path or line.path == '' or not line.pathStart or not line.pathFinish then
        return nil
    end
    if at < line.pathStart or at > line.pathFinish + 1 or line.path:find('%[%a+%]') then
        return nil
    end
    local dir = directoryOf(uri)
    if not dir then
        return nil
    end
    local target = dir .. '/' .. line.path:gsub('\\', '/')
    local ok, exists = pcall(fs.exists, fs.path(target))
    if not ok or not exists then
        return nil
    end
    local zero = { line = 0, character = 0 }
    return { { uri = furi.encode(target), range = { start = zero, ['end'] = zero } } }
end

-- Completion --------------------------------------------------------------------------------------------

---@param cursor wowToc.cursor
---@param first  integer where the typed word starts
---@param done   table<string, true>?  words already in the list (not offered again)
---@return table[]
local function gameTypeItems(cursor, first, done)
    ---@type wowToc.completionItem[]
    local items = {}
    ---@type table<string, true>
    local seen = {}
    ---@param word    string
    ---@param detail  string
    ---@param kind    integer
    local function add(word, detail, kind)
        if seen[word:lower()] or (done and done[word:lower()]) then
            return
        end
        seen[word:lower()] = true
        items[#items+1] = item(word, kind, cursor, first, { detail = detail })
    end
    for _, id in ipairs(syntax.gameOrder) do
        local game = syntax.gameById[id]
        add(id, game.display, CompletionItemKind.Enum)
        for _, alias in ipairs(game.aliases or {}) do
            add(alias, game.display, CompletionItemKind.Enum)
        end
    end
    for _, family in ipairs(games.families) do
        add(family.id, family.display .. ' (family)', CompletionItemKind.Enum)
    end
    return items
end

---@param cursor wowToc.cursor
---@param first  integer
---@param valueKind string
---@param values?   string[]
---@param done?     table<string, true>
---@return table[]
local function valueItems(cursor, first, valueKind, values, done)
    ---@type wowToc.completionItem[]
    local items = {}
    if valueKind == 'boolean01' then
        items[#items+1] = item('1', CompletionItemKind.Value, cursor, first, { detail = 'on' })
        items[#items+1] = item('0', CompletionItemKind.Value, cursor, first, { detail = 'off' })
    elseif valueKind == 'enum' then
        for _, value in ipairs(values or {}) do
            items[#items+1] = item(value, CompletionItemKind.Enum, cursor, first)
        end
    elseif valueKind == 'gametypes' then
        return gameTypeItems(cursor, first, done)
    elseif valueKind == 'locales' then
        for _, locale in ipairs(games.locales) do
            if not (done and done[locale:lower()]) then
                items[#items+1] = item(locale, CompletionItemKind.Enum, cursor, first)
            end
        end
    elseif valueKind == 'interface' then
        for _, id in ipairs(syntax.gameOrder) do
            local game = syntax.gameById[id]
            if game.interface then
                local number = tostring(game.interface.minimum)
                if not (done and done[number]) then
                    items[#items+1] = item(number, CompletionItemKind.Value, cursor, first, {
                        detail = ('%s, %s'):format(game.display, readInterface(game.interface.minimum)),
                        sortText = ('%08d'):format(1000000 - game.interface.minimum),
                    })
                end
            end
        end
    end
    return items
end

--- The words already written in a list (lowercase), for not offering them twice.
---@param text string
---@return table<string, true>
local function wordsOf(text)
    ---@type table<string, true>
    local done = {}
    for word in text:gmatch('[^%s,]+') do
        done[word:lower()] = true
    end
    return done
end

---@param uri      uri
---@param cursor   wowToc.cursor
---@return table[]?
local function completePath(uri, cursor)
    local line = cursor.line
    local typed = cursor.prefix:gsub('^%s+', '')
    local dir = directoryOf(uri)
    if not dir or typed:find('[%[%]]') then
        return nil
    end
    local first = cursor.col - #typed + 1
    local folder, partial = typed:match('^(.*[/\\])([^/\\]*)$')
    if not folder then
        folder, partial = '', typed
    end
    ---@type wowToc.completionItem[]
    local items = {}
    local ok, err = pcall(function ()
        for entry in fs.pairs(fs.path(dir .. '/' .. folder:gsub('\\', '/'))) do
            local name = entry:filename():string()
            local lower = name:lower()
            local isDirectory = fs.is_directory(entry)
            local wanted = isDirectory or lower:sub(-4) == '.lua' or lower:sub(-4) == '.xml'
            if wanted and name:sub(1, 1) ~= '.' and lower:sub(1, #partial) == partial:lower() then
                local start = first + #folder
                items[#items+1] = {
                    label    = isDirectory and (name .. '\\') or name,
                    kind     = isDirectory and CompletionItemKind.Folder or CompletionItemKind.File,
                    textEdit = {
                        range   = rangeOf(line.row, cursor.text, start, cursor.col),
                        newText = isDirectory and (name .. '\\') or name,
                    },
                    sortText = (isDirectory and '1' or '0') .. lower,
                }
            end
        end
    end)
    if not ok then
        log.warn('toc: cannot list ' .. tostring(err))
        return nil
    end
    return items
end

--- The values of `## Category:` (the English names) or `## Category-xxXX:` (the translations, those of the plain line's category first).
---@param cursor wowToc.cursor
---@param locale string?
---@return wowToc.completionItem[]
local function categoryItems(cursor, locale)
    ---@type string?
    local canonical
    if locale then
        for _, item in ipairs(games.locales) do
            if item:lower() == locale:lower() then
                canonical = item
            end
        end
        if not canonical then
            return {}
        end
    end
    ---@type wowToc.category?
    local base
    for _, line in ipairs(cursor.lines) do
        if line.kind == 'header' and line.directive and line.directive.name == 'Category' and not line.locale then
            base = categoryOf(line) or base
        end
    end
    local first = (cursor.prefix:match('^##%s*[%w_%-]+%s*:%s?()')) or (cursor.col + 1)
    ---@type wowToc.completionItem[]
    local items = {}
    for _, category in ipairs(syntax.categories) do
        local text = canonical and category.names[canonical] or (not canonical and category.name) or nil
        if text then
            items[#items+1] = {
                label    = text,
                kind     = CompletionItemKind.Enum,
                detail   = canonical and category.name or category.description,
                textEdit = { range = rangeOf(cursor.line.row, cursor.text, first, #cursor.text), newText = text },
                sortText = ((base == category) and '0' or '1') .. text:lower(),
            }
        end
    end
    return items
end

---@param uri      uri
---@param text     string
---@param position fileKind.position
---@return table[]?
local function complete(uri, text, position)
    local cursor = cursorAt(text, position)
    local prefix = cursor.prefix

    -- inside a `[` bracket not closed before the cursor
    local open = prefix:match('.*()%[') --[[@as integer?]]
    local closed = prefix:match('.*()%]') --[[@as integer?]]
    if open and (not closed or closed < open) then
        local inner = prefix:sub(open + 1)
        ---@type string, string
        local name, rest = inner:match('^%s*([%w_]*)(.*)$')
        if rest == '' then
            local first = open + 1 + #(inner:match('^%s*') or '')
            ---@type wowToc.completionItem[]
            local items = {}
            local closing = cursor.suffix:sub(1, 1) == ']'
            for _, inline in ipairs(directives.inlines) do
                local entry = item(inline.name, CompletionItemKind.Keyword, cursor, first, { detail = inline.description })
                if inline.value == 'none' then
                    entry.textEdit.newText = inline.name .. (closing and '' or ']')
                else
                    entry.textEdit.newText = inline.name .. ' '
                end
                items[#items+1] = entry
            end
            for _, variable in ipairs(directives.variables) do
                local entry = item(variable.name, CompletionItemKind.Variable, cursor, first, { detail = variable.description })
                entry.textEdit.newText = variable.name .. (closing and '' or ']')
                items[#items+1] = entry
            end
            return items
        end
        -- the value of an inline directive
        local lower = name:lower()
        for _, inline in ipairs(directives.inlines) do
            if inline.name:lower() == lower and inline.value ~= 'none' then
                ---@type string
                local value = rest:gsub('^%s+', '')
                local word = value:match('[^%s,]*$') or ''
                local first = cursor.col - #word + 1
                return valueItems(cursor, first, inline.value, inline.values, wordsOf(value:sub(1, #value - #word)))
            end
        end
        return {}
    end

    -- `## Key` and `## Key: value`
    local keyPart = prefix:match('^##%s*([%w_%-]*)$')
    if keyPart then
        local first = cursor.col - #keyPart + 1
        ---@type string?, string?
        local base, tag = keyPart:match('^([%w_]+)%-([%w_]*)$')
        ---@type wowToc.completionItem[]
        local items = {}
        if base then
            local directive = syntax.headerByName[base:lower()]
            if directive and directive.localizable then
                local tagFirst = cursor.col - #(tag or '') + 1
                for _, locale in ipairs(games.locales) do
                    items[#items+1] = item(locale, CompletionItemKind.Enum, cursor, tagFirst, { detail = 'locale' })
                end
            end
            return items
        end
        for _, directive in ipairs(directives.headers) do
            local entry = item(directive.name, CompletionItemKind.Property, cursor, first, {
                detail   = directive.value,
                sortText = (directive.restricted and '1' or '0') .. directive.name:lower(),
            })
            local hasColon = cursor.suffix:match('^%s*:') ~= nil
            entry.textEdit.newText = directive.name .. (hasColon and '' or ': ')
            if directive.restricted then
                entry.tags = { 1 }
                entry.documentation = 'Not available to third-party addons.'
            end
            items[#items+1] = entry
        end
        return items
    end

    local key, value = prefix:match('^##%s*([%w_%-]+)%s*:%s?(.*)$')
    if key then
        local directive, keyLocale = syntax.directiveOf(key)
        if not directive then
            return {}
        end
        if directive.name == 'Category' then
            return categoryItems(cursor, keyLocale)
        end
        local word = value:match('[^%s,]*$') or ''
        local first = cursor.col - #word + 1
        ---@type table<string, true>?
        local done
        if directive.value == 'gametypes' or directive.value == 'interface' then
            done = wordsOf(value:sub(1, #value - #word))
        end
        return valueItems(cursor, first, directive.value, directive.values, done)
    end

    -- a file line
    if prefix:sub(1, 1) ~= '#' then
        return completePath(uri, cursor)
    end
    return nil
end

syntax.kind.complete   = complete
syntax.kind.hover      = hover
syntax.kind.definition = definition
