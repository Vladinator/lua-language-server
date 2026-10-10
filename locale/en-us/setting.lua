---@diagnostic disable: undefined-global

config.addonManager.enable        =
"Whether the addon manager is enabled or not."
config.addonManager.repositoryBranch =
"Specifies the git branch used by the addon manager."
config.addonManager.repositoryPath =
"Specifies the git path used by the addon manager."
config.addonRepositoryPath        =
"Specifies the addon repository path (not related to the addon manager)."
config.runtime.version =
[[
The Lua version the code is written for.

It decides which syntax is accepted (`goto` from 5.2, integer division and bit operators from 5.3, `<const>` and `<close>` from 5.4) and which standard library the server assumes (see `Lua.runtime.builtin`). Use `Lua 5.1` for World of Warcraft addons and `LuaJIT` for LuaJIT code (see `Lua.runtime.enableLuaJITExtensions`).
]]
config.runtime.path =
[[
Where `require 'name'` looks for a file.

Each entry is a pattern in which `?` stands for the name, with dots turned into folder separators: `?.lua` finds `myfile.lua`, `?/init.lua` finds `myfile/init.lua`. The patterns are tried inside the workspace and the libraries of `Lua.workspace.library`.

Unless `Lua.runtime.pathStrict` is on, a pattern is also tried in every sub folder (`${workspace}/**/myfile/init.lua`).
]]
config.runtime.pathStrict =
[[
Search the `Lua.runtime.path` patterns from the root of the workspace only.

`true`: `require 'a.b'` finds only `<root>/a/b.lua`. `false`: it also finds `<root>/**/a/b.lua`, which is convenient but can pick a wrong file in a big project.
]]
config.runtime.special =
[[
Treat a custom global function as a built-in one.

The key is the name you use, the value the built-in it behaves like (`require`, `dofile`, `loadfile`, `pcall`, `xpcall`, `assert`, `error`, `type`, `setmetatable`, `rawset`, `rawget`, `os.exit`, `_G`). The server then resolves its arguments the same way.

```json
"Lua.runtime.special": {
    "include": "require"
}
```
]]
config.runtime.unicodeName =
[[
Allow Unicode letters in names.

`true`: `local größe = 1` is accepted. `false`: only ASCII letters, digits and `_` (the Lua standard) are, and a Unicode name is reported by the `unicode-name` syntax check.
]]
config.runtime.nonstandardSymbol =
[[
Accept syntax that is not standard Lua.

Each entry switches one form on (`+=`, `continue`, `//` comments, `?.`, ...). Turn on only what your runtime or preprocessor really supports: the editor otherwise accepts code that fails at run time.
]]
config.runtime.nonstandardSymbol['?.'] =
"Safe navigation (field/method: `a?.b` / `obj?.:method()` / `obj:method?.()`)."
config.runtime.nonstandardSymbol['?.('] =
"Safe navigation call (`f?.()` / `f?.\"str\"` / `f?.{...}` / `f?.[[...]]`)."
config.runtime.nonstandardSymbol['?.['] =
"Safe navigation index (`t?.[key]`)."
config.runtime.nonstandardSymbol['?('] =
"No-dot optional call (`f?()` equals `f?.()`; conflicts with ternary (`ternary`) parsing, not recommended together)."
config.runtime.nonstandardSymbol['?['] =
"No-dot optional index (`t?[1]` equals `t?.[1]`; conflicts with ternary (`ternary`) parsing, not recommended together)."
config.runtime.nonstandardSymbol['??'] =
"Nil-coalescing (`a ?? b`; takes the right side only when the left side is nil)."
config.runtime.nonstandardSymbol['ternary'] =
"Ternary operator (`cond ? x : y`, right-associative; method calls forbidden in the `x` part)."
config.runtime.nonstandardSymbol['?:'] =
"No-dot safe method (`obj?:get()` equals `obj?.:get()`)."
config.runtime.nonstandardSymbol['~>>'] =
"Arithmetic right shift (`a ~>> b`, LuaJIT-specific; plain `>>` is logical)."
config.runtime.nonstandardSymbol['~>>='] =
"Arithmetic right shift compound assignment (`a ~>>= b`)."
config.runtime.nonstandardSymbol['..='] =
"String concatenation compound assignment (`a ..= b`)."
config.runtime.nonstandardSymbol['~='] =
"Bitwise-xor compound assignment: only in statement context (e.g. `a ~= b` on its own line); in expressions it remains the not-equal operator."
config.runtime.nonstandardSymbol['const'] =
"`const` declaration (block-scoped local constant, cannot be reassigned or redeclared)."
config.runtime.nonstandardSymbol['->'] =
"Short function arrow (`x -> expr` / `|x| -> expr` / `|| -> expr` / `-> do ... end`)."
config.runtime.nonstandardSymbol['number_underscore'] =
"Underscores in number literals (e.g. `1_000`, `0x1_2`, `0b1_0`)."
config.runtime.nonstandardSymbol['//'] =
"Line comment (C style)."
config.runtime.nonstandardSymbol['/**/'] =
"Block comment (C style)."
config.runtime.nonstandardSymbol['`'] =
"Backtick string literal."
config.runtime.nonstandardSymbol['+='] =
"Add compound assignment."
config.runtime.nonstandardSymbol['-='] =
"Subtract compound assignment."
config.runtime.nonstandardSymbol['*='] =
"Multiply compound assignment."
config.runtime.nonstandardSymbol['/='] =
"Divide compound assignment."
config.runtime.nonstandardSymbol['%='] =
"Modulo compound assignment."
config.runtime.nonstandardSymbol['^='] =
"Power compound assignment."
config.runtime.nonstandardSymbol['//='] =
"Floor-divide compound assignment."
config.runtime.nonstandardSymbol['|='] =
"Bitwise-or compound assignment."
config.runtime.nonstandardSymbol['&='] =
"Bitwise-and compound assignment."
config.runtime.nonstandardSymbol['<<='] =
"Left shift compound assignment."
config.runtime.nonstandardSymbol['>>='] =
"Right shift compound assignment."
config.runtime.nonstandardSymbol['||'] =
"Logical or (equivalent to `or`)."
config.runtime.nonstandardSymbol['&&'] =
"Logical and (equivalent to `and`)."
config.runtime.nonstandardSymbol['!'] =
"Logical not (equivalent to `not`)."
config.runtime.nonstandardSymbol['!='] =
"Not equal (equivalent to `~=`)."
config.runtime.nonstandardSymbol['continue'] =
"`continue` statement."
config.runtime.nonstandardSymbol['|lambda|'] =
"Pipe-parameter short function (`|x| expr`)."
config.runtime.enableLuaJITExtensions =
[[
Accept the LuaJIT syntax extensions (`0x1p4` hex floats, `1LL` and `1ULL` integer suffixes, the `ffi` literals).

Needs `Lua.runtime.version` to be `LuaJIT`. Each extension can also be switched on alone through `Lua.runtime.nonstandardSymbol`.
]]
config.runtime.plugin =
[[
A Lua file (or a list of them) that rewrites the text of every source file before it is parsed, and can help `require` find files.

A plugin runs arbitrary code, so the first load asks you to trust it. See `doc/en-us/plugin.md` and the [wiki](https://luals.github.io/wiki/plugins).
]]
config.runtime.pluginArgs =
[[
Extra arguments handed to the plugin of `Lua.runtime.plugin`.

Either a list (given to every plugin) or a table whose keys are a part of a plugin path and whose values are the arguments of that plugin.
]]
config.runtime.fileEncoding =
[[
The text encoding of the source files.

`utf8` is right for nearly every project. `utf16le` and `utf16be` are for files saved as UTF-16; `ansi` follows the system code page and exists on Windows only.
]]
config.runtime.builtin =
[[
Switch the built-in libraries on or off by name (`basic`, `string`, `table`, `math`, `os`, `io`, `debug`, `package`, `coroutine`, `utf8`, `bit`, `bit32`, `jit`, `ffi`).

* `default`: on or off according to `Lua.runtime.version`
* `enable`: always on
* `disable`: always off. Use it when a framework replaces the library with its own (the WoW client has no `io`, `os` or `debug`).

```json
"Lua.runtime.builtin": { "io": "disable", "os": "disable" }
```
]]
config.runtime.meta =
[[
The name of the folder the generated library files (the "meta" files for the built-in libraries) are written to.

`${version}`, `${language}` and `${encoding}` are replaced by the Lua version, the language of the server and `Lua.runtime.fileEncoding`.
]]
config.diagnostics.enable =
[[
Run the diagnostics at all.

`false` turns every check off, the syntax errors too; hover, completion and the rest keep working.
]]
config.diagnostics.disable =
[[
The diagnostics that are not reported, by code (the code is shown in brackets next to a problem).

```json
"Lua.diagnostics.disable": ["undefined-global", "lowercase-global"]
```

One finding can be silenced in the source with `---@diagnostic disable-next-line: code`.
]]
config.diagnostics.globals =
[[
Global variables that are known to exist, so that `undefined-global` does not report them.

Use it for the globals a host program or framework provides (`vim`, `love`, the WoW API). Better still, declare them in a library folder (`Lua.workspace.library`) with their types.
]]
config.diagnostics.globalsRegex =
[[
Known globals given as patterns.

Every global whose name matches one of these Lua patterns counts as defined, e.g. `^MyAddon` for all globals that start with `MyAddon`.
]]
config.diagnostics.severity =
[[
Change how serious a diagnostic is, by code: `Error`, `Warning`, `Information` or `Hint`.

A trailing `!` on the value makes it win over the group setting `Lua.diagnostics.groupSeverity`.

```json
"Lua.diagnostics.severity": { "unused-local": "Warning", "undefined-field!": "Error" }
```
]]
config.diagnostics.neededFileStatus =
[[
Which files a diagnostic runs on, by code.

* `Opened`: only the files that are open in the editor
* `Any`: every file of the workspace (slower, and fills the Problems panel)
* `None`: the diagnostic is off

A trailing `!` on the value makes it win over the group setting `Lua.diagnostics.groupFileStatus`.
]]
config.diagnostics.groupSeverity =
[[
Change the severity of a whole group of diagnostics (`ambiguity`, `await`, `codestyle`, `conventions`, `duplicate`, `global`, `luadoc`, `redefined`, `redundant`, `secret`, `strict`, `strong`, `type-check`, `unbalanced`, `unused`).

`Fallback` leaves each diagnostic to `Lua.diagnostics.severity`. A group value overrides the single settings, except the ones that end with `!`.
]]
config.diagnostics.groupFileStatus =
[[
Change the file status (`Opened`, `Any`, `None`) of a whole group of diagnostics.

* `Opened`: only the open files
* `Any`: every file of the workspace
* `None`: the group is off

`Fallback` leaves each diagnostic to `Lua.diagnostics.neededFileStatus`. A group value overrides the single settings, except the ones that end with `!`.
]]
config.diagnostics.workspaceEvent =
[[
When the diagnostics of the files that are not open are (re)run.

`OnSave` (after the file is saved), `OnChange` (while you type, heavier), or `None` (never; only open files are checked).
]]
config.diagnostics.workspaceEvent.OnChange =
"Trigger workspace diagnostics when the file is changed."
config.diagnostics.workspaceEvent.OnSave =
"Trigger workspace diagnostics when the file is saved."
config.diagnostics.workspaceEvent.None =
"Disable workspace diagnostics."
config.diagnostics.workspaceDelay =
[[
How long to wait, in milliseconds, after the trigger of `Lua.diagnostics.workspaceEvent` before the workspace diagnosis starts.

A longer delay avoids restarts while you keep editing.
]]
config.diagnostics.workspaceRate =
[[
How much of the CPU the workspace diagnosis may use, in percent.

A lower value keeps the machine responsive and makes the diagnosis of the other files slower. The file you are editing is always diagnosed at full speed.
]]
config.diagnostics.libraryFiles =
[[
Whether the files of `Lua.workspace.library` are diagnosed.

`Opened` diagnoses a library file only while it is open in the editor.
]]
config.diagnostics.libraryFiles.Enable   =
"Always diagnose these files."
config.diagnostics.libraryFiles.Opened   =
"Only when these files are opened will it be diagnosed."
config.diagnostics.libraryFiles.Disable  =
"These files are not diagnosed."
config.diagnostics.ignoredFiles =
[[
Whether the files that `Lua.workspace.ignoreDir` and `.gitignore` exclude are diagnosed.

`Opened` diagnoses an ignored file only while it is open in the editor.
]]
config.diagnostics.ignoredFiles.Enable   =
"Always diagnose these files."
config.diagnostics.ignoredFiles.Opened   =
"Only when these files are opened will it be diagnosed."
config.diagnostics.ignoredFiles.Disable  =
"These files are not diagnosed."
config.diagnostics.disableScheme  =
'Do not diagnose Lua files that use the following scheme.'
config.diagnostics.validScheme  =
'Enable diagnostics for Lua files that use the following scheme.'
config.diagnostics.unusedLocalExclude =
[[
Names that `unused-local` leaves alone, given as patterns.

`_*` skips every variable that starts with an underscore, the usual way to say "unused on purpose".
]]
config.diagnostics.assignReadonlyBuilders =
[[
Names of functions that may fill in a `readonly` field of the object they build.

Inside a function with one of these names, an assignment to a `readonly` field is not reported by `assign-readonly`. By default: `new`, `init`, `constructor`, `ctor`, `__init`, `create`.
]]
config.diagnostics.pluginsDir     =
[[
A folder of custom diagnostic plugins (`.lua` files).

Blank (the default) loads none. Each file registers one diagnostic with `proto.diagnostic.register`, under a name equal to its file name, and returns `function(uri, callback) ... end`, like a built-in diagnostic.

A plugin runs arbitrary Lua code, so the first load of a folder asks you to trust it.
]]
config.workspace.ignoreDir =
[[
Files and folders the server does not load, in `.gitignore` syntax.

```json
"Lua.workspace.ignoreDir": [".vscode", "Libs/", "**/*.min.lua"]
```
]]-- .. example.ignoreDir,
config.workspace.ignoreSubmodules =
[[
Do not load the files of git submodules.

`true` is right when a submodule is a library you only use; set it to `false` when the submodule holds code you work on.
]]
config.workspace.useGitIgnore =
[[
Do not load what the `.gitignore` of the workspace lists.

`false` loads those files too (generated code, build output).
]]
config.workspace.tocSavedVariables =
[[
Treat the variables a WoW addon's `.toc` file saves as defined globals.

The names of `## SavedVariables:`, `## SavedVariablesPerCharacter:` and `## SavedVariablesMachine:` are no longer reported by `undefined-global`, `lowercase-global` or `global-element`. The `.toc` is the one in the folder of the file, or in the nearest folder above it that has one.
]]
config.workspace.tocFileArguments =
[[
Type the two arguments every addon file receives at its top level.

```lua
local addonName, ns = ...
local ns = select(2, ...)
```

The first is the folder name of the addon (a string literal). The second is the class `<Folder>NS` (see `Lua.workspace.tocNamespaceClass`), which takes new keys like a class written with `---@class` on that line. A `---@class` or `---@type` of your own on or above the line replaces it.

Only for files that have a `.toc` in their folder or above it.
]]
config.workspace.tocNamespaceClass =
[[
The class name of the namespace argument of an addon file (see `Lua.workspace.tocFileArguments`).

`{addon}` becomes the folder name of the addon (letters, digits and underscores): `{addon}NS` (the default), `{addon}.ns`, `{addon}_ns`. Use the same name in your own `---@class`, so the two merge.
]]
config.workspace.maxPreload =
[[
The most files the server reads when it opens a workspace.

Files beyond the limit are loaded only when they are opened or required. Raise it for a very big project, lower it to open faster.
]]
config.workspace.preloadFileSize =
[[
The size, in KB, above which a file is not read when the workspace opens.

Big generated files (data tables, minified code) slow the server down and are better skipped; they load when you open them.
]]
config.workspace.library =
[[
Folders outside the workspace whose Lua files are read as libraries.

The code in them is known to completion, hover and the type checks, but is not changed by renaming and is not diagnosed (see `Lua.diagnostics.libraryFiles`). Use it for annotation packages such as the WoW API annotations, or for a framework's sources.

```json
"Lua.workspace.library": ["~/.vscode/extensions/ketho.wow-api-0.22.3/Annotations/Core"]
```
]]
config.workspace.dofileRoots =
[[
Extra folders that `dofile` and `loadfile` may resolve a relative path in, besides the workspace.

The files there are loaded at once.
]]
config.workspace.checkThirdParty =
[[
Offer to add the type definitions of a known third-party environment when the workspace uses it: OpenResty, Cocos4.0, LÖVE, LÖVR, skynet and Jass.

`Ask` asks once per workspace, `Apply` adds it without asking, `ApplyInMemory` adds it without writing a setting, `Disable` never offers.
]]
config.workspace.userThirdParty =
[[
Paths to your own third-party configuration files, in the format of the [built-in ones](https://github.com/LuaLS/lua-language-server/tree/master/meta/3rd).
]]
config.workspace.supportScheme           =
'Provide language server for the Lua files of the following scheme.'
config.completion.enable =
[[
Offer completion while you type.
]]
config.completion.callSnippet =
[[
Whether a completed function is inserted with its argument list.

`Disable` inserts the name only, `Both` offers the name and a snippet entry, `Replace` inserts the snippet `f(arg1, arg2)` with tab stops.
]]
config.completion.callSnippet.Disable    =
"Only shows `function name`."
config.completion.callSnippet.Both       =
"Shows `function name` and `call snippet`."
config.completion.callSnippet.Replace    =
"Only shows `call snippet.`"
config.completion.keywordSnippet =
[[
Whether a keyword such as `if` or `function` is offered with its whole block.

`Disable` offers the word only, `Both` the word and a snippet entry, `Replace` the snippet (`if ... then ... end`).
]]
config.completion.keywordSnippet.Disable =
"Only shows `keyword`."
config.completion.keywordSnippet.Both    =
"Shows `keyword` and `syntax snippet`."
config.completion.keywordSnippet.Replace =
"Only shows `syntax snippet`."
config.completion.displayContext =
[[
Show the lines of source around a suggestion in its documentation.

The number is how many lines to show; `0` turns the preview off.
]]
config.completion.workspaceWord =
[[
Let the word suggestions (see `Lua.completion.showWord`) include words from the other files of the workspace, not only the current file.
]]
config.completion.showWord =
[[
Suggest plain words found in the text when nothing better is known.

`Fallback` offers them only when the type information gives no suggestion, `Enable` always, `Disable` never.
]]
config.completion.showWord.Enable        =
"Always show context words in suggestions."
config.completion.showWord.Fallback      =
"Contextual words are only displayed when suggestions based on semantics cannot be provided."
config.completion.showWord.Disable       =
"Do not display context words."
config.completion.autoRequire =
[[
When you complete a name that is a file of the workspace, insert the matching `local x = require 'x'` at the top of the file.
]]
config.completion.maxSuggestCount =
[[
The most fields of one table the server examines for a completion.

A table with more fields than this offers nothing until you have typed more of the name. Raise it only if a big table (a generated API) is missing from the list.
]]
config.completion.showParams =
[[
Show the parameter list of a function in the completion list.

A function with several definitions (overloads) gets one entry for each.
]]
config.completion.requireSeparator =
[[
The character that separates the folders in an inserted `require` (`.` gives `require 'a.b'`, `/` gives `require 'a/b'`).
]]
config.completion.postfix =
[[
The character that starts a postfix suggestion: after `value@` you can pick a template such as `if value then ... end`.
]]
config.color.mode                        =
"Color mode."
config.color.mode.Semantic               =
"Semantic color. You may need to set `editor.semanticHighlighting.enabled` to `true` to take effect."
config.color.mode.SemanticEnhanced       =
"Enhanced semantic color. Like `Semantic`, but with additional analysis which might be more computationally expensive."
config.color.mode.Grammar                =
"Grammar color."
config.semantic.enable =
[[
Colour the code from what the server knows about it (a parameter, a global, a type) instead of from the grammar alone.

The editor must have `editor.semanticHighlighting.enabled` on.
]]
config.semantic.variable =
[[
Colour variables, fields and parameters by kind (local, global, parameter, field, ...).
]]
config.semantic.annotation =
[[
Colour the types and tags inside `---@` comments.
]]
config.semantic.keyword =
[[
Colour keywords, literals and operators from the server too.

Only needed when the editor has no grammar for Lua of its own.
]]
config.signatureHelp.enable =
[[
Show the parameter list and the current argument while you type a call.
]]
config.hover.enable =
[[
Show the information card when the mouse rests on a name.
]]
config.hover.viewString =
[[
Show the text of a string literal in the hover, when the source has escapes (`\n`, `\x41`) that make it hard to read.
]]
config.hover.viewStringMax =
[[
The most characters of a string the hover shows (see `Lua.hover.viewString`).
]]
config.hover.viewNumber =
[[
Show the decimal value of a number literal written in another base (`0xFF` shows 255).
]]
config.hover.fieldInfer =
[[
How many milliseconds the hover of a table may spend inferring the types of its fields.

When the time is used up the remaining fields are listed without a type.
]]
config.hover.previewFields =
[[
The most fields of a table the hover lists.
]]
config.hover.enumsLimit =
[[
The most members of a union or an enum the hover lists before it cuts the list with `...`.
]]
config.hover.expandAlias =
[[
Show what an alias stands for.

`true`: a value of `---@alias myType boolean|number` shows as `boolean|number`. `false`: it shows as `myType`.
]]
config.develop.enable =
[[
Developer mode of the server itself. Slows it down; leave it off.
]]
config.develop.debuggerPort =
[[
The port the debugger of the server listens on (developer mode).
]]
config.develop.debuggerWait =
[[
Wait for the debugger to connect before the server starts (developer mode).
]]
config.intelliSense.searchDepth =
[[
How far the type inference follows a value through assignments and calls.

A bigger number finds more types and costs time. Adjust it to the project.
]]
config.intelliSense.fastGlobal =
[[
Treat the globals of the workspace in a simpler, faster way when completing and when hovering over `_G`.

The inferred types become slightly less exact. Worth it in a project with very many globals.
]]
config.window.statusBar =
[[
Show the server status in the status bar of the editor.
]]
config.window.progressBar =
[[
Show a progress bar while the server loads and diagnoses the workspace.
]]
config.hint.enable =
[[
Show inlay hints: small grey texts the editor draws inside the code (parameter names, types, `await`, ...). The kinds are chosen by the other `Lua.hint.*` settings.
]]
config.hint.paramType =
[[
Show the type of each parameter at the function definition.
]]
config.hint.setType =
[[
Show the inferred type after the name of a variable in an assignment, as `x: number = 1`.
]]
config.hint.paramName =
[[
Show the name of the parameter in front of an argument in a call.

`All` for every argument, `Literal` only for literals and constants (where the meaning is not clear), `Disable` for none.
]]
config.hint.paramName.All                =
'All types of parameters are shown.'
config.hint.paramName.Literal            =
'Only literal type parameters are shown.'
config.hint.paramName.Disable            =
'Disable parameter hints.'
config.hint.arrayIndex =
[[
Show the index of each item in a table constructor (`{ [1] = "a", [2] = "b" }`).

`Auto` shows them in a mixed table or one with more than three items, `Enable` in every table, `Disable` never.
]]
config.hint.arrayIndex.Enable            =
'Show hints in all tables.'
config.hint.arrayIndex.Auto              =
'Show hints only when the table is greater than 3 items, or the table is a mixed table.'
config.hint.arrayIndex.Disable           =
'Disable hints of array index.'
config.hint.await =
[[
Show `await` in front of a call to a function marked `---@async`.
]]
config.hint.awaitPropagate =
[[
Treat a function that calls an `---@async` function as `---@async` itself, and show its `await` hints too.
]]
config.hint.semicolon =
[[
Show a grey semicolon at the end of a statement that has none.

`SameLine` only between two statements on one line, `All` after every statement, `Disable` never.
]]
config.hint.semicolon.All                =
'All statements display virtual semicolons.'
config.hint.semicolon.SameLine            =
'When two statements are on the same line, display a semicolon between them.'
config.hint.semicolon.Disable            =
'Disable virtual semicolons.'
config.codeLens.enable =
[[
Show the number of references above each definition; clicking it lists them.
]]
config.format.enable =
[[
Offer the code formatter (format document, format selection, format on type).
]]
config.format.defaultConfig =
[[
The default options of the formatter, as a table of name to value (`indent_style`, `indent_size`, `max_line_length`, ...).

A `.editorconfig` in the workspace wins over this. See the [formatter docs](https://github.com/CppCXY/EmmyLuaCodeStyle/tree/master/docs).
]]
config.spell.dict =
[[
Words the spell check (`spell-check` diagnostic) accepts.
]]
config.nameStyle.config =
[[
The naming rules the `name-style-check` diagnostic enforces (for example camelCase for locals, PascalCase for classes).

See the [formatter docs](https://github.com/CppCXY/EmmyLuaCodeStyle/tree/master/docs).
]]
config.telemetry.enable =
[[
(VS Code extension) Send usage data and error logs to the developers of the original LuaLS.

See the [privacy policy](https://luals.github.io/privacy/#language-server).
]]
config.misc.parameters =
[[
[Command line parameters](https://github.com/LuaLS/lua-telemetry-server/tree/master/method) the VS Code extension passes to the server when it starts it.
]]
config.misc.executablePath =
[[
The path of the language server executable the VS Code extension starts, when it should not use its own.
]]
config.language.fixIndent =
[[
(VS Code only) Repair the indentation the editor guesses wrong, for example after a line break inside a string that contains the word `function`.
]]
config.language.completeAnnotation =
[[
(VS Code only) Continue a `---@` comment on the next line: pressing Enter inserts `---@ ` at the start of it.
]]
config.type.castNumberToInteger =
[[
Let a `number` be assigned to an `integer`.

`true`: it fits, as in the original LuaLS, which suits code that computes with plain numbers. `false` (strict): a `number` does not fit an `integer`, because it may have a fraction. The other way round, `integer` to `number`, always works.
]]
config.type.weakUnionCheck =
[[
Take a union as fitting once one of its members fits.

`false` (strict): `number|boolean` cannot be assigned to `number`, all members must fit. `true`: it can.
]]
config.type.weakNilCheck =
[[
Ignore the `nil` of a union when checking.

`false` (strict): `number|nil` cannot be assigned to `number`. `true`: it can, as if the `nil` were not there.
]]
config.type.checkFieldNilArguments       =
[[
Check the `nil` of a field that is passed as an argument.

`true` (the default): the field is checked like a variable, and narrowed like one: `if obj.field then f(obj.field) end` and `f(obj.field or {})` are fine.

`false` (the original LuaLS): `nil` is taken out of `f(obj.field)` before it is checked, so a `table?` field can be passed for a `table` parameter. The original could not narrow fields.

The `nil` of a field is checked even under `Lua.type.weakUnionCheck` (which takes a union as fitting when one member does), unless `Lua.type.weakNilCheck` ignores `nil`.
]]
config.type.inferParamType =
[[
Infer the type of a parameter that has no annotation from the arguments the function is called with.

`false`: such a parameter is `any`. `true`: it takes the types of the calls, which finds more but can produce surprising errors in a function with many callers.
]]
config.type.checkTableShape =
[[
Require a table value to have the fields of the class it is assigned to: a missing field is a type mismatch.

Off by default, because a table built in steps (`setmetatable({}, Meta)`, a mixin) is reported while it is still incomplete.
]]
config.annotations.dialects             =
[[
The annotation dialects the project is written for.

`legacyluals` (the original LuaLS), `luals` (this fork), `wowluals` (wowlua-ls), or `mixed` (all three, the default).

A `---@tag` that none of the listed dialects knows is reported as a hint (`non-portable-annotation`) instead of being ignored in silence. Parsing does not change: every spelling is always read.
]]
config.diagnostics.enableScheme =
'The URI schemes of the files that are diagnosed (`file` for files on disk). A file with another scheme (an untitled buffer, a virtual file system) gets no diagnostics.'
config.type.maxUnionVariants =
[[
How many variants of a union type `Lua.type.weakUnionCheck` compares before it stops.

`0` (the default) compares all of them. A limit trades precision for speed on very large unions.
]]
config.annotations.dialects.legacyluals =
'The original LuaLS (3.19.1, the base of this fork). A tag, keyword or type syntax it does not read is reported.'
config.annotations.dialects.luals       =
'This fork: the original plus what it added (secret values, `readonly`, `keyof`, utility types, `---@diagnostic expect-line`, ...).'
config.annotations.dialects.wowluals    =
'wowlua-ls: its own tags and the shared ones; a tag only the original or this fork reads is reported.'
config.annotations.dialects.mixed       =
'All three dialects: nothing is reported (the default).'
config.type.inferTableSize =
[[
The most fields of a table constructor the server looks at when it infers the type of the table.

A low value keeps the inference of big data tables cheap.
]]
config.doc.privateName =
[[
Treat the fields whose names match as `private`: they can be used only inside the class that declares them.

`m_*` makes `XXX.m_id` and `XXX.m_type` private.
]]
config.doc.protectedName =
[[
Treat the fields whose names match as `protected`: they can be used only inside the class that declares them and its subclasses.

`m_*` makes `XXX.m_id` and `XXX.m_type` protected.
]]
config.doc.packageName =
[[
Treat the fields whose names match as `package`: they can be used only inside the file that declares them.

`m_*` makes `XXX.m_id` and `XXX.m_type` package.
]]
config.doc.regengine =
[[
The pattern syntax of the names in `Lua.doc.privateName`, `Lua.doc.protectedName` and `Lua.doc.packageName`.
]]
config.doc.regengine.glob                =
'The default lightweight pattern syntax.'
config.doc.regengine.lua                 =
'Full Lua-style regular expressions.'
config.docScriptPath                     =
'The regular expression engine used for matching documentation scope names.'
config.diagnostics['cast-local-type']    =
'Enable diagnostics for casts of local variables where the target type does not match the defined type.'
config.diagnostics['circular-doc-class']    =
'Enable diagnostics for two classes inheriting from each other introducing a circular relation.'
config.diagnostics['action-after-return'] =
'Code after a `return` statement'
config.diagnostics['ambiguous-syntax'] =
'Ambiguous syntax'
config.diagnostics['args-after-dots'] =
'Arguments after `...`'
config.diagnostics['assign-const-global'] =
'Assigning to a const global variable'
config.diagnostics['block-after-else'] =
'Block after `else`'
config.diagnostics['break-outside'] =
'Using `break` outside a loop'
config.diagnostics['circle-doc-class'] =
'Circular `@class` inheritance'
config.diagnostics['declare-const'] =
'Redeclaring a const constant'
config.diagnostics['env-is-global'] =
'`_ENV` used as a global variable'
config.diagnostics['exp-in-action'] =
'Expression used in statement position'
config.diagnostics['global-close-attribute'] =
'Close attribute on a global variable'
config.diagnostics['index-in-func-name'] =
'Index in a function name'
config.diagnostics['jump-local-scope'] =
'Jumping into a local variable scope'
config.diagnostics['keyword'] =
'Improper use of a keyword'
config.diagnostics['local-limit'] =
'Too many local variables'
config.diagnostics['lua-doc-miss-sign'] =
'LuaDoc comment missing a sign'
config.diagnostics['malformed-number'] =
'Malformed number literal'
config.diagnostics['multi-close'] =
'Multiple close operations'
config.diagnostics['need-paren'] =
'Parentheses required'
config.diagnostics['nesting-long-mark'] =
'Nested long comment markers'
config.diagnostics['no-visible-label'] =
'Invisible label'
config.diagnostics['redefined-label'] =
'Redefined label'
config.diagnostics['set-const'] =
'Assigning to a const constant'
config.diagnostics['unicode-name'] =
'Unicode name'
config.diagnostics['unknown-attribute'] =
'Unknown attribute'
config.diagnostics['unknown-symbol'] =
'Unknown symbol'
config.diagnostics['unsupport-named-vararg'] =
'Unsupported named vararg'
config.diagnostics['variable-not-declared'] =
'Using an undeclared variable'
config.typeFormat.config                    =
'Configures the formatting behavior while typing Lua code.'
config.typeFormat.config.auto_complete_end  =
'Controls if `end` is automatically completed at suitable positions.'
config.typeFormat.config.auto_complete_table_sep =
'Controls if a separator is automatically appended at the end of a table declaration.'
config.typeFormat.config.format_line        =
'Controls if a line is formatted at all.'

command.exportDocument =
'Lua: Export Document ...'
command.addon_manager.open =
'Lua: Open Addon Manager ...'
command.reloadFFIMeta =
'Lua: Reload luajit ffi meta'
command.startServer =
'Lua: Restart Language Server'
command.stopServer =
'Lua: Stop Language Server'
