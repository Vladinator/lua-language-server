-- Completion, hover and definition for WoW `.toc` files (see syntax.lua for the parser, the scope rules and the diagnostics; games.lua and
-- directives.lua for the data). Adds the three features to the `toc` file kind that syntax.lua registered.

local fs         = require 'bee.filesystem'
local furi       = require 'file-uri'
local fileKinds  = require 'file-kinds'
local lang       = require 'language'
local games      = require 'core.diagnostics.extra.wow-toc.games'
local directives = require 'core.diagnostics.extra.wow-toc.directives'
local syntax     = require 'core.diagnostics.extra.wow-toc.syntax'

---@alias wowToc.completionItem table<string, any>

local CompletionItemKind = { Module = 9, Text = 1, Value = 12, Enum = 13, Keyword = 14, File = 17, Variable = 6, Property = 10, Folder = 19, Constant = 21, Function = 3 }

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

-- The look of a hover (HOVER-STYLE.md in the docs repo): a code-fenced signature, a summary, then short labelled facts -------------------------

--- The shape of the value of a directive, for the signature line.
---@param directive wowToc.directive
---@return string
local function valueShape(directive)
    local kind = directive.value
    if kind == 'text' then return '<text>' end
    if kind == 'boolean01' then return '<0|1>' end
    if kind == 'interface' then return '<number>[, <number>...]' end
    if kind == 'names' then return directive.addons and '<AddonName>[, <AddonName>...]' or '<GlobalName>[, <GlobalName>...]' end
    if kind == 'gametypes' then return '<game type>[, <game type>...]' end
    if kind == 'function' then return '<GlobalFunction>' end
    if kind == 'path' then return '<path>' end
    if kind == 'enum' then return '<' .. table.concat(directive.values or {}, '|') .. '>' end
    return '<value>'
end

--- What the value of a directive is, in a few words.
---@param directive wowToc.directive
---@return string
local function valueMeaning(directive)
    local kind = directive.value
    if kind == 'text' then return 'free text' end
    if kind == 'boolean01' then return '`1` (yes) or `0` (no)' end
    if kind == 'interface' then return 'whole numbers above 0, comma separated (`120100` is 12.1.0)' end
    if kind == 'names' then return directive.addons and 'names of addon folders, comma separated' or 'names of global variables, comma separated' end
    if kind == 'gametypes' then return 'game types or families, comma separated (`standard`, `classic`, ...)' end
    if kind == 'function' then return 'the name of a global function' end
    if kind == 'path' then return 'a path in the game files' end
    if kind == 'enum' then return table.concat((function ()
        ---@type string[]
        local shown = {}
        for _, value in ipairs(directive.values or {}) do shown[#shown+1] = '`' .. value .. '`' end
        return shown
    end)(), ', ') end
    return ''
end

--- A card: the signature in a code block, the summary, then labelled facts as a list.
---@param signature string
---@param summary   string?
---@param facts     string[]  each `**Label:** text`
---@return string
local function card(signature, summary, facts)
    local parts = { '```toc\n' .. signature .. '\n```' }
    if summary and summary ~= '' then
        parts[#parts+1] = summary
    end
    if #facts > 0 then
        ---@type string[]
        local rows = {}
        for _, fact in ipairs(facts) do rows[#rows+1] = '- ' .. fact end
        parts[#parts+1] = table.concat(rows, '\n')
    end
    return table.concat(parts, '\n\n')
end

--- The card of a `## Key: value` directive (`locale`: the key is a localized variant).
---@param directive wowToc.directive
---@param locale    string?
---@param typed     string  the key as it is written
---@return string
local function describeDirective(directive, locale, typed)
    local key = typed
    ---@type string[]
    local facts = { '**Value:** ' .. valueMeaning(directive) .. '.' }
    if directive.appends then
        facts[#facts+1] = '**Repeating the line:** adds to the list.'
    elseif directive.firstWins then
        facts[#facts+1] = '**Repeating the line:** only the first one counts.'
    else
        facts[#facts+1] = '**Repeating the line:** the last one wins.'
    end
    if directive.irreversible then
        facts[#facts+1] = '**Note:** once `1`, it cannot be turned off later in the file.'
    end
    if directive.localizable and not locale then
        facts[#facts+1] = ('**Localized:** `%s-<locale>` (for example `%s-deDE`). Write the plain line first, or the localized ones go unused.'):format(directive.name, directive.name)
    elseif locale then
        facts[#facts+1] = ('**Localized:** the text for the `%s` client. The plain `%s` line must come first.'):format(locale, directive.name)
    end
    if directive.aliases or directive.prefixes then
        ---@type string[]
        local also = {}
        for _, alias in ipairs(directive.aliases or {}) do also[#also+1] = '`' .. alias .. '`' end
        for _, prefix in ipairs(directive.prefixes or {}) do also[#also+1] = 'any key that starts with `' .. prefix .. '`' end
        facts[#facts+1] = '**Also written:** ' .. table.concat(also, ', ') .. '.'
    end
    if directive.only then
        facts[#facts+1] = '**Games:** only ' .. table.concat(directive.only, ', ') .. '.'
    end
    if directive.restricted then
        facts[#facts+1] = '**Not available** to third-party addons.'
    end
    if directive.since then
        facts[#facts+1] = '**History:** ' .. directive.since
    end
    return card(('## %s: %s'):format(key, valueShape(directive)), directive.description, facts)
end

--- The card of an inline directive (`[AllowLoadGameType standard]`).
---@param inline wowToc.inline
---@return string
local function describeInline(inline)
    local shape = ({
        none     = '',
        gametypes = ' <game type>[, <game type>...]',
        locales  = ' <locale>[, <locale>...]',
    })[inline.value]
    if inline.value == 'enum' then
        shape = ' <' .. table.concat(inline.values or {}, '|') .. '>'
    end
    ---@type string[]
    local facts = {}
    if inline.value == 'enum' then
        ---@type string[]
        local shown = {}
        for _, value in ipairs(inline.values or {}) do shown[#shown+1] = '`' .. value .. '`' end
        facts[#facts+1] = '**Values:** ' .. table.concat(shown, ', ') .. ' (case-insensitive).'
    elseif inline.value == 'gametypes' then
        facts[#facts+1] = '**Values:** game types or families, comma separated (`standard`, `classic`, ...).'
    elseif inline.value == 'locales' then
        facts[#facts+1] = '**Values:** client locales as `GetLocale` returns them (`enUS`, `frFR`, ...), comma separated.'
    else
        facts[#facts+1] = '**Values:** none.'
    end
    facts[#facts+1] = '**Where:** after the file name, or on a `## Key:` line; several brackets can follow each other.'
    if inline.only then
        facts[#facts+1] = '**Games:** only ' .. table.concat(inline.only, ', ') .. '.'
    end
    if inline.since then
        facts[#facts+1] = '**History:** ' .. inline.since
    end
    return card('[' .. inline.name .. shape .. ']', inline.description, facts)
end

--- The card of a `[Variable]` of a path.
---@param variable wowToc.variable
---@return string
local function describeVariable(variable)
    return card('[' .. variable.name .. ']', variable.description, { '**Use:** anywhere in a line, usually in a file path.' })
end

-- Completion and hover of the `# @diagnostic` comment ----------------------------------------------------------------

--- The parts of a `# @diagnostic <mode>: toc-x, toc-y` comment line, with their 1-based byte positions.
---@param text string
---@return { first: integer, last: integer }? keyword  the `@diagnostic` word
---@return { name: string, first: integer, last: integer }? mode
---@return { name: string, first: integer, last: integer }[] codes
local function diagnosticCommentParts(text)
    ---@type integer?
    local hash = text:match('^#%s*()@diagnostic')
    if not hash then
        return nil, nil, {}
    end
    local keyword = { first = hash, last = hash + #'@diagnostic' - 1 }
    local modeFirst, modeName = text:match('^#%s*@diagnostic%s+()([%a%-]+)')
    ---@type { name: string, first: integer, last: integer }?
    local mode
    ---@type { name: string, first: integer, last: integer }[]
    local codes = {}
    if modeFirst and modeName then
        mode = { name = modeName, first = modeFirst, last = modeFirst + #modeName - 1 }
        local colon = text:find(':', mode.last + 1, true)
        if colon then
            for first, name in text:gmatch('()([^%s,]+)', colon + 1) --[==[@as fun(): (integer, string)]==] do
                codes[#codes+1] = { name = name, first = first, last = first + #name - 1 }
            end
        end
    end
    return keyword, mode, codes
end

---@param code string
---@return string?  markdown
local function describeTocCode(code)
    for _, info in ipairs(syntax.diagnosticInfos) do
        if info[1] == code then
            return card('diagnostic  ' .. code, (info[3]:gsub('^Enable diagnostics for ', 'Reports ')), {
                '**Default severity:** ' .. info[2]:lower() .. '.',
                ('**Switch it off:** `# @diagnostic disable-next-line: %s` above a line, `# @diagnostic disable: %s` for the rest of the file, or `Lua.diagnostics.disable` for the workspace.'):format(code, code),
            })
        end
    end
    return nil
end

-- The addons next to this one ------------------------------------------------------------------------------------

---@class wowToc.addon
---@field name string  the folder name
---@field toc  string  path of its `.toc`

--- The addons installed next to the addon of a `.toc` (the folders of the parent folder that hold a `<Name>/<Name>.toc`), by lowercase name.
---@param uri uri
---@return table<string, wowToc.addon>
local function siblingAddons(uri)
    ---@type table<string, wowToc.addon>
    local found = {}
    local dir = directoryOf(uri)
    local parent = dir and dir:match('^(.*)[/\\][^/\\]*$')
    if not dir or not parent then
        return found
    end
    ---@type string
    local own = (dir:match('([^/\\]+)$') or ''):lower()
    pcall(function ()
        for entry in fs.pairs(fs.path(parent)) do
            ---@type string
            local name = entry:filename():string()
            ---@type string
            local toc = parent .. '/' .. name .. '/' .. name .. '.toc'
            if name:lower() ~= own and name:sub(1, 1) ~= '.' and fs.is_directory(entry) and fs.exists(fs.path(toc)) then
                found[name:lower()] = { name = name, toc = toc }
            end
        end
    end)
    return found
end

--- The `## Title:` of a `.toc` file on disk (plain, first one), if it has one.
---@param path string
---@return string?
local function titleOf(path)
    local file = io.open(path, 'rb')
    if not file then
        return nil
    end
    ---@type string
    local text = file:read('a')
    file:close()
    for line in (text .. string.char(10)):gmatch('(.-)\r?\n') do
        local title = line:match('^##%s*Title%s*:%s*(.-)%s*$')
        if title and title ~= '' then
            return title
        end
    end
    return nil
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
    ---@type string[]
    local facts = {}
    if game.aliases and #game.aliases > 0 then
        facts[#facts+1] = '**Also written:** `' .. table.concat(game.aliases, '`, `') .. '`.'
    end
    facts[#facts+1] = '**Families:** ' .. table.concat(game.families, ', ') .. '.'
    facts[#facts+1] = '**File name suffix:** `_' .. table.concat(game.suffixes, '`, `_') .. '` (`Name_' .. game.suffixes[1] .. '.toc`).'
    if game.interface then
        facts[#facts+1] = ('**Interface numbers:** `%d` to `%d`; the lowest worth declaring today is `%d`.'):format(game.interface.first, game.interface.last, game.interface.minimum)
    else
        facts[#facts+1] = '**Interface numbers:** no range is known for it.'
    end
    if game.upcoming then
        if game.interface then
            facts[#facts+1] = ('**Upcoming:** `%d` is the newest test / beta number; the released `%d` stays the one to declare.'):format(
                game.upcoming, game.interface.minimum)
        else
            facts[#facts+1] = ('**Not released yet:** its newest test / beta number is `%d`.'):format(game.upcoming)
        end
    end
    return card('game type  ' .. game.id, game.display .. '.' .. (game.note and (' ' .. game.note) or ''), facts)
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
        local family = lower:gsub('^%l', string.upper)
        return card('game family  ' .. lower, 'Every game type of the ' .. family .. ' family.',
            { '**Game types:** ' .. table.concat(names, ', ') .. '.', ('**File name suffix:** `_%s` (`Name_%s.toc`).'):format(family, family) })
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
    ---@type string[]
    local facts = {}
    for _, locale in ipairs(games.locales) do
        if category.names[locale] then
            facts[#facts+1] = ('`%s`  %s'):format(locale, category.names[locale])
        end
    end
    ---@type string[]
    local rows = {}
    for _, fact in ipairs(facts) do rows[#rows+1] = fact end
    local text = card('## Category: ' .. category.name, 'A recommended category of the Addon Categories page.'
        .. (category.description and (' ' .. category.description .. '.') or ''), {})
    if #rows > 0 then
        text = text .. '\n\n**Translations** (`## Category-<locale>:`)\n\n- ' .. table.concat(rows, '\n- ')
    end
    return text
end

--- "Loads on ..." for a line.
---@param uri    uri
---@param cursor wowToc.cursor
---@return string
local function loadScope(uri, cursor)
    local fileScope, suffix, base = syntax.fileScope(uri)
    local scope = syntax.lineScope(fileScope, cursor.lines, cursor.line)
    local everything = true
    for _, id in ipairs(syntax.gameOrder) do
        if not scope[id] then
            everything = false
        end
    end
    ---@type string
    local summary
    if everything then
        summary = 'Loads on every game type.'
    else
        summary = 'Loads on: ' .. syntax.describeGames(scope) .. '.'
    end
    ---@type string[]
    local facts = {}
    if suffix then
        facts[#facts+1] = ('**File name suffix:** `_%s` restricts the whole file.'):format(suffix)
    else
        -- a file without a suffix is the fallback of its folder: any game type without a file of its own reads it, one that comes later included
        facts[#facts+1] = ('**Fallback file:** read by every game type that has no `%s_<Suffix>.toc` next to it, a game type added later included.')
            :format(base)
        ---@type string[]
        local taken = {}
        for _, sibling in ipairs(syntax.siblingFiles(uri)) do
            taken[#taken+1] = ('`%s` (%s)'):format(sibling.file, syntax.describeGames(sibling.games))
        end
        if #taken > 0 then
            facts[#facts+1] = '**Taken by the files next to it:** ' .. table.concat(taken, '; ') .. '.'
        end
    end
    return card(cursor.line.path or 'file', summary, facts)
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

    -- the `# @diagnostic <mode>: toc-x` comment: the keyword, the mode and the codes
    if line.kind == 'comment' then
        local keyword, mode, codes = diagnosticCommentParts(cursor.text)
        if keyword then
            if at >= keyword.first and at <= keyword.last + 1 then
                return {
                    value = card('# @diagnostic <mode>: <code>[, <code>...]',
                        'Switches `toc-*` diagnostics off or on, like the LuaDoc comment does for Lua.', {
                            '**Modes:** `disable-next-line`, `disable`, `enable`, `expect-next-line`.',
                            '**Codes:** no code after the colon means every diagnostic.',
                            '**Note:** a `#` line is a comment for the game, so the file does not change.',
                        }),
                    range = range(keyword.first, keyword.last),
                }
            end
            if mode and at >= mode.first and at <= mode.last + 1 then
                for _, info in ipairs(directives.diagnosticModes) do
                    if info.name == mode.name:lower() then
                        return {
                            value = card('# @diagnostic ' .. info.name .. ': <code>[, <code>...]', info.description, {}),
                            range = range(mode.first, mode.last),
                        }
                    end
                end
                return nil
            end
            for _, code in ipairs(codes) do
                if at >= code.first and at <= code.last + 1 then
                    local described = describeTocCode(code.name:lower())
                    return described and { value = described, range = range(code.first, code.last) } or nil
                end
            end
        end
        return nil
    end

    -- inside a bracket (on a header or on a file line)
    for _, bracket in ipairs(line.brackets) do
        if at >= bracket.start and at <= bracket.finish then
            if at >= bracket.nameStart and at <= bracket.nameFinish + 1 then
                local lower = bracket.name:lower()
                for _, inline in ipairs(directives.inlines) do
                    if inline.name:lower() == lower then
                        return { value = describeInline(inline), range = range(bracket.nameStart, bracket.nameFinish) }
                    end
                end
                local variable = syntax.variableByName[lower]
                if variable then
                    return { value = describeVariable(variable), range = range(bracket.nameStart, bracket.nameFinish) }
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
                return { value = describeDirective(directive, locale, line.key), range = range(line.keyStart, line.keyFinish) }
            elseif custom then
                return {
                    value = card(('## %s: <text>'):format(line.key), 'A custom key of your own.',
                        { '**Value:** free text.', '**Read with:** `C_AddOns.GetAddOnMetadata(addon, "' .. line.key .. '")`.',
                          '**Note:** the client keeps every key that starts with `X-`.' }),
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
                        ---@type string[]
                        local facts = {}
                        for _, id in ipairs(syntax.gameOrder) do
                            local game = syntax.gameById[id]
                            if game.interface and number >= game.interface.first and number <= game.interface.last then
                                facts[#facts+1] = ('**Game:** %s. The lowest number worth declaring today is `%d`.'):format(game.display, game.interface.minimum)
                            end
                            -- (the number the game is about to move to: a test / beta number ahead of the release, also for a game with no range)
                            if game.upcoming == number then
                                facts[#facts+1] = ('**Upcoming:** the newest test / beta number of %s%s.'):format(game.display,
                                    game.interface and (' (released: `%d`)'):format(game.interface.minimum) or ' (not released yet)')
                            end
                        end
                        if #facts == 0 then
                            facts[1] = '**Game:** none of the known game types uses this range.'
                        end
                        return {
                            value = card('Interface  ' .. number, ('Reads as **%s** (major.minor.patch).'):format(readInterface(number)), facts),
                            range = range(first, last),
                        }
                    end
                elseif kind == 'gametypes' then
                    local described = describeGameWord(word)
                    if described then
                        return { value = described, range = range(first, last) }
                    end
                elseif line.directive.addons then
                    local addon = siblingAddons(uri)[word:lower()]
                    if addon then
                        local title = titleOf(addon.toc)
                        return {
                            value = card('addon  ' .. addon.name, title and ('**' .. title .. '**') or 'An addon installed next to this one.',
                                { '**Table of contents:** `' .. addon.toc .. '`.' }),
                            range = range(first, last),
                        }
                    end
                    return {
                        value = card('addon  ' .. word, ('No addon `%s` is installed next to this one.'):format(word),
                            { '**Looked in:** the folders next to this addon, for `<Name>/<Name>.toc`.' }),
                        range = range(first, last),
                    }
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
                return { value = describeVariable(variable), range = range(first, last - 1) }
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
    -- an addon named in a list of addons: its `.toc`
    if line.kind == 'header' and line.directive and line.directive.addons and line.value and line.valueStart and line.valueFinish
        and at >= line.valueStart and at <= line.valueFinish + 1 then
        local word = wordAt(cursor.text, math.min(at, line.valueFinish))
        local addon = word and siblingAddons(uri)[word:lower()]
        if addon then
            local zero = { line = 0, character = 0 }
            return { { uri = furi.encode(addon.toc), range = { start = zero, ['end'] = zero } } }
        end
        return nil
    end
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
            -- (the released number first, then the one the game is about to move to; a game with no release has only the second)
            local anchor = game.interface and game.interface.minimum or game.upcoming or 0
            if game.interface then
                local number = tostring(game.interface.minimum)
                if not (done and done[number]) then
                    items[#items+1] = item(number, CompletionItemKind.Value, cursor, first, {
                        detail = ('%s, %s'):format(game.display, readInterface(game.interface.minimum)),
                        sortText = ('%08d0'):format(1000000 - anchor),
                    })
                end
            end
            if game.upcoming then
                local number = tostring(game.upcoming)
                if not (done and done[number]) then
                    items[#items+1] = item(number, CompletionItemKind.Value, cursor, first, {
                        detail = ('%s, %s, upcoming'):format(game.display, readInterface(game.upcoming)),
                        sortText = ('%08d1'):format(1000000 - anchor),
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

    -- the `# @diagnostic <mode>: toc-x` comment (the TOC counterpart of the LuaDoc comment)
    local keywordWord = prefix:match('^#%s*@(%a*)$')
    if keywordWord then
        return { item('diagnostic', CompletionItemKind.Keyword, cursor, cursor.col - #keywordWord + 1, {
            detail = '# @diagnostic <mode>: toc-x, toc-y',
        }) }
    end
    local modeWord = prefix:match('^#%s*@diagnostic%s+([%a%-]*)$')
    if modeWord then
        ---@type wowToc.completionItem[]
        local modes = {}
        for _, info in ipairs(directives.diagnosticModes) do
            modes[#modes+1] = item(info.name, CompletionItemKind.Keyword, cursor, cursor.col - #modeWord + 1, {
                detail = '# @diagnostic ' .. info.name .. ': <code>',
                documentation = { kind = 'markdown', value = info.description },
            })
        end
        return modes
    end
    local codeList = prefix:match('^#%s*@diagnostic%s+[%a%-]+%s*:%s*(.*)$')
    if codeList then
        local word = codeList:match('[^%s,]*$') or ''
        local done = wordsOf(codeList:sub(1, #codeList - #word))
        ---@type wowToc.completionItem[]
        local codes = {}
        for _, info in ipairs(syntax.diagnosticInfos) do
            if not done[info[1]] then
                codes[#codes+1] = item(info[1], CompletionItemKind.Value, cursor, cursor.col - #word + 1, {
                    detail = info[2], documentation = (info[3]:gsub('^Enable diagnostics for ', 'Reports ')),
                })
            end
        end
        table.sort(codes, function (a, b) return a.label < b.label end)
        return codes
    end

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
                local entry = item(inline.name, CompletionItemKind.Keyword, cursor, first, {
                    detail = '[' .. inline.name .. (inline.value == 'none' and '' or ' <value>') .. ']',
                    documentation = { kind = 'markdown', value = describeInline(inline) },
                })
                if inline.value == 'none' then
                    entry.textEdit.newText = inline.name .. (closing and '' or ']')
                else
                    entry.textEdit.newText = inline.name .. ' '
                end
                items[#items+1] = entry
            end
            for _, variable in ipairs(directives.variables) do
                local entry = item(variable.name, CompletionItemKind.Variable, cursor, first, {
                    detail = '[' .. variable.name .. ']',
                    documentation = { kind = 'markdown', value = describeVariable(variable) },
                })
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
                detail        = ('## %s: %s'):format(directive.name, valueShape(directive)),
                documentation = { kind = 'markdown', value = describeDirective(directive, nil, directive.name) },
                sortText      = (directive.restricted and '1' or '0') .. directive.name:lower(),
            })
            local hasColon = cursor.suffix:match('^%s*:') ~= nil
            entry.textEdit.newText = directive.name .. (hasColon and '' or ': ')
            if directive.restricted then
                entry.tags = { 1 }
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
        if directive.addons then
            local word = value:match('[^%s,]*$') or ''
            local first = cursor.col - #word + 1
            local done = wordsOf(value:sub(1, #value - #word))
            ---@type wowToc.completionItem[]
            local items = {}
            ---@type wowToc.addon[]
            local names = {}
            for _, addon in pairs(siblingAddons(uri)) do
                names[#names+1] = addon
            end
            table.sort(names, function (a, b) return a.name:lower() < b.name:lower() end)
            for _, addon in ipairs(names) do
                if not done[addon.name:lower()] then
                    items[#items+1] = item(addon.name, CompletionItemKind.Module, cursor, first, { detail = titleOf(addon.toc) })
                end
            end
            return items
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

-- Code actions -------------------------------------------------------------------------------------------

--- Quick fixes for the diagnostics the client sends: a "did you mean" replaces the word, a retired directive gets its new name, a category
--- translation the page's text, a retired file name suffix a rename of the file.
--- The three ways to switch a `toc-*` diagnostic off, like the ones the Lua files get: in the workspace (the setting), for the next line and for the
--- file (a `# @diagnostic` comment, see `syntax.suppressionsOf`; an existing comment of the same kind just takes the code too).
---@param uri     uri
---@param lines   wowToc.line[]
---@param diag    fileKind.clientDiagnostic
---@param actions table[]
local function disableActions(uri, lines, diag, actions)
    local code = diag.code
    if type(code) ~= 'string' or code:sub(1, 4) ~= 'toc-' then
        return
    end
    local row = diag.range.start.line
    ---@param title string
    ---@param edit  { range: fileKind.range, newText: string }
    local function push(title, edit)
        actions[#actions+1] = {
            title = title,
            kind  = 'quickfix',
            data  = 'disable',
            edit  = { changes = { [uri] = { edit } } },
        }
    end
    ---@param at   integer  0-based row of a line that may already hold the directive
    ---@param mode string
    ---@return { range: fileKind.range, newText: string }?
    local function extend(at, mode)
        local line = lines[at + 1]
        if not line or line.kind ~= 'comment' then
            return nil
        end
        local found = line.text:match('^#%s*@diagnostic%s+([%a%-]+)%s*:')
        if not found or found:lower() ~= mode then
            return nil
        end
        local finish = fileKinds.toCharacter(line.text, #line.text)
        return { range = { start = { line = at, character = finish }, ['end'] = { line = at, character = finish } }, newText = ', ' .. code }
    end
    ---@param at   integer
    ---@param mode string
    ---@return { range: fileKind.range, newText: string }
    local function insert(at, mode)
        local zero = { line = at, character = 0 }
        return { range = { start = zero, ['end'] = zero }, newText = ('# @diagnostic %s: %s\n'):format(mode, code) }
    end
    actions[#actions+1] = {
        title   = lang.script('ACTION_DISABLE_DIAG', code),
        kind    = 'quickfix',
        data    = 'disable',
        command = {
            title     = lang.script.COMMAND_DISABLE_DIAG,
            command   = 'lua.setConfig',
            arguments = { { key = 'Lua.diagnostics.disable', action = 'add', value = code, uri = uri } },
        },
    }
    push(lang.script('ACTION_DISABLE_DIAG_LINE', code), extend(row - 1, 'disable-next-line') or insert(row, 'disable-next-line'))
    push(lang.script('ACTION_DISABLE_DIAG_FILE', code), extend(0, 'disable') or insert(0, 'disable'))
end

---@param uri         uri
---@param text        string
---@param _range      fileKind.range
---@param diagnostics fileKind.clientDiagnostic[]
---@return table[]?
local function codeAction(uri, text, _range, diagnostics)
    ---@type table[]
    local actions = {}
    local lines = syntax.parse(text)
    for _, diag in ipairs(diagnostics or {}) do
        disableActions(uri, lines, diag, actions)
        local code = diag.code
        local message = tostring(diag.message or '')
        ---@param title   string
        ---@param newText string
        local function replace(title, newText)
            actions[#actions+1] = {
                title       = title,
                kind        = 'quickfix',
                diagnostics = { diag },
                isPreferred = true,
                edit        = { changes = { [uri] = { { range = diag.range, newText = newText } } } },
            }
        end
        local suggestion = message:match('%(did you mean `([^`]+)`%?%)')
        if suggestion then
            replace(('Change to `%s`'):format(suggestion), suggestion)
        elseif code == 'toc-category-translation' then
            local expected = message:match(' as `([^`]+)` for ')
            if expected then
                replace(('Use the translation `%s`'):format(expected), expected)
            end
        elseif code == 'toc-retired-header' then
            local use = message:match('renamed `([^`]+)`')
            if use then
                replace(('Rename to `%s`'):format(use), use)
            end
        elseif code == 'toc-retired-suffix' then
            local use = message:match('rename it to `_([^`]+)`')
            local newUri, count = uri:gsub('_[^_/]*%.[tT][oO][cC]$', '_' .. (use or '') .. '.toc')
            if use and count == 1 then
                actions[#actions+1] = {
                    title       = ('Rename the file to use `_%s`'):format(use),
                    kind        = 'quickfix',
                    diagnostics = { diag },
                    isPreferred = true,
                    edit        = { documentChanges = { { kind = 'rename', oldUri = uri, newUri = newUri } } },
                }
            end
        end
    end
    return actions
end

syntax.kind.codeAction = codeAction
syntax.kind.complete   = complete
syntax.kind.hover      = hover
syntax.kind.definition = definition
