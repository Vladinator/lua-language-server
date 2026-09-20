# Writing a diagnostic plugin

A diagnostic plugin adds a diagnostic (and, if it wants, LuaDoc tags and flow narrowing) without a
line changed in the server. This is the guide to the pieces that exist; `script/core/diagnostics/extra/need-check-secret.lua`
is the complete example (a diagnostic, tags, keywords, narrowing and propagation in one file).

It is not the same thing as the `Lua.runtime.plugin` user plugins, which rewrite text and trees
([plugin.md](plugin.md)).

## Where a plugin lives

| Where | Loaded | Trust |
| --- | --- | --- |
| `script/core/diagnostics/extra/<name>.lua` | once, at server start | none: it ships with the server |
| the folder in `Lua.diagnostics.pluginsDir` | when the workspace loads | the same question as user plugins (`plugin-trust.lua`) |

Both are found by `core/diagnostics/custom-plugins.lua`, there is no list to add a line to and
none to remove one from. A file `<name>.test.lua` next to a plugin is its test, not a plugin.

**The one convention:** the file name (without `.lua`) is the name the plugin registers. The loader
uses it to find the check function of the diagnostic. A file that registers another name, that
does not `return` a function, or that collides with a diagnostic that exists, is skipped with a
warning in the log.

## The smallest plugin

```lua
-- extra/no-todo.lua: report `TODO` in strings
local protoDiagnostic = require 'proto.diagnostic'
local files           = require 'files'
local guide           = require 'parser.guide'

protoDiagnostic.register {
    'no-todo',
} {
    group       = 'strict',                -- the group it belongs to (settings, `groupSeverity`)
    severity    = 'Warning',               -- default severity
    status      = 'Any',                   -- 'Any': every file; 'Opened': only open files; 'None': off
    description = 'Enable diagnostics for a string that says `TODO`.',   -- English, shown in the settings
}

---@async
---@param uri      uri
---@param callback async fun(result: proto.diagnostic.result)
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end
    guide.eachSourceType(state.ast, 'string', function (source)
        if source[1] and source[1]:find('TODO', 1, true) then
            callback {
                start   = source.start,
                finish  = source.finish,
                message = 'A TODO left in a string.',
            }
        end
    end)
end
```

The check function gets a file and reports through `callback`. What `callback` takes is a
`proto.diagnostic.result`: `start` / `finish` (parser positions), `message`, and optionally `tags`,
`data` (handed back to code actions) and `related` (other locations, in this or another file).
The server fills in the severity and the `code` (the name). `await.delay()` between units of work keeps the
server responsive; a diagnostic that takes long on a file is logged.

Everything a plugin brings is derived from that one registration and needs nothing anywhere
else: the settings schema, the group in `Lua.diagnostics.groupSeverity` / `groupFileStatus`, `--checklevel`,
completion of the name after `---@diagnostic disable:`, and the documentation of the setting
(`tools/build-doc.lua` reads `description`).

## Settings the diagnostic reads

When a `Lua.diagnostics.*` setting changes, the workspace diagnosis does not restart: it runs again just the
diagnostics that read the setting. The server knows which built-in diagnostics read which setting; for a
plugin, say it in the registration:

```lua
protoDiagnostic.register { 'no-todo' } {
    ...
    reads = { 'Lua.diagnostics.globals' },   -- run me again when this changes
}
```

Without `reads`, a change of a setting your diagnostic reads is not seen until the next full pass
(a save, by default). The diagnostic's own severity and status need no entry.

`---@diagnostic expect-next-line` / `expect-line` comments work with plugin diagnostics like with
any other (the `unfulfilled-expect` check reads what every diagnostic suppressed, so a file with such
comments always gets all diagnostics).

## LuaDoc tags, keywords and attributes (`parser/docTags.lua`)

A plugin can teach the parser new tags. These are registries the parser consults, so nothing in `luadoc.lua` changes.

| Call | What it adds |
| --- | --- |
| `registerMarkerTag(name, docType, description?)` | `---@name`, a bare tag: a node `{ type = docType }` |
| `registerNameListTag(name, docType, description?)` | `---@name a, b`: also a list of names, as `node.names` (each `{ type = docType .. '.name' }`) |
| `registerBindRule(docType, rule)` | which declaration the tag binds to: `rule(doc, source, isParam)` |
| `registerFieldKeyword(keyword, resultField, description?)` | a word before a field name: `---@field name mykeyword string` sets `resultField` on the `doc.field` |
| `registerTypeKeyword(keyword, resultField, description?)` | a word before a type item: `---@param x mykeyword string`; only when a type follows it |
| `registerAttribute(docType, name, description?)` | an attribute in parentheses: `---@class (name) A` (`docType` is `doc.class`, `doc.alias` or `doc.enum`) |
| `registerContinuesAfterClassGroup(docType)`, `registerClassGroupDoc(docType)` | the tag may sit inside a `---@class` comment group / binds to the class |

Descriptions are what completion shows after `---@`, at the field-name and type positions, in the attribute
list, and what hover shows on the tag. Completion of the tags and keywords, the names of a name list,
hover and the colour of the tag word need nothing else. `parser/specials.lua` `register(name)` makes
calls to a global of that name `special` (like `pairs`), for a plugin that has to recognise them.

## Flags and narrowing (`vm/`)

A plugin that has to follow a property through assignments, calls and guards (as `need-check-secret`
does for "secret") uses these:

| Call | What for |
| --- | --- |
| `vm.registerPropagatingFlag(name)`, `vm.registerFlagDeriver(name, deriver)` | a boolean on a compiled node (`node:setFlag` / `hasFlag`), carried through merges and generics |
| `vm.registerGenesisRule(sourceType, rule)` | runs once for each compiled source of a type, and may set flags on its node |
| `vm.registerCallNarrowing { match, narrow }` | a call in a condition narrows its arguments (a "checker" function) |
| `vm.registerEqualityNarrowing { match, narrow }` | `x == literal` style narrowing |

Flow analysis is the tracer's job (`vm/tracer.lua`); these hooks give a plugin a place in it without
editing it.

## Tests: next to the plugin

`extra/no-todo.test.lua` is run by `test/diagnostics/init.lua` when, and only when, `extra/no-todo.lua`
exists; deleting the plugin deletes its tests. A `.test.lua` uses the usual diagnostic test form, where `<!...!>` marks
what must be reported and everything else must not be:

```lua
TEST [[
local s = <!"TODO: later"!>
local t = "done"
]]
```

The file is plain Lua, so it can also call the core APIs for what does not fit that form (completion,
hover and the colour of the plugin's tags: `need-check-secret.test.lua` does that at its end).

**A plugin must be removable.** Shared code and shared tests are generic and must pass with the whole `extra/`
folder deleted:

- test the registry machinery with the tags of `test/docfixture.lua`, never with a real plugin's;
- tests about what every plugin has in common take the plugins from `test/extra_diagnostics.lua`;
- no file outside the plugin names it (an example in a comment is fine).

Check it with `mv extra extra_off`, the suite (`bin/lua-language-server test.lua`), `mv` back.

## Checklist

1. The file name is the diagnostic name; the file `return`s `function (uri, callback)`.
2. `register` with `group`, `severity`, `status` and an English `description` (and `reads` if it reads settings).
3. A `<name>.test.lua` next to it.
4. If it has tags: descriptions on them, and a bind rule.
5. Run `py -3 tools/validate.py <files> --seeds 4`: a plugin that changes what other checks infer shows up as
   an order-dependent finding, and the suite proves the plugin can be removed.
