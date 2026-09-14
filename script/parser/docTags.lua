-- Registry that lets code outside parser.luadoc teach it new LuaDoc tags,
-- without editing luadoc.lua's own (file-local, unexported) dispatch
-- tables. Kept as a standalone parser-layer module -- not on the `vm`
-- table -- since luadoc.lua itself must not depend on vm (vm depends on
-- the parser, not the other way around).
local m = {}

---@type table<string, string>
local markerTags = {}

--- Register a "marker" LuaDoc tag that takes no arguments -- e.g.
--- `---@mytag` -- and just produces a bare
--- `{type = docType, start = ..., finish = ...}` node, the same shape as
--- `---@deprecated`.
---@param name    string tag name after the `@`, e.g. 'secret'
---@param docType string produced node's `.type`, e.g. 'doc.secret'
function m.registerMarkerTag(name, docType)
    markerTags[name] = docType
end

---@param name string
---@return string?
function m.getMarkerTagType(name)
    return markerTags[name]
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
---@param keyword     string
---@param resultField string
function m.registerFieldKeyword(keyword, resultField)
    fieldKeywords[keyword] = resultField
end

---@param keyword string
---@return string?
function m.getFieldKeyword(keyword)
    return fieldKeywords[keyword]
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
