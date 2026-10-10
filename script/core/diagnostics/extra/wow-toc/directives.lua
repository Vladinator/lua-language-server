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
---@field addons?      boolean  the names are addon folders (`Interface/AddOns/<Name>/<Name>.toc`)
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

---@class wowToc.retiredHeader
---@field name string  the old name (case-insensitive)
---@field use? string  the name that replaced it (nil: dropped without replacement)

---@class wowToc.diagnosticMode
---@field name        string
---@field description string

---@class wowToc.directives
---@field diagnosticModes wowToc.diagnosticMode[]
---@field retired   wowToc.retiredHeader[]
---@field headers   wowToc.directive[]
---@field inlines   wowToc.inline[]
---@field variables wowToc.variable[]

---@type wowToc.directives
return {
    -- the modes of the `# @diagnostic <mode>: toc-x, toc-y` comment (the TOC counterpart of the LuaDoc comment)
    diagnosticModes = {
        { name = 'disable-next-line', description = 'Switches the listed diagnostics off for the next line. No codes: every diagnostic.' },
        { name = 'disable', description = 'Switches the listed diagnostics off from this line to the end of the file, or until `enable`. No codes: every diagnostic.' },
        { name = 'enable', description = 'Switches the listed diagnostics on again after a `disable`. No codes: every diagnostic.' },
        { name = 'expect-next-line', description = 'Like `disable-next-line`, but the diagnostic must occur on the next line: when it does not, `toc-unfulfilled-expect` is reported on this comment.' },
    },

    -- directives the game dropped or renamed (wiki patch history): the "upgrade recommended" hint for `## Key:` lines
    retired = {
        { name = 'AllowLoadByGameMode', use = 'AllowLoadGameType' },
        { name = 'GuardedAddOn', use = 'LoadFirst' },
        { name = 'SuppressLocalTableRef' },
    },

    headers = {
        { name = 'Interface', value = 'interface',
          description = 'The game version(s) the addon was written for. A version that does not match the client marks the addon as out of date.',
          since = 'A comma separated list works since 10.2.7.' },
        { name = 'Title', value = 'text', localizable = true,
          description = 'The name shown in the AddOn List.' },
        { name = 'Notes', value = 'text', localizable = true,
          description = 'The tooltip shown in the AddOn List. UI escape colors work (`|cFFFF0000red|r`).' },
        { name = 'Category', value = 'text', localizable = true,
          description = 'The category header the addon is listed under in the AddOn List. Use the names of the Addon Categories page, so addons group the same way in every locale.' },
        { name = 'Author', value = 'text',
          description = 'The name of the author. Readable with `C_AddOns.GetAddOnMetadata`.' },
        { name = 'Version', value = 'text',
          description = 'The addon version, shown in the AddOn List tooltip. Some update tools expect it to start with a number.' },
        { name = 'Group', value = 'text',
          description = 'The name of the main addon of a group. Grouped addons are listed indented under it; nested groups are not supported. Without it the client guesses groups from names and dependencies. The value is a grouping key, so it is not localized.' },
        { name = 'IconTexture', value = 'path',
          description = 'A texture path for the icon in the AddOn List, for example `Interface\\Icons\\TEMP`. Wins over `IconAtlas` when both are set.' },
        { name = 'IconAtlas', value = 'text',
          description = 'An atlas name for the icon in the AddOn List. `IconTexture` wins when both are set.' },
        { name = 'AddonCompartmentFunc', value = 'function', only = { 'standard', 'forever' },
          description = 'A global function called when the addon is clicked in the addon compartment dropdown. Required for the addon to appear there under automatic registration.' },
        { name = 'AddonCompartmentFuncOnEnter', value = 'function', only = { 'standard', 'forever' },
          description = 'A global function called when the addon is highlighted in the addon compartment dropdown.' },
        { name = 'AddonCompartmentFuncOnLeave', value = 'function', only = { 'standard', 'forever' },
          description = 'A global function called when the highlight in the addon compartment dropdown ends.' },
        { name = 'LoadOnDemand', value = 'boolean01',
          description = '`1` delays loading until `C_AddOns.LoadAddOn` is called for the addon.' },
        { name = 'Dependencies', value = 'names', addons = true, appends = true, aliases = { 'RequiredDeps' }, prefixes = { 'Dep' },
          description = 'Addons that must load before this one.' },
        { name = 'OptionalDeps', value = 'names', addons = true, appends = true,
          description = 'Addons that load before this one when they are installed.' },
        { name = 'LoadWith', value = 'names', addons = true, appends = true,
          description = 'Addons whose loading triggers loading this one. Also makes this addon load on demand.' },
        { name = 'LoadManagers', value = 'names', addons = true, appends = true,
          description = 'When any of these addons is present, this addon loads on demand.',
          since = 'Added in 2.1.0.' },
        { name = 'AllowLoadGameType', value = 'gametypes', appends = true,
          description = 'Loads the addon only on the listed game types or families (case-insensitive). Pair it with `ExcludeLoadGameType`: when none of the listed types is known to the client, the condition still counts as met.',
          since = 'An addon directive since 11.1.5.' },
        { name = 'ExcludeLoadGameType', value = 'gametypes', appends = true,
          description = 'Loads the addon on every game type except the listed ones (case-insensitive).',
          since = 'Added in 12.0.0.' },
        { name = 'OnlyBetaAndPTR', value = 'boolean01',
          description = '`1` loads the addon only on Beta or PTR clients.' },
        { name = 'DefaultState', value = 'enum', values = { 'enabled', 'disabled' },
          description = '`disabled` makes the player enable the addon in the AddOn List.' },
        { name = 'LoadSavedVariablesFirst', value = 'boolean01', irreversible = true,
          description = '`1` loads the SavedVariables before the script files of the addon.',
          since = 'Added in 11.1.5.' },
        { name = 'SavedVariables', value = 'names', appends = true,
          description = 'Global variables saved per account, in `WTF\\[account]\\SavedVariables\\<AddOn>.lua`.' },
        { name = 'SavedVariablesPerCharacter', value = 'names', appends = true,
          description = 'Global variables saved per character.' },
        { name = 'AllowAddOnTableAccess', value = 'boolean01', firstWins = true,
          description = '`1` lets `C_AddOns.GetAddOnLocalTable` return the namespace table of the addon.',
          since = 'Added in 11.1.7.' },
        -- not available to third-party addons
        { name = 'AllowLoad', value = 'enum', values = { 'Both', 'Game', 'Glue' }, restricted = true,
          description = 'Controls the FrameXML and GlueXML environments the addon loads in.' },
        { name = 'EscalateErrorDuringLoad', value = 'boolean01', restricted = true,
          description = 'Appears to have no effect in public clients.' },
        { name = 'LoadFirst', value = 'boolean01', restricted = true,
          description = 'Marks a secure addon that cannot be disabled and loads before the others.' },
        { name = 'SavedVariablesMachine', value = 'names', appends = true, restricted = true,
          description = 'Global variables saved for all accounts on the machine.' },
        { name = 'UseSecureEnvironment', value = 'boolean01', restricted = true,
          description = '`1` loads all files of the addon into a private function environment.',
          since = 'Added in 11.0.0.' },
        { name = 'Secure', value = 'boolean01', restricted = true,
          description = 'A marker for Blizzard-signed secure code (listed by wowlua-ls).' },
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
