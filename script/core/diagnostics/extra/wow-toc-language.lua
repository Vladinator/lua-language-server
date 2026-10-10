-- WoW `.toc` files as a language of their own (see TOC-SPEC.md in the docs repo): diagnostics, completion, hover and definition for the file
-- that lists an addon's metadata and the files it loads. The server does not parse a `.toc` as Lua: the code registers a FILE KIND
-- (script/file-kinds.lua) and lives in wow-toc/syntax.lua, with the data it works from in wow-toc/games.lua (game types, families, suffixes,
-- locales, Interface hints) and wow-toc/directives.lua (the `## Key: Value` directives, the `[Inline]` directives, the `[Variables]`).
-- This file only loads it: a feature plugin, it runs no Lua diagnostic. Deleting this file, the folder next to it and the test removes the
-- feature. Its tests are next to it (wow-toc-language.test.lua).
require 'core.diagnostics.extra.wow-toc.syntax'
require 'core.diagnostics.extra.wow-toc.editor'
