# Writing a diagnostic plugin

A diagnostic plugin adds a diagnostic (and, if it wants, LuaDoc tags and flow narrowing) without a
line changed in the server. This is the guide to the pieces that exist; `script/core/diagnostics/extra/secret-access.lua`
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
diagnostics that read the setting. Each diagnostic says it in its own registration, built-in or plugin:

```lua
protoDiagnostic.register { 'no-todo' } {
    ...
    reads = { 'Lua.diagnostics.globals' },   -- run me again when this changes
}
```

Without `reads`, a change of a setting your diagnostic reads is not seen until the next full pass
(a save, by default). The diagnostic's own severity and status need no entry.

`reads` is safe for any setting (a change the server cannot narrow down still runs everything). A
diagnostic that owns a setting, one that nothing else reads (the built-in global checks and
`Lua.diagnostics.globals`), can list it in `narrowSettings` instead: the change then runs just the
diagnostics that list it, not all of them. Listing a setting other diagnostics read too leaves their results stale.

`---@diagnostic expect-next-line` / `expect-line` comments work with plugin diagnostics like with
any other. A diagnostic that needs the outcome of all the others says `afterAll = true` in its
registration (`unfulfilled-expect` does: it reports what the others did not suppress): it runs after the
rest, and a request for it, or for a file it says it must always see complete (`fullRunWhen = function (state)
... end`, for `unfulfilled-expect` a file with such comments), runs all the diagnostics.

## LuaDoc tags, keywords and attributes (`parser/docTags.lua`)

A plugin can teach the parser new tags. These are registries the parser consults, so nothing in `luadoc.lua` changes.

| Call | What it adds |
| --- | --- |
| `registerMarkerTag(name, docType, description?)` | `---@name`, a bare tag: a node `{ type = docType }` |
| `registerNameListTag(name, docType, description?)` | `---@name a, b`: also a list of names, as `node.names` (each `{ type = docType .. '.name' }`) |
| `registerGuardTag(name, docType, description?)` | `---@name x is T` / `---@name x is not T`: a parameter name and a type, as `node.param` (a name node), `node.extends` (a `doc.type`) and `node.negated`; anything else leaves the tag bare |
| `registerParamKindTag(name, docType, kinds, description?)` | `---@name x kind`: a parameter name (`...` for the vararg) and one word out of `kinds`, as `node.param` and `node.kind`; anything else leaves the tag bare |
| `registerKindParamsTag(name, docType, kinds, description?)` | `---@name kind [a b ...]`: one word out of `kinds`, then parameter names, as `node.kind` and `node.names`; anything else leaves the tag bare |
| `registerNameTypeTag(name, docType, description?)` | `---@name T: Type` / `---@name T extends Type`: a name and a type, as `node.name` (a type parameter token) and `node.extends`; the `extends` spelling also sets `kwStart` / `kwFinish`; anything else leaves the tag bare (the core's `@requires` uses it) |
| `registerBindRule(docType, rule)` | which declaration the tag binds to: `rule(doc, source, isParam)` |
| `registerFieldKeyword(keyword, resultField, description?)` | a word before a field name: `---@field name mykeyword string` sets `resultField` on the `doc.field` |
| `registerTypeKeyword(keyword, resultField, description?)` | a word before a type item: `---@param x mykeyword string`; only when a type follows it |
| `registerAttribute(docType, name, description?)` | an attribute in parentheses: `---@class (name) A` (`docType` is `doc.class`, `doc.alias` or `doc.enum`) |
| `registerTypeKeywordAlias(alias, keyword)` | another spelling of a registered type keyword: parsed the same, not offered by completion |
| `setTagFlavors(name, flavors)`, `setKeywordFlavors(keyword, flavors)` | which annotation dialects (`legacyluals`, `luals`, `wowluals`) know the tag / keyword, for the `non-portable-annotation` lint; the default is `luals` only |
| `registerContinuesAfterClassGroup(docType)`, `registerClassGroupDoc(docType)` | the tag may sit inside a `---@class` comment group / binds to the class |

Descriptions are what completion shows after `---@`, at the field-name and type positions, in the attribute
list, and what hover shows on the tag. Completion of the tags and keywords, the names of a name list,
hover and the colour of the tag word need nothing else. `parser/specials.lua` `register(name)` makes
calls to a global of that name `special` (like `pairs`), for a plugin that has to recognise them.

## Flags and narrowing (`vm/`)

A plugin that has to follow a property through assignments, calls and guards (as the secret diagnostics
do for "secret") uses these:

| Call | What for |
| --- | --- |
| `vm.registerPropagatingFlag(name)`, `vm.registerFlagDeriver(name, deriver)` | a boolean on a compiled node (`node:setFlag` / `hasFlag`), carried through merges and generics |
| `vm.registerGenesisRule(sourceType, rule)` | runs once for each compiled source of a type, and may set flags on its node |
| `vm.registerCallNarrowing { match, narrow }` | a call in a condition narrows its arguments (a "checker" function) |
| `vm.registerEqualityNarrowing { match, narrow }` | `x == literal` style narrowing |
| `vm.registerFlowNarrowing { match, narrowings }` | the same for the flow analysis (`vm/flow.lua`): `narrowings(call)` lists `{ target, whenTrue?, whenFalse?, after? }`, and the flow applies them on the right edges. `target` is an argument of the call or a made-up `getfield` node (`{ type = 'getfield', node = <base>, field = { type = 'field', [1] = name } }`) for a field the call is about, as `secret-access.lua` does for the keys of a guard |

Flow analysis is the tracer's job (`vm/tracer.lua`); these hooks give a plugin a place in it without
editing it.

## Feature plugins

A plugin that adds no diagnostic registers nothing with `proto.diagnostic` and returns nothing: the loader accepts it. It
extends the server through a registry of the core, and its tests sit next to it like any plugin's. What is about Lua in
general belongs in the core; what is about one host (a game, a product) goes in a plugin, and when it needs a hook the core
gets a generic one first.

| Call | What for |
| --- | --- |
| `proto.diagnostic.registerAlias(alias, canonical)` | another name of a diagnostic, accepted wherever a name is read from the user |
| `vm.registerGlobalProvider(fn)` | `fn(uri, name)` says a global exists although no Lua assigns it (the host creates it) |
| `vm.registerMainVarargProvider(fn)` | `fn(uri, index)` names the type of the argument the host passes to a file (`...` of the main chunk) |
| `require('core.diagnostics.helper.reachable-function').registerExportedLocalRule(rule)` | `rule(loc)` says a local table is shared with other files, so its functions count as reachable |

Test each hook in the shared tests with a fake name only that test uses, so they still pass with `extra/` removed.

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
hover and the colour of the plugin's tags: `secret-access.test.lua` does that at its end).

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
5. Run `py -3 tools/check_plugin_isolation.py --run` after a plugin or a shared hook: no word of a plugin in shared code, and the
   suite passes with `extra/` moved away.
6. Run `py -3 tools/validate.py <files> --seeds 4`: a plugin that changes what other checks infer shows up as
   an order-dependent finding, and the suite proves the plugin can be removed.
