local files      = require 'files'
local vm         = require 'vm'
local guide      = require 'parser.guide'
local findSource = require 'core.find-source'

---@class core.type-hierarchy.item
---@field name         string
---@field uri          uri
---@field start        integer the whole `---@class` line
---@field finish       integer
---@field nameStart    integer the class name
---@field nameFinish   integer

local accept = {
    ['doc.class.name']   = true,
    ['doc.type.name']    = true,
    ['doc.extends.name'] = true,
    ['local']            = true,
    ['getlocal']         = true,
    ['setlocal']         = true,
    ['getglobal']        = true,
    ['setglobal']        = true,
}

---@param doc parser.object a `doc.class`
---@return core.type-hierarchy.item
local function itemOf(doc)
    return {
        name       = doc.class[1],
        uri        = guide.getUri(doc),
        start      = doc.start,
        finish     = doc.finish,
        nameStart  = doc.class.start,
        nameFinish = doc.class.finish,
    }
end

---@param uri  uri
---@param name string
---@return parser.object[]
local function classDocs(uri, name)
    ---@type parser.object[]
    local docs = {}
    for _, doc in ipairs(vm.getDocSets(uri, name)) do
        if doc.type == 'doc.class' then
            docs[#docs+1] = doc
        end
    end
    return docs
end

--- The names a class extends (`---@class A : B, C`).
---@param doc parser.object a `doc.class`
---@return string[]
local function parentNames(doc)
    ---@type string[]
    local names = {}
    for _, ext in ipairs(doc.extends or {}) do
        if ext.type == 'doc.extends.name' then
            names[#names+1] = ext[1]
        end
    end
    return names
end

--- The class the name at the position is, as a hierarchy item: a class name in an annotation, or a variable that holds a class.
---@param uri      uri
---@param position integer
---@return core.type-hierarchy.item[]?
local function prepare(uri, position)
    local state = files.getState(uri)
    if not state then
        return nil
    end
    local source = findSource(state, position, accept)
    if not source then
        return nil
    end
    ---@type parser.object?
    local class
    if source.type == 'doc.class.name'
    or source.type == 'doc.type.name'
    or source.type == 'doc.extends.name' then
        class = classDocs(uri, source[1])[1]
    else
        for _, def in ipairs(vm.getDefs(source)) do
            if def.type == 'doc.class' then
                class = def
                break
            end
        end
    end
    if not class then
        return nil
    end
    return { itemOf(class) }
end

--- The classes `---@class name : Parent` extends.
---@param uri  uri
---@param name string
---@return core.type-hierarchy.item[]
local function supertypes(uri, name)
    ---@type core.type-hierarchy.item[]
    local items = {}
    ---@type table<string, true>
    local seen = {}
    for _, doc in ipairs(classDocs(uri, name)) do
        for _, parent in ipairs(parentNames(doc)) do
            local parentDoc = not seen[parent] and classDocs(uri, parent)[1]
            if parentDoc then
                seen[parent] = true
                items[#items+1] = itemOf(parentDoc)
            end
        end
    end
    return items
end

--- The classes that extend `name`.
---@param uri  uri
---@param name string
---@return core.type-hierarchy.item[]
local function subtypes(uri, name)
    ---@type core.type-hierarchy.item[]
    local items = {}
    ---@type table<string, true>
    local seen = {}
    for _, class in ipairs(vm.getGlobals('type')) do
        for _, doc in ipairs(class:getSets(uri)) do
            ---@type string?
            local className = doc.type == 'doc.class' and doc.class[1] or nil
            if className and not seen[className] then
                for _, parent in ipairs(parentNames(doc)) do
                    if parent == name then
                        seen[className] = true
                        items[#items+1] = itemOf(doc)
                        break
                    end
                end
            end
        end
    end
    table.sort(items, function (a, b)
        return a.name < b.name
    end)
    return items
end

return {
    prepare    = prepare,
    supertypes = supertypes,
    subtypes   = subtypes,
}
