-- The `## Key: Value` directives, the `[Inline]` directives and the `[Variables]` of a WoW `.toc` file, as DATA (see games.lua): a new directive is a
-- row here and a row in the tests. Source: https://warcraft.wiki.gg/wiki/TOC_format (read 2026-10-10), cross-read with the wowlua-ls guide.
--
-- header directive:
--   name        as the wiki spells it; matched case-insensitively
--   value       what the value is, for the checks and for completion: 'text', 'boolean01' (`1` / `0`), 'interface' (comma list of whole numbers
--               above 0), 'names' (a comma list of names: addons or globals), 'gametypes' (comma list of game types or families), 'function'
--               (a global function name), 'path' (a game path), 'enum' (see `values`)
--   values      for 'enum': the accepted words (case-insensitive)
--   appends     repeating the line ADDS to the list; otherwise the last one wins
--   firstWins   only the FIRST line counts
--   localizable `Name-<locale>` variants exist
--   aliases     other names of the directive
--   prefixes    any key that starts with one of these is the directive (`Dep*`)
--   only        the game ids that know the directive (omitted: all)
--   restricted  not available to third-party addons
--   irreversible once set to 1 it cannot be turned off later in the file
--   since       free text for hover
--   description what hover says

---@class wowToc.directive
---@field name         string
---@field value        'text'|'boolean01'|'interface'|'names'|'gametypes'|'function'|'path'|'enum'
---@field values?      string[]
---@field appends?     boolean
---@field firstWins?   boolean
---@field localizable? boolean
---@field aliases?     string[]
---@field prefixes?    string[]
---@field only?        string[]
---@field restricted?  boolean
---@field irreversible? boolean
---@field since?       string
---@field description  string

---@class wowToc.inline
---@field name        string
---@field value       'none'|'gametypes'|'locales'|'enum'
---@field values?     string[]
---@field only?       string[]
---@field since?      string
---@field description string

---@class wowToc.variable
---@field name        string
---@field description string

---@class wowToc.directives
---@field headers   wowToc.directive[]
---@field inlines   wowToc.inline[]
---@field variables wowToc.variable[]

---@type wowToc.directives
return {
    headers = {
        { name = 'Interface', value = 'interface',
          description = 'The client interface version(s) this addon was written for, a comma separated list of whole numbers (`120100` is 12.1.0). A number that does not match the client marks the addon out of date.',
          since = 'A comma separated list since 10.2.7.' },
        { name = 'Title', value = 'text', localizable = true,
          description = 'The name shown in the AddOn List. `Title-frFR` and the like localize it; the plain `Title` must come first.' },
        { name = 'Notes', value = 'text', localizable = true,
          description = 'The tooltip in the AddOn List. UI escape colour codes work. Localizable (`Notes-deDE`).' },
        { name = 'Category', value = 'text', localizable = true,
          description = 'A collapsible category header in the AddOn List. Use the translated names of the Addon Categories page so addons group the same in every locale.' },
        { name = 'Author', value = 'text',
          description = 'The author, readable with `C_AddOns.GetAddOnMetadata`.' },
        { name = 'Version', value = 'text',
          description = 'Shown in the AddOn List tooltip. Some update tools expect it to start with a number.' },
        { name = 'Group', value = 'text',
          description = 'The name of the main addon: grouped addons are listed as indented, non-collapsible sub-lists. Nested groups are not supported. Without it the client infers groups from names and dependencies.' },
        { name = 'IconTexture', value = 'path',
          description = 'A texture path for the AddOn List icon, e.g. `Interface\\Icons\\TEMP`. Wins over `IconAtlas`.' },
        { name = 'IconAtlas', value = 'text',
          description = 'An atlas name for the AddOn List icon. `IconTexture` wins over it.' },
        { name = 'AddonCompartmentFunc', value = 'function', only = { 'standard', 'forever' },
          description = 'A global function run when the addon is clicked in the addon compartment dropdown. Required for the addon to appear there under automatic registration.' },
        { name = 'AddonCompartmentFuncOnEnter', value = 'function', only = { 'standard', 'forever' },
          description = 'A global function run when the addon is highlighted in the addon compartment.' },
        { name = 'AddonCompartmentFuncOnLeave', value = 'function', only = { 'standard', 'forever' },
          description = 'A global function run when the highlight ends.' },
        { name = 'LoadOnDemand', value = 'boolean01',
          description = '`1` delays loading until `C_AddOns.LoadAddOn` is called for the addon.' },
        { name = 'Dependencies', value = 'names', appends = true, aliases = { 'RequiredDeps' }, prefixes = { 'Dep' },
          description = 'Addons that must load before this one (a comma separated list). `RequiredDeps` and any key that starts with `Dep` mean the same. A repeated line adds to the list.' },
        { name = 'OptionalDeps', value = 'names', appends = true,
          description = 'Addons that load before this one if they are present. A repeated line adds to the list.' },
        { name = 'LoadWith', value = 'names', appends = true,
          description = 'Addons whose loading triggers this one. Implies LoadOnDemand. A repeated line adds to the list.' },
        { name = 'LoadManagers', value = 'names', appends = true,
          description = 'If any of these addons is present, this one behaves as LoadOnDemand. A repeated line adds to the list.',
          since = 'Added in 2.1.0.' },
        { name = 'AllowLoadGameType', value = 'gametypes', appends = true,
          description = 'Restricts loading to the listed game types or families (case-insensitive). If none of the listed types is recognized the condition is still satisfied: pair it with `ExcludeLoadGameType`. A repeated line adds to the list.',
          since = 'An addon directive since 11.1.5.' },
        { name = 'ExcludeLoadGameType', value = 'gametypes', appends = true,
          description = 'The inverse of `AllowLoadGameType`: loads on every game type except the listed ones. A repeated line adds to the list.',
          since = 'Added in 12.0.0.' },
        { name = 'OnlyBetaAndPTR', value = 'boolean01',
          description = '`1` restricts loading to Beta or PTR clients.' },
        { name = 'DefaultState', value = 'enum', values = { 'enabled', 'disabled' },
          description = '`disabled` makes the user enable the addon manually in the AddOn List.' },
        { name = 'LoadSavedVariablesFirst', value = 'boolean01', irreversible = true,
          description = '`1` loads the SavedVariables before all script files. Once `1`, it cannot be turned off later in the file.',
          since = 'Added in 11.1.5.' },
        { name = 'SavedVariables', value = 'names', appends = true,
          description = 'Global names saved per account in `WTF\\[account]\\SavedVariables\\<AddOn>.lua`. A repeated line adds to the list.' },
        { name = 'SavedVariablesPerCharacter', value = 'names', appends = true,
          description = 'Global names saved per character. A repeated line adds to the list.' },
        { name = 'AllowAddOnTableAccess', value = 'boolean01', firstWins = true,
          description = '`1` allows `C_AddOns.GetAddOnLocalTable` to return the addon\'s namespace table. Only the first line counts.',
          since = 'Added in 11.1.7.' },
        -- not available to third-party addons
        { name = 'AllowLoad', value = 'enum', values = { 'Both', 'Game', 'Glue' }, restricted = true,
          description = 'Controls the FrameXML and GlueXML environments. Not available to third-party addons.' },
        { name = 'EscalateErrorDuringLoad', value = 'boolean01', restricted = true,
          description = 'Appears to have no effect in public clients. Not available to third-party addons.' },
        { name = 'LoadFirst', value = 'boolean01', restricted = true,
          description = 'Marks a secure addon that cannot be disabled and loads before the others. Not available to third-party addons.' },
        { name = 'SavedVariablesMachine', value = 'names', appends = true, restricted = true,
          description = 'Global names persisted across all accounts on the machine. Not available to third-party addons.' },
        { name = 'UseSecureEnvironment', value = 'boolean01', restricted = true,
          description = '`1` loads all addon files into a private function environment. Not available to third-party addons.',
          since = 'Added in 11.0.0.' },
        { name = 'Secure', value = 'boolean01', restricted = true,
          description = 'A Blizzard-signed secure code marker (wowlua-ls lists it). Not available to third-party addons.' },
    },

    inlines = {
        { name = 'AllowLoad', value = 'enum', values = { 'Game', 'Glue', 'Both' },
          description = 'Loads this line only in the given environment. `Glue` (the login screen) is effectively unused by addons.' },
        { name = 'AllowLoadGameType', value = 'gametypes',
          description = 'Loads this line only on the listed game types or families, comma separated.' },
        { name = 'ExcludeLoadGameType', value = 'gametypes',
          description = 'Loads this line on every game type except the listed ones.' },
        { name = 'AllowLoadTextLocale', value = 'locales',
          description = 'Loads this line only for the listed client locales (as `GetLocale` returns them: `enUS`, `frFR`, ...).' },
        { name = 'AllowLoadEnvironment', value = 'enum', values = { 'Global', 'Secure' },
          description = 'Loads this line only into the given environment. `Secure` is effectively unused by addons.' },
        { name = 'LoadIntoEnvironment', value = 'enum', values = { 'Global', 'Secure' },
          description = 'Loads the file into the given environment.' },
        { name = 'Bootstrap', value = 'none', only = { 'standard', 'forever' },
          description = 'Restricts the line to the LoadOnDemand bootstrap process.',
          since = 'Added in 12.1.0.' },
    },

    variables = {
        { name = 'Family',     description = 'Expands to the game family: `Mainline` or `Classic`.' },
        { name = 'Game',       description = 'Expands to the game type: `Standard`, `Mists`, `Cata`, `Vanilla`, `TBC`, `Wrath`, `Camelot`, ...' },
        { name = 'TextLocale', description = 'Expands to the client text locale (`enUS`, `frFR`, `deDE`, ...): `Localization\\[TextLocale].lua` loads the file of the locale.' },
    },
}
