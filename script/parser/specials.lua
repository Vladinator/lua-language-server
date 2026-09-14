-- Registry for extra builtin call names that should be recognized the
-- same way as the parser's own built-in Specials list (pairs, ipairs,
-- assert, type, etc. -- see bindSpecial in parser.compile) -- i.e. call
-- sites to a global of this name get `.special` set to it. Kept as a
-- standalone parser-layer module for the same reason parser.docTags is:
-- parser.compile must not depend on vm, only the reverse.
local m = {}

---@type table<string, true>
local registered = {}

---@param name string
function m.register(name)
    registered[name] = true
end

---@param name string
---@return boolean
function m.has(name)
    return registered[name] == true
end

return m
