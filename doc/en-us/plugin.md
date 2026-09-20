# User plugins (`Lua.runtime.plugin`)

A plugin is a Lua file that changes how the server reads your code: it can rewrite the text before
it is parsed, edit the syntax tree after, help `require` find a file, or give a function parameter
a type. (Plugins that add new **diagnostics** are a separate system: see
[diagnostic-plugin.md](diagnostic-plugin.md) and `Lua.diagnostics.pluginsDir` in [config.md](config.md).)

```jsonc
{
    "Lua.runtime.plugin": "plugin.lua",          // a path, or an array of paths, relative to the workspace
    "Lua.runtime.pluginArgs": ["--flag"]         // handed to every plugin, see below
}
```

## Trust

A plugin runs with the full power of the server, so it is loaded only after you agreed to it. The
first time a plugin path is seen the client asks; a *yes* is remembered in the `trusted` file next to
the server log. Clients that vouch for the workspace themselves set the `trustByClient` option, and
the server started with `TRUST_ALL_PLUGINS` skips the question.

## Writing a plugin

The file is run once per workspace load, in an environment where reading an unknown global falls
back to the server's own globals. **The globals it defines are its hooks**; every hook is optional.
The chunk itself receives three values: `...` is `(chunk, workspaceUri, args)`.
The folder of the plugin is added to `package.path`, so `require 'helper'` finds `helper.lua`
next to it.

| Hook | Called | Returns |
| --- | --- | --- |
| `OnSetText(uri, text)` | when a file's text is set, before parsing | a `string` (the new text), or a list of diffs `{ start = 1, finish = 2, text = '...' }` (the first and last byte of the original text to replace, 1-based, inclusive) |
| `OnTransformAst(uri, ast)` | after parsing, before the file is used | a replacement tree (`table`), or nothing when it edited `ast` in place. Anything else is ignored |
| `ResolveRequire(scopeUri, name, fromUri)` | for every `require 'name'` | a list of file uris; `nil` lets the server search as usual |
| `VM = { OnCompileFunctionParam = f }` | when the type of a function parameter without annotation is inferred | `f(next, func, param)`: call `next(func, param)` for the default, return `true` after you gave the parameter a type with `vm.setNode` |

```lua
function OnSetText(uri, text)
    -- treat `local x <mut> = 1` as plain Lua
    return (text:gsub('<mut>', '     '))
end
```

Rules the server follows:

- **Several plugins** run in the order of the `Lua.runtime.plugin` array. A plugin without the hook
  is skipped. When more than one returns something, the last non-`nil` result wins.
- **A plugin that fails** (an error while loading, running a hook, or a syntax error) is reported once
  per reload with the error text and skipped for that call; the other plugins keep working. A hook that
  takes longer than 0.1 s is logged.
- **The tree hooks are unstable API.** `parser.object` fields and `parser.guide` helpers change with
  the parser; keep a plugin's tests next to it (`test/plugins/ast`, `test/plugins/node` are examples).
