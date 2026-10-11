local proto   = require 'proto.proto'
local define  = require 'proto.define'
local config  = require 'config'
local client  = require 'client'
local encoder = require 'encoder'
local lang    = require 'language'
local util    = require 'utility'
local diagd   = require 'proto.diagnostic'
local tm      = require 'text-merger'
local await   = require 'await'
local ws      = require 'workspace'
local files   = require 'files'

-- File KINDS: documents that are not Lua (a WoW addon's `.toc`) but that the server can still help with: diagnostics, completion, hover,
-- definition. A kind is registered by a plugin, like a diagnostic or a LuaDoc tag; the server then keeps the text of an open document of that
-- kind in this module (NOT in `files`: nothing may parse it as Lua, index it, or run the Lua diagnostics on it) and asks the kind.
--
-- A kind works with LSP positions (0-based line, character in the encoding the client negotiated). `m.toCharacter` / `m.fromCharacter`
-- convert between that and the byte offsets of a Lua string, so a kind can scan its text with ordinary string functions.
--
-- The diagnostics of a kind are ordinary diagnostic names: the kind registers them with `proto.diagnostic.register` and `fileKind = <id>`
-- (so that the Lua pipeline does not try to run them), which gives them the settings docs, `Lua.diagnostics.disable` and `severity`.

---@class fileKind.position
---@field line      integer
---@field character integer

---@class fileKind.range
---@field start fileKind.position
---@field end   fileKind.position

---@class fileKind.diagnostic
---@field code    string registered diagnostic name (`proto.diagnostic.register`, with `fileKind` set)
---@field range   fileKind.range
---@field message string
---@field tags?   integer[]

---@class fileKind.clientDiagnostic  a diagnostic as the client sends it back with a code action request
---@field code?    string|integer
---@field message? string
---@field range    fileKind.range

---@class fileKind.hover
---@field value  string markdown
---@field range? fileKind.range

---@class fileKind
---@field id                  string
---@field match               fun(uri: uri): boolean
---@field diagnose            fun(uri: uri, text: string): fileKind.diagnostic[]
---@field complete?           fun(uri: uri, text: string, position: fileKind.position): table[]?  LSP CompletionItem[]
---@field hover?              fun(uri: uri, text: string, position: fileKind.position): fileKind.hover?
---@field definition?         fun(uri: uri, text: string, position: fileKind.position): table[]?  LSP Location[]
---@field codeAction?         fun(uri: uri, text: string, range: fileKind.range, diagnostics: fileKind.clientDiagnostic[]): table[]?  LSP CodeAction[] (`edit.changes` / `edit.documentChanges` in LSP positions)
---@field triggerCharacters?  string[] characters that open completion in a document of this kind
---@field needsWorkspace?     boolean the diagnostics depend on the whole workspace: they wait until it is loaded and are made again when it reloads
---@field prepare?             async fun(uri: uri, text: string) with `needsWorkspace`: runs before every verdict, to build the full picture of the workspace (compile the files nobody opened); nothing is published before it ends

---@class file-kinds
local m = {}

---@type fileKind[]
local kinds = {}

---@class fileKind.document
---@field text    string
---@field version integer?
---@field kind    fileKind

---@type table<uri, fileKind.document>
local documents = {}

---@param kind fileKind
function m.register(kind)
    kinds[#kinds+1] = kind
end

--- The kind a uri is a document of, if any.
---@param uri uri
---@return fileKind?
function m.of(uri)
    for _, kind in ipairs(kinds) do
        if kind.match(uri) then
            return kind
        end
    end
    return nil
end

---@return string[]
function m.getTriggerCharacters()
    ---@type string[]
    local chars = {}
    for _, kind in ipairs(kinds) do
        for _, char in ipairs(kind.triggerCharacters or {}) do
            chars[#chars+1] = char
        end
    end
    return chars
end

---@return encoder.encoding
local function getEncoding()
    return (client.getOffsetEncoding():lower():gsub('%-', '')) --[[@as encoder.encoding]]
end

--- The character (in the client's encoding) of a byte offset in a line: `byteOffset` is 0-based, the number of bytes before the place.
---@param lineText   string
---@param byteOffset integer
---@return integer
function m.toCharacter(lineText, byteOffset)
    return encoder.len(getEncoding(), lineText:sub(1, byteOffset))
end

--- The number of bytes of a line before a character (in the client's encoding).
---@param lineText  string
---@param character integer
---@return integer
function m.fromCharacter(lineText, character)
    local encoding = getEncoding()
    if character <= 0 then
        return 0
    end
    if character >= encoder.len(encoding, lineText) then
        return #lineText
    end
    return encoder.offset(encoding, lineText, character + 1) - 1
end

---@param uri uri
---@return string?
function m.getText(uri)
    local document = documents[uri]
    return document and document.text
end

--- Whether a document of a kind is open: the Lua side must leave it alone.
---@param uri uri
---@return boolean
function m.isOpen(uri)
    return documents[uri] ~= nil
end

--- The diagnostics of a text of a kind, as the client gets them (the disabled ones left out, the severity of the settings applied).
---@param uri  uri
---@param kind fileKind
---@param text string
---@return table[]
function m.collectDiagnostics(uri, kind, text)
    ---@type table[]
    local result = {}
    local ok, found = xpcall(kind.diagnose, log.error, uri, text)
    for _, diag in ipairs(ok and found or {}) do
        if diagd.isEnabled(uri, diag.code, true) then
            local severity = diagd.getSeverity(uri, diag.code)
            result[#result+1] = {
                range    = diag.range,
                severity = define.DiagnosticSeverity[severity],
                source   = lang.script.DIAG_DIAGNOSTICS,
                code     = diag.code,
                message  = diag.message,
                tags     = diag.tags,
            }
        end
    end
    return result
end

---@param uri uri
local function send(uri)
    local document = documents[uri]
    if not document then
        return
    end
    local result = m.collectDiagnostics(uri, document.kind, document.text)
    proto.notify('textDocument/publishDiagnostics', {
        uri         = uri,
        version     = document.version,
        diagnostics = result,
    })
end

--- Sends the diagnostics of a document to the client.
---@param uri uri
function m.publish(uri)
    local document = documents[uri]
    if not document then
        return
    end
    if not document.kind.needsWorkspace then
        send(uri)
        return
    end
    -- a verdict about the workspace made while it loads, or before the files nobody opened are known, would be wrong: a wrong
    -- warning is noise, so nothing is sent until the picture is complete (a newer request replaces an older one that is still waiting)
    await.call(function () ---@async
        await.unique('file-kinds: publish ' .. uri)
        ws.awaitReady(uri)
        local now = documents[uri]
        if now and now.kind.prepare then
            now.kind.prepare(uri, now.text)
        end
        send(uri)
    end)
end

---@param uri     uri
---@param text    string
---@param version integer?
function m.open(uri, text, version)
    local kind = m.of(uri)
    if not kind then
        return
    end
    documents[uri] = { text = text, version = version, kind = kind }
    log.info(('file kind `%s`: opened %s'):format(kind.id, uri))
    m.publish(uri)
end

---@param uri     uri
---@param changes table[] LSP content changes
---@param version integer?
function m.change(uri, changes, version)
    local document = documents[uri]
    if not document then
        return
    end
    document.text = tm(document.text, nil, changes)
    document.version = version
    m.publish(uri)
end

---@param uri uri
function m.close(uri)
    if not documents[uri] then
        return
    end
    documents[uri] = nil
    proto.notify('textDocument/publishDiagnostics', {
        uri         = uri,
        diagnostics = {},
    })
end

--- Completion items for a position of an open document of a kind (nil: not ours, or nothing to offer).
---@param uri      uri
---@param position fileKind.position
---@return table[]?
function m.complete(uri, position)
    local document = documents[uri]
    if not document or not document.kind.complete then
        return nil
    end
    local ok, items = xpcall(document.kind.complete, log.error, uri, document.text, position)
    return ok and items or nil
end

---@param uri      uri
---@param position fileKind.position
---@return table?
function m.hover(uri, position)
    local document = documents[uri]
    if not document or not document.kind.hover then
        return nil
    end
    local ok, hover = xpcall(document.kind.hover, log.error, uri, document.text, position)
    if not ok or not hover then
        return nil
    end
    return {
        contents = { kind = 'markdown', value = hover.value },
        range    = hover.range,
    }
end

---@param uri      uri
---@param position fileKind.position
---@return table[]?
function m.definition(uri, position)
    local document = documents[uri]
    if not document or not document.kind.definition then
        return nil
    end
    local ok, locations = xpcall(document.kind.definition, log.error, uri, document.text, position)
    return ok and locations or nil
end

--- Code actions for a range of an open document of a kind (`diagnostics` are the ones the client sent for it).
---@param uri         uri
---@param range       fileKind.range
---@param diagnostics fileKind.clientDiagnostic[]
---@return table[]?
function m.codeAction(uri, range, diagnostics)
    local document = documents[uri]
    if not document or not document.kind.codeAction then
        return nil
    end
    local ok, actions = xpcall(document.kind.codeAction, log.error, uri, document.text, range, diagnostics)
    if not ok or not actions or #actions == 0 then
        return nil
    end
    return actions
end

-- The documents that judge the workspace are judged again when it reloads.
ws.watch(function (ev)
    if ev ~= 'reload' then
        return
    end
    for uri, document in pairs(documents) do
        if document.kind.needsWorkspace then
            m.publish(uri)
        end
    end
end)

-- ... and when the code they judge changes: a Lua file that was compiled (its globals are known only then) or removed. Debounced, a
-- burst of edits is one new verdict.
files.watch(function (ev) ---@async
    if ev ~= 'compile' and ev ~= 'remove' then
        return
    end
    local any = false
    for _, document in pairs(documents) do
        if document.kind.needsWorkspace then
            any = true
        end
    end
    if not any then
        return
    end
    await.unique('file-kinds: judge the workspace again')
    await.sleep(1.0)
    for uri, document in pairs(documents) do
        if document.kind.needsWorkspace then
            m.publish(uri)
        end
    end
end)

-- A change of the diagnostic settings changes what is published for the open documents. `config.update` reports a changed key
-- only when the old configuration held it: a setting that the client sends for the first time (the configuration arrives after
-- a restored tab opened the document) is reported by the end-of-update event (key `''`) alone.
config.watch(function (_, key, value, oldValue)
    if key == '' or (util.stringStartWith(key, 'Lua.diagnostics') and value ~= oldValue) then
        for uri in pairs(documents) do
            m.publish(uri)
        end
    end
end)

return m
