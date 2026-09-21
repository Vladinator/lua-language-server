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

---@type table<string, string> # produced node type -> tag name
local tagByDocType = {}

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
    tagByDocType[docType]  = name
end

--- The registered tag that produces nodes of `docType`, with its description, for hover.
---@param docType string
---@return string? name
---@return string? description
function m.getTagInfo(docType)
    local name = tagByDocType[docType]
    if name then
        return name, tagDescriptions[name]
    end
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
local guardTags = {}

--- A tag that says something about a parameter of the function it is bound to and a type:
--- `---@mytag x is T` or `---@mytag x is not T`, produced as `{ type = docType, param = <name node>,
--- negated = <true when `not`>, extends = <doc.type> }`. Anything that does not read like that leaves
--- the tag bare (no `param`, no `extends`), so a plugin can report it.
---@param name        string tag name after the `@`, e.g. 'guard'
---@param docType     string produced node's `.type`, e.g. 'doc.guard'
---@param description? string shown by completion (markdown)
function m.registerGuardTag(name, docType, description)
    m.registerMarkerTag(name, docType, description)
    guardTags[docType] = true
    -- so the tree walkers (hover, completion, references, undefined-doc-name...) reach both parts
    guide.registerChildren(docType, {'param', 'extends'})
end

---@param docType string
---@return boolean
function m.isGuardTag(docType)
    return guardTags[docType] == true
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

---@type table<string, table<string, string>> # doc type -> attribute -> description
local attributes = {}

--- Register an attribute usable in parentheses right after a tag, e.g. `---@class (exact) A`
--- (`docType` is `doc.class`). The parser reads any name there; the checkers ask for the ones
--- they know (`vm.docHasAttr`), so this registry is what completion offers, and where a plugin
--- announces the attribute it reads.
---@param docType      string
---@param name         string
---@param description? string shown by completion (markdown)
function m.registerAttribute(docType, name, description)
    attributes[docType] = attributes[docType] or {}
    attributes[docType][name] = description or ''
end

---@param docType string
---@param name     string
---@return string?
function m.getAttributeDescription(docType, name)
    local set = attributes[docType]
    return set and set[name]
end

--- The attributes registered for `docType` with their descriptions, sorted, for completion.
---@param docType string
---@return fun(): string?, string?
function m.eachAttribute(docType)
    local set = attributes[docType] or {}
    ---@type string[]
    local names = {}
    for name in pairs(set) do
        names[#names+1] = name
    end
    table.sort(names)
    local i = 0
    return function ()
        i = i + 1
        local name = names[i]
        if name then
            return name, set[name]
        end
    end
end

-- the attributes of the language the core checkers read (an attribute only one diagnostic reads is
-- registered by that diagnostic's own file: `incremental` in missing-fields.lua)
m.registerAttribute('doc.class', 'exact', 'Fields that are assigned to this class but not declared are reported (`inject-field`).')
m.registerAttribute('doc.class', 'partial', 'The class may be declared again elsewhere; the declarations are merged and complete each other (`missing-fields`).')
m.registerAttribute('doc.alias', 'partial', 'The alias may be declared more than once; the declarations are merged (`duplicate-doc-alias`).')
m.registerAttribute('doc.enum', 'key', 'The enum stands for the keys of the table, not its values.')

return m
