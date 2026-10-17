# addonManager.enable

Whether the addon manager is enabled or not.

## type

```ts
boolean
```

## default

```jsonc
true
```

# addonManager.repositoryBranch

Specifies the git branch used by the addon manager.

## type

```ts
string
```

## default

```jsonc
""
```

# addonManager.repositoryPath

Specifies the git path used by the addon manager.

## type

```ts
string
```

## default

```jsonc
""
```

# addonRepositoryPath

Specifies the addon repository path (not related to the addon manager).

## type

```ts
string
```

## default

```jsonc
""
```

# annotations.dialects

The annotation dialects the project is written for.

`legacyluals` (the original LuaLS), `luals` (this fork), `wowluals` (wowlua-ls), or `mixed` (all three, the default).

A `---@tag` that none of the listed dialects knows is reported as a hint (`non-portable-annotation`) instead of being ignored in silence. Parsing does not change: every spelling is always read.


## type

```ts
Array<string>
```

## enum

* ``"legacyluals"``: The original LuaLS (3.19.1, the base of this fork). A tag, keyword or type syntax it does not read is reported.
* ``"luals"``: This fork: the original plus what it added (secret values, `readonly`, `keyof`, utility types, `---@diagnostic expect-line`, ...).
* ``"wowluals"``: wowlua-ls: its own tags and the shared ones; a tag only the original or this fork reads is reported.
* ``"mixed"``: All three dialects: nothing is reported (the default).

## default

```jsonc
["mixed"]
```

# codeLens.enable

Show the number of references above each definition; clicking it lists them.


## type

```ts
boolean
```

## default

```jsonc
false
```

# completion.autoRequire

When you complete a name that is a file of the workspace, insert the matching `local x = require 'x'` at the top of the file.


## type

```ts
boolean
```

## default

```jsonc
true
```

# completion.callSnippet

Whether a completed function is inserted with its argument list.

`Disable` inserts the name only, `Both` offers the name and a snippet entry, `Replace` inserts the snippet `f(arg1, arg2)` with tab stops.


## type

```ts
string
```

## enum

* ``"Disable"``: Only shows `function name`.
* ``"Both"``: Shows `function name` and `call snippet`.
* ``"Replace"``: Only shows `call snippet.`

## default

```jsonc
"Disable"
```

# completion.displayContext

Show the lines of source around a suggestion in its documentation.

The number is how many lines to show; `0` turns the preview off.


## type

```ts
integer
```

## default

```jsonc
0
```

# completion.enable

Offer completion while you type.


## type

```ts
boolean
```

## default

```jsonc
true
```

# completion.keywordSnippet

Whether a keyword such as `if` or `function` is offered with its whole block.

`Disable` offers the word only, `Both` the word and a snippet entry, `Replace` the snippet (`if ... then ... end`).


## type

```ts
string
```

## enum

* ``"Disable"``: Only shows `keyword`.
* ``"Both"``: Shows `keyword` and `syntax snippet`.
* ``"Replace"``: Only shows `syntax snippet`.

## default

```jsonc
"Replace"
```

# completion.maxSuggestCount

The most fields of one table the server examines for a completion.

A table with more fields than this offers nothing until you have typed more of the name. Raise it only if a big table (a generated API) is missing from the list.


## type

```ts
integer
```

## default

```jsonc
100
```

# completion.postfix

The character that starts a postfix suggestion: after `value@` you can pick a template such as `if value then ... end`.


## type

```ts
string
```

## default

```jsonc
"@"
```

# completion.requireSeparator

The character that separates the folders in an inserted `require` (`.` gives `require 'a.b'`, `/` gives `require 'a/b'`).


## type

```ts
string
```

## default

```jsonc
"."
```

# completion.showParams

Show the parameter list of a function in the completion list.

A function with several definitions (overloads) gets one entry for each.


## type

```ts
boolean
```

## default

```jsonc
true
```

# completion.showWord

Suggest plain words found in the text when nothing better is known.

`Fallback` offers them only when the type information gives no suggestion, `Enable` always, `Disable` never.


## type

```ts
string
```

## enum

* ``"Enable"``: Always show context words in suggestions.
* ``"Fallback"``: Contextual words are only displayed when suggestions based on semantics cannot be provided.
* ``"Disable"``: Do not display context words.

## default

```jsonc
"Fallback"
```

# completion.workspaceWord

Let the word suggestions (see `Lua.completion.showWord`) include words from the other files of the workspace, not only the current file.


## type

```ts
boolean
```

## default

```jsonc
true
```

# diagnostics.assignReadonlyBuilders

Names of functions that may fill in a `readonly` field of the object they build.

Inside a function with one of these names, an assignment to a `readonly` field is not reported by `assign-readonly`. By default: `new`, `init`, `constructor`, `ctor`, `__init`, `create`.


## type

```ts
Array<string>
```

## default

```jsonc
["new","init","constructor","ctor","__init","create"]
```

# diagnostics.disable

The diagnostics that are not reported, by code (the code is shown in brackets next to a problem).

```json
"Lua.diagnostics.disable": ["undefined-global", "lowercase-global"]
```

One finding can be silenced in the source with `---@diagnostic disable-next-line: code`.


## type

```ts
Array<string>
```

## enum

* ``"access-private"``
* ``"access-protected"``
* ``"action-after-return"``: Code after a `return` statement
* ``"ambiguity-1"``: Enable ambiguous operator precedence diagnostics. For example, the `num or 0 + 1` expression will be suggested `(num or 0) + 1` instead.
* ``"ambiguous-syntax"``: Ambiguous syntax
* ``"args-after-dots"``: Arguments after `...`
* ``"assign-const-global"``: Assigning to a const global variable
* ``"assign-readonly"``: Enable diagnostics for assigning a field that is declared `readonly` (`---@field readonly name string`) outside the code that builds the object.
* ``"assign-type-mismatch"``: Enable diagnostics for assignments in which the value's type does not match the type of the assigned variable.
* ``"await-in-sync"``: Enable diagnostics for calls of asynchronous functions within a synchronous function.
* ``"block-after-else"``: Block after `else`
* ``"break-outside"``: Using `break` outside a loop
* ``"cannot-call"``: Enable diagnostics for calling a local variable or a literal whose every known type is one that cannot be called (a number, a string, a boolean). Anything that could be callable (a function, a table, a class, `any`, an unknown value, a union with one of those) is left alone, and so are field and method accesses, whose type is not certain; a value that may be `nil` is `need-check-nil`.
* ``"cast-local-type"``: Enable diagnostics for casts of local variables where the target type does not match the defined type.
* ``"cast-type-mismatch"``: Enable diagnostics for casts where the target type does not match the initial type.
* ``"circle-doc-class"``: Circular `@class` inheritance
* ``"close-non-object"``: Enable diagnostics for attempts to close a variable with a non-object.
* ``"code-after-break"``: Enable diagnostics for code placed after a break statement in a loop.
* ``"codestyle-check"``: Enable diagnostics for incorrectly styled lines.
* ``"count-down-loop"``: Enable diagnostics for `for` loops which will never reach their max/limit because the loop is incrementing instead of decrementing.
* ``"declare-const"``: Redeclaring a const constant
* ``"deprecated"``: Enable diagnostics to highlight deprecated API.
* ``"different-requires"``: Enable diagnostics for files which are required by two different paths.
* ``"discard-returns"``: Enable diagnostics for calls of functions annotated with `---@nodiscard` where the return values are ignored.
* ``"doc-field-no-class"``: Enable diagnostics to highlight a field annotation without a defining class annotation.
* ``"duplicate-doc-alias"``: Enable diagnostics for a duplicated alias annotation name.
* ``"duplicate-doc-field"``: Enable diagnostics for a duplicated field annotation name.
* ``"duplicate-doc-param"``: Enable diagnostics for a duplicated param annotation name.
* ``"duplicate-index"``: Enable duplicate table index diagnostics.
* ``"duplicate-set-field"``: Enable diagnostics for setting the same field in a class more than once.
* ``"empty-block"``: Enable empty code block diagnostics.
* ``"env-is-global"``: `_ENV` used as a global variable
* ``"err-assign-as-eq"``
* ``"err-c-long-comment"``
* ``"err-comment-prefix"``
* ``"err-do-as-then"``
* ``"err-eq-as-assign"``
* ``"err-esc"``
* ``"err-nonstandard-symbol"``
* ``"err-then-as-do"``
* ``"excess-field"``: A table constructor given to a class has a field the class does not declare (the excess property check of TypeScript).
* ``"exp-in-action"``: Expression used in statement position
* ``"generic-constraint-mismatch"``: Enable diagnostics for the type arguments of a class or an alias that do not satisfy the constraint of their type parameter (`Widget<number>` where `---@class Widget<T: Frame>`), and for calls of a generic function where an argument does not fit a `keyof` of another argument: the type bound to a type parameter does not satisfy a constraint that names another type parameter (`---@generic K: keyof T`), or the argument of a parameter typed `keyof T` (`---@param key keyof T`, `---@param ... keyof T`: every extra argument) is not a key of `T`. A constraint on its own (`---@generic T: Base`) is already reported by `param-type-mismatch`. The wowlua-ls diagnostic of the same name.
* ``"generic-param-mismatch"``: Enable diagnostics for calls of a generic function where two arguments bound to the same type parameter (`---@param a T`, `---@param b T`) have types that do not fit together: the first argument binds `T`, a later one has to be assignable to it (or be wider, which widens `T`).
* ``"global-close-attribute"``: Close attribute on a global variable
* ``"global-element"``: Enable diagnostics to warn about global elements.
* ``"global-in-nil-env"``: Enable cannot use global variables （ `_ENV` is set to `nil`） diagnostics.
* ``"grouped-return-mismatch"``: Enable diagnostics for return values that each fit their own slot but together match none of the cases of a tuple-union return annotation (`---@return (A, B) | (C, D)`).
* ``"implicit-nil-return"``: Enable diagnostics for a bare `return` in a function whose first `@return` is optional (`T?`): write `return nil` to say it on purpose.
* ``"incompatible-override"``: Enable diagnostics for a class that overrides a member of a class it inherits from with something that does not fit it (TypeScript's "class incorrectly extends"): a method that needs more arguments, takes or gives other types, or a field redeclared with a type that is not assignable to the parent's. A narrower type is an override; a wider or unrelated one is a collision. Only parents the user owns are judged: a member declared in a library outside the workspace (third-party annotations, which a polyfill class may re-annotate on purpose) is left alone.
* ``"incomplete-signature-doc"``: Incomplete @param or @return annotations for functions.
* ``"index-in-func-name"``: Index in a function name
* ``"inject-field"``: Injecting a field into an object
* ``"invalid-class-parent"``: Enable diagnostics for a `---@class Child : Parent` whose parent is a primitive type (`string`, `number`, `integer`, `boolean`, `true`, `false`, `nil`, `function`, `thread`): a class describes a table. `table`, `userdata` and `any` stay allowed. Off by default: `---@class Name : string` is also used on purpose, as a named string type.
* ``"invalid-guard"``: Enable diagnostics for a `---@guard x is T` / `---@asserts x is T` that is not of that form, or names something that is not a parameter of the function it is bound to.
* ``"invalid-secret-context"``: Enable diagnostics for a secret-context tag (`---@secret-when`, `---@secret-unless`, `---@secret-clears`, `---@secret-restriction-guard`, `---@secret-precondition`, `---@secret-satisfies`) that is not of its form, is not above a function, or names a parameter the function does not have.
* ``"invalid-secret-guard"``: Enable diagnostics for a `---@secret-guard <parameter> <is-secret|accessible|any-secret>` that is not of that form, is not above a function, or names something that is not a parameter of that function.
* ``"invisible"``: Enable diagnostics for accesses to fields which are invisible.
* ``"jump-local-scope"``: Jumping into a local variable scope
* ``"keyword"``: Improper use of a keyword
* ``"local-limit"``: Too many local variables
* ``"lowercase-global"``: Enable lowercase global variable definition diagnostics.
* ``"lua-doc-miss-sign"``: LuaDoc comment missing a sign
* ``"luadoc-error-diag-mode"``
* ``"luadoc-miss-alias-extends"``
* ``"luadoc-miss-alias-name"``
* ``"luadoc-miss-arg-name"``
* ``"luadoc-miss-cate-name"``
* ``"luadoc-miss-class-extends-name"``
* ``"luadoc-miss-class-name"``
* ``"luadoc-miss-diag-mode"``
* ``"luadoc-miss-diag-name"``
* ``"luadoc-miss-field-extends"``
* ``"luadoc-miss-field-name"``
* ``"luadoc-miss-fun-after-overload"``
* ``"luadoc-miss-generic-name"``
* ``"luadoc-miss-local-name"``
* ``"luadoc-miss-module-name"``
* ``"luadoc-miss-operator-name"``
* ``"luadoc-miss-param-extends"``
* ``"luadoc-miss-param-name"``
* ``"luadoc-miss-see-name"``
* ``"luadoc-miss-sign-name"``
* ``"luadoc-miss-symbol"``
* ``"luadoc-miss-type-name"``
* ``"luadoc-miss-vararg-type"``
* ``"luadoc-miss-version"``
* ``"malformed-number"``: Malformed number literal
* ``"miss-end"``
* ``"miss-esc-x"``
* ``"miss-exp"``
* ``"miss-exponent"``
* ``"miss-field"``
* ``"miss-loop-max"``
* ``"miss-loop-min"``
* ``"miss-method"``
* ``"miss-name"``
* ``"miss-sep-in-table"``
* ``"miss-space-between"``
* ``"miss-symbol"``
* ``"missing-fields"``: Missing fields
* ``"missing-global-doc"``: Missing annotations for globals! Global functions must have a comment and annotations for all parameters and return values.
* ``"missing-local-export-doc"``: Missing annotations for exported locals! Exported local functions must have a comment and annotations for all parameters and return values.
* ``"missing-param-annotation"``: Enable diagnostics for a function that other files can reach (a global, a function of a global table, of an exported table) with a parameter that has no `---@param`. Local functions and file-private tables are not looked at (the wowlua-ls diagnostic of the same name).
* ``"missing-parameter"``: Enable diagnostics for function calls where the number of arguments is less than the number of annotated function parameters.
* ``"missing-return"``: Enable diagnostics for functions with return annotations which have no return statement.
* ``"missing-return-annotation"``: Enable diagnostics for a function that other files can reach (a global, a function of a global table, of an exported table) whose body returns a value but has no `---@return`. Local functions and file-private tables are not looked at (the wowlua-ls diagnostic of the same name).
* ``"missing-return-value"``: Enable diagnostics for return statements without values although the containing function declares returns.
* ``"mixed-enum-values"``: Enable diagnostics for an `---@enum` whose values are not all numbers or all strings: a value of another kind than the first literal one is reported, and so is a value that is neither (a boolean, a table, a function).
* ``"multi-close"``: Multiple close operations
* ``"mutate-readonly"``: Enable diagnostics for mutating a value through a reference declared `readonly` (`---@param t readonly T`, `---@type readonly T`): assigning one of its fields/indices, or passing it to a mutating stdlib call (`table.insert`, `table.remove`, `table.sort`, `rawset`).
* ``"name-style-check"``: Enable diagnostics for name style.
* ``"need-check-nil"``: Enable diagnostics for variable usages if `nil` or an optional (potentially `nil`) value was assigned to the variable before.
* ``"need-paren"``: Parentheses required
* ``"nesting-long-mark"``: Nested long comment markers
* ``"newfield-call"``: Enable newfield call diagnostics. It is raised when the parenthesis of a function call appear on the following line when defining a field in a table.
* ``"newline-call"``: Enable newline call diagnostics. It's raised when a line starting with `(` is encountered, which is syntactically parsed as a function call on the previous line.
* ``"nil-index"``: Enable diagnostics for reading a table with a possibly-nil key through brackets (`t[k]` where `k` may be `nil`). Writing one is `need-check-nil`.
* ``"nil-table-key"``: Enable diagnostics for a table type whose key type includes `nil` (`table<string?, V>`): `nil` is not a valid table key.
* ``"no-unknown"``: Enable diagnostics for cases in which the type cannot be inferred.
* ``"no-visible-label"``: Invisible label
* ``"non-portable-annotation"``: Enable diagnostics for a `---@tag` that none of the dialects listed in `Lua.annotations.dialects` knows (it is otherwise silently ignored).
* ``"not-precedence"``: Enable diagnostics for a comparison whose left side is a bare `not x`: `not x == y` is `(not x) == y`, not `not (x == y)`. Brackets say which one is meant.
* ``"not-yieldable"``: Enable diagnostics for calls to `coroutine.yield()` when it is not permitted.
* ``"param-constraint-mismatch"``: Enable diagnostics for calls of a method marked `---@requires T: Constraint` on a receiver whose class type argument for `T` does not satisfy the constraint (`Widget<number>` where the method requires `T: Frame`). The receiver may also inherit the method from a parent class (`---@class Numbers: Widget<number>`). The wowlua-ls diagnostic of the same name.
* ``"param-type-mismatch"``: Enable diagnostics for function calls where the type of a provided parameter does not match the type of the annotated function definition.
* ``"possible-field-typo"``: Enable diagnostics for a field a method of a `---@class` declares by assigning it (`self.totl = 1`) whose name is one edit (a letter added, dropped (not a plural `s`) or changed, two swapped, or another case) away from a field the class declares.
* ``"redefined-label"``: Redefined label
* ``"redefined-local"``: Enable redefined local variable diagnostics.
* ``"redundant-and"``: Enable diagnostics for `a and b` where `a` is always falsy (`b` is never evaluated) or always truthy (the `and` changes nothing).
* ``"redundant-class-generic"``: Enable diagnostics for a method whose `---@generic` names a type parameter its class already declares (`---@class Box<T>`): the class-level one is the one in scope. The wowlua-ls diagnostic of the same name.
* ``"redundant-condition"``: Enable diagnostics for an `if` / `elseif` / `while` condition that is provably constant: always truthy or always falsy by its type, or a value compared with itself.
* ``"redundant-or"``: Enable diagnostics for `a or b` where `a` is always truthy: `b` is never evaluated.
* ``"redundant-parameter"``: Enable redundant function parameter diagnostics.
* ``"redundant-return"``: Enable diagnostics for return statements which are not needed because the function would exit on its own.
* ``"redundant-return-value"``: Enable diagnostics for return statements which return an extra value which is not specified by a return annotation.
* ``"redundant-secret-unwrap"``: Enable diagnostics for a `---@secret-unwrap` on a local that is not secret, so there is nothing to unwrap.
* ``"redundant-value"``: Enable the redundant values assigned diagnostics. It's raised during assignment operation, when the number of values is higher than the number of objects being assigned.
* ``"return-mismatch"``
* ``"return-type-mismatch"``: Enable diagnostics for return values whose type does not match the type declared in the corresponding return annotation.
* ``"secret-access"``: Enable diagnostics for indexing (`s.x`, `s[k]`, `s:m()`), calling (`s()`) or iterating (`pairs(s)`, `ipairs(s)`, `next(s)`) a secret value before it is checked.
* ``"secret-argument"``: Enable diagnostics for passing a secret value to a parameter that is declared `nosecret` (`---@param str nosecret string`).
* ``"secret-arithmetic"``: Enable diagnostics for arithmetic or a unary operator (`-`, `#`, `~`) applied to a secret value before it is checked with a `---@secret-check` / `---@secret-access-check` / `---@secret-guard` function.
* ``"secret-comparison"``: Enable diagnostics for comparing a secret value (`==`, `~=`, `<`, `<=`, `>`, `>=`) before it is checked.
* ``"secret-condition"``: Enable diagnostics for testing a secret boolean directly as a condition (`if s`, `not s`, `s and ...`) before it is checked. A secret that is not a boolean may still be tested for truthiness.
* ``"secret-field"``: Enable diagnostics for assigning a secret value to a field that is declared `nosecret` (`---@field name nosecret string`).
* ``"secret-return"``: Enable diagnostics for returning a secret value from a function declared `nosecret` (`---@nosecret`, `---@return nosecret string`), and for a function declared both secret and `nosecret`.
* ``"secret-table-key"``: Enable diagnostics for using a secret value as a table key (`t[s]`, `t[s] = v`, `{ [s] = v }`) before it is checked.
* ``"secret-variable"``: Enable diagnostics for assigning a secret value to a local declared `nosecret` (`---@type nosecret string`, `---@nosecret`), and for a local declared both secret and `nosecret`.
* ``"set-const"``: Assigning to a const constant
* ``"shadowed-local"``
* ``"spell-check"``: Enable diagnostics for typos in strings.
* ``"toc-category-translation"``: Enable diagnostics for a `## Category-xxXX:` whose text differs from the Addon Categories wiki page translation of the plain `## Category:` for that locale.
* ``"toc-duplicate-header"``: Enable diagnostics for a `## Key:` line that repeats a key whose lines do not add up (the last one wins, or only the first counts).
* ``"toc-file-name"``: Enable diagnostics for a `.toc` file whose name does not match its folder.
* ``"toc-interface-mismatch"``: Enable diagnostics for an `## Interface` number that belongs to a game the file does not load on.
* ``"toc-interface-missing-game"``: Enable diagnostics for a `.toc` that loads on a game type none of whose `## Interface` numbers fits.
* ``"toc-interface-never-matches"``: Enable diagnostics for a `.toc` whose `## Interface` numbers all belong to games it does not load on: the client would mark it out of date.
* ``"toc-interface-too-low"``: Enable diagnostics for an `## Interface` number below the lowest number worth declaring for its game today.
* ``"toc-invalid-interface"``: Enable diagnostics for an `## Interface` item that is not a whole number above 0.
* ``"toc-invalid-value"``: Enable diagnostics for a value that does not fit its directive: a flag that is not 0 or 1, an unknown game type or locale, an unknown or unclosed `[inline directive]`.
* ``"toc-line-too-long"``: Enable diagnostics for a `.toc` line over 1024 characters: the game reads only the first 1024.
* ``"toc-localized-before-base"``: Enable diagnostics for a localized `Title-deDE` that comes before the plain `Title`, or has none: the localized ones go unused.
* ``"toc-missing-interface"``: Enable diagnostics for a `.toc` file without an `## Interface` line.
* ``"toc-nonexistent-file"``: Enable diagnostics for a file line of a `.toc` that is not on disk.
* ``"toc-redundant-condition"``: Enable diagnostics for a load condition that does not change where the line loads.
* ``"toc-restricted-header"``: Enable diagnostics for a directive that only Blizzard code may use.
* ``"toc-retired-header"``: Enable diagnostics for a `## Key:` the game dropped or renamed (`AllowLoadByGameMode`, `GuardedAddOn`, `SuppressLocalTableRef`): the line does nothing.
* ``"toc-retired-suffix"``: Enable diagnostics for a `.toc` file name suffix the game does not read any more (`_BCC`, `_WOTLK`): the file is ignored, rename it.
* ``"toc-unfulfilled-expect"``: Enable diagnostics for a `# @diagnostic expect-next-line: toc-x` comment whose diagnostic does not occur on the next line.
* ``"toc-unknown-category"``: Enable diagnostics for a `## Category:` that is not one of the recommended names of the Addon Categories wiki page (a custom category is allowed, the page recommends its names).
* ``"toc-unknown-header"``: Enable diagnostics for a `## Key:` that is not a known directive, an `X-*` custom key or a localized variant.
* ``"toc-unreachable-line"``: Enable diagnostics for a line of a `.toc` whose load conditions and file name suffix leave no game type it can load on.
* ``"trailing-space"``: Enable trailing space diagnostics.
* ``"type-mismatch"``
* ``"unbalanced-assignments"``: Enable diagnostics on multiple assignments if not all variables obtain a value (e.g., `local x,y = 1`), also when the last value is a call of a function of the project that returns fewer values than there are variables.
* ``"unchecked-array-index"``: Enable diagnostics for reading an element of a `T[]` array (`arr[i]`) in a context that treats the value as definitely not `nil` (arithmetic, further indexing, a call, a numeric `for` bound, ...). Off by default: a Lua array has no compile-time length, so most such reads are guarded by something the checker cannot see (a loop bound, a known constructor); this finds candidates to review.
* ``"undefined-doc-class"``: Enable diagnostics for class annotations in which an undefined class is referenced.
* ``"undefined-doc-name"``: Enable diagnostics for type annotations referencing an undefined type or alias.
* ``"undefined-doc-param"``: Enable diagnostics for cases in which a parameter annotation is given without declaring the parameter in the function definition.
* ``"undefined-env-child"``: Enable undefined environment variable diagnostics. It's raised when `_ENV` table is set to a new literal table, but the used global variable is no longer present in the global environment.
* ``"undefined-field"``: Enable diagnostics for cases in which an undefined field of a variable is read, also through an index that chooses between literal names (`t[flag and "a" or "b"]`).
* ``"undefined-global"``: Enable undefined global variable diagnostics.
* ``"undefined-secret-name"``: Enable diagnostics for a name in `---@secret a, b` / `---@secret-unwrap a, b` / `---@nosecret a, b` that is not a local of the statement the tag applies to.
* ``"unexpect-dots"``
* ``"unexpect-efunc-name"``
* ``"unexpect-gfunc-name"``
* ``"unexpect-lfunc-name"``
* ``"unexpect-symbol"``
* ``"unfulfilled-expect"``: Enable diagnostics for `---@diagnostic expect-next-line` / `expect-line` comments whose expected diagnostic did not occur, so a stale suppression cannot outlive the problem it hid.
* ``"unicode-name"``: Unicode name
* ``"unknown-attribute"``: Unknown attribute
* ``"unknown-cast-variable"``: Enable diagnostics for casts of undefined variables.
* ``"unknown-diag-code"``: Enable diagnostics in cases in which an unknown diagnostics code is entered.
* ``"unknown-field-type"``
* ``"unknown-local-type"``
* ``"unknown-operator"``: Enable diagnostics for unknown operators.
* ``"unknown-param-type"``
* ``"unknown-return-type"``
* ``"unknown-symbol"``: Unknown symbol
* ``"unreachable-code"``: Enable diagnostics for unreachable code.
* ``"unsupport-named-vararg"``: Unsupported named vararg
* ``"unsupport-symbol"``
* ``"unused-config-global"``: Enable diagnostics for an entry of `Lua.diagnostics.globals` or `Lua.diagnostics.globalsRegex` in a project's settings file that does nothing: the global is defined, or nothing in the workspace uses it.
* ``"unused-function"``: Enable unused function diagnostics.
* ``"unused-label"``: Enable unused label diagnostics.
* ``"unused-local"``: Enable unused local variable diagnostics.
* ``"unused-vararg"``: Enable unused vararg diagnostics.
* ``"variable-not-declared"``: Using an undeclared variable

## default

```jsonc
[]
```

# diagnostics.enable

Run the diagnostics at all.

`false` turns every check off, the syntax errors too; hover, completion and the rest keep working.


## type

```ts
boolean
```

## default

```jsonc
true
```

# diagnostics.enableScheme

The URI schemes of the files that are diagnosed (`file` for files on disk). A file with another scheme (an untitled buffer, a virtual file system) gets no diagnostics.

## type

```ts
Array<string>
```

## default

```jsonc
["file"]
```

# diagnostics.globals

Global variables that are known to exist, so that `undefined-global` does not report them.

Use it for the globals a host program or framework provides (`vim`, `love`, the WoW API). Better still, declare them in a library folder (`Lua.workspace.library`) with their types.


## type

```ts
Array<string>
```

## default

```jsonc
[]
```

# diagnostics.globalsRegex

Known globals given as patterns.

Every global whose name matches one of these Lua patterns counts as defined, e.g. `^MyAddon` for all globals that start with `MyAddon`.


## type

```ts
Array<string>
```

## default

```jsonc
[]
```

# diagnostics.groupFileStatus

Change the file status (`Opened`, `Any`, `None`) of a whole group of diagnostics.

* `Opened`: only the open files
* `Any`: every file of the workspace
* `None`: the group is off

`Fallback` leaves each diagnostic to `Lua.diagnostics.neededFileStatus`. A group value overrides the single settings, except the ones that end with `!`.

The name `*` stands for every diagnostic that no group setting speaks for: `{ "*": "Any" }` checks every file of the workspace with the diagnostics that are on, not only the open files (the ones that are off by default stay off, and a group set to something else still wins for its own diagnostics).


## type

```ts
object<string, string>
```

## enum

* ``"Any"``
* ``"Opened"``
* ``"None"``
* ``"Fallback"``

## default

```jsonc
{
    /*
    * ambiguity-1
    * count-down-loop
    * different-requires
    * newfield-call
    * newline-call
    * not-precedence
    */
    "ambiguity": "Fallback",
    /*
    * await-in-sync
    * not-yieldable
    */
    "await": "Fallback",
    /*
    * codestyle-check
    * name-style-check
    * spell-check
    */
    "codestyle": "Fallback",
    /*
    * global-element
    * implicit-nil-return
    */
    "conventions": "Fallback",
    /*
    * duplicate-index
    * duplicate-set-field
    */
    "duplicate": "Fallback",
    /*
    * global-in-nil-env
    * lowercase-global
    * undefined-env-child
    * undefined-global
    */
    "global": "Fallback",
    /*
    * circle-doc-class
    * doc-field-no-class
    * duplicate-doc-alias
    * duplicate-doc-field
    * duplicate-doc-param
    * incomplete-signature-doc
    * invalid-guard
    * invalid-secret-context
    * invalid-secret-guard
    * missing-global-doc
    * missing-local-export-doc
    * missing-param-annotation
    * missing-return-annotation
    * nil-table-key
    * non-portable-annotation
    * redundant-class-generic
    * undefined-doc-class
    * undefined-doc-name
    * undefined-doc-param
    * unfulfilled-expect
    * unknown-cast-variable
    * unknown-diag-code
    * unknown-operator
    */
    "luadoc": "Fallback",
    /*
    * redefined-local
    */
    "redefined": "Fallback",
    /*
    * redundant-and
    * redundant-condition
    * redundant-or
    */
    "redundant": "Fallback",
    /*
    * redundant-secret-unwrap
    * secret-access
    * secret-argument
    * secret-arithmetic
    * secret-comparison
    * secret-condition
    * secret-field
    * secret-return
    * secret-table-key
    * secret-variable
    * undefined-secret-name
    */
    "secret": "Fallback",
    /*
    * close-non-object
    * deprecated
    * discard-returns
    * invisible
    */
    "strict": "Fallback",
    /*
    * no-unknown
    */
    "strong": "Fallback",
    /*
    * toc-category-translation
    * toc-duplicate-header
    * toc-file-name
    * toc-interface-mismatch
    * toc-interface-missing-game
    * toc-interface-never-matches
    * toc-interface-too-low
    * toc-invalid-interface
    * toc-invalid-value
    * toc-line-too-long
    * toc-localized-before-base
    * toc-missing-interface
    * toc-nonexistent-file
    * toc-redundant-condition
    * toc-restricted-header
    * toc-retired-header
    * toc-retired-suffix
    * toc-unfulfilled-expect
    * toc-unknown-category
    * toc-unknown-header
    * toc-unreachable-line
    */
    "toc": "Fallback",
    /*
    * assign-readonly
    * assign-type-mismatch
    * cannot-call
    * cast-local-type
    * cast-type-mismatch
    * excess-field
    * generic-constraint-mismatch
    * generic-param-mismatch
    * grouped-return-mismatch
    * incompatible-override
    * inject-field
    * invalid-class-parent
    * mixed-enum-values
    * mutate-readonly
    * need-check-nil
    * nil-index
    * param-constraint-mismatch
    * param-type-mismatch
    * possible-field-typo
    * return-type-mismatch
    * unchecked-array-index
    * undefined-field
    */
    "type-check": "Fallback",
    /*
    * missing-fields
    * missing-parameter
    * missing-return
    * missing-return-value
    * redundant-parameter
    * redundant-return-value
    * redundant-value
    * unbalanced-assignments
    */
    "unbalanced": "Fallback",
    /*
    * code-after-break
    * empty-block
    * redundant-return
    * trailing-space
    * unreachable-code
    * unused-config-global
    * unused-function
    * unused-label
    * unused-local
    * unused-vararg
    */
    "unused": "Fallback"
}
```

# diagnostics.groupSeverity

Change the severity of a whole group of diagnostics (`ambiguity`, `await`, `codestyle`, `conventions`, `duplicate`, `global`, `luadoc`, `redefined`, `redundant`, `secret`, `strict`, `strong`, `type-check`, `unbalanced`, `unused`).

`Fallback` leaves each diagnostic to `Lua.diagnostics.severity`. A group value overrides the single settings, except the ones that end with `!`.

The name `*` stands for every diagnostic that no group setting speaks for: `{ "*": "Hint" }` makes all of them hints, and a group set to something else keeps its own value.


## type

```ts
object<string, string>
```

## enum

* ``"Error"``
* ``"Warning"``
* ``"Information"``
* ``"Hint"``
* ``"Fallback"``

## default

```jsonc
{
    /*
    * ambiguity-1
    * count-down-loop
    * different-requires
    * newfield-call
    * newline-call
    * not-precedence
    */
    "ambiguity": "Fallback",
    /*
    * await-in-sync
    * not-yieldable
    */
    "await": "Fallback",
    /*
    * codestyle-check
    * name-style-check
    * spell-check
    */
    "codestyle": "Fallback",
    /*
    * global-element
    * implicit-nil-return
    */
    "conventions": "Fallback",
    /*
    * duplicate-index
    * duplicate-set-field
    */
    "duplicate": "Fallback",
    /*
    * global-in-nil-env
    * lowercase-global
    * undefined-env-child
    * undefined-global
    */
    "global": "Fallback",
    /*
    * circle-doc-class
    * doc-field-no-class
    * duplicate-doc-alias
    * duplicate-doc-field
    * duplicate-doc-param
    * incomplete-signature-doc
    * invalid-guard
    * invalid-secret-context
    * invalid-secret-guard
    * missing-global-doc
    * missing-local-export-doc
    * missing-param-annotation
    * missing-return-annotation
    * nil-table-key
    * non-portable-annotation
    * redundant-class-generic
    * undefined-doc-class
    * undefined-doc-name
    * undefined-doc-param
    * unfulfilled-expect
    * unknown-cast-variable
    * unknown-diag-code
    * unknown-operator
    */
    "luadoc": "Fallback",
    /*
    * redefined-local
    */
    "redefined": "Fallback",
    /*
    * redundant-and
    * redundant-condition
    * redundant-or
    */
    "redundant": "Fallback",
    /*
    * redundant-secret-unwrap
    * secret-access
    * secret-argument
    * secret-arithmetic
    * secret-comparison
    * secret-condition
    * secret-field
    * secret-return
    * secret-table-key
    * secret-variable
    * undefined-secret-name
    */
    "secret": "Fallback",
    /*
    * close-non-object
    * deprecated
    * discard-returns
    * invisible
    */
    "strict": "Fallback",
    /*
    * no-unknown
    */
    "strong": "Fallback",
    /*
    * toc-category-translation
    * toc-duplicate-header
    * toc-file-name
    * toc-interface-mismatch
    * toc-interface-missing-game
    * toc-interface-never-matches
    * toc-interface-too-low
    * toc-invalid-interface
    * toc-invalid-value
    * toc-line-too-long
    * toc-localized-before-base
    * toc-missing-interface
    * toc-nonexistent-file
    * toc-redundant-condition
    * toc-restricted-header
    * toc-retired-header
    * toc-retired-suffix
    * toc-unfulfilled-expect
    * toc-unknown-category
    * toc-unknown-header
    * toc-unreachable-line
    */
    "toc": "Fallback",
    /*
    * assign-readonly
    * assign-type-mismatch
    * cannot-call
    * cast-local-type
    * cast-type-mismatch
    * excess-field
    * generic-constraint-mismatch
    * generic-param-mismatch
    * grouped-return-mismatch
    * incompatible-override
    * inject-field
    * invalid-class-parent
    * mixed-enum-values
    * mutate-readonly
    * need-check-nil
    * nil-index
    * param-constraint-mismatch
    * param-type-mismatch
    * possible-field-typo
    * return-type-mismatch
    * unchecked-array-index
    * undefined-field
    */
    "type-check": "Fallback",
    /*
    * missing-fields
    * missing-parameter
    * missing-return
    * missing-return-value
    * redundant-parameter
    * redundant-return-value
    * redundant-value
    * unbalanced-assignments
    */
    "unbalanced": "Fallback",
    /*
    * code-after-break
    * empty-block
    * redundant-return
    * trailing-space
    * unreachable-code
    * unused-config-global
    * unused-function
    * unused-label
    * unused-local
    * unused-vararg
    */
    "unused": "Fallback"
}
```

# diagnostics.ignoredFiles

Whether the files that `Lua.workspace.ignoreDir` and `.gitignore` exclude are diagnosed.

`Opened` diagnoses an ignored file only while it is open in the editor.


## type

```ts
string
```

## enum

* ``"Enable"``: Always diagnose these files.
* ``"Opened"``: Only when these files are opened will it be diagnosed.
* ``"Disable"``: These files are not diagnosed.

## default

```jsonc
"Opened"
```

# diagnostics.libraryFiles

Whether the files of `Lua.workspace.library` are diagnosed.

`Opened` diagnoses a library file only while it is open in the editor.


## type

```ts
string
```

## enum

* ``"Enable"``: Always diagnose these files.
* ``"Opened"``: Only when these files are opened will it be diagnosed.
* ``"Disable"``: These files are not diagnosed.

## default

```jsonc
"Opened"
```

# diagnostics.neededFileStatus

Which files a diagnostic runs on, by code.

* `Opened`: only the files that are open in the editor
* `Any`: every file of the workspace (slower, and fills the Problems panel)
* `None`: the diagnostic is off

A trailing `!` on the value makes it win over the group setting `Lua.diagnostics.groupFileStatus`.

The name `*` is the value for every diagnostic this table does not list: `{ "*": "Any" }` checks every file of the workspace with the diagnostics that are on, not only the open files (the ones that are off by default stay off), and `{ "*": "Any", "unused-local": "Opened" }` leaves `unused-local` alone. `{ "*": "None" }` turns every unlisted diagnostic off. A group set in `Lua.diagnostics.groupFileStatus` still wins for its own diagnostics.


## type

```ts
object<string, string>
```

## enum

* ``"Any"``
* ``"Opened"``
* ``"None"``
* ``"Any!"``
* ``"Opened!"``
* ``"None!"``

## default

```jsonc
{
    /*
    Enable ambiguous operator precedence diagnostics. For example, the `num or 0 + 1` expression will be suggested `(num or 0) + 1` instead.
    */
    "ambiguity-1": "Any",
    /*
    Enable diagnostics for assigning a field that is declared `readonly` (`---@field readonly name string`) outside the code that builds the object.
    */
    "assign-readonly": "Opened",
    /*
    Enable diagnostics for assignments in which the value's type does not match the type of the assigned variable.
    */
    "assign-type-mismatch": "Opened",
    /*
    Enable diagnostics for calls of asynchronous functions within a synchronous function.
    */
    "await-in-sync": "None",
    /*
    Enable diagnostics for calling a local variable or a literal whose every known type is one that cannot be called (a number, a string, a boolean). Anything that could be callable (a function, a table, a class, `any`, an unknown value, a union with one of those) is left alone, and so are field and method accesses, whose type is not certain; a value that may be `nil` is `need-check-nil`.
    */
    "cannot-call": "Opened",
    /*
    Enable diagnostics for casts of local variables where the target type does not match the defined type.
    */
    "cast-local-type": "Opened",
    /*
    Enable diagnostics for casts where the target type does not match the initial type.
    */
    "cast-type-mismatch": "Opened",
    /*
    Circular `@class` inheritance
    */
    "circle-doc-class": "Any",
    /*
    Enable diagnostics for attempts to close a variable with a non-object.
    */
    "close-non-object": "Any",
    /*
    Enable diagnostics for code placed after a break statement in a loop.
    */
    "code-after-break": "Opened",
    /*
    Enable diagnostics for incorrectly styled lines.
    */
    "codestyle-check": "None",
    /*
    Enable diagnostics for `for` loops which will never reach their max/limit because the loop is incrementing instead of decrementing.
    */
    "count-down-loop": "Any",
    /*
    Enable diagnostics to highlight deprecated API.
    */
    "deprecated": "Any",
    /*
    Enable diagnostics for files which are required by two different paths.
    */
    "different-requires": "Any",
    /*
    Enable diagnostics for calls of functions annotated with `---@nodiscard` where the return values are ignored.
    */
    "discard-returns": "Any",
    /*
    Enable diagnostics to highlight a field annotation without a defining class annotation.
    */
    "doc-field-no-class": "Any",
    /*
    Enable diagnostics for a duplicated alias annotation name.
    */
    "duplicate-doc-alias": "Any",
    /*
    Enable diagnostics for a duplicated field annotation name.
    */
    "duplicate-doc-field": "Any",
    /*
    Enable diagnostics for a duplicated param annotation name.
    */
    "duplicate-doc-param": "Any",
    /*
    Enable duplicate table index diagnostics.
    */
    "duplicate-index": "Any",
    /*
    Enable diagnostics for setting the same field in a class more than once.
    */
    "duplicate-set-field": "Opened",
    /*
    Enable empty code block diagnostics.
    */
    "empty-block": "Opened",
    /*
    A table constructor given to a class has a field the class does not declare (the excess property check of TypeScript).
    */
    "excess-field": "Opened",
    /*
    Enable diagnostics for the type arguments of a class or an alias that do not satisfy the constraint of their type parameter (`Widget<number>` where `---@class Widget<T: Frame>`), and for calls of a generic function where an argument does not fit a `keyof` of another argument: the type bound to a type parameter does not satisfy a constraint that names another type parameter (`---@generic K: keyof T`), or the argument of a parameter typed `keyof T` (`---@param key keyof T`, `---@param ... keyof T`: every extra argument) is not a key of `T`. A constraint on its own (`---@generic T: Base`) is already reported by `param-type-mismatch`. The wowlua-ls diagnostic of the same name.
    */
    "generic-constraint-mismatch": "Opened",
    /*
    Enable diagnostics for calls of a generic function where two arguments bound to the same type parameter (`---@param a T`, `---@param b T`) have types that do not fit together: the first argument binds `T`, a later one has to be assignable to it (or be wider, which widens `T`).
    */
    "generic-param-mismatch": "Opened",
    /*
    Enable diagnostics to warn about global elements.
    */
    "global-element": "None",
    /*
    Enable cannot use global variables （ `_ENV` is set to `nil`） diagnostics.
    */
    "global-in-nil-env": "Any",
    /*
    Enable diagnostics for return values that each fit their own slot but together match none of the cases of a tuple-union return annotation (`---@return (A, B) | (C, D)`).
    */
    "grouped-return-mismatch": "Opened",
    /*
    Enable diagnostics for a bare `return` in a function whose first `@return` is optional (`T?`): write `return nil` to say it on purpose.
    */
    "implicit-nil-return": "None",
    /*
    Enable diagnostics for a class that overrides a member of a class it inherits from with something that does not fit it (TypeScript's "class incorrectly extends"): a method that needs more arguments, takes or gives other types, or a field redeclared with a type that is not assignable to the parent's. A narrower type is an override; a wider or unrelated one is a collision. Only parents the user owns are judged: a member declared in a library outside the workspace (third-party annotations, which a polyfill class may re-annotate on purpose) is left alone.
    */
    "incompatible-override": "Opened",
    /*
    Incomplete @param or @return annotations for functions.
    */
    "incomplete-signature-doc": "None",
    /*
    Injecting a field into an object
    */
    "inject-field": "Opened",
    /*
    Enable diagnostics for a `---@class Child : Parent` whose parent is a primitive type (`string`, `number`, `integer`, `boolean`, `true`, `false`, `nil`, `function`, `thread`): a class describes a table. `table`, `userdata` and `any` stay allowed. Off by default: `---@class Name : string` is also used on purpose, as a named string type.
    */
    "invalid-class-parent": "None",
    /*
    Enable diagnostics for a `---@guard x is T` / `---@asserts x is T` that is not of that form, or names something that is not a parameter of the function it is bound to.
    */
    "invalid-guard": "Opened",
    /*
    Enable diagnostics for a secret-context tag (`---@secret-when`, `---@secret-unless`, `---@secret-clears`, `---@secret-restriction-guard`, `---@secret-precondition`, `---@secret-satisfies`) that is not of its form, is not above a function, or names a parameter the function does not have.
    */
    "invalid-secret-context": "Opened",
    /*
    Enable diagnostics for a `---@secret-guard <parameter> <is-secret|accessible|any-secret>` that is not of that form, is not above a function, or names something that is not a parameter of that function.
    */
    "invalid-secret-guard": "Opened",
    /*
    Enable diagnostics for accesses to fields which are invisible.
    */
    "invisible": "Any",
    /*
    Enable lowercase global variable definition diagnostics.
    */
    "lowercase-global": "Any",
    /*
    Missing fields
    */
    "missing-fields": "Any",
    /*
    Missing annotations for globals! Global functions must have a comment and annotations for all parameters and return values.
    */
    "missing-global-doc": "None",
    /*
    Missing annotations for exported locals! Exported local functions must have a comment and annotations for all parameters and return values.
    */
    "missing-local-export-doc": "None",
    /*
    Enable diagnostics for a function that other files can reach (a global, a function of a global table, of an exported table) with a parameter that has no `---@param`. Local functions and file-private tables are not looked at (the wowlua-ls diagnostic of the same name).
    */
    "missing-param-annotation": "None",
    /*
    Enable diagnostics for function calls where the number of arguments is less than the number of annotated function parameters.
    */
    "missing-parameter": "Any",
    /*
    Enable diagnostics for functions with return annotations which have no return statement.
    */
    "missing-return": "Any",
    /*
    Enable diagnostics for a function that other files can reach (a global, a function of a global table, of an exported table) whose body returns a value but has no `---@return`. Local functions and file-private tables are not looked at (the wowlua-ls diagnostic of the same name).
    */
    "missing-return-annotation": "None",
    /*
    Enable diagnostics for return statements without values although the containing function declares returns.
    */
    "missing-return-value": "Any",
    /*
    Enable diagnostics for an `---@enum` whose values are not all numbers or all strings: a value of another kind than the first literal one is reported, and so is a value that is neither (a boolean, a table, a function).
    */
    "mixed-enum-values": "Opened",
    /*
    Enable diagnostics for mutating a value through a reference declared `readonly` (`---@param t readonly T`, `---@type readonly T`): assigning one of its fields/indices, or passing it to a mutating stdlib call (`table.insert`, `table.remove`, `table.sort`, `rawset`).
    */
    "mutate-readonly": "Opened",
    /*
    Enable diagnostics for name style.
    */
    "name-style-check": "None",
    /*
    Enable diagnostics for variable usages if `nil` or an optional (potentially `nil`) value was assigned to the variable before.
    */
    "need-check-nil": "Opened",
    /*
    Enable newfield call diagnostics. It is raised when the parenthesis of a function call appear on the following line when defining a field in a table.
    */
    "newfield-call": "Any",
    /*
    Enable newline call diagnostics. It's raised when a line starting with `(` is encountered, which is syntactically parsed as a function call on the previous line.
    */
    "newline-call": "Any",
    /*
    Enable diagnostics for reading a table with a possibly-nil key through brackets (`t[k]` where `k` may be `nil`). Writing one is `need-check-nil`.
    */
    "nil-index": "Opened",
    /*
    Enable diagnostics for a table type whose key type includes `nil` (`table<string?, V>`): `nil` is not a valid table key.
    */
    "nil-table-key": "Any",
    /*
    Enable diagnostics for cases in which the type cannot be inferred.
    */
    "no-unknown": "None",
    /*
    Enable diagnostics for a `---@tag` that none of the dialects listed in `Lua.annotations.dialects` knows (it is otherwise silently ignored).
    */
    "non-portable-annotation": "Any",
    /*
    Enable diagnostics for a comparison whose left side is a bare `not x`: `not x == y` is `(not x) == y`, not `not (x == y)`. Brackets say which one is meant.
    */
    "not-precedence": "Any",
    /*
    Enable diagnostics for calls to `coroutine.yield()` when it is not permitted.
    */
    "not-yieldable": "None",
    /*
    Enable diagnostics for calls of a method marked `---@requires T: Constraint` on a receiver whose class type argument for `T` does not satisfy the constraint (`Widget<number>` where the method requires `T: Frame`). The receiver may also inherit the method from a parent class (`---@class Numbers: Widget<number>`). The wowlua-ls diagnostic of the same name.
    */
    "param-constraint-mismatch": "Opened",
    /*
    Enable diagnostics for function calls where the type of a provided parameter does not match the type of the annotated function definition.
    */
    "param-type-mismatch": "Opened",
    /*
    Enable diagnostics for a field a method of a `---@class` declares by assigning it (`self.totl = 1`) whose name is one edit (a letter added, dropped (not a plural `s`) or changed, two swapped, or another case) away from a field the class declares.
    */
    "possible-field-typo": "Opened",
    /*
    Enable redefined local variable diagnostics.
    */
    "redefined-local": "Opened",
    /*
    Enable diagnostics for `a and b` where `a` is always falsy (`b` is never evaluated) or always truthy (the `and` changes nothing).
    */
    "redundant-and": "None",
    /*
    Enable diagnostics for a method whose `---@generic` names a type parameter its class already declares (`---@class Box<T>`): the class-level one is the one in scope. The wowlua-ls diagnostic of the same name.
    */
    "redundant-class-generic": "Opened",
    /*
    Enable diagnostics for an `if` / `elseif` / `while` condition that is provably constant: always truthy or always falsy by its type, or a value compared with itself.
    */
    "redundant-condition": "None",
    /*
    Enable diagnostics for `a or b` where `a` is always truthy: `b` is never evaluated.
    */
    "redundant-or": "None",
    /*
    Enable redundant function parameter diagnostics.
    */
    "redundant-parameter": "Any",
    /*
    Enable diagnostics for return statements which are not needed because the function would exit on its own.
    */
    "redundant-return": "Opened",
    /*
    Enable diagnostics for return statements which return an extra value which is not specified by a return annotation.
    */
    "redundant-return-value": "Any",
    /*
    Enable diagnostics for a `---@secret-unwrap` on a local that is not secret, so there is nothing to unwrap.
    */
    "redundant-secret-unwrap": "Opened",
    /*
    Enable the redundant values assigned diagnostics. It's raised during assignment operation, when the number of values is higher than the number of objects being assigned.
    */
    "redundant-value": "Any",
    /*
    Enable diagnostics for return values whose type does not match the type declared in the corresponding return annotation.
    */
    "return-type-mismatch": "Opened",
    /*
    Enable diagnostics for indexing (`s.x`, `s[k]`, `s:m()`), calling (`s()`) or iterating (`pairs(s)`, `ipairs(s)`, `next(s)`) a secret value before it is checked.
    */
    "secret-access": "Opened",
    /*
    Enable diagnostics for passing a secret value to a parameter that is declared `nosecret` (`---@param str nosecret string`).
    */
    "secret-argument": "Opened",
    /*
    Enable diagnostics for arithmetic or a unary operator (`-`, `#`, `~`) applied to a secret value before it is checked with a `---@secret-check` / `---@secret-access-check` / `---@secret-guard` function.
    */
    "secret-arithmetic": "Opened",
    /*
    Enable diagnostics for comparing a secret value (`==`, `~=`, `<`, `<=`, `>`, `>=`) before it is checked.
    */
    "secret-comparison": "Opened",
    /*
    Enable diagnostics for testing a secret boolean directly as a condition (`if s`, `not s`, `s and ...`) before it is checked. A secret that is not a boolean may still be tested for truthiness.
    */
    "secret-condition": "Opened",
    /*
    Enable diagnostics for assigning a secret value to a field that is declared `nosecret` (`---@field name nosecret string`).
    */
    "secret-field": "Opened",
    /*
    Enable diagnostics for returning a secret value from a function declared `nosecret` (`---@nosecret`, `---@return nosecret string`), and for a function declared both secret and `nosecret`.
    */
    "secret-return": "Opened",
    /*
    Enable diagnostics for using a secret value as a table key (`t[s]`, `t[s] = v`, `{ [s] = v }`) before it is checked.
    */
    "secret-table-key": "Opened",
    /*
    Enable diagnostics for assigning a secret value to a local declared `nosecret` (`---@type nosecret string`, `---@nosecret`), and for a local declared both secret and `nosecret`.
    */
    "secret-variable": "Opened",
    /*
    Enable diagnostics for typos in strings.
    */
    "spell-check": "None",
    /*
    Enable diagnostics for a `## Category-xxXX:` whose text differs from the Addon Categories wiki page translation of the plain `## Category:` for that locale.
    */
    "toc-category-translation": "Any",
    /*
    Enable diagnostics for a `## Key:` line that repeats a key whose lines do not add up (the last one wins, or only the first counts).
    */
    "toc-duplicate-header": "Any",
    /*
    Enable diagnostics for a `.toc` file whose name does not match its folder.
    */
    "toc-file-name": "Any",
    /*
    Enable diagnostics for an `## Interface` number that belongs to a game the file does not load on.
    */
    "toc-interface-mismatch": "Any",
    /*
    Enable diagnostics for a `.toc` that loads on a game type none of whose `## Interface` numbers fits.
    */
    "toc-interface-missing-game": "Any",
    /*
    Enable diagnostics for a `.toc` whose `## Interface` numbers all belong to games it does not load on: the client would mark it out of date.
    */
    "toc-interface-never-matches": "Any",
    /*
    Enable diagnostics for an `## Interface` number below the lowest number worth declaring for its game today.
    */
    "toc-interface-too-low": "Any",
    /*
    Enable diagnostics for an `## Interface` item that is not a whole number above 0.
    */
    "toc-invalid-interface": "Any",
    /*
    Enable diagnostics for a value that does not fit its directive: a flag that is not 0 or 1, an unknown game type or locale, an unknown or unclosed `[inline directive]`.
    */
    "toc-invalid-value": "Any",
    /*
    Enable diagnostics for a `.toc` line over 1024 characters: the game reads only the first 1024.
    */
    "toc-line-too-long": "Any",
    /*
    Enable diagnostics for a localized `Title-deDE` that comes before the plain `Title`, or has none: the localized ones go unused.
    */
    "toc-localized-before-base": "Any",
    /*
    Enable diagnostics for a `.toc` file without an `## Interface` line.
    */
    "toc-missing-interface": "Any",
    /*
    Enable diagnostics for a file line of a `.toc` that is not on disk.
    */
    "toc-nonexistent-file": "Any",
    /*
    Enable diagnostics for a load condition that does not change where the line loads.
    */
    "toc-redundant-condition": "Any",
    /*
    Enable diagnostics for a directive that only Blizzard code may use.
    */
    "toc-restricted-header": "Any",
    /*
    Enable diagnostics for a `## Key:` the game dropped or renamed (`AllowLoadByGameMode`, `GuardedAddOn`, `SuppressLocalTableRef`): the line does nothing.
    */
    "toc-retired-header": "Any",
    /*
    Enable diagnostics for a `.toc` file name suffix the game does not read any more (`_BCC`, `_WOTLK`): the file is ignored, rename it.
    */
    "toc-retired-suffix": "Any",
    /*
    Enable diagnostics for a `# @diagnostic expect-next-line: toc-x` comment whose diagnostic does not occur on the next line.
    */
    "toc-unfulfilled-expect": "Any",
    /*
    Enable diagnostics for a `## Category:` that is not one of the recommended names of the Addon Categories wiki page (a custom category is allowed, the page recommends its names).
    */
    "toc-unknown-category": "Any",
    /*
    Enable diagnostics for a `## Key:` that is not a known directive, an `X-*` custom key or a localized variant.
    */
    "toc-unknown-header": "Any",
    /*
    Enable diagnostics for a line of a `.toc` whose load conditions and file name suffix leave no game type it can load on.
    */
    "toc-unreachable-line": "Any",
    /*
    Enable trailing space diagnostics.
    */
    "trailing-space": "Opened",
    /*
    Enable diagnostics on multiple assignments if not all variables obtain a value (e.g., `local x,y = 1`), also when the last value is a call of a function of the project that returns fewer values than there are variables.
    */
    "unbalanced-assignments": "Any",
    /*
    Enable diagnostics for reading an element of a `T[]` array (`arr[i]`) in a context that treats the value as definitely not `nil` (arithmetic, further indexing, a call, a numeric `for` bound, ...). Off by default: a Lua array has no compile-time length, so most such reads are guarded by something the checker cannot see (a loop bound, a known constructor); this finds candidates to review.
    */
    "unchecked-array-index": "None",
    /*
    Enable diagnostics for class annotations in which an undefined class is referenced.
    */
    "undefined-doc-class": "Any",
    /*
    Enable diagnostics for type annotations referencing an undefined type or alias.
    */
    "undefined-doc-name": "Any",
    /*
    Enable diagnostics for cases in which a parameter annotation is given without declaring the parameter in the function definition.
    */
    "undefined-doc-param": "Any",
    /*
    Enable undefined environment variable diagnostics. It's raised when `_ENV` table is set to a new literal table, but the used global variable is no longer present in the global environment.
    */
    "undefined-env-child": "Any",
    /*
    Enable diagnostics for cases in which an undefined field of a variable is read, also through an index that chooses between literal names (`t[flag and "a" or "b"]`).
    */
    "undefined-field": "Opened",
    /*
    Enable undefined global variable diagnostics.
    */
    "undefined-global": "Any",
    /*
    Enable diagnostics for a name in `---@secret a, b` / `---@secret-unwrap a, b` / `---@nosecret a, b` that is not a local of the statement the tag applies to.
    */
    "undefined-secret-name": "Opened",
    /*
    Enable diagnostics for `---@diagnostic expect-next-line` / `expect-line` comments whose expected diagnostic did not occur, so a stale suppression cannot outlive the problem it hid.
    */
    "unfulfilled-expect": "Any",
    /*
    Enable diagnostics for casts of undefined variables.
    */
    "unknown-cast-variable": "Any",
    /*
    Enable diagnostics in cases in which an unknown diagnostics code is entered.
    */
    "unknown-diag-code": "Any",
    /*
    Enable diagnostics for unknown operators.
    */
    "unknown-operator": "Any",
    /*
    Enable diagnostics for unreachable code.
    */
    "unreachable-code": "Opened",
    /*
    Enable diagnostics for an entry of `Lua.diagnostics.globals` or `Lua.diagnostics.globalsRegex` in a project's settings file that does nothing: the global is defined, or nothing in the workspace uses it.
    */
    "unused-config-global": "Any",
    /*
    Enable unused function diagnostics.
    */
    "unused-function": "Opened",
    /*
    Enable unused label diagnostics.
    */
    "unused-label": "Opened",
    /*
    Enable unused local variable diagnostics.
    */
    "unused-local": "Opened",
    /*
    Enable unused vararg diagnostics.
    */
    "unused-vararg": "Opened"
}
```

# diagnostics.pluginsDir

A folder of custom diagnostic plugins (`.lua` files).

Blank (the default) loads none. Each file registers one diagnostic with `proto.diagnostic.register`, under a name equal to its file name, and returns `function(uri, callback) ... end`, like a built-in diagnostic.

A plugin runs arbitrary Lua code, so the first load of a folder asks you to trust it.


## type

```ts
string
```

## default

```jsonc
""
```

# diagnostics.severity

Change how serious a diagnostic is, by code: `Error`, `Warning`, `Information` or `Hint`.

A trailing `!` on the value makes it win over the group setting `Lua.diagnostics.groupSeverity`.

The name `*` is the severity of every diagnostic this table does not list: `{ "*": "Hint" }` quietens everything, `{ "*": "Warning", "unused-local": "Hint" }` raises all but `unused-local`. A group set in `Lua.diagnostics.groupSeverity` still wins for its own diagnostics.

```json
"Lua.diagnostics.severity": { "unused-local": "Warning", "undefined-field!": "Error" }
```


## type

```ts
object<string, string>
```

## enum

* ``"Error"``
* ``"Warning"``
* ``"Information"``
* ``"Hint"``
* ``"Error!"``
* ``"Warning!"``
* ``"Information!"``
* ``"Hint!"``

## default

```jsonc
{
    /*
    Enable ambiguous operator precedence diagnostics. For example, the `num or 0 + 1` expression will be suggested `(num or 0) + 1` instead.
    */
    "ambiguity-1": "Warning",
    /*
    Enable diagnostics for assigning a field that is declared `readonly` (`---@field readonly name string`) outside the code that builds the object.
    */
    "assign-readonly": "Warning",
    /*
    Enable diagnostics for assignments in which the value's type does not match the type of the assigned variable.
    */
    "assign-type-mismatch": "Warning",
    /*
    Enable diagnostics for calls of asynchronous functions within a synchronous function.
    */
    "await-in-sync": "Warning",
    /*
    Enable diagnostics for calling a local variable or a literal whose every known type is one that cannot be called (a number, a string, a boolean). Anything that could be callable (a function, a table, a class, `any`, an unknown value, a union with one of those) is left alone, and so are field and method accesses, whose type is not certain; a value that may be `nil` is `need-check-nil`.
    */
    "cannot-call": "Warning",
    /*
    Enable diagnostics for casts of local variables where the target type does not match the defined type.
    */
    "cast-local-type": "Warning",
    /*
    Enable diagnostics for casts where the target type does not match the initial type.
    */
    "cast-type-mismatch": "Warning",
    /*
    Circular `@class` inheritance
    */
    "circle-doc-class": "Warning",
    /*
    Enable diagnostics for attempts to close a variable with a non-object.
    */
    "close-non-object": "Warning",
    /*
    Enable diagnostics for code placed after a break statement in a loop.
    */
    "code-after-break": "Hint",
    /*
    Enable diagnostics for incorrectly styled lines.
    */
    "codestyle-check": "Warning",
    /*
    Enable diagnostics for `for` loops which will never reach their max/limit because the loop is incrementing instead of decrementing.
    */
    "count-down-loop": "Warning",
    /*
    Enable diagnostics to highlight deprecated API.
    */
    "deprecated": "Warning",
    /*
    Enable diagnostics for files which are required by two different paths.
    */
    "different-requires": "Warning",
    /*
    Enable diagnostics for calls of functions annotated with `---@nodiscard` where the return values are ignored.
    */
    "discard-returns": "Warning",
    /*
    Enable diagnostics to highlight a field annotation without a defining class annotation.
    */
    "doc-field-no-class": "Warning",
    /*
    Enable diagnostics for a duplicated alias annotation name.
    */
    "duplicate-doc-alias": "Warning",
    /*
    Enable diagnostics for a duplicated field annotation name.
    */
    "duplicate-doc-field": "Warning",
    /*
    Enable diagnostics for a duplicated param annotation name.
    */
    "duplicate-doc-param": "Warning",
    /*
    Enable duplicate table index diagnostics.
    */
    "duplicate-index": "Warning",
    /*
    Enable diagnostics for setting the same field in a class more than once.
    */
    "duplicate-set-field": "Warning",
    /*
    Enable empty code block diagnostics.
    */
    "empty-block": "Hint",
    /*
    A table constructor given to a class has a field the class does not declare (the excess property check of TypeScript).
    */
    "excess-field": "Warning",
    /*
    Enable diagnostics for the type arguments of a class or an alias that do not satisfy the constraint of their type parameter (`Widget<number>` where `---@class Widget<T: Frame>`), and for calls of a generic function where an argument does not fit a `keyof` of another argument: the type bound to a type parameter does not satisfy a constraint that names another type parameter (`---@generic K: keyof T`), or the argument of a parameter typed `keyof T` (`---@param key keyof T`, `---@param ... keyof T`: every extra argument) is not a key of `T`. A constraint on its own (`---@generic T: Base`) is already reported by `param-type-mismatch`. The wowlua-ls diagnostic of the same name.
    */
    "generic-constraint-mismatch": "Warning",
    /*
    Enable diagnostics for calls of a generic function where two arguments bound to the same type parameter (`---@param a T`, `---@param b T`) have types that do not fit together: the first argument binds `T`, a later one has to be assignable to it (or be wider, which widens `T`).
    */
    "generic-param-mismatch": "Warning",
    /*
    Enable diagnostics to warn about global elements.
    */
    "global-element": "Warning",
    /*
    Enable cannot use global variables （ `_ENV` is set to `nil`） diagnostics.
    */
    "global-in-nil-env": "Warning",
    /*
    Enable diagnostics for return values that each fit their own slot but together match none of the cases of a tuple-union return annotation (`---@return (A, B) | (C, D)`).
    */
    "grouped-return-mismatch": "Warning",
    /*
    Enable diagnostics for a bare `return` in a function whose first `@return` is optional (`T?`): write `return nil` to say it on purpose.
    */
    "implicit-nil-return": "Hint",
    /*
    Enable diagnostics for a class that overrides a member of a class it inherits from with something that does not fit it (TypeScript's "class incorrectly extends"): a method that needs more arguments, takes or gives other types, or a field redeclared with a type that is not assignable to the parent's. A narrower type is an override; a wider or unrelated one is a collision. Only parents the user owns are judged: a member declared in a library outside the workspace (third-party annotations, which a polyfill class may re-annotate on purpose) is left alone.
    */
    "incompatible-override": "Information",
    /*
    Incomplete @param or @return annotations for functions.
    */
    "incomplete-signature-doc": "Warning",
    /*
    Injecting a field into an object
    */
    "inject-field": "Warning",
    /*
    Enable diagnostics for a `---@class Child : Parent` whose parent is a primitive type (`string`, `number`, `integer`, `boolean`, `true`, `false`, `nil`, `function`, `thread`): a class describes a table. `table`, `userdata` and `any` stay allowed. Off by default: `---@class Name : string` is also used on purpose, as a named string type.
    */
    "invalid-class-parent": "Warning",
    /*
    Enable diagnostics for a `---@guard x is T` / `---@asserts x is T` that is not of that form, or names something that is not a parameter of the function it is bound to.
    */
    "invalid-guard": "Warning",
    /*
    Enable diagnostics for a secret-context tag (`---@secret-when`, `---@secret-unless`, `---@secret-clears`, `---@secret-restriction-guard`, `---@secret-precondition`, `---@secret-satisfies`) that is not of its form, is not above a function, or names a parameter the function does not have.
    */
    "invalid-secret-context": "Warning",
    /*
    Enable diagnostics for a `---@secret-guard <parameter> <is-secret|accessible|any-secret>` that is not of that form, is not above a function, or names something that is not a parameter of that function.
    */
    "invalid-secret-guard": "Warning",
    /*
    Enable diagnostics for accesses to fields which are invisible.
    */
    "invisible": "Warning",
    /*
    Enable lowercase global variable definition diagnostics.
    */
    "lowercase-global": "Information",
    /*
    Missing fields
    */
    "missing-fields": "Warning",
    /*
    Missing annotations for globals! Global functions must have a comment and annotations for all parameters and return values.
    */
    "missing-global-doc": "Warning",
    /*
    Missing annotations for exported locals! Exported local functions must have a comment and annotations for all parameters and return values.
    */
    "missing-local-export-doc": "Warning",
    /*
    Enable diagnostics for a function that other files can reach (a global, a function of a global table, of an exported table) with a parameter that has no `---@param`. Local functions and file-private tables are not looked at (the wowlua-ls diagnostic of the same name).
    */
    "missing-param-annotation": "Hint",
    /*
    Enable diagnostics for function calls where the number of arguments is less than the number of annotated function parameters.
    */
    "missing-parameter": "Warning",
    /*
    Enable diagnostics for functions with return annotations which have no return statement.
    */
    "missing-return": "Warning",
    /*
    Enable diagnostics for a function that other files can reach (a global, a function of a global table, of an exported table) whose body returns a value but has no `---@return`. Local functions and file-private tables are not looked at (the wowlua-ls diagnostic of the same name).
    */
    "missing-return-annotation": "Hint",
    /*
    Enable diagnostics for return statements without values although the containing function declares returns.
    */
    "missing-return-value": "Warning",
    /*
    Enable diagnostics for an `---@enum` whose values are not all numbers or all strings: a value of another kind than the first literal one is reported, and so is a value that is neither (a boolean, a table, a function).
    */
    "mixed-enum-values": "Warning",
    /*
    Enable diagnostics for mutating a value through a reference declared `readonly` (`---@param t readonly T`, `---@type readonly T`): assigning one of its fields/indices, or passing it to a mutating stdlib call (`table.insert`, `table.remove`, `table.sort`, `rawset`).
    */
    "mutate-readonly": "Warning",
    /*
    Enable diagnostics for name style.
    */
    "name-style-check": "Warning",
    /*
    Enable diagnostics for variable usages if `nil` or an optional (potentially `nil`) value was assigned to the variable before.
    */
    "need-check-nil": "Warning",
    /*
    Enable newfield call diagnostics. It is raised when the parenthesis of a function call appear on the following line when defining a field in a table.
    */
    "newfield-call": "Warning",
    /*
    Enable newline call diagnostics. It's raised when a line starting with `(` is encountered, which is syntactically parsed as a function call on the previous line.
    */
    "newline-call": "Warning",
    /*
    Enable diagnostics for reading a table with a possibly-nil key through brackets (`t[k]` where `k` may be `nil`). Writing one is `need-check-nil`.
    */
    "nil-index": "Warning",
    /*
    Enable diagnostics for a table type whose key type includes `nil` (`table<string?, V>`): `nil` is not a valid table key.
    */
    "nil-table-key": "Warning",
    /*
    Enable diagnostics for cases in which the type cannot be inferred.
    */
    "no-unknown": "Warning",
    /*
    Enable diagnostics for a `---@tag` that none of the dialects listed in `Lua.annotations.dialects` knows (it is otherwise silently ignored).
    */
    "non-portable-annotation": "Hint",
    /*
    Enable diagnostics for a comparison whose left side is a bare `not x`: `not x == y` is `(not x) == y`, not `not (x == y)`. Brackets say which one is meant.
    */
    "not-precedence": "Warning",
    /*
    Enable diagnostics for calls to `coroutine.yield()` when it is not permitted.
    */
    "not-yieldable": "Warning",
    /*
    Enable diagnostics for calls of a method marked `---@requires T: Constraint` on a receiver whose class type argument for `T` does not satisfy the constraint (`Widget<number>` where the method requires `T: Frame`). The receiver may also inherit the method from a parent class (`---@class Numbers: Widget<number>`). The wowlua-ls diagnostic of the same name.
    */
    "param-constraint-mismatch": "Warning",
    /*
    Enable diagnostics for function calls where the type of a provided parameter does not match the type of the annotated function definition.
    */
    "param-type-mismatch": "Warning",
    /*
    Enable diagnostics for a field a method of a `---@class` declares by assigning it (`self.totl = 1`) whose name is one edit (a letter added, dropped (not a plural `s`) or changed, two swapped, or another case) away from a field the class declares.
    */
    "possible-field-typo": "Information",
    /*
    Enable redefined local variable diagnostics.
    */
    "redefined-local": "Hint",
    /*
    Enable diagnostics for `a and b` where `a` is always falsy (`b` is never evaluated) or always truthy (the `and` changes nothing).
    */
    "redundant-and": "Hint",
    /*
    Enable diagnostics for a method whose `---@generic` names a type parameter its class already declares (`---@class Box<T>`): the class-level one is the one in scope. The wowlua-ls diagnostic of the same name.
    */
    "redundant-class-generic": "Warning",
    /*
    Enable diagnostics for an `if` / `elseif` / `while` condition that is provably constant: always truthy or always falsy by its type, or a value compared with itself.
    */
    "redundant-condition": "Hint",
    /*
    Enable diagnostics for `a or b` where `a` is always truthy: `b` is never evaluated.
    */
    "redundant-or": "Hint",
    /*
    Enable redundant function parameter diagnostics.
    */
    "redundant-parameter": "Warning",
    /*
    Enable diagnostics for return statements which are not needed because the function would exit on its own.
    */
    "redundant-return": "Hint",
    /*
    Enable diagnostics for return statements which return an extra value which is not specified by a return annotation.
    */
    "redundant-return-value": "Warning",
    /*
    Enable diagnostics for a `---@secret-unwrap` on a local that is not secret, so there is nothing to unwrap.
    */
    "redundant-secret-unwrap": "Warning",
    /*
    Enable the redundant values assigned diagnostics. It's raised during assignment operation, when the number of values is higher than the number of objects being assigned.
    */
    "redundant-value": "Warning",
    /*
    Enable diagnostics for return values whose type does not match the type declared in the corresponding return annotation.
    */
    "return-type-mismatch": "Warning",
    /*
    Enable diagnostics for indexing (`s.x`, `s[k]`, `s:m()`), calling (`s()`) or iterating (`pairs(s)`, `ipairs(s)`, `next(s)`) a secret value before it is checked.
    */
    "secret-access": "Warning",
    /*
    Enable diagnostics for passing a secret value to a parameter that is declared `nosecret` (`---@param str nosecret string`).
    */
    "secret-argument": "Warning",
    /*
    Enable diagnostics for arithmetic or a unary operator (`-`, `#`, `~`) applied to a secret value before it is checked with a `---@secret-check` / `---@secret-access-check` / `---@secret-guard` function.
    */
    "secret-arithmetic": "Warning",
    /*
    Enable diagnostics for comparing a secret value (`==`, `~=`, `<`, `<=`, `>`, `>=`) before it is checked.
    */
    "secret-comparison": "Warning",
    /*
    Enable diagnostics for testing a secret boolean directly as a condition (`if s`, `not s`, `s and ...`) before it is checked. A secret that is not a boolean may still be tested for truthiness.
    */
    "secret-condition": "Warning",
    /*
    Enable diagnostics for assigning a secret value to a field that is declared `nosecret` (`---@field name nosecret string`).
    */
    "secret-field": "Warning",
    /*
    Enable diagnostics for returning a secret value from a function declared `nosecret` (`---@nosecret`, `---@return nosecret string`), and for a function declared both secret and `nosecret`.
    */
    "secret-return": "Warning",
    /*
    Enable diagnostics for using a secret value as a table key (`t[s]`, `t[s] = v`, `{ [s] = v }`) before it is checked.
    */
    "secret-table-key": "Warning",
    /*
    Enable diagnostics for assigning a secret value to a local declared `nosecret` (`---@type nosecret string`, `---@nosecret`), and for a local declared both secret and `nosecret`.
    */
    "secret-variable": "Warning",
    /*
    Enable diagnostics for typos in strings.
    */
    "spell-check": "Information",
    /*
    Enable diagnostics for a `## Category-xxXX:` whose text differs from the Addon Categories wiki page translation of the plain `## Category:` for that locale.
    */
    "toc-category-translation": "Hint",
    /*
    Enable diagnostics for a `## Key:` line that repeats a key whose lines do not add up (the last one wins, or only the first counts).
    */
    "toc-duplicate-header": "Warning",
    /*
    Enable diagnostics for a `.toc` file whose name does not match its folder.
    */
    "toc-file-name": "Warning",
    /*
    Enable diagnostics for an `## Interface` number that belongs to a game the file does not load on.
    */
    "toc-interface-mismatch": "Hint",
    /*
    Enable diagnostics for a `.toc` that loads on a game type none of whose `## Interface` numbers fits.
    */
    "toc-interface-missing-game": "Hint",
    /*
    Enable diagnostics for a `.toc` whose `## Interface` numbers all belong to games it does not load on: the client would mark it out of date.
    */
    "toc-interface-never-matches": "Warning",
    /*
    Enable diagnostics for an `## Interface` number below the lowest number worth declaring for its game today.
    */
    "toc-interface-too-low": "Hint",
    /*
    Enable diagnostics for an `## Interface` item that is not a whole number above 0.
    */
    "toc-invalid-interface": "Error",
    /*
    Enable diagnostics for a value that does not fit its directive: a flag that is not 0 or 1, an unknown game type or locale, an unknown or unclosed `[inline directive]`.
    */
    "toc-invalid-value": "Warning",
    /*
    Enable diagnostics for a `.toc` line over 1024 characters: the game reads only the first 1024.
    */
    "toc-line-too-long": "Warning",
    /*
    Enable diagnostics for a localized `Title-deDE` that comes before the plain `Title`, or has none: the localized ones go unused.
    */
    "toc-localized-before-base": "Hint",
    /*
    Enable diagnostics for a `.toc` file without an `## Interface` line.
    */
    "toc-missing-interface": "Warning",
    /*
    Enable diagnostics for a file line of a `.toc` that is not on disk.
    */
    "toc-nonexistent-file": "Warning",
    /*
    Enable diagnostics for a load condition that does not change where the line loads.
    */
    "toc-redundant-condition": "Hint",
    /*
    Enable diagnostics for a directive that only Blizzard code may use.
    */
    "toc-restricted-header": "Hint",
    /*
    Enable diagnostics for a `## Key:` the game dropped or renamed (`AllowLoadByGameMode`, `GuardedAddOn`, `SuppressLocalTableRef`): the line does nothing.
    */
    "toc-retired-header": "Warning",
    /*
    Enable diagnostics for a `.toc` file name suffix the game does not read any more (`_BCC`, `_WOTLK`): the file is ignored, rename it.
    */
    "toc-retired-suffix": "Warning",
    /*
    Enable diagnostics for a `# @diagnostic expect-next-line: toc-x` comment whose diagnostic does not occur on the next line.
    */
    "toc-unfulfilled-expect": "Warning",
    /*
    Enable diagnostics for a `## Category:` that is not one of the recommended names of the Addon Categories wiki page (a custom category is allowed, the page recommends its names).
    */
    "toc-unknown-category": "Hint",
    /*
    Enable diagnostics for a `## Key:` that is not a known directive, an `X-*` custom key or a localized variant.
    */
    "toc-unknown-header": "Hint",
    /*
    Enable diagnostics for a line of a `.toc` whose load conditions and file name suffix leave no game type it can load on.
    */
    "toc-unreachable-line": "Warning",
    /*
    Enable trailing space diagnostics.
    */
    "trailing-space": "Hint",
    /*
    Enable diagnostics on multiple assignments if not all variables obtain a value (e.g., `local x,y = 1`), also when the last value is a call of a function of the project that returns fewer values than there are variables.
    */
    "unbalanced-assignments": "Warning",
    /*
    Enable diagnostics for reading an element of a `T[]` array (`arr[i]`) in a context that treats the value as definitely not `nil` (arithmetic, further indexing, a call, a numeric `for` bound, ...). Off by default: a Lua array has no compile-time length, so most such reads are guarded by something the checker cannot see (a loop bound, a known constructor); this finds candidates to review.
    */
    "unchecked-array-index": "Warning",
    /*
    Enable diagnostics for class annotations in which an undefined class is referenced.
    */
    "undefined-doc-class": "Warning",
    /*
    Enable diagnostics for type annotations referencing an undefined type or alias.
    */
    "undefined-doc-name": "Warning",
    /*
    Enable diagnostics for cases in which a parameter annotation is given without declaring the parameter in the function definition.
    */
    "undefined-doc-param": "Warning",
    /*
    Enable undefined environment variable diagnostics. It's raised when `_ENV` table is set to a new literal table, but the used global variable is no longer present in the global environment.
    */
    "undefined-env-child": "Information",
    /*
    Enable diagnostics for cases in which an undefined field of a variable is read, also through an index that chooses between literal names (`t[flag and "a" or "b"]`).
    */
    "undefined-field": "Warning",
    /*
    Enable undefined global variable diagnostics.
    */
    "undefined-global": "Warning",
    /*
    Enable diagnostics for a name in `---@secret a, b` / `---@secret-unwrap a, b` / `---@nosecret a, b` that is not a local of the statement the tag applies to.
    */
    "undefined-secret-name": "Warning",
    /*
    Enable diagnostics for `---@diagnostic expect-next-line` / `expect-line` comments whose expected diagnostic did not occur, so a stale suppression cannot outlive the problem it hid.
    */
    "unfulfilled-expect": "Warning",
    /*
    Enable diagnostics for casts of undefined variables.
    */
    "unknown-cast-variable": "Warning",
    /*
    Enable diagnostics in cases in which an unknown diagnostics code is entered.
    */
    "unknown-diag-code": "Warning",
    /*
    Enable diagnostics for unknown operators.
    */
    "unknown-operator": "Warning",
    /*
    Enable diagnostics for unreachable code.
    */
    "unreachable-code": "Hint",
    /*
    Enable diagnostics for an entry of `Lua.diagnostics.globals` or `Lua.diagnostics.globalsRegex` in a project's settings file that does nothing: the global is defined, or nothing in the workspace uses it.
    */
    "unused-config-global": "Warning",
    /*
    Enable unused function diagnostics.
    */
    "unused-function": "Hint",
    /*
    Enable unused label diagnostics.
    */
    "unused-label": "Hint",
    /*
    Enable unused local variable diagnostics.
    */
    "unused-local": "Hint",
    /*
    Enable unused vararg diagnostics.
    */
    "unused-vararg": "Hint"
}
```

# diagnostics.unusedLocalExclude

Names that `unused-local` leaves alone, given as patterns.

`_*` skips every variable that starts with an underscore, the usual way to say "unused on purpose".


## type

```ts
Array<string>
```

## default

```jsonc
[]
```

# diagnostics.workspaceDelay

How long to wait, in milliseconds, after the trigger of `Lua.diagnostics.workspaceEvent` before the workspace diagnosis starts.

A longer delay avoids restarts while you keep editing.


## type

```ts
integer
```

## default

```jsonc
3000
```

# diagnostics.workspaceEvent

When the diagnostics of the files that are not open are (re)run.

`OnSave` (after the file is saved), `OnChange` (while you type, heavier), or `None` (never; only open files are checked).


## type

```ts
string
```

## enum

* ``"OnChange"``: Trigger workspace diagnostics when the file is changed.
* ``"OnSave"``: Trigger workspace diagnostics when the file is saved.
* ``"None"``: Disable workspace diagnostics.

## default

```jsonc
"OnSave"
```

# diagnostics.workspaceRate

How much of the CPU the workspace diagnosis may use, in percent.

A lower value keeps the machine responsive and makes the diagnosis of the other files slower. The file you are editing is always diagnosed at full speed.


## type

```ts
integer
```

## default

```jsonc
100
```

# doc.packageName

Treat the fields whose names match as `package`: they can be used only inside the file that declares them.

`m_*` makes `XXX.m_id` and `XXX.m_type` package.


## type

```ts
Array<string>
```

## default

```jsonc
[]
```

# doc.privateName

Treat the fields whose names match as `private`: they can be used only inside the class that declares them.

`m_*` makes `XXX.m_id` and `XXX.m_type` private.


## type

```ts
Array<string>
```

## default

```jsonc
[]
```

# doc.protectedName

Treat the fields whose names match as `protected`: they can be used only inside the class that declares them and its subclasses.

`m_*` makes `XXX.m_id` and `XXX.m_type` protected.


## type

```ts
Array<string>
```

## default

```jsonc
[]
```

# doc.regengine

The pattern syntax of the names in `Lua.doc.privateName`, `Lua.doc.protectedName` and `Lua.doc.packageName`.


## type

```ts
string
```

## enum

* ``"glob"``: The default lightweight pattern syntax.
* ``"lua"``: Full Lua-style regular expressions.

## default

```jsonc
"glob"
```

# docScriptPath

The regular expression engine used for matching documentation scope names.

## type

```ts
string
```

## default

```jsonc
""
```

# format.defaultConfig

The default options of the formatter, as a table of name to value (`indent_style`, `indent_size`, `max_line_length`, ...).

A `.editorconfig` in the workspace wins over this. See the [formatter docs](https://github.com/CppCXY/EmmyLuaCodeStyle/tree/master/docs).


## type

```ts
Object<string, string>
```

## default

```jsonc
{}
```

# format.enable

Offer the code formatter (format document, format selection, format on type).


## type

```ts
boolean
```

## default

```jsonc
true
```

# hint.arrayIndex

Show the index of each item in a table constructor (`{ [1] = "a", [2] = "b" }`).

`Auto` shows them in a mixed table or one with more than three items, `Enable` in every table, `Disable` never.


## type

```ts
string
```

## enum

* ``"Enable"``: Show hints in all tables.
* ``"Auto"``: Show hints only when the table is greater than 3 items, or the table is a mixed table.
* ``"Disable"``: Disable hints of array index.

## default

```jsonc
"Auto"
```

# hint.await

Show `await` in front of a call to a function marked `---@async`.


## type

```ts
boolean
```

## default

```jsonc
true
```

# hint.awaitPropagate

Treat a function that calls an `---@async` function as `---@async` itself, and show its `await` hints too.


## type

```ts
boolean
```

## default

```jsonc
false
```

# hint.enable

Show inlay hints: small grey texts the editor draws inside the code (parameter names, types, `await`, ...). The kinds are chosen by the other `Lua.hint.*` settings.


## type

```ts
boolean
```

## default

```jsonc
false
```

# hint.paramName

Show the name of the parameter in front of an argument in a call.

`All` for every argument, `Literal` only for literals and constants (where the meaning is not clear), `Disable` for none.


## type

```ts
string
```

## enum

* ``"All"``: All types of parameters are shown.
* ``"Literal"``: Only literal type parameters are shown.
* ``"Disable"``: Disable parameter hints.

## default

```jsonc
"All"
```

# hint.paramType

Show the type of each parameter at the function definition.


## type

```ts
boolean
```

## default

```jsonc
true
```

# hint.semicolon

Show a grey semicolon at the end of a statement that has none.

`SameLine` only between two statements on one line, `All` after every statement, `Disable` never.


## type

```ts
string
```

## enum

* ``"All"``: All statements display virtual semicolons.
* ``"SameLine"``: When two statements are on the same line, display a semicolon between them.
* ``"Disable"``: Disable virtual semicolons.

## default

```jsonc
"SameLine"
```

# hint.setType

Show the inferred type after the name of a variable in an assignment, as `x: number = 1`.


## type

```ts
boolean
```

## default

```jsonc
false
```

# hover.enable

Show the information card when the mouse rests on a name.


## type

```ts
boolean
```

## default

```jsonc
true
```

# hover.enumsLimit

The most members of a union or an enum the hover lists before it cuts the list with `...`.


## type

```ts
integer
```

## default

```jsonc
5
```

# hover.expandAlias

Show what an alias stands for.

`true`: a value of `---@alias myType boolean|number` shows as `boolean|number`. `false`: it shows as `myType`.


## type

```ts
boolean
```

## default

```jsonc
true
```

# hover.previewFields

The most fields of a table the hover lists.


## type

```ts
integer
```

## default

```jsonc
10
```

# hover.viewNumber

Show the decimal value of a number literal written in another base (`0xFF` shows 255).


## type

```ts
boolean
```

## default

```jsonc
true
```

# hover.viewString

Show the text of a string literal in the hover, when the source has escapes (`\n`, `\x41`) that make it hard to read.


## type

```ts
boolean
```

## default

```jsonc
true
```

# hover.viewStringMax

The most characters of a string the hover shows (see `Lua.hover.viewString`).


## type

```ts
integer
```

## default

```jsonc
1000
```

# language.completeAnnotation

(VS Code only) Continue a `---@` comment on the next line: pressing Enter inserts `---@ ` at the start of it.


## type

```ts
boolean
```

## default

```jsonc
true
```

# language.fixIndent

(VS Code only) Repair the indentation the editor guesses wrong, for example after a line break inside a string that contains the word `function`.


## type

```ts
boolean
```

## default

```jsonc
true
```

# misc.executablePath

The path of the language server executable the VS Code extension starts, when it should not use its own.


## type

```ts
string
```

## default

```jsonc
""
```

# misc.parameters

[Command line parameters](https://github.com/LuaLS/lua-telemetry-server/tree/master/method) the VS Code extension passes to the server when it starts it.


## type

```ts
Array<string>
```

## default

```jsonc
[]
```

# nameStyle.config

The naming rules the `name-style-check` diagnostic enforces (for example camelCase for locals, PascalCase for classes).

See the [formatter docs](https://github.com/CppCXY/EmmyLuaCodeStyle/tree/master/docs).


## type

```ts
Object<string, string | array>
```

## default

```jsonc
{}
```

# runtime.builtin

Switch the built-in libraries on or off by name (`basic`, `string`, `table`, `math`, `os`, `io`, `debug`, `package`, `coroutine`, `utf8`, `bit`, `bit32`, `jit`, `ffi`).

* `default`: on or off according to `Lua.runtime.version`
* `enable`: always on
* `disable`: always off. Use it when a framework replaces the library with its own (the WoW client has no `io`, `os` or `debug`).

```json
"Lua.runtime.builtin": { "io": "disable", "os": "disable" }
```


## type

```ts
object<string, string>
```

## enum

* ``"default"``
* ``"enable"``
* ``"disable"``

## default

```jsonc
{
    "basic": "default",
    "bit": "default",
    "bit32": "default",
    "builtin": "default",
    "coroutine": "default",
    "debug": "default",
    "ffi": "default",
    "io": "default",
    "jit": "default",
    "jit.profile": "default",
    "jit.util": "default",
    "math": "default",
    "os": "default",
    "package": "default",
    "string": "default",
    "string.buffer": "default",
    "table": "default",
    "table.clear": "default",
    "table.new": "default",
    "utf8": "default"
}
```

# runtime.enableLuaJITExtensions

Accept the LuaJIT syntax extensions (`0x1p4` hex floats, `1LL` and `1ULL` integer suffixes, the `ffi` literals).

Needs `Lua.runtime.version` to be `LuaJIT`. Each extension can also be switched on alone through `Lua.runtime.nonstandardSymbol`.


## type

```ts
boolean
```

## default

```jsonc
false
```

# runtime.fileEncoding

The text encoding of the source files.

`utf8` is right for nearly every project. `utf16le` and `utf16be` are for files saved as UTF-16; `ansi` follows the system code page and exists on Windows only.


## type

```ts
string
```

## enum

* ``"utf8"``
* ``"ansi"``
* ``"utf16le"``
* ``"utf16be"``

## default

```jsonc
"utf8"
```

# runtime.meta

The name of the folder the generated library files (the "meta" files for the built-in libraries) are written to.

`${version}`, `${language}` and `${encoding}` are replaced by the Lua version, the language of the server and `Lua.runtime.fileEncoding`.


## type

```ts
string
```

## default

```jsonc
"${version} ${language} ${encoding}"
```

# runtime.nonstandardSymbol

Accept syntax that is not standard Lua.

Each entry switches one form on (`+=`, `continue`, `//` comments, `?.`, ...). Turn on only what your runtime or preprocessor really supports: the editor otherwise accepts code that fails at run time.


## type

```ts
Array<string>
```

## enum

* ``"//"``: Line comment (C style).
* ``"/**/"``: Block comment (C style).
* ``"`"``: Backtick string literal.
* ``"+="``: Add compound assignment.
* ``"-="``: Subtract compound assignment.
* ``"*="``: Multiply compound assignment.
* ``"/="``: Divide compound assignment.
* ``"%="``: Modulo compound assignment.
* ``"^="``: Power compound assignment.
* ``"//="``: Floor-divide compound assignment.
* ``"|="``: Bitwise-or compound assignment.
* ``"&="``: Bitwise-and compound assignment.
* ``"<<="``: Left shift compound assignment.
* ``">>="``: Right shift compound assignment.
* ``"||"``: Logical or (equivalent to `or`).
* ``"&&"``: Logical and (equivalent to `and`).
* ``"!"``: Logical not (equivalent to `not`).
* ``"!="``: Not equal (equivalent to `~=`).
* ``"continue"``: `continue` statement.
* ``"|lambda|"``: Pipe-parameter short function (`|x| expr`).
* ``"?."``: Safe navigation (field/method: `a?.b` / `obj?.:method()` / `obj:method?.()`).
* ``"?.("``: Safe navigation call (`f?.()` / `f?."str"` / `f?.{...}` / `f?.[[...]]`).
* ``"?.["``: Safe navigation index (`t?.[key]`).
* ``"??"``: Nil-coalescing (`a ?? b`; takes the right side only when the left side is nil).
* ``"ternary"``: Ternary operator (`cond ? x : y`, right-associative; method calls forbidden in the `x` part).
* ``"~>>"``: Arithmetic right shift (`a ~>> b`, LuaJIT-specific; plain `>>` is logical).
* ``"~>>="``: Arithmetic right shift compound assignment (`a ~>>= b`).
* ``"..="``: String concatenation compound assignment (`a ..= b`).
* ``"~="``: Bitwise-xor compound assignment: only in statement context (e.g. `a ~= b` on its own line); in expressions it remains the not-equal operator.
* ``"const"``: `const` declaration (block-scoped local constant, cannot be reassigned or redeclared).
* ``"->"``: Short function arrow (`x -> expr` / `|x| -> expr` / `|| -> expr` / `-> do ... end`).
* ``"number_underscore"``: Underscores in number literals (e.g. `1_000`, `0x1_2`, `0b1_0`).
* ``"?("``: No-dot optional call (`f?()` equals `f?.()`; conflicts with ternary (`ternary`) parsing, not recommended together).
* ``"?["``: No-dot optional index (`t?[1]` equals `t?.[1]`; conflicts with ternary (`ternary`) parsing, not recommended together).
* ``"?:"``: No-dot safe method (`obj?:get()` equals `obj?.:get()`).

## default

```jsonc
[]
```

# runtime.path

Where `require 'name'` looks for a file.

Each entry is a pattern in which `?` stands for the name, with dots turned into folder separators: `?.lua` finds `myfile.lua`, `?/init.lua` finds `myfile/init.lua`. The patterns are tried inside the workspace and the libraries of `Lua.workspace.library`.

Unless `Lua.runtime.pathStrict` is on, a pattern is also tried in every sub folder (`${workspace}/**/myfile/init.lua`).


## type

```ts
Array<string>
```

## default

```jsonc
["?.lua","?/init.lua"]
```

# runtime.pathStrict

Search the `Lua.runtime.path` patterns from the root of the workspace only.

`true`: `require 'a.b'` finds only `<root>/a/b.lua`. `false`: it also finds `<root>/**/a/b.lua`, which is convenient but can pick a wrong file in a big project.


## type

```ts
boolean
```

## default

```jsonc
false
```

# runtime.plugin

A Lua file (or a list of them) that rewrites the text of every source file before it is parsed, and can help `require` find files.

A plugin runs arbitrary code, so the first load asks you to trust it. See `doc/en-us/plugin.md` and the [wiki](https://luals.github.io/wiki/plugins).


## type

```ts
string | array
```

## default

```jsonc
null
```

# runtime.pluginArgs

Extra arguments handed to the plugin of `Lua.runtime.plugin`.

Either a list (given to every plugin) or a table whose keys are a part of a plugin path and whose values are the arguments of that plugin.


## type

```ts
object | array
```

## default

```jsonc
null
```

# runtime.special

Treat a custom global function as a built-in one.

The key is the name you use, the value the built-in it behaves like (`require`, `dofile`, `loadfile`, `pcall`, `xpcall`, `assert`, `error`, `type`, `setmetatable`, `rawset`, `rawget`, `os.exit`, `_G`). The server then resolves its arguments the same way.

```json
"Lua.runtime.special": {
    "include": "require"
}
```


## type

```ts
Object<string, string>
```

## default

```jsonc
{}
```

# runtime.unicodeName

Allow Unicode letters in names.

`true`: `local größe = 1` is accepted. `false`: only ASCII letters, digits and `_` (the Lua standard) are, and a Unicode name is reported by the `unicode-name` syntax check.


## type

```ts
boolean
```

## default

```jsonc
false
```

# runtime.version

The Lua version the code is written for.

It decides which syntax is accepted (`goto` from 5.2, integer division and bit operators from 5.3, `<const>` and `<close>` from 5.4) and which standard library the server assumes (see `Lua.runtime.builtin`). Use `Lua 5.1` for World of Warcraft addons and `LuaJIT` for LuaJIT code (see `Lua.runtime.enableLuaJITExtensions`).


## type

```ts
string
```

## enum

* ``"Lua 5.1"``
* ``"Lua 5.2"``
* ``"Lua 5.3"``
* ``"Lua 5.4"``
* ``"Lua 5.5"``
* ``"LuaJIT"``

## default

```jsonc
"Lua 5.4"
```

# semantic.annotation

Colour the types and tags inside `---@` comments.


## type

```ts
boolean
```

## default

```jsonc
true
```

# semantic.enable

Colour the code from what the server knows about it (a parameter, a global, a type) instead of from the grammar alone.

The editor must have `editor.semanticHighlighting.enabled` on.


## type

```ts
boolean
```

## default

```jsonc
true
```

# semantic.keyword

Colour keywords, literals and operators from the server too.

Only needed when the editor has no grammar for Lua of its own.


## type

```ts
boolean
```

## default

```jsonc
false
```

# semantic.variable

Colour variables, fields and parameters by kind (local, global, parameter, field, ...).


## type

```ts
boolean
```

## default

```jsonc
true
```

# signatureHelp.enable

Show the parameter list and the current argument while you type a call.


## type

```ts
boolean
```

## default

```jsonc
true
```

# spell.dict

Words the spell check (`spell-check` diagnostic) accepts.


## type

```ts
Array<string>
```

## default

```jsonc
[]
```

# type.castNumberToInteger

Let a `number` be assigned to an `integer`.

`true`: it fits, as in the original LuaLS, which suits code that computes with plain numbers. `false` (strict): a `number` does not fit an `integer`, because it may have a fraction. The other way round, `integer` to `number`, always works.


## type

```ts
boolean
```

## default

```jsonc
true
```

# type.checkFieldNilArguments

Check the `nil` of a field that is passed as an argument.

`true` (the default): the field is checked like a variable, and narrowed like one: `if obj.field then f(obj.field) end` and `f(obj.field or {})` are fine.

`false` (the original LuaLS): `nil` is taken out of `f(obj.field)` before it is checked, so a `table?` field can be passed for a `table` parameter. The original could not narrow fields.

The `nil` of a field is checked even under `Lua.type.weakUnionCheck` (which takes a union as fitting when one member does), unless `Lua.type.weakNilCheck` ignores `nil`.


## type

```ts
boolean
```

## default

```jsonc
true
```

# type.checkTableShape

Require a table value to have the fields of the class it is assigned to: a missing field is a type mismatch.

Off by default, because a table built in steps (`setmetatable({}, Meta)`, a mixin) is reported while it is still incomplete.


## type

```ts
boolean
```

## default

```jsonc
false
```

# type.inferParamType

Infer the type of a parameter that has no annotation from the arguments the function is called with.

`false`: such a parameter is `any`. `true`: it takes the types of the calls, which finds more but can produce surprising errors in a function with many callers.


## type

```ts
boolean
```

## default

```jsonc
false
```

# type.inferTableSize

The most fields of a table constructor the server looks at when it infers the type of the table.

A low value keeps the inference of big data tables cheap.


## type

```ts
integer
```

## default

```jsonc
10
```

# type.maxUnionVariants

How many variants of a union type `Lua.type.weakUnionCheck` compares before it stops.

`0` (the default) compares all of them. A limit trades precision for speed on very large unions.


## type

```ts
integer
```

## default

```jsonc
0
```

# type.weakNilCheck

Ignore the `nil` of a union when checking.

`false` (strict): `number|nil` cannot be assigned to `number`. `true`: it can, as if the `nil` were not there.


## type

```ts
boolean
```

## default

```jsonc
false
```

# type.weakUnionCheck

Take a union as fitting once one of its members fits.

`false` (strict): `number|boolean` cannot be assigned to `number`, all members must fit. `true`: it can.


## type

```ts
boolean
```

## default

```jsonc
false
```

# typeFormat.config

Configures the formatting behavior while typing Lua code.

## type

```ts
object<string, string>
```

## default

```jsonc
{
    /*
    Controls if `end` is automatically completed at suitable positions.
    */
    "auto_complete_end": "true",
    /*
    Controls if a separator is automatically appended at the end of a table declaration.
    */
    "auto_complete_table_sep": "true",
    /*
    Controls if a line is formatted at all.
    */
    "format_line": "true"
}
```

# window.progressBar

Show a progress bar while the server loads and diagnoses the workspace.


## type

```ts
boolean
```

## default

```jsonc
true
```

# window.statusBar

Show the server status in the status bar of the editor.


## type

```ts
boolean
```

## default

```jsonc
true
```

# workspace.checkThirdParty

Offer to add the type definitions of a known third-party environment when the workspace uses it: OpenResty, Cocos4.0, LÖVE, LÖVR, skynet and Jass.

`Ask` asks once per workspace, `Apply` adds it without asking, `ApplyInMemory` adds it without writing a setting, `Disable` never offers.


## type

```ts
string | boolean
```

## default

```jsonc
null
```

# workspace.dofileRoots

Extra folders that `dofile` and `loadfile` may resolve a relative path in, besides the workspace.

The files there are loaded at once.


## type

```ts
Array<string>
```

## default

```jsonc
[]
```

# workspace.ignoreDir

Files and folders the server does not load, in `.gitignore` syntax.

```json
"Lua.workspace.ignoreDir": [".vscode", "Libs/", "**/*.min.lua"]
```


## type

```ts
Array<string>
```

## default

```jsonc
[".vscode"]
```

# workspace.ignoreSubmodules

Do not load the files of git submodules.

`true` is right when a submodule is a library you only use; set it to `false` when the submodule holds code you work on.


## type

```ts
boolean
```

## default

```jsonc
true
```

# workspace.library

Folders outside the workspace whose Lua files are read as libraries.

The code in them is known to completion, hover and the type checks, but is not changed by renaming and is not diagnosed (see `Lua.diagnostics.libraryFiles`). Use it for annotation packages such as the WoW API annotations, or for a framework's sources.

```json
"Lua.workspace.library": ["~/.vscode/extensions/ketho.wow-api-0.22.3/Annotations/Core"]
```


## type

```ts
Array<string>
```

## default

```jsonc
[]
```

# workspace.maxPreload

The most files the server reads when it opens a workspace.

Files beyond the limit are loaded only when they are opened or required. Raise it for a very big project, lower it to open faster.


## type

```ts
integer
```

## default

```jsonc
5000
```

# workspace.preloadFileSize

The size, in KB, above which a file is not read when the workspace opens.

A file past the limit is skipped until you open it: the classes, aliases and globals it defines are unknown to the other files meanwhile (they report `undefined-doc-name`, `undefined-global`, ...). Parsing costs about 5 seconds for 850 KB of hand-written code, so the default (2000) keeps real source files in and leaves generated data tables (megabytes) out. Lower it to open big projects faster.


## type

```ts
integer
```

## default

```jsonc
2000
```

# workspace.tocFileArguments

Type the two arguments every addon file receives at its top level.

```lua
local addonName, ns = ...
local ns = select(2, ...)
```

The first is the folder name of the addon (a string literal). The second is the class `<Folder>NS` (see `Lua.workspace.tocNamespaceClass`), which takes new keys like a class written with `---@class` on that line. A `---@class` or `---@type` of your own on or above the line replaces it.

Only for files that have a `.toc` in their folder or above it.


## type

```ts
boolean
```

## default

```jsonc
false
```

# workspace.tocNamespaceClass

The class name of the namespace argument of an addon file (see `Lua.workspace.tocFileArguments`).

`{addon}` becomes the folder name of the addon (letters, digits and underscores): `{addon}NS` (the default), `{addon}.ns`, `{addon}_ns`. Use the same name in your own `---@class`, so the two merge.


## type

```ts
string
```

## default

```jsonc
"{addon}NS"
```

# workspace.tocSavedVariables

Treat the variables a WoW addon's `.toc` file saves as defined globals.

The names of `## SavedVariables:`, `## SavedVariablesPerCharacter:` and `## SavedVariablesMachine:` are no longer reported by `undefined-global`, `lowercase-global` or `global-element`. The `.toc` is the one in the folder of the file, or in the nearest folder above it that has one.


## type

```ts
boolean
```

## default

```jsonc
false
```

# workspace.useGitIgnore

Do not load what the `.gitignore` of the workspace lists.

`false` loads those files too (generated code, build output).


## type

```ts
boolean
```

## default

```jsonc
true
```

# workspace.userThirdParty

Paths to your own third-party configuration files, in the format of the [built-in ones](https://github.com/LuaLS/lua-language-server/tree/master/meta/3rd).


## type

```ts
Array<string>
```

## default

```jsonc
[]
```