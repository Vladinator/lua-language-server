-- The wowlua-ls restriction tags are accepted as syntax: they parse, bind to the function below them, have a description (completion,
-- hover) and belong to the wowluals dialect only.
local files   = require 'files'
local guide   = require 'parser.guide'
local docTags = require 'parser.docTags'

---@diagnostic disable: await-in-sync

local lines = {
    ['secret-unless']           = '---@secret-unless unit "player"',
    ['secret-when']             = '---@secret-when InCombat the unit is in combat',
    ['secret-clears']           = '---@secret-clears InCombat, InEncounter unit == false',
    ['secret-restriction-guard'] = '---@secret-restriction-guard Combat == true',
    ['secret-precondition']     = '---@secret-precondition NoSecrets Error it needs a clean context',
    ['secret-satisfies']        = '---@secret-satisfies NoSecrets unit',
    ['secret-aspect']           = '---@secret-aspect text',
}

for name, line in pairs(lines) do
    local docType = 'doc.' .. name
    assert(docTags.getMarkerTagType(name) == docType, name .. ': registered')
    local tagName, description = docTags.getTagInfo(docType)
    assert(tagName == name and description and description ~= '', name .. ': has a description')
    assert(table.concat(docTags.getTagFlavors(name), ',') == 'wowluals', name .. ': known to wowluals only')

    files.setText(TESTURI, line .. string.char(10) .. 'local function f(unit) end' .. string.char(10))
    local state = assert(files.getState(TESTURI))
    ---@type parser.object?
    local found
    guide.eachSourceType(state.ast, docType, function (doc)
        found = doc
    end)
    assert(found, name .. ': parsed')
    local bound = false
    guide.eachSourceType(state.ast, 'function', function (func)
        for _, doc in ipairs(func.bindDocs or {}) do
            if doc == found then
                bound = true
            end
        end
    end)
    assert(bound, name .. ': bound to the function below it')
    files.remove(TESTURI)
end

-- a tag nobody registered is not one of them
assert(docTags.getMarkerTagType('secret-nothing') == nil, 'an unknown tag stays unknown')
