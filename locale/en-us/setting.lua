---@diagnostic disable: undefined-global

config.addonManager.enable        =
"Whether the addon manager is enabled or not."
config.addonManager.repositoryBranch =
"Specifies the git branch used by the addon manager."
config.addonManager.repositoryPath =
"Specifies the git path used by the addon manager."
config.addonRepositoryPath        =
"Specifies the addon repository path (not related to the addon manager)."
config.runtime.version            =
"Lua runtime version."
config.runtime.path               =
[[
When using `require`, how to find the file based on the input name.
Setting this config to `?/init.lua` means that when you enter `require 'myfile'`, `${workspace}/myfile/init.lua` will be searched from the loaded files.
if `runtime.pathStrict` is `false`, `${workspace}/**/myfile/init.lua` will also be searched.
If you want to load files outside the workspace, you need to set `Lua.workspace.library` first.
]]
config.runtime.pathStrict         =
'When enabled, `runtime.path` will only search the first level of directories, see the description of `runtime.path`.'
config.runtime.special            =
[[The custom global variables are regarded as some special built-in variables, and the language server will provide special support
The following example shows that 'include' is treated as' require '.
```json
"Lua.runtime.special" : {
    "include" : "require"
}
```
]]
config.runtime.unicodeName        =
"Allows Unicode characters in name."
config.runtime.nonstandardSymbol  =
"Supports non-standard symbols. Make sure that your runtime environment supports these symbols."
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
Enable LuaJIT extension syntax (requires `Lua.runtime.version` to be set to `LuaJIT`).
Each extension can also be enabled individually via `Lua.runtime.nonstandardSymbol`.
]]
config.runtime.plugin             =
"Plugin path. Please read [wiki](https://luals.github.io/wiki/plugins) to learn more."
config.runtime.pluginArgs         =
"Additional arguments for the plugin."
config.runtime.fileEncoding       =
"File encoding. The `ansi` option is only available under the `Windows` platform."
config.runtime.builtin            =
[[
Adjust the enabled state of the built-in library. You can disable (or redefine) the non-existent library according to the actual runtime environment.

* `default`: Indicates that the library will be enabled or disabled according to the runtime version
* `enable`: always enable
* `disable`: always disable
]]
config.runtime.meta               =
'Format of the directory name of the meta files.'
config.diagnostics.enable         =
"Enable diagnostics."
config.diagnostics.disable        =
"Disabled diagnostic (Use code in hover brackets)."
config.diagnostics.globals        =
"Defined global variables."
config.diagnostics.globalsRegex   =
"Find defined global variables using regex."
config.diagnostics.severity       =
[[
Modify the diagnostic severity.

End with `!` means override the group setting `diagnostics.groupSeverity`.
]]
config.diagnostics.neededFileStatus =
[[
* Opened:  only diagnose opened files
* Any:     diagnose all files
* None:    disable this diagnostic

End with `!` means override the group setting `diagnostics.groupFileStatus`.
]]
config.diagnostics.groupSeverity  =
[[
Modify the diagnostic severity in a group.
`Fallback` means that diagnostics in this group are controlled by `diagnostics.severity` separately.
Other settings will override individual settings without end of `!`.
]]
config.diagnostics.groupFileStatus =
[[
Modify the diagnostic needed file status in a group.

* Opened:  only diagnose opened files
* Any:     diagnose all files
* None:    disable this diagnostic

`Fallback` means that diagnostics in this group are controlled by `diagnostics.neededFileStatus` separately.
Other settings will override individual settings without end of `!`.
]]
config.diagnostics.workspaceEvent =
"Set the time to trigger workspace diagnostics."
config.diagnostics.workspaceEvent.OnChange =
"Trigger workspace diagnostics when the file is changed."
config.diagnostics.workspaceEvent.OnSave =
"Trigger workspace diagnostics when the file is saved."
config.diagnostics.workspaceEvent.None =
"Disable workspace diagnostics."
config.diagnostics.workspaceDelay =
"Latency (milliseconds) for workspace diagnostics."
config.diagnostics.workspaceRate  =
"Workspace diagnostics run rate (%). Decreasing this value reduces CPU usage, but also reduces the speed of workspace diagnostics. The diagnosis of the file you are currently editing is always done at full speed and is not affected by this setting."
config.diagnostics.libraryFiles   =
"How to diagnose files loaded via `Lua.workspace.library`."
config.diagnostics.libraryFiles.Enable   =
"Always diagnose these files."
config.diagnostics.libraryFiles.Opened   =
"Only when these files are opened will it be diagnosed."
config.diagnostics.libraryFiles.Disable  =
"These files are not diagnosed."
config.diagnostics.ignoredFiles   =
"How to diagnose ignored files."
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
'Do not diagnose `unused-local` when the variable name matches the following pattern.'
config.workspace.ignoreDir        =
"Ignored files and directories (Use `.gitignore` grammar)."-- .. example.ignoreDir,
config.workspace.ignoreSubmodules =
"Ignore submodules."
config.workspace.useGitIgnore     =
"Ignore files list in `.gitignore` ."
config.workspace.maxPreload       =
"Max preloaded files."
config.workspace.preloadFileSize  =
"Skip files larger than this value (KB) when preloading."
config.workspace.library          =
"In addition to the current workspace, which directories will load files from. The files in these directories will be treated as externally provided code libraries, and some features (such as renaming fields) will not modify these files."
config.workspace.dofileRoots      =
"In addition to the current workspace, which directories `dofile` will treat as a possible root. The files in these directories will be loaded immediately."
config.workspace.checkThirdParty  =
[[
Automatic detection and adaptation of third-party libraries, currently supported libraries are:

* OpenResty
* Cocos4.0
* LÖVE
* LÖVR
* skynet
* Jass
]]
config.workspace.userThirdParty          =
'Add private third-party library configuration file paths here, please refer to the built-in [configuration file path](https://github.com/LuaLS/lua-language-server/tree/master/meta/3rd)'
config.workspace.supportScheme           =
'Provide language server for the Lua files of the following scheme.'
config.completion.enable                 =
'Enable completion.'
config.completion.callSnippet            =
'Shows function call snippets.'
config.completion.callSnippet.Disable    =
"Only shows `function name`."
config.completion.callSnippet.Both       =
"Shows `function name` and `call snippet`."
config.completion.callSnippet.Replace    =
"Only shows `call snippet.`"
config.completion.keywordSnippet         =
'Shows keyword syntax snippets.'
config.completion.keywordSnippet.Disable =
"Only shows `keyword`."
config.completion.keywordSnippet.Both    =
"Shows `keyword` and `syntax snippet`."
config.completion.keywordSnippet.Replace =
"Only shows `syntax snippet`."
config.completion.displayContext         =
"Previewing the relevant code snippet of the suggestion may help you understand the usage of the suggestion. The number set indicates the number of intercepted lines in the code fragment. If it is set to `0`, this feature can be disabled."
config.completion.workspaceWord          =
"Whether the displayed context word contains the content of other files in the workspace."
config.completion.showWord               =
"Show contextual words in suggestions."
config.completion.showWord.Enable        =
"Always show context words in suggestions."
config.completion.showWord.Fallback      =
"Contextual words are only displayed when suggestions based on semantics cannot be provided."
config.completion.showWord.Disable       =
"Do not display context words."
config.completion.autoRequire            =
"When the input looks like a file name, automatically `require` this file."
config.completion.maxSuggestCount        =
"Maximum number of fields to analyze for completions. When an object has more fields than this limit, completions will require more specific input to appear."
config.completion.showParams             =
"Display parameters in completion list. When the function has multiple definitions, they will be displayed separately."
config.completion.requireSeparator       =
"The separator used when `require`."
config.completion.postfix                =
"The symbol used to trigger the postfix suggestion."
config.color.mode                        =
"Color mode."
config.color.mode.Semantic               =
"Semantic color. You may need to set `editor.semanticHighlighting.enabled` to `true` to take effect."
config.color.mode.SemanticEnhanced       =
"Enhanced semantic color. Like `Semantic`, but with additional analysis which might be more computationally expensive."
config.color.mode.Grammar                =
"Grammar color."
config.semantic.enable                   =
"Enable semantic color. You may need to set `editor.semanticHighlighting.enabled` to `true` to take effect."
config.semantic.variable                 =
"Semantic coloring of variables/fields/parameters."
config.semantic.annotation               =
"Semantic coloring of type annotations."
config.semantic.keyword                  =
"Semantic coloring of keywords/literals/operators. You only need to enable this feature if your editor cannot do syntax coloring."
config.signatureHelp.enable              =
"Enable signature help."
config.hover.enable                      =
"Enable hover."
config.hover.viewString                  =
"Hover to view the contents of a string (only if the literal contains an escape character)."
config.hover.viewStringMax               =
"The maximum length of a hover to view the contents of a string."
config.hover.viewNumber                  =
"Hover to view numeric content (only if literal is not decimal)."
config.hover.fieldInfer                  =
"When hovering to view a table, type infer will be performed for each field. When the accumulated time of type infer reaches the set value (MS), the type infer of subsequent fields will be skipped."
config.hover.previewFields               =
"When hovering to view a table, limits the maximum number of previews for fields."
config.hover.enumsLimit                  =
"When the value corresponds to multiple types, limit the number of types displaying."
config.hover.expandAlias                 =
[[
Whether to expand the alias. For example, expands `---@alias myType boolean|number` appears as `boolean|number`, otherwise it appears as `myType'.
]]
config.develop.enable                    =
'Developer mode. Do not enable, performance will be affected.'
config.develop.debuggerPort              =
'Listen port of debugger.'
config.develop.debuggerWait              =
'Suspend before debugger connects.'
config.intelliSense.searchDepth          =
'Set the search depth for IntelliSense. Increasing this value increases accuracy, but decreases performance. Different workspace have different tolerance for this setting. Please adjust it to the appropriate value.'
config.intelliSense.fastGlobal           =
'In the global variable completion, and view `_G` suspension prompt. This will slightly reduce the accuracy of type speculation, but it will have a significant performance improvement for projects that use a lot of global variables.'
config.window.statusBar                  =
'Show extension status in status bar.'
config.window.progressBar                =
'Show progress bar in status bar.'
config.hint.enable                       =
'Enable inlay hint.'
config.hint.paramType                    =
'Show type hints at the parameter of the function.'
config.hint.setType                      =
'Show hints of type at assignment operation.'
config.hint.paramName                    =
'Show hints of parameter name at the function call.'
config.hint.paramName.All                =
'All types of parameters are shown.'
config.hint.paramName.Literal            =
'Only literal type parameters are shown.'
config.hint.paramName.Disable            =
'Disable parameter hints.'
config.hint.arrayIndex                   =
'Show hints of array index when constructing a table.'
config.hint.arrayIndex.Enable            =
'Show hints in all tables.'
config.hint.arrayIndex.Auto              =
'Show hints only when the table is greater than 3 items, or the table is a mixed table.'
config.hint.arrayIndex.Disable           =
'Disable hints of array index.'
config.hint.await                        =
'If the called function is marked `---@async`, prompt `await` at the call.'
config.hint.awaitPropagate               =
'Enable the propagation of `await`. When a function calls a function marked `---@async`,\z
it will be automatically marked as `---@async`.'
config.hint.semicolon                    =
'If there is no semicolon at the end of the statement, display a virtual semicolon.'
config.hint.semicolon.All                =
'All statements display virtual semicolons.'
config.hint.semicolon.SameLine            =
'When two statements are on the same line, display a semicolon between them.'
config.hint.semicolon.Disable            =
'Disable virtual semicolons.'
config.codeLens.enable                   =
'Enable code lens.'
config.format.enable                     =
'Enable code formatter.'
config.format.defaultConfig              =
[[
The default format configuration. Has a lower priority than `.editorconfig` file in the workspace.
Read [formatter docs](https://github.com/CppCXY/EmmyLuaCodeStyle/tree/master/docs) to learn usage.
]]
config.spell.dict                        =
'Custom words for spell checking.'
config.nameStyle.config                  =
[[
Set name style config.
Read [formatter docs](https://github.com/CppCXY/EmmyLuaCodeStyle/tree/master/docs) to learn usage.
]]
config.telemetry.enable                  =
[[
Enable telemetry to send your editor information and error logs over the network. Read our privacy policy [here](https://luals.github.io/privacy/#language-server).
]]
config.misc.parameters                   =
'[Command line parameters](https://github.com/LuaLS/lua-telemetry-server/tree/master/method) when starting the language server in VSCode.'
config.misc.executablePath               =
'Specify the executable path in VSCode.'
config.language.fixIndent                =
'(VSCode only) Fix incorrect auto-indentation, such as incorrect indentation when line breaks occur within a string containing the word "function".'
config.language.completeAnnotation       =
'(VSCode only) Automatically insert "---@ " after a line break following a annotation.'
config.type.castNumberToInteger          =
'Allowed to assign the `number` type to the `integer` type.'
config.type.weakUnionCheck               =
[[
Once one subtype of a union type meets the condition, the union type also meets the condition.

When this setting is `false`, the `number|boolean` type cannot be assigned to the `number` type. It can be with `true`.
]]
config.type.weakNilCheck                 =
[[
When checking the type of union type, ignore the `nil` in it.

When this setting is `false`, the `number|nil` type cannot be assigned to the `number` type. It can be with `true`.
]]
config.type.inferParamType               =
[[
When a parameter type is not annotated, it is inferred from the function's call sites.

When this setting is `false`, the type of the parameter is `any` when it is not annotated.
]]
config.type.checkTableShape              =
[[
Strictly check the shape of the table.
]]
config.type.inferTableSize               =
'Maximum number of table fields analyzed during type inference.'
config.doc.privateName                   =
'Treat specific field names as private, e.g. `m_*` means `XXX.m_id` and `XXX.m_type` are private, witch can only be accessed in the class where the definition is located.'
config.doc.protectedName                 =
'Treat specific field names as protected, e.g. `m_*` means `XXX.m_id` and `XXX.m_type` are protected, witch can only be accessed in the class where the definition is located and its subclasses.'
config.doc.packageName                   =
'Treat specific field names as package, e.g. `m_*` means `XXX.m_id` and `XXX.m_type` are package, witch can only be accessed in the file where the definition is located.'
config.doc.regengine                     =
'The regular expression engine used for matching documentation scope names.'
config.doc.regengine.glob                =
'The default lightweight pattern syntax.'
config.doc.regengine.lua                 =
'Full Lua-style regular expressions.'
config.docScriptPath                     =
'The regular expression engine used for matching documentation scope names.'
config.diagnostics['unused-label']          =
'Enable unused label diagnostics.'
config.diagnostics['redundant-value']       =
'Enable the redundant values assigned diagnostics. It\'s raised during assignment operation, when the number of values is higher than the number of objects being assigned.'
config.diagnostics['await-in-sync']         =
'Enable diagnostics for calls of asynchronous functions within a synchronous function.'
config.diagnostics['cast-local-type']    =
'Enable diagnostics for casts of local variables where the target type does not match the defined type.'
config.diagnostics['circular-doc-class']    =
'Enable diagnostics for two classes inheriting from each other introducing a circular relation.'
config.diagnostics['discard-returns']       =
'Enable diagnostics for calls of functions annotated with `---@nodiscard` where the return values are ignored.'
config.diagnostics['missing-parameter']     =
'Enable diagnostics for function calls where the number of arguments is less than the number of annotated function parameters.'
config.diagnostics['unnecessary-assert']    =
'Enable diagnostics for redundant assertions on truthy values.'
config.diagnostics['redundant-return']      =
'Enable diagnostics for return statements which are not needed because the function would exit on its own.'
config.diagnostics['spell-check']           =
'Enable diagnostics for typos in strings.'
config.diagnostics['name-style-check']      =
'Enable diagnostics for name style.'
config.diagnostics['undefined-doc-param']   =
'Enable diagnostics for cases in which a parameter annotation is given without declaring the parameter in the function definition.'
config.diagnostics['undefined-field']       =
'Enable diagnostics for cases in which an undefined field of a variable is read.'
config.diagnostics['unknown-cast-variable'] =
'Enable diagnostics for casts of undefined variables.'
config.diagnostics['unknown-diag-code']     =
'Enable diagnostics in cases in which an unknown diagnostics code is entered.'
config.diagnostics['unknown-operator']      =
'Enable diagnostics for unknown operators.'
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
