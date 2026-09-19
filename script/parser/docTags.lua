-- Registry that lets code outside parser.luadoc teach it new LuaDoc tags,
-- without editing luadoc.lua's own (file-local, unexported) dispatch
-- tables. Kept as a standalone parser-layer module -- not on the `vm`
-- table -- since luadoc.lua itself must not depend on vm (vm depends on
-- the parser, not the other way around).
local guide = require 'parser.guide'

local m = {}

---@type table<string, string>
local markerTags = {}

--- Text shown next to a tag / keyword in completion, keyed by its name.
---@type table<string, string>
local tagDescriptions = {}

---@type table<string, string>
local keywordDescriptions = {}

---@param keywords table<string, string>
---@param prefix   string
---@return fun(): string?, string?
local function eachKeyword(keywords, prefix)
    ---@type string[]
    local names = {}
    for name in pairs(keywords) do
        names[#names+1] = name
    end
    table.sort(names)
    local i = 0
    return function ()
        i = i + 1
        local name = names[i]
        if name then
            return name, keywordDescriptions[prefix .. name]
        end
    end
end

--- Register a "marker" LuaDoc tag that takes no arguments -- e.g.
--- `---@mytag` -- and just produces a bare
--- `{type = docType, start = ..., finish = ...}` node, the same shape as
--- `---@deprecated`.
---@param name        string tag name after the `@`, e.g. 'secret'
---@param docType     string produced node's `.type`, e.g. 'doc.secret'
---@param description? string shown by completion (markdown)
function m.registerMarkerTag(name, docType, description)
    markerTags[name]       = docType
    tagDescriptions[name]  = description
end

--- The registered tag names (marker and name-list tags) with their descriptions, sorted by
--- name, for completion.
---@return fun(): string?, string?
function m.eachTag()
    ---@type string[]
    local names = {}
    for name in pairs(markerTags) do
        names[#names+1] = name
    end
    table.sort(names)
    local i = 0
    return function ()
        i = i + 1
        local name = names[i]
        if name then
            return name, tagDescriptions[name]
        end
    end
end

---@param name string
---@return string?
function m.getMarkerTagType(name)
    return markerTags[name]
end

---@type table<string, true>
local nameListTags = {}

--- Like registerMarkerTag, but the tag may also carry a comma separated list of
--- names -- `---@mytag a, b` -- produced as `node.names`, an array of
--- `{type = docType .. '.name', [1] = name}` nodes. The list is only taken when the
--- rest of the line is *exactly* such a list; anything else (a description, a
--- dangling comma) leaves the tag bare and the text is an ordinary comment, so
--- `---@mytag some words` keeps working as before.
---@param name        string tag name after the `@`, e.g. 'secret'
---@param docType     string produced node's `.type`, e.g. 'doc.secret'
---@param description? string shown by completion (markdown)
function m.registerNameListTag(name, docType, description)
    m.registerMarkerTag(name, docType, description)
    nameListTags[docType] = true
    -- so the tree walkers (hover, completion, references...) reach the names
    guide.registerChildren(docType, {'#names'})
end

---@param docType string
---@return boolean
function m.isNameListTag(docType)
    return nameListTags[docType] == true
end

---@type table<string, true>
local continuesAfterClassGroup = {}

--- Register a doc type that, appearing right after a `@class`/`@field`/
--- `@operator`, should not break that group's continuation (mirrors the
--- built-in doc.field/doc.operator/doc.comment/doc.overload/doc.source
--- allowance).
---@param docType string
function m.registerContinuesAfterClassGroup(docType)
    continuesAfterClassGroup[docType] = true
end

---@param docType string
---@return boolean
function m.continuesAfterClassGroup(docType)
    return continuesAfterClassGroup[docType] == true
end

---@alias parser.docTags.bindRule fun(doc: parser.object, source: parser.object, isParam: boolean): boolean

---@type table<string, parser.docTags.bindRule>
local bindRules = {}

--- Register how a custom doc type decides whether it binds to a given
--- declaration `source`. Checked as a fallback after the built-in
--- bindDoc cases; one rule per doc type.
---@param docType string
---@param rule    parser.docTags.bindRule
function m.registerBindRule(docType, rule)
    bindRules[docType] = rule
end

---@param docType string
---@return parser.docTags.bindRule?
function m.getBindRule(docType)
    return bindRules[docType]
end

---@type table<string, string>
local fieldKeywords = {}

--- Register an additional bare keyword usable right after `---@field`,
--- alongside the built-in visibility keywords (public/protected/private/
--- package) -- e.g. `---@field name mykeyword string` sets
--- `result[resultField] = true` on the produced doc.field node.
---@param keyword      string
---@param resultField  string
---@param description? string shown by completion (markdown)
function m.registerFieldKeyword(keyword, resultField, description)
    fieldKeywords[keyword] = resultField
    keywordDescriptions['field:' .. keyword] = description
end

--- The registered `---@field` keywords with their descriptions, sorted, for completion.
---@return fun(): string?, string?
function m.eachFieldKeyword()
    return eachKeyword(fieldKeywords, 'field:')
end

---@param keyword string
---@return string?
function m.getFieldKeyword(keyword)
    return fieldKeywords[keyword]
end

---@type table<string, string>
local typeKeywords = {}

--- Register a bare keyword usable in front of a type expression --
--- `---@type number, mykeyword string`, `---@param x mykeyword string`,
--- `---@return mykeyword string` -- like the field keywords above but per type item:
--- `result[resultField] = true` on the produced `doc.type` node. It only counts
--- as a keyword when another type follows it, so a class that happens to be
--- called like the keyword still parses as a type on its own.
---@param keyword      string
---@param resultField  string
---@param description? string shown by completion (markdown)
function m.registerTypeKeyword(keyword, resultField, description)
    typeKeywords[keyword] = resultField
    keywordDescriptions['type:' .. keyword] = description
end

--- The registered type keywords with their descriptions, sorted, for completion.
---@return fun(): string?, string?
function m.eachTypeKeyword()
    return eachKeyword(typeKeywords, 'type:')
end

---@param keyword string
---@return string?
function m.getTypeKeyword(keyword)
    return typeKeywords[keyword]
end

---@type table<string, true>
local classGroupDocTypes = {}

--- Register a doc type that, found alongside a `@class` in the same
--- comment group, binds directly to that class (like doc.secret does)
--- instead of going through the normal per-statement bindDoc dispatch.
---@param docType string
function m.registerClassGroupDoc(docType)
    classGroupDocTypes[docType] = true
end

---@param docType string
---@return boolean
function m.isClassGroupDoc(docType)
    return classGroupDocTypes[docType] == true
end

return m
