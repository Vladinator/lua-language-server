-- The game types, families and locales a WoW `.toc` file talks about, as DATA (nothing here is logic): a new game type, an alias, a suffix or
-- a new locale is an edit of this table and a row in the tests, never a change in the parser or the checks. Read by
-- ../wow-toc-language.lua. Source: https://warcraft.wiki.gg/wiki/TOC_format (read 2026-10-10).
--
-- game entry:
--   id          the canonical name (lowercase), what the checks and the tests use
--   display     what hover shows
--   aliases     other spellings of the same game type accepted in `AllowLoadGameType` / `ExcludeLoadGameType` values (case-insensitive)
--   families    the families it belongs to
--   suffixes    the suffixes of `Name_<Suffix>.toc` that select exactly this game (case-insensitive)
--   variable    what `[Game]` expands to
--   interface   OPTIONAL: `first`..`last` is the range of Interface numbers that mean this game (110200 and 120100 are both retail), `minimum`
--               the lowest number worth declaring for it today (a hint, not a validity rule: any whole number above 0 is valid); omitted
--               for a game nothing is known about (Forever has no range: its beta numbers overlap Classic Era's)
--   note        OPTIONAL: one line for hover
--
-- Last revised 2026-10-10; the Interface minimums are the "live" values of the wiki table of that day.

---@class wowToc.game
---@field id        string
---@field display   string
---@field aliases?  string[]
---@field families  string[]
---@field suffixes  string[]
---@field variable  string
---@field interface? { first: integer, last: integer, minimum: integer }
---@field note?     string

---@class wowToc.family
---@field id        string
---@field display   string
---@field suffix    string  the `Name_<Suffix>.toc` suffix of the family
---@field variable  string  what `[Family]` expands to

---@class wowToc.games
---@field games     wowToc.game[]
---@field families  wowToc.family[]
---@field locales   string[]

---@type wowToc.games
return {
    games = {
        {
            id = 'standard', display = 'Retail (Midnight)', aliases = { 'retail', 'midnight' }, families = { 'mainline' },
            suffixes = { 'Standard' }, variable = 'Standard', interface = { first = 60000, last = 199999, minimum = 120100 },
        },
        {
            id = 'forever', display = 'Forever', aliases = { 'camelot' }, families = { 'mainline' },
            suffixes = { 'Forever', 'Camelot' }, variable = 'Camelot',
            note = 'The wiki says the Camelot name may change to Forever.',
        },
        {
            id = 'mists', display = 'Mists of Pandaria Classic', families = { 'classic' },
            suffixes = { 'Mists' }, variable = 'Mists', interface = { first = 50000, last = 59999, minimum = 50504 },
        },
        {
            id = 'cata', display = 'Cataclysm Classic', families = { 'classic' },
            suffixes = { 'Cata' }, variable = 'Cata', interface = { first = 40000, last = 49999, minimum = 40402 },
        },
        {
            id = 'wrath', display = 'Wrath of the Lich King Classic', families = { 'classic' },
            suffixes = { 'Wrath' }, variable = 'Wrath', interface = { first = 30000, last = 39999, minimum = 30405 },
            note = 'Includes Titan Reforged (Interface 38002).',
        },
        {
            id = 'tbc', display = 'The Burning Crusade Classic', families = { 'classic' },
            suffixes = { 'TBC' }, variable = 'TBC', interface = { first = 20000, last = 29999, minimum = 20506 },
        },
        {
            id = 'vanilla', display = 'Classic Era', aliases = { 'classic_era' }, families = { 'classic' },
            suffixes = { 'Vanilla' }, variable = 'Vanilla', interface = { first = 10000, last = 19999, minimum = 11509 },
        },
        {
            id = 'plunderstorm', display = 'Plunderstorm', aliases = { 'wowlabs' }, families = { 'mainline' },
            suffixes = { 'Plunderstorm', 'WoWLabs' }, variable = 'Plunderstorm',
        },
        {
            id = 'wowhack', display = 'Talebound', families = { 'mainline' },
            suffixes = { 'WoWHack' }, variable = 'WoWHack',
        },
    },

    families = {
        { id = 'mainline', display = 'Mainline',  suffix = 'Mainline', variable = 'Mainline' },
        { id = 'classic',  display = 'Classic',   suffix = 'Classic',  variable = 'Classic' },
    },

    -- the values `GetLocale` returns
    locales = { 'enUS', 'enGB', 'deDE', 'esES', 'esMX', 'frFR', 'itIT', 'koKR', 'ptBR', 'ruRU', 'zhCN', 'zhTW' },
}
