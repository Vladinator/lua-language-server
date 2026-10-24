-- A file closed without saving is what is on disk again: the editor drops the changes that were not saved, and the server must not keep them (the files
-- that use it, hover and go to definition went on using the discarded text until the file changed on disk).
local lclient = require 'lclient'
local fs      = require 'bee.filesystem'
local util    = require 'utility'
local furi    = require 'file-uri'
local ws      = require 'workspace'
local files   = require 'files'
local await   = require 'await'

local rootPath = LOGPATH .. '/close-unsaved'
local rootUri  = furi.encode(rootPath)

fs.create_directories(fs.path(rootPath))
local DISK = 'local onDisk = 1\n'
util.saveFile(rootPath .. '/saved.lua', DISK)
util.saveFile(rootPath .. '/untouched.lua', DISK)

---@async
lclient():start(function (client)
    client:registerFakers()
    client:initialize {
        rootPath = rootPath,
        rootUri  = rootUri,
    }
    ws.awaitReady(rootUri)

    local savedUri     = furi.encode(rootPath .. '/saved.lua')
    local untouchedUri = furi.encode(rootPath .. '/untouched.lua')

    -- the editor opens a file, the user types, and closes it with "Don't save"
    client:notify('textDocument/didOpen', { textDocument = { uri = savedUri, languageId = 'lua', version = 1, text = DISK } })
    await.sleep(0.2)
    client:notify('textDocument/didChange', {
        textDocument   = { uri = savedUri, version = 2 },
        contentChanges = { { text = 'local discarded = 2\n' } },
    })
    await.sleep(0.5)
    assert(files.getText(savedUri) == 'local discarded = 2\n', 'the edited text is what the server has while the file is open')
    client:notify('textDocument/didClose', { textDocument = { uri = savedUri } })
    await.sleep(0.5)
    assert(files.getText(savedUri) == DISK, ('closed without saving: the text on disk again, got %q'):format(tostring(files.getText(savedUri))))

    -- a file that was only opened and closed is untouched
    client:notify('textDocument/didOpen', { textDocument = { uri = untouchedUri, languageId = 'lua', version = 1, text = DISK } })
    await.sleep(0.2)
    client:notify('textDocument/didClose', { textDocument = { uri = untouchedUri } })
    await.sleep(0.5)
    assert(files.getText(untouchedUri) == DISK)

    -- a file that is not on disk (a new, unsaved buffer): closing it does not fail and does not bring text from nowhere
    local newUri = furi.encode(rootPath .. '/never-saved.lua')
    client:notify('textDocument/didOpen', { textDocument = { uri = newUri, languageId = 'lua', version = 1, text = 'local fresh = 1\n' } })
    await.sleep(0.2)
    client:notify('textDocument/didClose', { textDocument = { uri = newUri } })
    await.sleep(0.5)
    assert(files.getText(newUri) ~= 'local discarded = 2\n')
end)
