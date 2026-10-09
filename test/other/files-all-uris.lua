-- files.getAllUris keeps the sorted list of a scope until a file is added or removed or a link of a scope changes: the same table comes back
-- while nothing changed, and every change that matters shows in the next list.
local files = require 'files'
local scope = require 'workspace.scope'
local furi  = require 'file-uri'

---@diagnostic disable: await-in-sync

---@param list uri[]
---@param uri  uri
---@return boolean
local function contains(list, uri)
    for _, item in ipairs(list) do
        if item == uri then
            return true
        end
    end
    return false
end

local inside = furi.encode(TESTROOT .. 'all-uris-inside.lua')
local linkDir = 'file:///all-uris-linked-dir'
local linked = linkDir .. '/lib.lua'

local before = files.getAllUris(TESTURI)
assert(rawequal(files.getAllUris(TESTURI), before), 'unchanged: the same list')
assert(not contains(before, inside), 'not there yet')

-- a file added shows
files.setText(inside, '')
local added = files.getAllUris(TESTURI)
assert(contains(added, inside), 'an added file shows')
assert(not rawequal(added, before), 'a new list after the change')
assert(rawequal(files.getAllUris(TESTURI), added), 'and it is kept again')

-- a change of its text is not a change of the set
files.setText(inside, 'local x = 1')
assert(rawequal(files.getAllUris(TESTURI), added), 'a text change keeps the list')

-- a file outside the scope is not in the list, until the scope links it
files.setText(linked, '')
assert(not contains(files.getAllUris(TESTURI), linked), 'outside the scope')
local scp = scope.getScope(TESTURI)
scp:addLink(linkDir)
assert(contains(files.getAllUris(TESTURI), linked), 'a linked file shows')
scp:removeLink(linkDir)
assert(not contains(files.getAllUris(TESTURI), linked), 'an unlinked file is gone')

-- a file removed is gone
files.remove(inside)
assert(not contains(files.getAllUris(TESTURI), inside), 'a removed file is gone')
files.remove(linked)

-- the list is sorted
local list = files.getAllUris(TESTURI)
for i = 2, #list do
    assert(list[i - 1] < list[i], 'sorted')
end
