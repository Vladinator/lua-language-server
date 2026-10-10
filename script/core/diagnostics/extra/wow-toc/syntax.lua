-- WoW `.toc` files as a language of their own (see TOC-SPEC.md in the docs repo): diagnostics, completion, hover and definition for the
-- file that lists an addon's metadata and the files it loads. The server does not parse a `.toc` as Lua: this plugin registers a FILE KIND
-- (script/file-kinds.lua) and everything about the syntax lives here and in the two data files next to it:
--   wow-toc/games.lua       the game types, families, suffixes, locales and Interface hints
--   wow-toc/directives.lua  the `## Key: Value` directives, the `[Inline]` directives and the `[Variables]`
-- A feature plugin (it runs no Lua diagnostic): deleting these files removes the feature. Its tests are next to it.

local fs        = require 'bee.filesystem'
local furi      = require 'file-uri'
local diagd     = require 'proto.diagnostic'
local fileKinds = require 'file-kinds'
local games     = require 'core.diagnostics.extra.wow-toc.games'
local directives = require 'core.diagnostics.extra.wow-toc.directives'
local categories = require 'core.diagnostics.extra.wow-toc.categories'

local m = {}

-- The diagnostics ---------------------------------------------------------------------------------------

---@type { [1]: string, [2]: DiagnosticSeverity, [3]: string }[]
local DIAGNOSTICS = {
    { 'toc-missing-interface',   'Warning', 'Enable diagnostics for a `.toc` file without an `## Interface` line.' },
    { 'toc-invalid-interface',   'Error',   'Enable diagnostics for an `## Interface` item that is not a whole number above 0.' },
    { 'toc-duplicate-header',    'Warning', 'Enable diagnostics for a `## Key:` line that repeats a key whose lines do not add up (the last one wins, or only the first counts).' },
    { 'toc-unknown-category',    'Hint',    'Enable diagnostics for a `## Category:` that is not one of the recommended names of the Addon Categories wiki page (a custom category is allowed, the page recommends its names).' },
    { 'toc-category-translation', 'Hint',   'Enable diagnostics for a `## Category-xxXX:` whose text differs from the Addon Categories wiki page translation of the plain `## Category:` for that locale.' },
    { 'toc-retired-header',      'Warning', 'Enable diagnostics for a `## Key:` the game dropped or renamed (`AllowLoadByGameMode`, `GuardedAddOn`, `SuppressLocalTableRef`): the line does nothing.' },
    { 'toc-unknown-header',      'Hint',    'Enable diagnostics for a `## Key:` that is not a known directive, an `X-*` custom key or a localized variant.' },
    { 'toc-invalid-value',       'Warning', 'Enable diagnostics for a value that does not fit its directive: a flag that is not 0 or 1, an unknown game type or locale, an unknown or unclosed `[inline directive]`.' },
    { 'toc-nonexistent-file',    'Warning', 'Enable diagnostics for a file line of a `.toc` that is not on disk.' },
    { 'toc-line-too-long',       'Warning', 'Enable diagnostics for a `.toc` line over 1024 characters: the game reads only the first 1024.' },
    { 'toc-localized-before-base', 'Hint',  'Enable diagnostics for a localized `Title-deDE` that comes before the plain `Title`, or has none: the localized ones go unused.' },
    { 'toc-restricted-header',   'Hint',    'Enable diagnostics for a directive that only Blizzard code may use.' },
    { 'toc-unreachable-line',    'Warning', 'Enable diagnostics for a line of a `.toc` whose load conditions and file name suffix leave no game type it can load on.' },
    { 'toc-redundant-condition', 'Hint',    'Enable diagnostics for a load condition that does not change where the line loads.' },
    { 'toc-interface-too-low',   'Hint',    'Enable diagnostics for an `## Interface` number below the lowest number worth declaring for its game today.' },
    { 'toc-interface-mismatch',  'Hint',    'Enable diagnostics for an `## Interface` number that belongs to a game the file does not load on.' },
    { 'toc-interface-never-matches', 'Warning', 'Enable diagnostics for a `.toc` whose `## Interface` numbers all belong to games it does not load on: the client would mark it out of date.' },
    { 'toc-interface-missing-game', 'Hint', 'Enable diagnostics for a `.toc` that loads on a game type none of whose `## Interface` numbers fits.' },
    { 'toc-retired-suffix',      'Warning', 'Enable diagnostics for a `.toc` file name suffix the game does not read any more (`_BCC`, `_WOTLK`): the file is ignored, rename it.' },
    { 'toc-file-name',          'Warning', 'Enable diagnostics for a `.toc` file whose name does not match its folder.' },
}
for _, entry in ipairs(DIAGNOSTICS) do
    diagd.register { entry[1] } {
        group       = 'toc',
        severity    = entry[2],
        status      = 'Any',
        fileKind    = 'toc',
        description = entry[3],
    }
end

-- Data lookups ------------------------------------------------------------------------------------------

---@type table<string, wowToc.game>
local gameById = {}
---@type table<string, string>        lowercase name -> game id, for every game id and alias
local gameName = {}
---@type table<string, string[]>      lowercase family id -> game ids
local familyGames = {}
---@type table<string, wowToc.family>
local familyById = {}
---@type table<string, string[]>      lowercase suffix -> game ids (a game suffix: one game; a family suffix: its games)
local suffixGames = {}
---@type table<string, wowToc.category>   normalized English category name -> category
local categoryByName = {}
---@type string[]
local categoryNames = {}

--- A category name for comparing: lowercase, the typographic apostrophe written as the plain one.
---@param text string
---@return string
local function normalizeName(text)
    return (text:lower():gsub(utf8.char(0x2019), "'"))
end
for _, category in ipairs(categories) do
    categoryByName[normalizeName(category.name)] = category
    categoryNames[#categoryNames+1] = category.name
end

---@type table<string, wowToc.retiredSuffix>   lowercase suffix the game does not read any more
local retiredBySuffix = {}
for _, retired in ipairs(games.retiredSuffixes) do
    retiredBySuffix[retired.suffix:lower()] = retired
end
---@type table<string, true>          lowercase suffix of a family (not of one game)
local familySuffix = {}
---@type table<string, string>        lowercase suffix -> description for hover
local suffixText = {}
---@type string[]
local gameOrder = {}

for _, game in ipairs(games.games) do
    gameById[game.id] = game
    gameOrder[#gameOrder+1] = game.id
    gameName[game.id] = game.id
    for _, alias in ipairs(game.aliases or {}) do
        gameName[alias:lower()] = game.id
    end
    for _, family in ipairs(game.families) do
        familyGames[family] = familyGames[family] or {}
        table.insert(familyGames[family], game.id)
    end
    for _, suffix in ipairs(game.suffixes) do
        suffixGames[suffix:lower()] = { game.id }
        suffixText[suffix:lower()] = ('the game %s'):format(game.display)
    end
end
for _, family in ipairs(games.families) do
    familyById[family.id] = family
    suffixGames[family.suffix:lower()] = familyGames[family.id] or {}
    familySuffix[family.suffix:lower()] = true
    suffixText[family.suffix:lower()] = ('the family %s'):format(family.display)
end

---@type table<string, wowToc.directive>   lowercase name (and alias) -> directive
local headerByName = {}
for _, directive in ipairs(directives.headers) do
    headerByName[directive.name:lower()] = directive
    for _, alias in ipairs(directive.aliases or {}) do
        headerByName[alias:lower()] = directive
    end
end
---@type table<string, wowToc.retiredHeader>   lowercase name of a directive the game dropped
local retiredHeaderByName = {}
for _, retired in ipairs(directives.retired) do
    retiredHeaderByName[retired.name:lower()] = retired
end
---@type table<string, wowToc.inline>
local inlineByName = {}
for _, inline in ipairs(directives.inlines) do
    inlineByName[inline.name:lower()] = inline
end
---@type table<string, wowToc.variable>
local variableByName = {}
for _, variable in ipairs(directives.variables) do
    variableByName[variable.name:lower()] = variable
end
---@type table<string, string>   lowercase locale -> locale
local localeByName = {}
for _, locale in ipairs(games.locales) do
    localeByName[locale:lower()] = locale
end

--- The game ids a game type word stands for (a game, an alias or a family), nil for a word nobody knows.
---@param word string
---@return string[]?
local function resolveGameWord(word)
    local lower = word:lower()
    if gameName[lower] then
        return { gameName[lower] }
    end
    if familyGames[lower] then
        return familyGames[lower]
    end
    return nil
end

---@param set table<string, true>
---@return string[]
local function sortedIds(set)
    ---@type string[]
    local list = {}
    for _, id in ipairs(gameOrder) do
        if set[id] then
            list[#list+1] = id
        end
    end
    return list
end

---@return table<string, true>
local function allGames()
    ---@type table<string, true>
    local set = {}
    for _, id in ipairs(gameOrder) do
        set[id] = true
    end
    return set
end

--- The directive a key names: its entry, and the locale when it is a localized variant (`Title-frFR`).
---@param key string
---@return wowToc.directive? directive
---@return string? locale     the text after the dash of a localized key
---@return boolean? custom    an `X-*` key
function m.directiveOf(key)
    local lower = key:lower()
    if headerByName[lower] then
        return headerByName[lower], nil, nil
    end
    if lower:sub(1, 2) == 'x-' then
        return nil, nil, true
    end
    local base, tag = key:match('^([%w_]+)%-([%w_]+)$')
    if base then
        local directive = headerByName[base:lower()]
        if directive and directive.localizable then
            return directive, tag, nil
        end
    end
    for _, directive in ipairs(directives.headers) do
        for _, prefix in ipairs(directive.prefixes or {}) do
            if lower:sub(1, #prefix) == prefix:lower() then
                return directive, nil, nil
            end
        end
    end
    return nil, nil, nil
end

--- The closest name of a list (an edit distance of at most 2), for a "did you mean".
---@param word  string
---@param names string[]
---@return string?
local function nearest(word, names)
    local function distance(a, b)
        a, b = a:lower(), b:lower()
        ---@type table<integer, integer>
        local previous = {}
        for j = 0, #b do
            previous[j] = j
        end
        for i = 1, #a do
            ---@type table<integer, integer>
            local current = { [0] = i }
            for j = 1, #b do
                local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
                current[j] = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            end
            previous = current
        end
        return previous[#b]
    end
    ---@type string?
    local best
    ---@type integer?
    local bestDistance
    for _, name in ipairs(names) do
        local d = distance(word, name)
        if d <= 2 and (not bestDistance or d < bestDistance) then
            best, bestDistance = name, d
        end
    end
    return best
end

--- " (did you mean `x`?)" for a misspelt game type word, or "".
---@param word string
---@return string
local function gameTypeHint(word)
    ---@type string[]
    local names = {}
    for name in pairs(gameName) do
        names[#names+1] = name
    end
    for name in pairs(familyGames) do
        names[#names+1] = name
    end
    table.sort(names)
    local suggestion = nearest(word, names)
    return suggestion and (' (did you mean `%s`?)'):format(suggestion) or ''
end

-- Parsing -----------------------------------------------------------------------------------------------

local MAX_LINE = 1024

---@class wowToc.bracket
---@field start   integer 1-based byte of `[`
---@field finish  integer 1-based byte of the last character (the `]`, or the end of the line when it is not closed)
---@field closed  boolean
---@field name    string
---@field nameStart integer
---@field nameFinish integer
---@field value   string
---@field valueStart integer
---@field valueFinish integer

---@class wowToc.number
---@field number integer
---@field line   wowToc.line
---@field first  integer 1-based byte
---@field last   integer 1-based byte, inclusive

---@class wowToc.line
---@field row      integer 0-based
---@field text     string  the first 1024 characters
---@field tooLong  boolean
---@field length   integer  the length of the whole line, also past 1024 characters
---@field kind     'blank'|'comment'|'header'|'file'
---@field key?     string
---@field keyStart? integer
---@field keyFinish? integer
---@field value?   string
---@field valueStart? integer
---@field valueFinish? integer
---@field directive? wowToc.directive
---@field locale?  string
---@field custom?  boolean
---@field path?    string   a file line: the text before the first bracket, trimmed
---@field pathStart? integer
---@field pathFinish? integer
---@field brackets wowToc.bracket[]

---@param text string the text after a bracket name up to the closing bracket
---@return string value, integer start, integer finish
local function trimmedValue(text, offset)
    local first = text:find('%S')
    if not first then
        return '', offset, offset - 1
    end
    local last = #text
    while text:sub(last, last):match('%s') do
        last = last - 1
    end
    return text:sub(first, last), offset + first - 1, offset + last - 1
end

--- The `[...]` pieces of a line.
---@param text string
---@param from integer 1-based byte where to start looking
---@return wowToc.bracket[]
local function scanBrackets(text, from)
    ---@type wowToc.bracket[]
    local found = {}
    local at = from
    while true do
        local open = text:find('[', at, true)
        if not open then
            break
        end
        local close = text:find(']', open + 1, true)
        local inner = text:sub(open + 1, (close or #text + 1) - 1)
        local nameFirst, nameLast = inner:find('^%s*[%w_]*')
        local name = inner:match('^%s*([%w_]*)') or ''
        local nameStart = open + 1 + (inner:find('[%w_]') or (#inner + 1)) - 1
        if name == '' then
            nameStart = open + 1
        end
        local rest = inner:sub(nameLast and nameLast + 1 or 1)
        local value, valueStart, valueFinish = trimmedValue(rest, open + 1 + (nameLast or 0))
        found[#found+1] = {
            start = open, finish = close or #text, closed = close ~= nil,
            name = name, nameStart = nameStart, nameFinish = nameStart + #name - 1,
            value = value, valueStart = valueStart, valueFinish = valueFinish,
        }
        if not close then
            break
        end
        at = close + 1
    end
    return found
end

---@param rowText string the line without its line ending
---@param row     integer 0-based
---@return wowToc.line
local function parseLine(rowText, row)
    local tooLong = #rowText > MAX_LINE
    local text = tooLong and rowText:sub(1, MAX_LINE) or rowText
    ---@type wowToc.line
    local line = { row = row, text = text, tooLong = tooLong, length = #rowText, kind = 'blank', brackets = {} }
    if not text:find('%S') then
        return line
    end
    -- `#` at the very start is a comment (leading whitespace before it makes the line a file name)
    if text:sub(1, 2) == '##' then
        local keyStart, keyFinish = text:find('^##%s*()[%w_%-]+', 1)
        local key = text:match('^##%s*([%w_%-]+)%s*:')
        if key then
            local first = text:find(key, 3, true) --[[@as integer]]
            local colon = text:find(':', first + #key, true) --[[@as integer]]
            local brackets = scanBrackets(text, colon + 1)
            -- the value ends where the first inline directive starts (`## Interface: 50504 [AllowLoadGameType classic]`); a bracket the
            -- directive tables do not know (`## Title: [PvP] Tools`) stays part of the text
            local valueEnd = #text
            for _, bracket in ipairs(brackets) do
                local lower = bracket.name:lower()
                if inlineByName[lower] or variableByName[lower] then
                    valueEnd = bracket.start - 1
                    break
                end
            end
            local value, valueStart, valueFinish = trimmedValue(text:sub(colon + 1, valueEnd), colon + 1)
            line.kind = 'header'
            line.key, line.keyStart, line.keyFinish = key, first, first + #key - 1
            line.value, line.valueStart, line.valueFinish = value, valueStart, valueFinish
            line.directive, line.locale, line.custom = m.directiveOf(key)
            line.brackets = brackets
            return line
        end
        line.kind = 'comment'
        return line
    end
    if text:sub(1, 1) == '#' then
        line.kind = 'comment'
        return line
    end
    line.kind = 'file'
    local all = scanBrackets(text, 1)
    -- a variable written inside the path (`Localization\[TextLocale].lua`) is part of the path, not a condition
    ---@type integer?
    local firstBracket
    for _, bracket in ipairs(all) do
        local lower = bracket.name:lower()
        local touching = text:sub(bracket.start - 1, bracket.start - 1):match('%S') or text:sub(bracket.finish + 1, bracket.finish + 1):match('%S')
        if bracket.closed and bracket.value == '' and variableByName[lower] and touching and bracket.start > 1 and not text:sub(1, bracket.start - 1):match('^%s*$') then
            -- in the path
        else
            firstBracket = bracket.start
            break
        end
    end
    local pathText = firstBracket and text:sub(1, firstBracket - 1) or text
    local path, pathStart, pathFinish = trimmedValue(pathText, 1)
    -- a path written after the brackets (`[AllowLoad Game] File.lua`) is accepted too
    line.brackets = {}
    for _, bracket in ipairs(all) do
        if firstBracket and bracket.start >= firstBracket then
            line.brackets[#line.brackets+1] = bracket
        end
    end
    if path == '' and #line.brackets > 0 then
        local last = line.brackets[#line.brackets]
        path, pathStart, pathFinish = trimmedValue(text:sub(last.finish + 1), last.finish + 1)
    end
    line.path, line.pathStart, line.pathFinish = path, pathStart, pathFinish
    return line
end

---@param text string
---@return wowToc.line[]
function m.parse(text)
    ---@type wowToc.line[]
    local lines = {}
    local row = 0
    for rowText in (text .. '\n'):gmatch('(.-)\r?\n') do
        lines[#lines+1] = parseLine(rowText, row)
        row = row + 1
    end
    -- the text ends with a line ending: the last empty piece is not a line
    if #lines > 0 and lines[#lines].kind == 'blank' and lines[#lines].text == '' and text:sub(-1) == '\n' then
        lines[#lines] = nil
    end
    return lines
end

-- Scope: the games a file or a line can load on ------------------------------------------------------------

--- A copy of `set` without the games of `remove`.
---@param set    table<string, true>
---@param remove table<string, true>
---@return table<string, true>
local function without(set, remove)
    ---@type table<string, true>
    local result = {}
    for id in pairs(set) do
        if not remove[id] then
            result[id] = true
        end
    end
    return result
end

--- The `.toc` files next to a file that carry the same name and a suffix: the games with a file of their own (a game suffix) and the
--- games a family suffix file takes.
---@param dir  string
---@param base string
---@param self string  the lowercase file name of the file itself
---@return table<string, true> ownFile    games that have a `Name_<Game>.toc`
---@return table<string, true> familyFile games that have a `Name_<Family>.toc` (and no file of their own)
local function siblingsOf(dir, base, self)
    ---@type table<string, true>, table<string, true>
    local own, family = {}, {}
    local lowerBase = base:lower()
    local ok = pcall(function ()
        for entry in fs.pairs(fs.path(dir)) do
            local file = entry:filename():string():lower()
            local suffix = file ~= self and file:match('^' .. lowerBase:gsub('%p', '%%%0') .. '_([%w]+)%.toc$')
            if suffix and suffixGames[suffix] then
                for _, id in ipairs(suffixGames[suffix]) do
                    if familySuffix[suffix] then
                        family[id] = true
                    else
                        own[id] = true
                    end
                end
            end
        end
    end)
    if not ok then
        return {}, {}
    end
    for id in pairs(own) do
        family[id] = nil
    end
    return own, family
end

--- The games a file name selects: the game suffix first, then the family suffix, else every game. Next to files of other suffixes a
--- file keeps the games none of them takes: `Name.toc` is what is left when `Name_Classic.toc` exists (the mainline games), and
--- `Name_Classic.toc` leaves out the classic games that have a `Name_<Game>.toc` of their own.
---@param uri uri
---@return table<string, true> set
---@return string? suffix   the suffix that selected them
---@return string  base     the file name without extension and suffix
function m.fileScope(uri)
    local path = furi.decode(uri)
    local name = path:match('([^/\\]+)$') or path
    ---@type string
    local stem = name:gsub('%.[tT][oO][cC]$', '')
    ---@type string?, string?
    local base, suffix = stem:match('^(.*)_([%w]+)$')
    if base and suffix and suffixGames[suffix:lower()] then
        ---@type table<string, true>
        local set = {}
        for _, id in ipairs(suffixGames[suffix:lower()]) do
            set[id] = true
        end
        if familySuffix[suffix:lower()] then
            local own = siblingsOf(path:match('^(.*)[/\\][^/\\]*$') or '.', base, name:lower())
            local rest = without(set, own)
            -- every game has a file of its own: this one is never picked, keep the family so its own checks still make sense
            if next(rest) ~= nil then
                set = rest
            end
        end
        return set, suffix, base
    end
    local own, family = siblingsOf(path:match('^(.*)[/\\][^/\\]*$') or '.', stem, name:lower())
    local set = without(without(allGames(), own), family)
    if next(set) == nil then
        -- a file for every game: this one is never picked, keep the whole set so its own checks still make sense
        set = allGames()
    end
    return set, nil, stem
end

--- The game words of a value (`mainline, cata`, `vanilla tbc`): the games they name and the words nobody knows.
---@param value string
---@return table<string, true> set
---@return { word: string, start: integer, finish: integer }[] unknown positions in `value`, 1-based
---@return integer count how many words there were
function m.gameWords(value)
    ---@type table<string, true>
    local set = {}
    ---@type { word: string, start: integer, finish: integer }[]
    local unknown = {}
    local count = 0
    for first, word, last in value:gmatch('()([^,%s]+)()') --[==[@as fun(): (integer, string, integer)]==] do
        count = count + 1
        local ids = resolveGameWord(word)
        if ids then
            for _, id in ipairs(ids) do
                set[id] = true
            end
        else
            unknown[#unknown+1] = { word = word, start = first, finish = last - 1 }
        end
    end
    return set, unknown, count
end

---@param a table<string, true>
---@param b table<string, true>
---@return table<string, true>
local function intersect(a, b)
    ---@type table<string, true>
    local set = {}
    for id in pairs(a) do
        if b[id] then
            set[id] = true
        end
    end
    return set
end

---@param a table<string, true>
---@param b table<string, true>
---@return table<string, true>
local function subtract(a, b)
    ---@type table<string, true>
    local set = {}
    for id in pairs(a) do
        if not b[id] then
            set[id] = true
        end
    end
    return set
end

---@param set table<string, true>
---@return boolean
local function isEmpty(set)
    return next(set) == nil
end

---@param a table<string, true>
---@param b table<string, true>
---@return boolean
local function isSubset(a, b)
    for id in pairs(a) do
        if not b[id] then
            return false
        end
    end
    return true
end

--- What the game conditions of `## AllowLoadGameType` / `## ExcludeLoadGameType` lines leave of a scope. An allow list none of whose words is known
--- restricts nothing (the wiki: an unknown type still satisfies AllowLoadGameType).
---@param scope table<string, true>
---@param allowWords string[] the values of the allow lines/brackets
---@param excludeWords string[]
---@return table<string, true>
local function applyConditions(scope, allowWords, excludeWords)
    if #allowWords > 0 then
        ---@type table<string, true>
        local allowed = {}
        local anyKnown = false
        for _, value in ipairs(allowWords) do
            local set = m.gameWords(value)
            for id in pairs(set) do
                allowed[id] = true
                anyKnown = true
            end
        end
        if anyKnown then
            scope = intersect(scope, allowed)
        end
    end
    for _, value in ipairs(excludeWords) do
        scope = subtract(scope, (m.gameWords(value)))
    end
    return scope
end

---@param lines wowToc.line[]
---@return string[] allow, string[] exclude  the values of the header lines
local function headerConditions(lines)
    ---@type string[], string[]
    local allow, exclude = {}, {}
    for _, line in ipairs(lines) do
        if line.kind == 'header' and line.directive then
            local name = line.directive.name
            if name == 'AllowLoadGameType' then
                allow[#allow+1] = line.value or ''
            elseif name == 'ExcludeLoadGameType' then
                exclude[#exclude+1] = line.value or ''
            end
        end
    end
    return allow, exclude
end

--- The games a line loads on.
---@param fileScope table<string, true>
---@param lines     wowToc.line[]
---@param line      wowToc.line
---@return table<string, true> scope
function m.lineScope(fileScope, lines, line)
    local allow, exclude = headerConditions(lines)
    local scope = applyConditions(fileScope, allow, exclude)
    ---@type string[], string[]
    local lineAllow, lineExclude = {}, {}
    for _, bracket in ipairs(line.brackets) do
        local name = bracket.name:lower()
        if name == 'allowloadgametype' then
            lineAllow[#lineAllow+1] = bracket.value
        elseif name == 'excludeloadgametype' then
            lineExclude[#lineExclude+1] = bracket.value
        end
    end
    return applyConditions(scope, lineAllow, lineExclude)
end

--- The names of a set of games for a message.
---@param set table<string, true>
---@return string
function m.describeGames(set)
    ---@type string[]
    local names = {}
    for _, id in ipairs(sortedIds(set)) do
        names[#names+1] = gameById[id].display
    end
    if #names == 0 then
        return 'no game'
    end
    return table.concat(names, ', ')
end

-- Diagnostics -------------------------------------------------------------------------------------------

--- The comment directives that switch `toc-*` diagnostics off, the TOC counterpart of the LuaDoc comment: `# @diagnostic disable-next-line: toc-x, toc-y`,
--- `# @diagnostic disable: toc-x` (from that line on) and `# @diagnostic enable: toc-x`. A `#` line is a comment for the game, so the file does not
--- change for it. No codes after the colon means every code.
---@param lines wowToc.line[]
---@return fun(row: integer, code: string): boolean  isSuppressed  (row: 0-based)
function m.suppressionsOf(lines)
    ---@type table<integer, table<string, true>>   row -> codes switched off for that line only
    local nextLine = {}
    ---@type { row: integer, disable: boolean, codes: string[] }[]
    local ranges = {}
    for _, line in ipairs(lines) do
        if line.kind == 'comment' then
            ---@type string?, string?
            local mode, list = line.text:lower():match('^#%s*@diagnostic%s+([%a%-]+)%s*:%s*(.-)%s*$')
            if mode and list then
                mode = mode:lower()
                ---@type string[]
                local codes = {}
                for code in list:gmatch('[^%s,]+') do
                    codes[#codes+1] = code:lower()
                end
                if #codes == 0 then
                    codes[1] = '*'
                end
                if mode == 'disable-next-line' then
                    local set = nextLine[line.row + 1] or {}
                    nextLine[line.row + 1] = set
                    for _, code in ipairs(codes) do
                        set[code] = true
                    end
                elseif mode == 'disable' or mode == 'enable' then
                    ranges[#ranges+1] = { row = line.row, disable = mode == 'disable', codes = codes }
                end
            end
        end
    end
    return function (row, code)
        local set = nextLine[row]
        if set and (set[code] or set['*']) then
            return true
        end
        local disabled = false
        for _, range in ipairs(ranges) do
            if range.row > row then
                break
            end
            for _, name in ipairs(range.codes) do
                if name == code or name == '*' then
                    disabled = range.disable
                end
            end
        end
        return disabled
    end
end

---@param uri uri
---@param text string
---@return fileKind.diagnostic[]
function m.diagnose(uri, text)
    local lines = m.parse(text)
    ---@type fileKind.diagnostic[]
    local found = {}

    ---@param row     integer
    ---@param first   integer 1-based byte
    ---@param last    integer 1-based byte, inclusive
    ---@param code    string
    ---@param message string
    ---@param tags?   integer[]
    local function report(row, first, last, code, message, tags)
        local lineText = lines[row + 1] and lines[row + 1].text or ''
        found[#found+1] = {
            code    = code,
            message = message,
            tags    = tags,
            range   = {
                start   = { line = row, character = fileKinds.toCharacter(lineText, first - 1) },
                ['end'] = { line = row, character = fileKinds.toCharacter(lineText, last) },
            },
        }
    end

    -- the diagnostics of the file as a whole sit on its first line, past the `# @diagnostic` comments that open it: a `disable-next-line` written
    -- above that line then reaches them too
    local anchorRow = 0
    while lines[anchorRow + 1] and lines[anchorRow + 1].kind == 'comment'
        and lines[anchorRow + 1].text:lower():find('^#%s*@diagnostic%s') do
        anchorRow = anchorRow + 1
    end
    if not lines[anchorRow + 1] then
        anchorRow = math.max(#lines - 1, 0)
    end
    local fileScope, suffix, base = m.fileScope(uri)
    local folder = furi.decode(uri):match('([^/\\]+)[/\\][^/\\]+$')

    -- a suffix the game does not read any more (data: games.lua)
    local retiredSuffix = furi.decode(uri):match('_([%w]+)%.[tT][oO][cC]$')
    local retired = retiredSuffix and retiredBySuffix[retiredSuffix:lower()]
    if retired and retiredSuffix then
        report(anchorRow, 1, math.max(#(lines[anchorRow + 1] and lines[anchorRow + 1].text or ''), 1), 'toc-retired-suffix',
            ('The suffix `_%s` is no longer supported: the game ignores this file; rename it to `_%s`.'):format(retiredSuffix, retired.use))
    end

    -- the file name belongs to its folder
    -- (a repository checkout can be the install folder: the game only compares the folder name with the file name)
    if folder and base:lower() ~= folder:lower() and not retired then
        report(anchorRow, 1, math.max(#(lines[anchorRow + 1] and lines[anchorRow + 1].text or ''), 1), 'toc-file-name',
            ('The file name should match the folder: `%s.toc` (it is `%s`).'):format(folder, base))
    end

    -- Interface
    ---@type wowToc.line[]
    local interfaceLines = {}
    ---@type table<string, wowToc.line>
    local seen = {}
    ---@type table<string, wowToc.line>
    local firstBase = {}
    for _, line in ipairs(lines) do
        if line.tooLong then
            -- (the range is what is ignored: from the 1025th byte to the end; the report needs the whole line to convert the end)
            lines[line.row + 1].text = line.text
            report(line.row, MAX_LINE + 1, MAX_LINE + 1, 'toc-line-too-long',
                ('Only the first %d characters of a line are read: the rest (%d bytes) is ignored.'):format(MAX_LINE, line.length - MAX_LINE))
        end
        if line.kind == 'header' then
            local directive = line.directive
            local key = line.key or ''
            if not directive and not line.custom then
                ---@type string[]
                local names = {}
                for _, entry in ipairs(directives.headers) do
                    names[#names+1] = entry.name
                end
                local suggestion = nearest(key, names)
                local retired = retiredHeaderByName[key:lower()]
                if retired then
                    report(line.row, line.keyStart or 1, line.keyFinish or 1, 'toc-retired-header',
                        retired.use and ('`%s` is no longer supported: it was renamed `%s`.'):format(retired.name, retired.use)
                            or ('`%s` is no longer supported and does nothing.'):format(retired.name))
                else
                    report(line.row, line.keyStart or 1, line.keyFinish or 1, 'toc-unknown-header',
                        ('Unknown directive `%s`%s.'):format(key, suggestion and (' (did you mean `%s`?)'):format(suggestion) or ''))
                end
            elseif directive then
                if directive.restricted then
                    report(line.row, line.keyStart or 1, line.keyFinish or 1, 'toc-restricted-header',
                        ('`%s` is not available to third-party addons.'):format(directive.name))
                end
                if directive.name == 'Interface' then
                    interfaceLines[#interfaceLines+1] = line
                end
                -- repeated keys
                local id = directive.name:lower() .. (line.locale and ('-' .. line.locale:lower()) or '')
                if directive.prefixes and not headerByName[key:lower()] then
                    id = directive.name:lower()
                end
                local previous = seen[id]
                -- (the wiki's own example repeats `## Title:` with an inline condition on the second line: that is how a title is made per game)
                local conditional = previous and (#previous.brackets > 0 or #line.brackets > 0)
                if previous and not directive.appends and not conditional then
                    if directive.firstWins then
                        report(line.row, line.keyStart or 1, line.keyFinish or 1, 'toc-duplicate-header',
                            ('`%s` is repeated: only the first (line %d) counts, this one is ignored.'):format(key, previous.row + 1))
                    else
                        report(line.row, line.keyStart or 1, line.keyFinish or 1, 'toc-duplicate-header',
                            ('`%s` is repeated: this line replaces the one on line %d.'):format(key, previous.row + 1))
                    end
                end
                seen[id] = previous or line
                if not line.locale and not firstBase[directive.name] then
                    firstBase[directive.name] = line
                end
                -- localized variants
                if line.locale then
                    if not localeByName[line.locale:lower()] then
                        local suggestion = nearest(line.locale, games.locales)
                        report(line.row, (line.keyStart or 1) + #key - #line.locale, line.keyFinish or 1, 'toc-invalid-value',
                            ('Unknown locale `%s`%s.'):format(line.locale, suggestion and (' (did you mean `%s`?)'):format(suggestion) or ''))
                    end
                    if not firstBase[directive.name] then
                        report(line.row, line.keyStart or 1, line.keyFinish or 1, 'toc-localized-before-base',
                            ('`%s` comes before the plain `%s`, or there is none: the localized ones go unused.'):format(key, directive.name))
                    end
                end
                -- values
                local value = line.value or ''
                if value == '' and directive.value ~= 'text' then
                    report(line.row, line.keyStart or 1, line.keyFinish or 1, 'toc-invalid-value', ('`%s` has no value.'):format(key))
                elseif directive.value == 'boolean01' and value ~= '0' and value ~= '1' then
                    report(line.row, line.valueStart or 1, line.valueFinish or 1, 'toc-invalid-value', ('`%s` takes `1` or `0`, not `%s`.'):format(key, value))
                elseif directive.value == 'enum' then
                    local ok = false
                    for _, word in ipairs(directive.values or {}) do
                        if word:lower() == value:lower() then
                            ok = true
                        end
                    end
                    if not ok and value ~= '' then
                        report(line.row, line.valueStart or 1, line.valueFinish or 1, 'toc-invalid-value',
                            ('`%s` takes %s, not `%s`.'):format(key, '`' .. table.concat(directive.values or {}, '`, `') .. '`', value))
                    end
                elseif directive.value == 'function' and value ~= '' and not value:match('^[%a_][%w_]*$') then
                    report(line.row, line.valueStart or 1, line.valueFinish or 1, 'toc-invalid-value', ('`%s` takes the name of a global function, not `%s`.'):format(key, value))
                elseif directive.value == 'gametypes' and value ~= '' then
                    local _, unknown = m.gameWords(value)
                    for _, item in ipairs(unknown) do
                        report(line.row, (line.valueStart or 1) + item.start - 1, (line.valueStart or 1) + item.finish - 1, 'toc-invalid-value',
                            ('Unknown game type `%s`%s. (The client treats an unknown type as satisfying `AllowLoadGameType`.)'):format(item.word, gameTypeHint(item.word)))
                    end
                end
            end
        end
    end

    -- Category: the recommended names of the Addon Categories page and their translations (a recommendation: a hint, never an error)
    do
        ---@type wowToc.category?
        local base
        for _, line in ipairs(lines) do
            if line.kind == 'header' and line.directive and line.directive.name == 'Category' and not line.locale and line.value and line.value ~= '' then
                base = categoryByName[normalizeName(line.value)]
            end
        end
        for _, line in ipairs(lines) do
            if line.kind == 'header' and line.directive and line.directive.name == 'Category' and line.value and line.value ~= ''
                and line.valueStart and line.valueFinish then
                if not line.locale then
                    if not categoryByName[normalizeName(line.value)] then
                        local suggestion = nearest(line.value, categoryNames)
                        report(line.row, line.valueStart, line.valueFinish, 'toc-unknown-category',
                            ('`%s` is not one of the recommended categories%s.'):format(line.value, suggestion and (' (did you mean `%s`?)'):format(suggestion) or ''))
                    end
                elseif base and localeByName[line.locale:lower()] then
                    local locale = localeByName[line.locale:lower()]
                    local expected = base.names[locale]
                    if expected and normalizeName(expected) ~= normalizeName(line.value) then
                        report(line.row, line.valueStart, line.valueFinish, 'toc-category-translation',
                            ('The Addon Categories page translates `%s` as `%s` for %s.'):format(base.name, expected, locale))
                    end
                end
            end
        end
    end

    -- Interface present, valid
    local scopeLines = lines
    if #interfaceLines == 0 then
        report(anchorRow, 1, math.max(#(lines[anchorRow + 1] and lines[anchorRow + 1].text or ''), 1), 'toc-missing-interface', 'The `.toc` has no `## Interface:` line.')
    end
    ---@type wowToc.number[]
    local numbers = {}
    for _, line in ipairs(interfaceLines) do
        for first, item, last in (line.value or ''):gmatch('()([^,%s]+)()') --[==[@as fun(): (integer, string, integer)]==] do
            local at = (line.valueStart or 1) + first - 1
            ---@type integer?
            local number
            if item:match('^%d+$') then
                number = tonumber(item) --[[@as integer]]
            end
            if number and number > 0 then
                numbers[#numbers+1] = { number = number, line = line, first = at, last = at + #item - 1 }
            else
                report(line.row, at, at + #item - 1, 'toc-invalid-interface', ('`%s` is not a whole number above 0.'):format(item))
            end
        end
    end

    -- a repeated `## Interface` replaces the earlier line: only the last one counts for the games
    local conditionalInterface = false
    for _, line in ipairs(interfaceLines) do
        conditionalInterface = conditionalInterface or #line.brackets > 0
    end
    if #interfaceLines > 1 and not conditionalInterface then
        local lastLine = interfaceLines[#interfaceLines]
        ---@type wowToc.number[]
        local kept = {}
        for _, entry in ipairs(numbers) do
            if entry.line == lastLine then
                kept[#kept+1] = entry
            end
        end
        numbers = kept
    end

    -- the scope of the file and of its lines
    local headerAllow, headerExclude = headerConditions(scopeLines)
    local scope = applyConditions(fileScope, headerAllow, headerExclude)
    -- narrowed: something really takes games away (an allow list nobody knows, or an exclude of unknown types, takes none). A plain
    -- file next to files of other suffixes is the mainline file by position, but it declares no restriction: the Interface checks
    -- leave it alone unless its own directives narrow it.
    local narrowed = suffix ~= nil or not isSubset(allGames(), applyConditions(allGames(), headerAllow, headerExclude))

    -- Interface against the games of the scope
    if #numbers > 0 then
        ---@type table<string, integer[]>   game id -> the numbers whose major is the game's
        local byGame = {}
        local matched, mismatched = 0, 0
        -- a game without a known range (Forever, Plunderstorm...) can take any number: nothing is a mismatch for a scope that holds one
        local unknownInScope = false
        for id in pairs(scope) do
            if not gameById[id].interface then
                unknownInScope = true
            end
        end
        ---@type { entry: table, owners: string[] }[]
        local foreign = {}
        ---@type table<string, wowToc.number>   game id -> its highest number in the list
        local highest = {}
        for _, entry in ipairs(numbers) do
            ---@type string[]
            local owners = {}
            for _, id in ipairs(gameOrder) do
                local data = gameById[id].interface
                if data and entry.number >= data.first and entry.number <= data.last then
                    owners[#owners+1] = id
                end
            end
            if #owners > 0 then
                local inScope = false
                for _, id in ipairs(owners) do
                    byGame[id] = byGame[id] or {}
                    table.insert(byGame[id], entry.number)
                    if scope[id] then
                        inScope = true
                    end
                end
                if inScope then
                    matched = matched + 1
                else
                    mismatched = mismatched + 1
                    foreign[#foreign+1] = { entry = entry, owners = owners }
                end
                for _, id in ipairs(owners) do
                    if scope[id] and (not highest[id] or highest[id].number < entry.number) then
                        highest[id] = entry
                    end
                end
            end
        end
        -- a stray number next to numbers that fit; when none fits, `never-matches` says it
        if narrowed and matched > 0 and not unknownInScope then
            for _, item in ipairs(foreign) do
                local entry = item.entry
                local game = gameById[item.owners[1]]
                report(entry.line.row, entry.first, entry.last, 'toc-interface-mismatch',
                    ('`%d` reads as %d.%d.%d, a number of %s; this file loads on %s.'):format(
                        entry.number, entry.number // 10000, entry.number // 100 % 100, entry.number % 100, game.display, m.describeGames(scope)))
            end
        end
        if narrowed and matched == 0 and mismatched > 0 and not unknownInScope then
            local line = numbers[1].line
            report(line.row, line.keyStart or 1, line.keyFinish or 1, 'toc-interface-never-matches',
                ('None of the Interface numbers belongs to a game this file loads on (%s): the client would mark it out of date.'):format(m.describeGames(scope)))
        end
        -- a game whose newest number is below the minimum (older numbers next to a current one are on purpose: they keep older clients working)
        for _, id in ipairs(gameOrder) do
            local entry = highest[id]
            local data = gameById[id].interface
            if entry and data and entry.number < data.minimum then
                report(entry.line.row, entry.first, entry.last, 'toc-interface-too-low',
                    ('%s needs at least `%d` today; `%d` is out of date for it.'):format(gameById[id].display, data.minimum, entry.number))
            end
        end
        -- a game of a narrowed scope without a number
        if narrowed then
            ---@type table<string, true>
            local missing = {}
            for id in pairs(scope) do
                if gameById[id].interface and not byGame[id] then
                    missing[id] = true
                end
            end
            if not isEmpty(missing) then
                local line = numbers[1].line
                report(line.row, line.keyStart or 1, line.keyFinish or 1, 'toc-interface-missing-game',
                    ('No Interface number for %s, which this file loads on.'):format(m.describeGames(missing)))
            end
        end
    end

    -- per line: brackets, conditions, files
    local dirPath = furi.decode(uri):match('^(.*)[/\\][^/\\]*$')
    for _, line in ipairs(lines) do
        if line.kind == 'header' or line.kind == 'file' then
            for _, bracket in ipairs(line.brackets) do
                local lower = bracket.name:lower()
                local inline = inlineByName[lower]
                if not bracket.closed then
                    report(line.row, bracket.start, bracket.finish, 'toc-invalid-value', 'This `[` is not closed.')
                elseif bracket.name == '' then
                    report(line.row, bracket.start, bracket.finish, 'toc-invalid-value', 'An empty `[]`.')
                elseif variableByName[lower] then
                    if bracket.value ~= '' then
                        report(line.row, bracket.start, bracket.finish, 'toc-invalid-value', ('`[%s]` is a variable and takes no value.'):format(bracket.name))
                    end
                elseif not inline then
                    ---@type string[]
                    local names = {}
                    for _, entry in ipairs(directives.inlines) do
                        names[#names+1] = entry.name
                    end
                    for _, entry in ipairs(directives.variables) do
                        names[#names+1] = entry.name
                    end
                    local suggestion = nearest(bracket.name, names)
                    report(line.row, bracket.nameStart, bracket.nameFinish, 'toc-invalid-value',
                        ('Unknown directive `[%s]`%s.'):format(bracket.name, suggestion and (' (did you mean `%s`?)'):format(suggestion) or ''))
                elseif inline.value == 'none' then
                    if bracket.value ~= '' then
                        report(line.row, bracket.valueStart, bracket.valueFinish, 'toc-invalid-value', ('`[%s]` takes no value.'):format(inline.name))
                    end
                elseif bracket.value == '' then
                    report(line.row, bracket.start, bracket.finish, 'toc-invalid-value', ('`[%s]` needs a value.'):format(inline.name))
                elseif inline.value == 'enum' then
                    local ok = false
                    for _, word in ipairs(inline.values or {}) do
                        if word:lower() == bracket.value:lower() then
                            ok = true
                        end
                    end
                    if not ok then
                        report(line.row, bracket.valueStart, bracket.valueFinish, 'toc-invalid-value',
                            ('`[%s]` takes %s, not `%s`.'):format(inline.name, '`' .. table.concat(inline.values or {}, '`, `') .. '`', bracket.value))
                    end
                elseif inline.value == 'gametypes' then
                    local _, unknown = m.gameWords(bracket.value)
                    for _, item in ipairs(unknown) do
                        report(line.row, bracket.valueStart + item.start - 1, bracket.valueStart + item.finish - 1, 'toc-invalid-value',
                            ('Unknown game type `%s`%s.'):format(item.word, gameTypeHint(item.word)))
                    end
                elseif inline.value == 'locales' then
                    for first, word, last in bracket.value:gmatch('()([^,%s]+)()') --[==[@as fun(): (integer, string, integer)]==] do
                        if not localeByName[word:lower()] then
                            local suggestion = nearest(word, games.locales)
                            report(line.row, bracket.valueStart + first - 1, bracket.valueStart + last - 2, 'toc-invalid-value',
                                ('Unknown locale `%s`%s.'):format(word, suggestion and (' (did you mean `%s`?)'):format(suggestion) or ''))
                        end
                    end
                end
            end
            -- load conditions that leave nothing, or change nothing
            if #line.brackets > 0 then
                local before = applyConditions(fileScope, headerAllow, headerExclude)
                local lineScope = m.lineScope(fileScope, lines, line)
                if isEmpty(lineScope) and not isEmpty(before) then
                    report(line.row, 1, math.max(#line.text, 1), 'toc-unreachable-line',
                        ('This line never loads: the file loads on %s and its conditions leave none of them.'):format(m.describeGames(before)), { 1 })
                elseif not isEmpty(before) then
                    for _, bracket in ipairs(line.brackets) do
                        local lower = bracket.name:lower()
                        if bracket.closed and (lower == 'allowloadgametype' or lower == 'excludeloadgametype') then
                            local words = m.gameWords(bracket.value)
                            ---@type boolean
                            local redundant
                            if lower == 'allowloadgametype' then
                                redundant = not isEmpty(words) and isSubset(before, words)
                            else
                                redundant = isEmpty(intersect(before, words))
                            end
                            if redundant then
                                report(line.row, bracket.start, bracket.finish, 'toc-redundant-condition',
                                    ('This condition changes nothing: the file already loads on %s only.'):format(m.describeGames(before)))
                            end
                        end
                    end
                end
            end
            -- files that exist
            if line.kind == 'file' and line.path and line.path ~= '' and dirPath then
                local path = line.path
                local variable = path:find('%[%a+%]')
                if not variable then
                    local ok, exists = pcall(fs.exists, fs.path(dirPath .. '/' .. path:gsub('\\', '/')))
                    if ok and not exists then
                        report(line.row, line.pathStart or 1, line.pathFinish or 1, 'toc-nonexistent-file', ('The file `%s` does not exist.'):format(path))
                    end
                end
            end
        end
    end

    local isSuppressed = m.suppressionsOf(lines)
    ---@type fileKind.diagnostic[]
    local kept = {}
    for _, diag in ipairs(found) do
        if not isSuppressed(diag.range.start.line, diag.code) then
            kept[#kept+1] = diag
        end
    end
    return kept
end

-- what editor.lua (completion, hover, definition) reads from the tables above
m.gameById          = gameById
m.gameOrder         = gameOrder
m.familyGames       = familyGames
m.resolveGameWord   = resolveGameWord
m.headerByName      = headerByName
m.variableByName    = variableByName
m.categories        = categories
m.categoryByName    = categoryByName
m.normalizeName     = normalizeName

--- The kind of document; editor.lua adds `complete`, `hover` and `definition` to it.
---@type fileKind
m.kind = {
    id       = 'toc',
    match    = function (uri) return uri:lower():sub(-4) == '.toc' end,
    diagnose = m.diagnose,
}
fileKinds.register(m.kind)

return m
