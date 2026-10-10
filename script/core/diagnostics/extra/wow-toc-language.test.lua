-- Lives next to wow-toc-language.lua on purpose: it only runs if the plugin does too. Table-driven cases taken from the rules of
-- https://warcraft.wiki.gg/wiki/TOC_format (the case name is the rule): positive AND negative cases for each, so that a typo or a gap in the
-- syntax shows. Plain Lua (the file kind is not a Lua diagnostic).

local syntax = require 'core.diagnostics.extra.wow-toc.syntax'
local games  = require 'core.diagnostics.extra.wow-toc.games'
local direct = require 'core.diagnostics.extra.wow-toc.directives'
local furi   = require 'file-uri'
local fs     = require 'bee.filesystem'

---@diagnostic disable: await-in-sync

local nl = string.char(10)
local ADDON = TESTROOT .. 'MyAddon'
-- (a run that failed half way leaves its files behind: start from an empty folder)
pcall((fs --[[@as any]]).remove_all, fs.path(ADDON)) -- (not in the bee typings)
fs.create_directories(fs.path(ADDON))

--- Files that exist next to the toc while a case runs.
---@param names string[]
local function touch(names)
    for _, name in ipairs(names) do
        local path = fs.path(ADDON .. '/' .. name)
        fs.create_directories(path:parent_path())
        local f = assert(io.open(path:string(), 'w'))
        f:write('-- test file')
        f:close()
    end
end
---@param names string[]
local function untouch(names)
    for _, name in ipairs(names) do
        pcall(fs.remove, fs.path(ADDON .. '/' .. name))
    end
end

---@param text string
---@param tocName? string the file name (default MyAddon.toc)
---@return fileKind.diagnostic[]
local function diagnose(text, tocName)
    return syntax.diagnose(furi.encode(ADDON .. '/' .. (tocName or 'MyAddon.toc')), text)
end

---@param list fileKind.diagnostic[]
---@return string[]
local function codes(list)
    ---@type string[]
    local result = {}
    for _, diag in ipairs(list) do
        result[#result+1] = diag.code
    end
    table.sort(result)
    return result
end

local HEADER = '## Interface: 120100' .. nl

---@type string[]
local failures = {}

--- One case: the text, the codes it must raise (in any order), the file name, the files that exist.
---@param name     string
---@param text     string
---@param expected string[]
---@param options? { toc?: string, files?: string[] }
local function case(name, text, expected, options)
    options = options or {}
    touch(options.files or {})
    local list = diagnose(text, options.toc)
    untouch(options.files or {})
    table.sort(expected)
    local got = codes(list)
    local same = #got == #expected
    for i = 1, #got do
        same = same and got[i] == expected[i]
    end
    if not same then
        ---@type string[]
        local detail = {}
        for _, diag in ipairs(list) do
            detail[#detail+1] = ('%s %d:%d %s'):format(diag.code, diag.range.start.line, diag.range.start.character, diag.message)
        end
        failures[#failures+1] = ('case `%s`: expected {%s}, got {%s}%s%s'):format(name, table.concat(expected, ', '), table.concat(got, ', '), nl, table.concat(detail, nl))
    end
end

--- Where the first diagnostic with a code is (line, start, finish).
---@param text string
---@param code string
---@param toc? string
---@return integer? line, integer? start, integer? finish
local function where(text, code, toc)
    for _, diag in ipairs(diagnose(text, toc)) do
        if diag.code == code then
            return diag.range.start.line, diag.range.start.character, diag.range['end'].character
        end
    end
end

-- 1. Lexical rules ---------------------------------------------------------------------------------------------------------------------------

case('a header and a title are fine', HEADER .. '## Title: My Addon' .. nl, {})
case('line endings: CRLF', '## Interface: 120100' .. string.char(13) .. nl .. '## Title: x' .. string.char(13) .. nl, {})
case('an empty file only lacks an Interface', '', { 'toc-missing-interface' })
case('only blank lines', nl .. nl, { 'toc-missing-interface' })
case('# is a comment', HEADER .. '# Title: not a header' .. nl, {})
case('## without a colon is not a directive', HEADER .. '## just some words' .. nl, {})
case('whitespace around the value is trimmed', '##   Interface  :   120100   ' .. nl, {})
case('no space after ##', '##Interface:120100' .. nl, {})
case('leading whitespace before # makes a file name', HEADER .. '  # not.lua' .. nl, { 'toc-nonexistent-file' })
case('a leading space before ## is a file name too', HEADER .. ' ## Title: x' .. nl, { 'toc-nonexistent-file' })
case('a line over 1024 characters', HEADER .. '## Notes: ' .. string.rep('x', 1100) .. nl, { 'toc-line-too-long' })
case('exactly 1024 characters is fine', HEADER .. '## Notes: ' .. string.rep('x', 1014) .. nl, {})
case('a header key may not be empty text', HEADER .. '## Title:' .. nl, {})
case('a flag with no value', HEADER .. '## LoadOnDemand:' .. nl, { 'toc-invalid-value' })
case('a header after file lines is still a header', HEADER .. 'Core.lua' .. nl .. '## Title: late' .. nl, { 'toc-nonexistent-file' })

do
    local line, start, finish = where(HEADER .. '## Notes: ' .. string.rep('x', 1100) .. nl, 'toc-line-too-long')
    assert(line == 1 and start == 1024, 'the report is at the cut: ' .. tostring(start))
    -- non-ASCII text: columns are characters, not bytes
    line, start, finish = where(HEADER .. '## Title-deDE: Übersicht ' .. nl .. '## Bogus: x' .. nl, 'toc-unknown-header')
    assert(line == 2 and start == 3 and finish == 8, 'the key of an ASCII line')
    line, start, finish = where('## Interface: 120100' .. nl .. '## Title: Übersicht [Bogus]' .. nl, 'toc-invalid-value')
    assert(line == 1 and start == 21 and finish == 26, 'characters, not bytes, after an Ü: ' .. tostring(start) .. '-' .. tostring(finish))
end

-- 2. The directive catalog ---------------------------------------------------------------------------------------------------------------------

for _, directive in ipairs(direct.headers) do
    if not directive.restricted and directive.value ~= 'boolean01' and directive.value ~= 'enum' and directive.value ~= 'interface'
    and directive.value ~= 'gametypes' and not directive.only then
        case('a known directive: ' .. directive.name, HEADER .. '## ' .. directive.name .. (directive.name == 'Category' and ': Combat' or ': Something') .. nl,
            directive.value == 'function' and {} or {})
    end
end
case('names are case-insensitive', HEADER .. '## TITLE: x' .. nl .. '## notes: y' .. nl, {})
case('X-* custom keys are never unknown', HEADER .. '## X-Website: https://example.com' .. nl .. '## X-Curse-Project-ID: 1' .. nl, {})
case('an unknown key', HEADER .. '## Titel: x' .. nl, { 'toc-unknown-header' })
case('an unknown key is a hint with a suggestion', HEADER .. '## Interfaces: 120100' .. nl, { 'toc-unknown-header' })
case('RequiredDeps is Dependencies', HEADER .. '## RequiredDeps: Ace3' .. nl, {})
case('any key that starts with Dep is Dependencies', HEADER .. '## Dep1: Ace3' .. nl .. '## Dep2: LibStub' .. nl, {})
case('Dependencies appends', HEADER .. '## Dependencies: A' .. nl .. '## Dependencies: B' .. nl, {})
case('OptionalDeps appends', HEADER .. '## OptionalDeps: A' .. nl .. '## OptionalDeps: B' .. nl, {})
case('LoadWith appends', HEADER .. '## LoadWith: A' .. nl .. '## LoadWith: B' .. nl, {})
case('LoadManagers appends', HEADER .. '## LoadManagers: A' .. nl .. '## LoadManagers: B' .. nl, {})
case('SavedVariables appends', HEADER .. '## SavedVariables: A' .. nl .. '## SavedVariables: B' .. nl, {})
case('SavedVariablesPerCharacter appends', HEADER .. '## SavedVariablesPerCharacter: A' .. nl .. '## SavedVariablesPerCharacter: B' .. nl, {})
case('AllowLoadGameType appends', '## Interface: 120100, 40402' .. nl .. '## AllowLoadGameType: mainline' .. nl .. '## AllowLoadGameType: cata' .. nl, {})
case('ExcludeLoadGameType appends', '## Interface: 120100, 50504, 40402, 30405' .. nl .. '## ExcludeLoadGameType: vanilla' .. nl .. '## ExcludeLoadGameType: tbc' .. nl, {})
case('a repeated Title: the last wins', HEADER .. '## Title: A' .. nl .. '## Title: B' .. nl, { 'toc-duplicate-header' })
case('a repeated Notes', HEADER .. '## Notes: A' .. nl .. '## Notes: B' .. nl, { 'toc-duplicate-header' })
case('a repeated Interface', HEADER .. '## Interface: 120100' .. nl, { 'toc-duplicate-header' })
case('AllowAddOnTableAccess: only the first counts', HEADER .. '## AllowAddOnTableAccess: 1' .. nl .. '## AllowAddOnTableAccess: 0' .. nl, { 'toc-duplicate-header' })
case('a single AllowAddOnTableAccess', HEADER .. '## AllowAddOnTableAccess: 1' .. nl, {})
case('a localized variant is its own key', HEADER .. '## Title: A' .. nl .. '## Title-frFR: B' .. nl .. '## Title-deDE: C' .. nl, {})
case('the same locale twice', HEADER .. '## Title: A' .. nl .. '## Title-frFR: B' .. nl .. '## Title-frFR: C' .. nl, { 'toc-duplicate-header' })
case('Notes is localizable', HEADER .. '## Notes: A' .. nl .. '## Notes-deDE: B' .. nl, {})
case('Category is localizable', HEADER .. '## Category: Combat' .. nl .. '## Category-deDE: Kampf' .. nl, {})

-- 2b. Categories (a recommendation: hints only)
local categories = require 'core.diagnostics.extra.wow-toc.categories'
case('a recommended category', HEADER .. '## Category: Combat' .. nl, {})
case('a category is case-insensitive', HEADER .. '## Category: combat' .. nl, {})
case('a category with spaces and an ampersand', HEADER .. '## Category: Dungeons & Raids' .. nl, {})
case('a custom category is only a hint', HEADER .. '## Category: My Own Things' .. nl, { 'toc-unknown-category' })
case('a typo of a category suggests the name', HEADER .. '## Category: Combatt' .. nl, { 'toc-unknown-category' })
case('the translation of the page', HEADER .. '## Category: Combat' .. nl .. '## Category-frFR: Combat' .. nl .. '## Category-deDE: Kampf' .. nl, {})
case('a different translation', HEADER .. '## Category: Combat' .. nl .. '## Category-deDE: Gefecht' .. nl, { 'toc-category-translation' })
case('a translation of another category', HEADER .. '## Category: Combat' .. nl .. '## Category-deDE: Karte' .. nl, { 'toc-category-translation' })
case('a translation next to a custom category is left alone', HEADER .. '## Category: Mine' .. nl .. '## Category-deDE: Meins' .. nl, { 'toc-unknown-category' })
case('the typographic apostrophe is the plain one', HEADER .. '## Category: Action Bars' .. nl .. '## Category-frFR: Barres d' .. utf8.char(0x27) .. 'action' .. nl, {})
case('a locale the page does not list is left alone', HEADER .. '## Category: Combat' .. nl .. '## Category-enUS: Combat' .. nl, {})
for _, category in ipairs(categories) do
    assert(category.name ~= '', 'a category without a name')
    for locale, text in pairs(category.names) do
        local known = false
        for _, item in ipairs(games.locales) do
            known = known or item == locale
        end
        assert(known, category.name .. ' has a translation for an unknown locale: ' .. locale)
        assert(text ~= '', category.name .. ' has an empty translation for ' .. locale)
    end
end
for _, category in ipairs(categories) do
    case('every recommended category: ' .. category.name, HEADER .. '## Category: ' .. category.name .. nl, {})
    for locale, text in pairs(category.names) do
        case('its translation: ' .. category.name .. ' ' .. locale, HEADER .. '## Category: ' .. category.name .. nl .. '## Category-' .. locale .. ': ' .. text .. nl, {})
    end
end
case('Author is not localizable', HEADER .. '## Author-deDE: B' .. nl, { 'toc-unknown-header' })
case('the unlocalized one has to come first', HEADER .. '## Title-frFR: B' .. nl .. '## Title: A' .. nl, { 'toc-localized-before-base' })
case('a localized one with no plain one', HEADER .. '## Title-frFR: B' .. nl, { 'toc-localized-before-base' })
case('an unknown locale', HEADER .. '## Title: A' .. nl .. '## Title-frFX: B' .. nl, { 'toc-invalid-value' })
case('every locale of the data is known', HEADER .. '## Title: A' .. nl .. (function ()
    ---@type string[]
    local out = {}
    for _, locale in ipairs(games.locales) do
        out[#out+1] = '## Title-' .. locale .. ': A'
    end
    return table.concat(out, nl) .. nl
end)(), {})
case('restricted directives', HEADER .. '## LoadFirst: 1' .. nl .. '## AllowLoad: Game' .. nl .. '## UseSecureEnvironment: 1' .. nl
    .. '## EscalateErrorDuringLoad: 1' .. nl .. '## SavedVariablesMachine: X' .. nl, { 'toc-restricted-header', 'toc-restricted-header', 'toc-restricted-header', 'toc-restricted-header', 'toc-restricted-header' })
case('LoadOnDemand 1', HEADER .. '## LoadOnDemand: 1' .. nl, {})
case('LoadOnDemand 0', HEADER .. '## LoadOnDemand: 0' .. nl, {})
case('LoadOnDemand yes', HEADER .. '## LoadOnDemand: yes' .. nl, { 'toc-invalid-value' })
case('OnlyBetaAndPTR 2', HEADER .. '## OnlyBetaAndPTR: 2' .. nl, { 'toc-invalid-value' })
case('LoadSavedVariablesFirst 1', HEADER .. '## LoadSavedVariablesFirst: 1' .. nl, {})
case('DefaultState disabled', HEADER .. '## DefaultState: disabled' .. nl, {})
case('DefaultState enabled', HEADER .. '## DefaultState: enabled' .. nl, {})
case('DefaultState is case-insensitive', HEADER .. '## DefaultState: Disabled' .. nl, {})
case('DefaultState off', HEADER .. '## DefaultState: off' .. nl, { 'toc-invalid-value' })
case('AddonCompartmentFunc names a function', HEADER .. '## AddonCompartmentFunc: MyAddon_OnClick' .. nl, {})
case('AddonCompartmentFunc with a dot is not a global name', HEADER .. '## AddonCompartmentFunc: My.Addon' .. nl, { 'toc-invalid-value' })

-- 3. Inline directives and variables -------------------------------------------------------------------------------------------------------------------

local FILES = { 'File.lua', 'Core.lua', 'Localization/enUS.lua', 'Mainline/Core.lua' }
local function withFile(line, expected, name)
    case(name or ('a file line: ' .. line), HEADER .. line .. nl, expected, { files = FILES })
end
withFile('File.lua', {})
withFile('Missing.lua', { 'toc-nonexistent-file' })
withFile('Localization\\enUS.lua', {}, 'backslashes are the recommended separator')
withFile('Localization/enUS.lua', {}, 'forward slashes work in the file system check')
withFile('File.lua [AllowLoadGameType standard]', {}, 'the wiki example: File.lua [AllowLoadGameType standard]')
withFile('File.lua [AllowLoadGameType mainline]', {})
withFile('File.lua [AllowLoadGameType mainline, classic]', { 'toc-redundant-condition' }, 'a condition that lists every game changes nothing')
withFile('File.lua [ExcludeLoadGameType vanilla tbc wrath]', {})
withFile('File.lua [AllowLoadGameType standard] [AllowLoadTextLocale enUS]', {}, 'several brackets on a line')
withFile('File.lua [AllowLoadTextLocale enUS,frFR]', {})
withFile('File.lua [AllowLoadTextLocale enXX]', { 'toc-invalid-value' }, 'an unknown locale in a bracket')
withFile('File.lua [AllowLoadGameType nonsense]', { 'toc-invalid-value' }, 'an unknown game type in a bracket')
withFile('File.lua [allowloadgametype Standard]', {}, 'inline names and values are case-insensitive')
withFile('File.lua [AllowLoad Game]', {})
withFile('File.lua [AllowLoad Both]', {})
withFile('File.lua [AllowLoad Sometimes]', { 'toc-invalid-value' })
withFile('File.lua [AllowLoadEnvironment Global]', {})
withFile('File.lua [AllowLoadEnvironment Elsewhere]', { 'toc-invalid-value' })
withFile('File.lua [LoadIntoEnvironment Secure]', {})
withFile('File.lua [AllowLoadGameType]', { 'toc-invalid-value' }, 'a bracket directive needs a value')
withFile('File.lua [Bootstrap]', {})
withFile('File.lua [Bootstrap yes]', { 'toc-invalid-value' }, 'Bootstrap takes no value')
withFile('File.lua [AllowLoadGameTyp standard]', { 'toc-invalid-value' }, 'a misspelt directive')
withFile('File.lua [AllowLoadGameType standard', { 'toc-invalid-value' }, 'an unclosed bracket')
withFile('File.lua []', { 'toc-invalid-value' }, 'an empty bracket')
withFile('Localization\\[TextLocale].lua', {}, 'the wiki example: Localization\\[TextLocale].lua (a variable in the path is not checked on disk)')
withFile('Nowhere\\[TextLocale].lua', {}, 'a variable inside a path of a folder that is not there')
withFile('Nowhere\\[TextLocale].lua [AllowLoadGameType cata]', {}, 'a variable inside a path, then a condition')
withFile('Nowhere\\Missing.lua', { 'toc-nonexistent-file' }, 'the same folder without the variable')
withFile('[Family]\\Core.lua', {}, '[Family] in a path')
withFile('[Game]\\Core.lua', {}, '[Game] in a path')
withFile('[Family]\\Core.lua [AllowLoadGameType mainline]', {})
withFile('[TextLocale] File.lua', {}, 'a variable in the name is not expanded: the file is not checked on disk')
withFile('File.lua [Family extra]', { 'toc-invalid-value' }, 'a variable takes no value')
withFile('[AllowLoadGameType standard] File.lua', {}, 'the prefix form is accepted too')
case('inline directives on a header line (12.0.7)', HEADER .. '## Title: A [AllowLoadGameType standard]' .. nl, {})
case('a bracket in a comment is nothing', HEADER .. '# [Bogus]' .. nl, {})

-- 4. The file name: suffixes and scope -----------------------------------------------------------------------------------------------------------

case('the name matches the folder', HEADER, {}, { toc = 'MyAddon.toc' })
case('the name does not match', HEADER, { 'toc-file-name' }, { toc = 'Other.toc' })
case('the folder name is compared case-insensitively', HEADER, {}, { toc = 'myaddon.toc' })
for _, game in ipairs(games.games) do
    for _, suffix in ipairs(game.suffixes) do
        case('suffix _' .. suffix .. ' selects ' .. game.id, '## Interface: ' .. (game.interface and game.interface.minimum or 120100) .. nl, {}, { toc = 'MyAddon_' .. suffix .. '.toc' })
    end
end
for _, family in ipairs(games.families) do
    case('family suffix _' .. family.suffix, HEADER, family.id == 'mainline' and {} or { 'toc-interface-never-matches', 'toc-interface-missing-game' }, { toc = 'MyAddon_' .. family.suffix .. '.toc' })
end
case('suffixes are case-insensitive', HEADER, {}, { toc = 'MyAddon_mainline.toc' })
case('an unknown suffix is part of the name', HEADER, { 'toc-file-name' }, { toc = 'MyAddon_Bogus.toc' })
case('a game suffix with its own number', '## Interface: 11509' .. nl, {}, { toc = 'MyAddon_Vanilla.toc' })
case('a game suffix with the number of another game', '## Interface: 120100' .. nl, { 'toc-interface-never-matches', 'toc-interface-missing-game' }, { toc = 'MyAddon_Vanilla.toc' })
case('_Classic with numbers for every classic game', '## Interface: 11509, 20506, 30405, 40402, 50504' .. nl, {}, { toc = 'MyAddon_Classic.toc' })
case('_Classic with a number that is not classic', '## Interface: 11509, 20506, 30405, 40402, 50504, 120100' .. nl, { 'toc-interface-mismatch' }, { toc = 'MyAddon_Classic.toc' })
case('_Classic with one number only', '## Interface: 11509' .. nl, { 'toc-interface-missing-game' }, { toc = 'MyAddon_Classic.toc' })
case('a line that cannot load in a game suffix file', 'File.lua [AllowLoadGameType standard]' .. nl, { 'toc-unreachable-line', 'toc-missing-interface' }, { toc = 'MyAddon_Vanilla.toc', files = { 'File.lua' } })
case('a condition the suffix already implies', '## Interface: 120100' .. nl .. 'File.lua [AllowLoadGameType standard]' .. nl, { 'toc-redundant-condition' }, { toc = 'MyAddon_Standard.toc', files = { 'File.lua' } })
case('a line allowed on a game of the suffix family', '## Interface: 11509, 20506, 30405, 40402, 50504' .. nl .. 'File.lua [AllowLoadGameType vanilla]' .. nl, {}, { toc = 'MyAddon_Classic.toc', files = { 'File.lua' } })
case('a header Exclude removes games for the lines', HEADER .. '## ExcludeLoadGameType: standard' .. nl .. 'File.lua [AllowLoadGameType standard]' .. nl, { 'toc-unreachable-line', 'toc-interface-missing-game' }, { files = { 'File.lua' } })
case('Allow then Exclude', HEADER .. '## AllowLoadGameType: mainline' .. nl .. '## ExcludeLoadGameType: forever' .. nl .. 'File.lua [AllowLoadGameType forever]' .. nl, { 'toc-unreachable-line' }, { files = { 'File.lua' } })
case('an Allow list nobody knows restricts nothing', HEADER .. '## AllowLoadGameType: nonsense' .. nl, { 'toc-invalid-value' })
case('an Exclude of an unknown type excludes nothing', HEADER .. '## ExcludeLoadGameType: nonsense' .. nl, { 'toc-invalid-value' })
case('game type aliases: camelot is forever', HEADER .. '## AllowLoadGameType: camelot' .. nl .. 'File.lua [AllowLoadGameType standard]' .. nl, { 'toc-unreachable-line' }, { files = { 'File.lua' } })
case('game type aliases: mainline includes standard', HEADER .. '## AllowLoadGameType: mainline' .. nl, {})

-- 5. The Interface number -----------------------------------------------------------------------------------------------------------------------------

case('a whole number above 0', '## Interface: 1' .. nl, {})
case('zero', '## Interface: 0' .. nl, { 'toc-invalid-interface' })
case('not a number', '## Interface: abc' .. nl, { 'toc-invalid-interface' })
case('a dotted version', '## Interface: 12.1.0' .. nl, { 'toc-invalid-interface' })
case('negative', '## Interface: -5' .. nl, { 'toc-invalid-interface' })
case('a comma list', '## Interface: 120100, 50504, 11509' .. nl, {})
case('a comma list without spaces', '## Interface: 120100,50504,11509' .. nl, {})
case('one bad item of a list', '## Interface: 120100, nope' .. nl, { 'toc-invalid-interface' })
case('an empty Interface', '## Interface:' .. nl, { 'toc-invalid-value' })
case('a number below the minimum of its game', '## Interface: 110200' .. nl, { 'toc-interface-too-low' })
case('the minimum itself', '## Interface: 120100' .. nl, {})
case('above the minimum', '## Interface: 120105' .. nl, {})
case('every game minimum of the data is accepted', (function ()
    ---@type string[]
    local out = {}
    for _, game in ipairs(games.games) do
        if game.interface then
            out[#out+1] = tostring(game.interface.minimum)
        end
    end
    return '## Interface: ' .. table.concat(out, ',') .. nl
end)(), {})
case('a number nobody knows the game of', '## Interface: 900000' .. nl, {})
case('Interface numbers imply the game: mainline only', HEADER .. '## AllowLoadGameType: mainline' .. nl, {})
case('Interface for a game the allow list excludes', '## Interface: 120100, 11509' .. nl .. '## AllowLoadGameType: standard' .. nl, { 'toc-interface-mismatch' })
case('a game of the allow list without a number', HEADER .. '## AllowLoadGameType: mainline, cata' .. nl, { 'toc-interface-missing-game' })
case('two numbers of one game are fine', '## Interface: 120100, 120105' .. nl .. '## AllowLoadGameType: mainline' .. nl, {})
case('older numbers next to a current one keep older clients working', '## Interface: 120100, 100000, 110000' .. nl, {})
case('only old numbers: one report, at the newest', '## Interface: 120000, 100000, 110000' .. nl, { 'toc-interface-too-low' })
case('no narrowing: a single number is fine', '## Interface: 120100' .. nl, {})
case('Interface on several lines counts together', '## Interface: 120100' .. nl .. '## Interface: 11509' .. nl, { 'toc-duplicate-header' })
case('a missing Interface', '## Title: x' .. nl, { 'toc-missing-interface' })

-- 6. The wiki examples, verbatim: no finding --------------------------------------------------------------------------------------------------------------

case('wiki example: a complete toc', table.concat({
    '## Interface: 120100',
    '## Title: My Addon',
    '## Title-frFR: Mon addon',
    '## Notes: Does useful things',
    '## Author: Someone',
    '## Version: 1.0.0',
    '## SavedVariables: MyAddonDB',
    '## SavedVariablesPerCharacter: MyAddonCharDB',
    '## IconTexture: Interface\\Icons\\INV_Misc_QuestionMark',
    '## X-Website: https://example.com',
    '',
    '# Core files',
    'Core\\Init.lua',
    'Core\\Config.lua',
}, nl) .. nl, {}, { files = { 'Core/Init.lua', 'Core/Config.lua' } })

-- 7. Data integrity: the data files are checked as data ----------------------------------------------------------------------------------------------------

do
    ---@type table<string, string>
    local names = {}
    ---@type table<string, string>
    local suffixes = {}
    ---@type table<string, true>
    local familyIds = {}
    for _, family in ipairs(games.families) do
        assert(not familyIds[family.id], 'family id twice: ' .. family.id)
        familyIds[family.id] = true
        assert(not suffixes[family.suffix:lower()], 'suffix twice: ' .. family.suffix)
        suffixes[family.suffix:lower()] = family.id
    end
    for _, game in ipairs(games.games) do
        for _, name in ipairs({ game.id, table.unpack(game.aliases or {}) }) do
            assert(not names[name:lower()], 'game name or alias twice: ' .. name)
            assert(not familyIds[name:lower()], 'a game name is a family name: ' .. name)
            names[name:lower()] = game.id
        end
        for _, suffix in ipairs(game.suffixes) do
            assert(not suffixes[suffix:lower()], 'suffix twice: ' .. suffix)
            suffixes[suffix:lower()] = game.id
        end
        for _, family in ipairs(game.families) do
            assert(familyIds[family], game.id .. ' names a family that does not exist: ' .. family)
        end
        assert(game.variable and game.variable ~= '', game.id .. ' has no [Game] value')
        if game.interface then
            assert(game.interface.first <= game.interface.minimum and game.interface.minimum <= game.interface.last,
                game.id .. ': the minimum is inside the range')
        end
    end
    -- the ranges of the games do not overlap
    for i, a in ipairs(games.games) do
        for j, b in ipairs(games.games) do
            if i < j and a.interface and b.interface then
                assert(a.interface.last < b.interface.first or b.interface.last < a.interface.first, a.id .. ' and ' .. b.id .. ' overlap in Interface numbers')
            end
        end
    end
    ---@type table<string, true>
    local locales = {}
    for _, locale in ipairs(games.locales) do
        assert(locale:match('^%l%l%u%u$') and not locales[locale], 'a locale: ' .. locale)
        locales[locale] = true
    end
    ---@type table<string, true>
    local directiveNames = {}
    for _, directive in ipairs(direct.headers) do
        assert(not directiveNames[directive.name:lower()], 'directive twice: ' .. directive.name)
        directiveNames[directive.name:lower()] = true
        assert(directive.description ~= '', directive.name .. ' has no description')
        assert(({ text = 1, boolean01 = 1, interface = 1, names = 1, gametypes = 1, ['function'] = 1, path = 1, enum = 1 })[directive.value], directive.name .. ': value kind')
        if directive.value == 'enum' then
            assert(directive.values and #directive.values > 0, directive.name .. ' is an enum without values')
        end
        for _, id in ipairs(directive.only or {}) do
            assert(games.games and (function ()
                for _, game in ipairs(games.games) do
                    if game.id == id then return true end
                end
            end)(), directive.name .. ' is only for a game that does not exist: ' .. id)
        end
    end
    ---@type table<string, true>
    local inlineNames = {}
    for _, inline in ipairs(direct.inlines) do
        assert(not inlineNames[inline.name:lower()], 'inline directive twice: ' .. inline.name)
        inlineNames[inline.name:lower()] = true
        assert(inline.description ~= '', inline.name .. ' has no description')
    end
    for _, variable in ipairs(direct.variables) do
        assert(not inlineNames[variable.name:lower()], 'a variable is also a directive: ' .. variable.name)
    end
end

-- 7a. Retired directives and repeated keys with inline conditions (wiki patch history and example)

case('a renamed directive: GuardedAddOn', HEADER .. '## GuardedAddOn: 1' .. nl, { 'toc-retired-header' })
case('a renamed directive: AllowLoadByGameMode', HEADER .. '## AllowLoadByGameMode: classic' .. nl, { 'toc-retired-header' })
case('a dropped directive: SuppressLocalTableRef', HEADER .. '## SuppressLocalTableRef: 1' .. nl, { 'toc-retired-header' })
case('a retired directive is case-insensitive', HEADER .. '## guardedaddon: 1' .. nl, { 'toc-retired-header' })
case('a typo is not a retired directive', HEADER .. '## GuardedAdOn2: 1' .. nl, { 'toc-unknown-header' })
case('the wiki example: a repeated Title with an inline condition', HEADER .. '## Title: My Cool AddOn' .. nl .. '## Title: My Cool AddOn in Classic [AllowLoadGameType classic]' .. nl, {})
case('a repeated Title where the first has the condition', HEADER .. '## Title: A [AllowLoadGameType classic]' .. nl .. '## Title: B' .. nl, {})
case('a repeated Title without a condition is still reported', HEADER .. '## Title: A' .. nl .. '## Title: B' .. nl, { 'toc-duplicate-header' })
case('a repeated Interface with a condition', '## Interface: 120100' .. nl .. '## Interface: 50504 [AllowLoadGameType classic]' .. nl, {})
case('every Interface line counts when one has a condition', '## Interface: 120100' .. nl .. '## Interface: 11509 [AllowLoadGameType classic]' .. nl .. '## AllowLoadGameType: standard' .. nl, { 'toc-interface-mismatch', 'toc-unreachable-line' })
case('without a condition only the last Interface line counts', '## Interface: 120100' .. nl .. '## Interface: 11509' .. nl .. '## AllowLoadGameType: standard' .. nl, { 'toc-duplicate-header', 'toc-interface-never-matches', 'toc-interface-missing-game' })
do
    ---@type table<string, true>
    local current = {}
    for _, directive in ipairs(direct.headers) do
        current[directive.name:lower()] = true
        for _, alias in ipairs(directive.aliases or {}) do
            current[alias:lower()] = true
        end
    end
    for _, retired in ipairs(direct.retired) do
        assert(not current[retired.name:lower()], 'a retired directive is also a current one: ' .. retired.name)
        assert(not retired.use or current[retired.use:lower()], 'the replacement of ' .. retired.name .. ' is not a directive: ' .. tostring(retired.use))
    end
end

-- 7b. Retired suffixes and the files next to a file ------------------------------------------------------------------------------------------------------

case('a retired suffix _BCC', HEADER, { 'toc-retired-suffix' }, { toc = 'MyAddon_BCC.toc' })
case('a retired suffix _WOTLK', HEADER, { 'toc-retired-suffix' }, { toc = 'MyAddon_WOTLK.toc' })
case('a retired suffix is case-insensitive', HEADER, { 'toc-retired-suffix' }, { toc = 'MyAddon_bcc.toc' })
case('the current suffix of the same game is not retired', '## Interface: 20506' .. nl, {}, { toc = 'MyAddon_TBC.toc' })
case('an unknown suffix is not a retired one', HEADER, { 'toc-file-name' }, { toc = 'MyAddon_Bogus.toc' })
for _, retired in ipairs(games.retiredSuffixes) do
    local used = false
    for _, game in ipairs(games.games) do
        for _, suffix in ipairs(game.suffixes) do
            used = used or suffix:lower() == retired.suffix:lower()
        end
    end
    assert(not used, 'a retired suffix is also a current one: ' .. retired.suffix)
    assert(retired.use ~= '', retired.suffix .. ' has no replacement')
end

-- the plain file is what is left when files of other suffixes exist (mainline unless it says otherwise)
touch({ 'MyAddon_Cata.toc', 'MyAddon_Mists.toc' })
case('a plain file next to _Cata: Cata is not its', HEADER .. 'File.lua [AllowLoadGameType cata]' .. nl, { 'toc-unreachable-line' }, { files = { 'File.lua' } })
case('a plain file next to _Cata: Vanilla still is', HEADER .. 'File.lua [AllowLoadGameType vanilla]' .. nl, {}, { files = { 'File.lua' } })
case('a plain file next to _Cata: a retail number fits', HEADER, {})
case('a plain file next to _Mists and _Cata declares no restriction: no Interface hints', '## Interface: 120100, 11509' .. nl, {})
untouch({ 'MyAddon_Cata.toc', 'MyAddon_Mists.toc' })
case('a plain file with no other files loads everywhere', HEADER .. 'File.lua [AllowLoadGameType cata]' .. nl, {}, { files = { 'File.lua' } })
touch({ 'MyAddon_Classic.toc' })
case('a plain file next to _Classic: no classic game', HEADER .. 'File.lua [AllowLoadGameType vanilla]' .. nl, { 'toc-unreachable-line' }, { files = { 'File.lua' } })
case('a plain file next to _Classic: the mainline games', HEADER .. 'File.lua [AllowLoadGameType plunderstorm]' .. nl, {}, { files = { 'File.lua' } })
untouch({ 'MyAddon_Classic.toc' })
touch({ 'MyAddon_Vanilla.toc' })
case('_Classic leaves Vanilla to its own file', '## Interface: 20506' .. nl .. 'File.lua [AllowLoadGameType vanilla]' .. nl, { 'toc-unreachable-line', 'toc-interface-missing-game' }, { toc = 'MyAddon_Classic.toc', files = { 'File.lua' } })
untouch({ 'MyAddon_Vanilla.toc' })
do
    local siblings = { 'MyAddon_Standard.toc', 'MyAddon_Forever.toc', 'MyAddon_Plunderstorm.toc', 'MyAddon_WoWHack.toc' }
    touch(siblings)
    local set = syntax.fileScope(furi.encode(ADDON .. '/MyAddon_Mainline.toc'))
    assert(set.standard and set.forever and set.plunderstorm and set.wowhack, 'a family file whose games all have files keeps the family')
    untouch(siblings)
end

-- 8. The scope of a line, directly ----------------------------------------------------------------------------------------------------------------------

do
    local lines = syntax.parse('## AllowLoadGameType: mainline' .. nl .. 'File.lua [ExcludeLoadGameType forever]' .. nl)
    ---@type table<string, true>
    local all = {}
    for _, game in ipairs(games.games) do
        all[game.id] = true
    end
    local scope = syntax.lineScope(all, lines, lines[2])
    assert(scope.standard and scope.plunderstorm and scope.wowhack and not scope.forever and not scope.vanilla, 'scope of a line: ' .. syntax.describeGames(scope))
    local set, suffix, base = syntax.fileScope(furi.encode(ADDON .. '/MyAddon_Mainline.toc'))
    assert(suffix == 'Mainline' and base == 'MyAddon' and set.standard and set.forever and not set.cata, 'a family suffix')
    set, suffix = syntax.fileScope(furi.encode(ADDON .. '/MyAddon_TBC.toc'))
    assert(suffix == 'TBC' and set.tbc and not set.vanilla, 'a game suffix')
    set, suffix = syntax.fileScope(furi.encode(ADDON .. '/MyAddon.toc'))
    assert(suffix == nil and set.vanilla and set.standard, 'no suffix: every game')
end

-- 9a. Code actions (quick fixes)

---@param text    string
---@param code    string  the diagnostic to fix
---@param tocName? string
---@return string? fixedText, table? action
local function quickFix(text, code, tocName)
    local uri = furi.encode(ADDON .. '/' .. (tocName or 'MyAddon.toc'))
    ---@type fileKind.diagnostic[]
    local found = {}
    for _, diag in ipairs(syntax.diagnose(uri, text)) do
        if diag.code == code then
            found[#found+1] = diag
        end
    end
    if #found == 0 then
        return nil, nil
    end
    local diag = found[1]
    local actions = assert(syntax.kind.codeAction)(uri, text, diag.range, { { code = diag.code, message = diag.message, range = diag.range } })
    local action = actions and actions[1]
    if not action then
        return nil, nil
    end
    ---@type { range: fileKind.range, newText: string }[]?
    local edits = action.edit.changes and action.edit.changes[uri]
    if not edits then
        return text, action
    end
    -- apply the edit (single line edits)
    ---@type string[]
    local lines = {}
    for line in (text .. nl):gmatch('(.-)' .. nl) do
        lines[#lines+1] = line
    end
    for _, edit in ipairs(edits) do
        local row = edit.range.start.line + 1
        lines[row] = lines[row]:sub(1, edit.range.start.character) .. edit.newText .. lines[row]:sub(edit.range['end'].character + 1)
    end
    if lines[#lines] == '' then
        lines[#lines] = nil
    end
    return table.concat(lines, nl) .. nl, action
end

---@param name     string
---@param text     string
---@param code     string
---@param expected string?  the text after the fix (nil: no fix offered)
---@param tocName? string
local function fixes(name, text, code, expected, tocName)
    local got = quickFix(text, code, tocName)
    if got ~= expected then
        failures[#failures+1] = ('quick fix `%s`: expected %s, got %s'):format(name, tostring(expected), tostring(got))
    end
end

fixes('a misspelt header', HEADER .. '## Titel: x' .. nl, 'toc-unknown-header', HEADER .. '## Title: x' .. nl)
fixes('no near name: no fix', HEADER .. '## Zzzzzzzz: x' .. nl, 'toc-unknown-header', nil)
fixes('a misspelt locale', HEADER .. '## Title: a' .. nl .. '## Title-deDF: b' .. nl, 'toc-invalid-value', HEADER .. '## Title: a' .. nl .. '## Title-deDE: b' .. nl)
fixes('a misspelt game type in a header', HEADER .. '## AllowLoadGameType: clasic' .. nl, 'toc-invalid-value', HEADER .. '## AllowLoadGameType: classic' .. nl)
fixes('a misspelt game type in a bracket', HEADER .. 'File.lua [AllowLoadGameType standrd]' .. nl, 'toc-invalid-value', HEADER .. 'File.lua [AllowLoadGameType standard]' .. nl)
fixes('a misspelt inline directive', HEADER .. 'File.lua [AllowLoadGameTyp standard]' .. nl, 'toc-invalid-value', HEADER .. 'File.lua [AllowLoadGameType standard]' .. nl)
fixes('a misspelt category', HEADER .. '## Category: Combatt' .. nl, 'toc-unknown-category', HEADER .. '## Category: Combat' .. nl)
fixes('a different translation', HEADER .. '## Category: Combat' .. nl .. '## Category-deDE: Gefecht' .. nl, 'toc-category-translation', HEADER .. '## Category: Combat' .. nl .. '## Category-deDE: Kampf' .. nl)
fixes('a renamed directive', HEADER .. '## GuardedAddOn: 1' .. nl, 'toc-retired-header', HEADER .. '## LoadFirst: 1' .. nl)
fixes('a dropped directive has no new name', HEADER .. '## SuppressLocalTableRef: 1' .. nl, 'toc-retired-header', nil)
do
    local text, action = quickFix(HEADER, 'toc-retired-suffix', 'MyAddon_BCC.toc')
    local change = action and action.edit.documentChanges and action.edit.documentChanges[1]
    if not (text and change and change.kind == 'rename' and change.newUri == furi.encode(ADDON .. '/MyAddon_TBC.toc')
        and change.oldUri == furi.encode(ADDON .. '/MyAddon_BCC.toc')) then
        failures[#failures+1] = 'quick fix `a retired suffix renames the file`'
    end
    text, action = quickFix(HEADER, 'toc-retired-suffix', 'MyAddon_WOTLK.toc')
    if not (action and action.edit.documentChanges[1].newUri == furi.encode(ADDON .. '/MyAddon_Wrath.toc')) then
        failures[#failures+1] = 'quick fix `_WOTLK becomes _Wrath`'
    end
end
do
    local uri = furi.encode(ADDON .. '/MyAddon.toc')
    local none = assert(syntax.kind.codeAction)(uri, HEADER, { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } }, {})
    if #(none or {}) ~= 0 then
        failures[#failures+1] = 'quick fix `no diagnostics, no actions`'
    end
end

-- 9. Completion, hover and definition ------------------------------------------------------------------------------------------------------------------
-- The text carries `|` where the cursor is.

touch({ 'Core.lua', 'View.xml', 'Sub/Deep.lua', 'Sub/notes.txt', 'Dir/[TextLocale].lua', '#Hidden.lua' })

---@param marked string
---@param tocName? string
---@return uri uri, string text, fileKind.position position
local function place(marked, tocName)
    local before, after = marked:match('^(.-)|(.*)$')
    assert(before, 'no cursor in ' .. marked)
    local row = select(2, before:gsub(nl, ''))
    local character = #before - (before:match('.*' .. nl .. '()') or 1) + 1
    return furi.encode(ADDON .. '/' .. (tocName or 'MyAddon.toc')), before .. after, { line = row, character = character }
end

---@param marked string
---@param tocName? string
---@return table[]?
local function completionOf(marked, tocName)
    local uri, text, position = place(marked, tocName)
    return assert(syntax.kind.complete)(uri, text, position)
end

---@param items table[]?
---@return table<string, table>
local function labels(items)
    ---@type table<string, table>
    local set = {}
    for _, entry in ipairs(items or {}) do
        set[entry.label] = entry
    end
    return set
end

---@param name    string
---@param marked  string
---@param offered string[]
---@param absent? string[]
---@param tocName? string
local function offers(name, marked, offered, absent, tocName)
    local items = completionOf(marked, tocName)
    local set = labels(items)
    for _, label in ipairs(offered) do
        if not set[label] then
            failures[#failures+1] = ('completion `%s`: `%s` is not offered'):format(name, label)
        end
    end
    for _, label in ipairs(absent or {}) do
        if set[label] then
            failures[#failures+1] = ('completion `%s`: `%s` must not be offered'):format(name, label)
        end
    end
end

offers('keys after ##', '## |', { 'Interface', 'Title', 'AllowLoadGameType', 'SavedVariables', 'Notes' }, { 'Bootstrap', 'standard' })
offers('keys while typing', '## Ti|', { 'Title' })
offers('keys include the restricted ones', '## |', { 'Secure', 'LoadFirst' })
offers('keys need ##', 'Ti|', {}, { 'Title', 'Interface' })
offers('nothing in a comment', '# |', {}, { 'Title', 'Interface' })
offers('no files in a comment', '#H|', {}, { '#Hidden.lua' })
offers('locale tags after a localizable key', '## Title-|', { 'deDE', 'frFR', 'zhTW' }, { 'Title' })
offers('locale tags while typing', '## Notes-de|', { 'deDE' })
offers('no locale tags for a key without them', '## Interface-|', {}, { 'deDE' })
offers('Interface numbers', '## Interface: |', { '120100', '50504', '11509' }, { 'standard' })
offers('Interface numbers are not repeated', '## Interface: 120100, |', { '50504' }, { '120100' })
offers('categories', '## Category: |', { 'Combat', 'Dungeons & Raids', 'Action Bars', 'Libraries' }, { 'Kampf' })
offers('categories while typing', '## Category: Dun|', { 'Dungeons & Raids' })
offers('translations of the locale', '## Category: Combat' .. nl .. '## Category-deDE: |', { 'Kampf', 'Aktionsleisten' }, { 'Combat', 'Barres d' })
offers('translations of another locale', '## Category-frFR: |', { 'Combat', 'Quêtes' }, { 'Kampf' })
offers('a locale nobody knows has no translations', '## Category-xxXX: |', {}, { 'Combat', 'Kampf' })
offers('the base category comes first', '## Category: Libraries' .. nl .. '## Category-deDE: |', { 'Bibliotheken' })
do
    local items = labels(completionOf('## Category: Libraries' .. nl .. '## Category-deDE: |'))
    if not (items.Bibliotheken and items.Aktionsleisten and items.Bibliotheken.sortText < items.Aktionsleisten.sortText) then
        failures[#failures+1] = 'completion `the translation of the plain line category sorts first`'
    end
end
-- addons installed next to this one (folders of the parent folder with a <Name>/<Name>.toc)
---@param name   string
---@param title? string
local function makeAddon(name, title)
    ---@type string
    local dir = TESTROOT .. name
    fs.create_directories(fs.path(dir))
    local file = assert(io.open(dir .. '/' .. name .. '.toc', 'w'))
    file:write('## Interface: 120100' .. nl .. (title and ('## Title: ' .. title .. nl) or ''))
    file:close()
end
makeAddon('ZzDepOne', 'First Dependency')
makeAddon('ZzDepTwo', nil)
makeAddon('MyAddon', nil) -- (the addon itself is no candidate)
fs.create_directories(fs.path(TESTROOT .. 'ZzNoToc'))
offers('addon names', '## Dependencies: |', { 'ZzDepOne', 'ZzDepTwo' }, { 'ZzNoToc', 'MyAddon' })
offers('addon names are not repeated', '## OptionalDeps: ZzDepOne, |', { 'ZzDepTwo' }, { 'ZzDepOne' })
offers('addon names for LoadWith', '## LoadWith: |', { 'ZzDepOne' })
offers('addon names for LoadManagers', '## LoadManagers: |', { 'ZzDepOne' })
offers('addon names for RequiredDeps', '## RequiredDeps: |', { 'ZzDepOne' })
offers('addon names for a Dep* key', '## Dep1: |', { 'ZzDepOne' })
offers('SavedVariables are globals, not addons', '## SavedVariables: |', {}, { 'ZzDepOne' })
offers('a boolean', '## LoadOnDemand: |', { '1', '0' })
offers('an enum', '## DefaultState: |', { 'enabled', 'disabled' }, { '1' })
offers('game types', '## AllowLoadGameType: |', { 'standard', 'mainline', 'classic', 'cata', 'camelot', 'forever' })
offers('game types in a list are not repeated', '## ExcludeLoadGameType: standard, |', { 'cata', 'classic' }, { 'standard' })
offers('game types after a partial word', '## AllowLoadGameType: ca|', { 'cata', 'camelot' })
offers('free text offers nothing', '## Title: |', {}, { '1', 'standard', 'enUS' })
offers('an unknown key offers nothing', '## Bogus: |', {}, { '1', 'standard' })
offers('inline directive names', 'File.lua [|', { 'AllowLoadGameType', 'ExcludeLoadGameType', 'AllowLoadTextLocale', 'Bootstrap', 'Family', 'TextLocale' }, { 'standard' })
offers('inline directive names on a header', '## Title: A [|', { 'AllowLoadGameType' })
offers('inline game types', 'File.lua [AllowLoadGameType |', { 'standard', 'mainline', 'cata' })
offers('inline game types are not repeated', 'File.lua [ExcludeLoadGameType vanilla tbc |', { 'cata' }, { 'vanilla', 'tbc' })
offers('inline locales', 'File.lua [AllowLoadTextLocale |', { 'enUS', 'deDE' }, { 'standard' })
offers('inline enum', 'File.lua [AllowLoad |', { 'Game', 'Glue', 'Both' })
offers('an inline directive without a value', 'File.lua [Bootstrap |', {}, { 'standard', 'Game' })
offers('a closed bracket is over', 'File.lua [AllowLoadGameType standard] |', {}, { 'AllowLoadGameType', 'cata' })
offers('files', 'Co|', { 'Core.lua' }, { 'View.xml', 'notes.txt' })
offers('files of both kinds', '|', { 'Core.lua', 'View.xml', 'Sub\\' })
offers('files of a folder', 'Sub\\|', { 'Deep.lua' }, { 'notes.txt', 'Core.lua' })
offers('files of a folder with a slash', 'Sub/|', { 'Deep.lua' })
offers('a folder', 'Su|', { 'Sub\\' })
offers('no files in a header value', '## Title: Co|', {}, { 'Core.lua' })

do
    -- the edit replaces the typed word, nothing else
    local items = labels(completionOf('## Ti|'))
    ---@type table?
    local edit = items.Title and items.Title.textEdit
    if not (edit and edit.newText == 'Title: ' and edit.range.start.character == 3 and edit.range['end'].character == 5) then
        failures[#failures+1] = 'completion edit of a key: ' .. tostring(edit and edit.newText)
    end
    items = labels(completionOf('## Notes-de|'))
    edit = items.deDE and items.deDE.textEdit
    if not (edit and edit.newText == 'deDE' and edit.range.start.character == 9 and edit.range['end'].character == 11) then
        failures[#failures+1] = 'completion edit of a locale tag'
    end
    items = labels(completionOf('File.lua [Boot|'))
    edit = items.Bootstrap and items.Bootstrap.textEdit
    if not (edit and edit.newText == 'Bootstrap]' and edit.range.start.character == 10) then
        failures[#failures+1] = 'completion edit of an inline directive: ' .. tostring(edit and edit.newText)
    end
    items = labels(completionOf('File.lua [Boot|]'))
    edit = items.Bootstrap and items.Bootstrap.textEdit
    if not (edit and edit.newText == 'Bootstrap') then
        failures[#failures+1] = 'an inline directive before a closing bracket'
    end
    items = labels(completionOf('## Ti|: x'))
    edit = items.Title and items.Title.textEdit
    if not (edit and edit.newText == 'Title') then
        failures[#failures+1] = 'a key before its colon'
    end
end

---@param name     string
---@param marked   string
---@param contains string[]
---@param tocName? string
local function hovers(name, marked, contains, tocName)
    local uri, text, position = place(marked, tocName)
    local result = assert(syntax.kind.hover)(uri, text, position)
    if #contains == 0 then
        if result then
            failures[#failures+1] = ('hover `%s`: nothing expected, got %s'):format(name, result.value)
        end
        return
    end
    if not result then
        failures[#failures+1] = ('hover `%s`: no hover'):format(name)
        return
    end
    for _, part in ipairs(contains) do
        if not result.value:find(part, 1, true) then
            failures[#failures+1] = ('hover `%s`: `%s` missing in: %s'):format(name, part, result.value)
        end
    end
end

hovers('a key', '## Inter|face: 120100', { '**Interface**', 'whole numbers' })
hovers('a key, the last letter', '## Interfac|e: 120100', { '**Interface**' })
hovers('a restricted key', '## Sec|ure: 1', { 'not available to third-party addons' })
hovers('an appending key', '## Dep|endencies: A', { 'adds to the list', 'RequiredDeps' })
hovers('a prefix key', '## Dep|Foo: A', { '**Dependencies**' })
hovers('a localized key', '## Title-de|DE: Hallo', { 'localized for deDE' })
hovers('a custom key', '## X-Wo|w: 1', { 'custom key' })
hovers('an unknown key', '## Bog|us: 1', {})
hovers('first wins', '## AllowAddOnTable|Access: 1', { 'first line counts' })
hovers('the value of a free text key', '## Title: He|llo', {})
hovers('a category', '## Category: Com|bat', { '**Combat**', 'Damage meters', '`deDE` Kampf' })
hovers('a category in lower case', '## Category: com|bat', { '**Combat**' })
hovers('a translated category', '## Category-deDE: Ka|mpf', { '**Combat**' })
hovers('a custom category', '## Category: My Ow|n Things', {})
hovers('an addon', '## Dependencies: Zz|DepOne', { '**ZzDepOne**', '(First Dependency)', 'ZzDepOne.toc' })
hovers('an addon without a title', '## OptionalDeps: ZzDep|Two', { '**ZzDepTwo**' })
hovers('an addon that is not there', '## Dependencies: Nowhe|re', { 'No addon `Nowhere`' })
hovers('a name of SavedVariables is no addon', '## SavedVariables: ZzDep|One', {})
hovers('an Interface number', '## Interface: 12|0100', { '12.1.0', 'Retail (Midnight)' })
hovers('an old Interface number', '## Interface: 11|509', { '1.15.9', 'Classic Era' })
hovers('a number nobody owns', '## Interface: 9|9', { '0.0.99' })
hovers('a game type', '## AllowLoadGameType: cat|a', { 'Cataclysm Classic', '`_Cata`', '40402' })
hovers('a family', '## AllowLoadGameType: main|line', { '(family)', 'Retail (Midnight)', 'Plunderstorm' })
hovers('an alias', '## ExcludeLoadGameType: camel|ot', { 'Forever' })
hovers('an inline directive', 'File.lua [AllowLoad|GameType cata]', { '`[AllowLoadGameType]`' })
hovers('an inline variable', 'Dir\\[Text|Locale].lua', { '`[TextLocale]`' })
hovers('a bracket value', 'File.lua [AllowLoadGameType ca|ta]', { 'Cataclysm Classic' })
hovers('a bracket word nobody knows', 'File.lua [AllowLoadGameType no|nsense]', {})
hovers('a file line says where it loads', 'Co|re.lua', { 'Loads on every game type' })
hovers('a restricted file line', 'Co|re.lua [AllowLoadGameType cata]', { 'Loads on: Cataclysm Classic.' })
hovers('a file line of a suffix file', 'Co|re.lua', { 'Loads on: The Burning Crusade Classic.', '`_TBC`' }, 'MyAddon_TBC.toc')
hovers('a comment', '# Co|re', {})
hovers('a blank line', '|', {})

---@param name     string
---@param marked   string
---@param expected string?  the file the line leads to (nil: no location)
local function leadsTo(name, marked, expected)
    local uri, text, position = place(marked)
    local result = assert(syntax.kind.definition)(uri, text, position)
    local got = result and result[1] and result[1].uri
    if expected == nil then
        if got then
            failures[#failures+1] = ('definition `%s`: nothing expected, got %s'):format(name, got)
        end
    elseif got ~= furi.encode(ADDON .. '/' .. expected) then
        failures[#failures+1] = ('definition `%s`: expected %s, got %s'):format(name, expected, tostring(got))
    end
end

leadsTo('a file', 'Co|re.lua', 'Core.lua')
leadsTo('a file in a folder', 'Sub\\De|ep.lua', 'Sub/Deep.lua')
leadsTo('a file with a condition', 'Co|re.lua [AllowLoadGameType cata]', 'Core.lua')
leadsTo('an xml file', 'Vi|ew.xml', 'View.xml')
do
    local uri, text, position = place('## Dependencies: Zz|DepOne, ZzDepTwo')
    local result = assert(syntax.kind.definition)(uri, text, position)
    if not (result and result[1] and result[1].uri == furi.encode(TESTROOT .. 'ZzDepOne/ZzDepOne.toc')) then
        failures[#failures+1] = 'definition `an addon in Dependencies`'
    end
    uri, text, position = place('## Dependencies: ZzDepOne, ZzDep|Two')
    result = assert(syntax.kind.definition)(uri, text, position)
    if not (result and result[1] and result[1].uri == furi.encode(TESTROOT .. 'ZzDepTwo/ZzDepTwo.toc')) then
        failures[#failures+1] = 'definition `the second addon of the list`'
    end
    uri, text, position = place('## Dependencies: Nowhe|re')
    if assert(syntax.kind.definition)(uri, text, position) then
        failures[#failures+1] = 'definition `an addon that is not there`'
    end
    uri, text, position = place('## SavedVariables: ZzDep|One')
    if assert(syntax.kind.definition)(uri, text, position) then
        failures[#failures+1] = 'definition `a SavedVariables name`'
    end
end
leadsTo('a file that is not there', 'Mi|ssing.lua', nil)
leadsTo('a variable in the path', 'Dir\\[TextLo|cale].lua', nil)
leadsTo('a header line', '## Ti|tle: Core.lua', nil)
leadsTo('a comment', '# Co|re.lua', nil)
untouch({ 'Core.lua', 'View.xml', 'Sub/Deep.lua', 'Sub/notes.txt', 'Dir/[TextLocale].lua', '#Hidden.lua' })
for _, name in ipairs { 'ZzDepOne', 'ZzDepTwo' } do
    pcall(fs.remove, fs.path(TESTROOT .. name .. '/' .. name .. '.toc'))
    pcall(fs.remove, fs.path(TESTROOT .. name))
end
pcall(fs.remove, fs.path(TESTROOT .. 'ZzNoToc'))
pcall(fs.remove, fs.path(TESTROOT .. 'MyAddon/MyAddon.toc'))
pcall(fs.remove, fs.path(ADDON .. '/Dir'))
pcall(fs.remove, fs.path(ADDON .. '/Sub'))

assert(#failures == 0, nl .. table.concat(failures, nl .. nl))
