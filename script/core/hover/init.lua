local files      = require 'files'
local vm         = require 'vm'
local getLabel   = require 'core.hover.label'
local getDesc    = require 'core.hover.description'
local util       = require 'utility'
local findSource = require 'core.find-source'
local markdown   = require 'provider.markdown'
local guide      = require 'parser.guide'
local wssymbol   = require 'core.workspace-symbol'
local docTags    = require 'parser.docTags'
local diag       = require 'proto.diagnostic'

--- What each mode of a `---@diagnostic` comment does (hover over the mode word).
---@type table<string, string>
local diagnosticModes = {
    ['disable']          = 'Turns the listed diagnostics off from here to the end of the file, or until a matching `enable`. Without a list: all of them.',
    ['enable']           = 'Turns the listed diagnostics on again after a `disable`.',
    ['disable-next-line'] = 'Turns the listed diagnostics off for the next line only. Without a list: all of them.',
    ['disable-line']     = 'Turns the listed diagnostics off for the line this comment is on. Without a list: all of them.',
    ['expect-next-line'] = 'This fork: the next line must produce the listed diagnostics. They are silenced there, and `unfulfilled-expect` reports one that does not occur.',
    ['expect-line']      = 'This fork: the line this comment is on must produce the listed diagnostics. They are silenced there, and `unfulfilled-expect` reports one that does not occur.',
}

---@type table<string, true>
local memberTypes = {
    ['doc.type.string']  = true,
    ['doc.type.integer'] = true,
    ['doc.type.boolean'] = true,
}

--- The alias name for a literal that is a value of an alias (`---| "value" # description`, or `---@alias Mode "fast"|"slow"`): those
--- nodes hang straight under the type of the `---@alias`, and a member line carries its description as a plain string.
---@param source parser.object
---@return parser.object? aliasName the `doc.alias.name` node of the alias
local function aliasOfMember(source)
    if not memberTypes[source.type] then
        return nil
    end
    local list = source.parent
    local alias = list and list.parent
    if list and list.type == 'doc.type' and alias and alias.type == 'doc.alias' then
        return alias.alias
    end
    return nil
end

---@async
---@param source parser.object
---@param level integer
---@return markdown
---@return integer
local function getHover(source, level)
    local md        = markdown()
    ---@type table<parser.object, boolean>
    local defMark   = {}
    ---@type table<string, boolean>
    local labelMark = {}
    ---@type table<string, boolean>
    local descMark  = {}
    local totalMaxLevel = 0

    -- what a plugin registered: a tag (`---@secret`) or an attribute (`---@class (exact)`)
    local tagName, tagDesc = docTags.getTagInfo(source.type)
    if tagName then
        md:add('md', ('`@%s`'):format(tagName))
        if tagDesc then
            md:add('md', tagDesc)
        end
        return md, 0
    end
    if source.type == 'doc.attr.name' then
        local owner = source.parent and source.parent.parent
        local desc = owner and docTags.getAttributeDescription(owner.type, source[1])
        if desc then
            md:add('md', ('`%s`'):format(source[1]))
            md:add('md', desc)
            return md, 0
        end
    end

    if source.type == 'doc.diagnostic.name' then
        -- `---@diagnostic disable: unused-local`: what the diagnostic checks
        local data = diag.diagnosticDatas[source[1] --[[@as string]]]
        if data and data.description then
            md:add('md', ('`%s`'):format(source[1]))
            md:add('md', data.description)
            return md, 0
        end
        return md, 0
    end

    if source.type == 'doc.diagnostic' then
        -- `---@diagnostic disable-next-line: name`: what the mode does
        local description = diagnosticModes[source.mode]
        if description then
            md:add('md', ('`%s`'):format(source.mode))
            md:add('md', description)
        end
        return md, 0
    end

    local alias = aliasOfMember(source)
    if alias then
        -- `---| "fast" # runs quickly`: a value of the alias, with the description after the `#`
        md:add('lua', ('(alias member) %s: %s'):format(alias[1], vm.getInfer(source):view(guide.getUri(source))))
        local description = source.comment
        if type(description) == 'string' and description ~= '' then
            md:add('md', description)
        end
        return md, 0
    end

    if source.type == 'doc.return.name' then
        -- `---@return string result`: the name of the returned value, with its type
        local valueType = source.parent
        if valueType then
            md:add('lua', ('(return) %s: %s'):format(source[1], vm.getInfer(valueType):view(guide.getUri(source))))
        end
        return md, 0
    end

    if source.type == 'doc.see.name' then
        for _, symbol in ipairs(wssymbol(source[1], guide.getUri(source))) do
            if symbol.name == source[1] then
                source = symbol.source
                break
            end
        end
    end

    ---@async
    ---@param def parser.object
    ---@param checkLable? boolean
    ---@param oop? boolean
    local function addHover(def, checkLable, oop)
        if defMark[def] then
            return
        end
        defMark[def] = true

        if checkLable then
            local label, maxLevel = getLabel(def, oop, level)
            if maxLevel and totalMaxLevel < maxLevel then
                totalMaxLevel = maxLevel
            end
            if not labelMark[tostring(label)] then
                labelMark[tostring(label)] = true
                md:add('lua', label)
                md:splitLine()
            end
        end

        local desc  = getDesc(def)
        if not descMark[tostring(desc)] then
            descMark[tostring(desc)] = true
            md:add('md', desc)
            md:splitLine()
        end
    end

    ---@type boolean?
    local oop
    if vm.getInfer(source):view(guide.getUri(source)) == 'function' then
        local defs = vm.getDefs(source)
        -- make sure `function` is before `doc.type.function`
        ---@type table<parser.object, integer>
        local orders = {}
        for i, def in ipairs(defs) do
            if def.type == 'function' then
                orders[def] = i - 20000
            elseif def.type == 'doc.type.function' then
                orders[def] = i - 10000
            else
                orders[def] = i
            end
        end
        table.sort(defs, function (a, b)
            return orders[a] < orders[b]
        end)
        ---@type boolean?
        local hasFunc
        for _, def in ipairs(defs) do
            if guide.isOOP(def) then
                oop = true
            end
            if  def.type == 'function'
            and not vm.isVarargFunctionWithOverloads(def) then
                hasFunc = true
                addHover(def, true, oop)
            end
            if def.type == 'doc.type.function' then
                hasFunc = true
                addHover(def, true, oop)
            end
        end
        if not hasFunc then
            addHover(source, true, oop)
        end
    else
        addHover(source, true, oop)
        for _, def in ipairs(vm.getDefs(source)) do
            if def.type == 'global'
            or def.type == 'setlocal' then
                goto CONTINUE
            end
            if guide.isOOP(def) then
                oop = true
            end
            ---@type boolean?
            local isFunction
            if def.type == 'function'
            or def.type == 'doc.type.function' then
                isFunction = true
            end
            addHover(def, isFunction, oop)
            ::CONTINUE::
        end
    end

    return md, totalMaxLevel
end

local accept = {
    ['local']          = true,
    ['setlocal']       = true,
    ['getlocal']       = true,
    ['setglobal']      = true,
    ['getglobal']      = true,
    ['field']          = true,
    ['method']         = true,
    ['string']         = true,
    ['number']         = true,
    ['integer']        = true,
    ['doc.type.name']  = true,
    ['doc.param.name'] = true,
    ['doc.field.name'] = true,
    ['doc.alias.name'] = true,
    ['doc.generic.name'] = true,
    ['doc.diagnostic.name'] = true,
    ['doc.diagnostic'] = true,
    ['doc.class.name'] = true,
    ['doc.enum.name']  = true,
    ['function']       = true,
    ['doc.module']     = true,
    ['doc.see.name']   = true,
    ['doc.return.name'] = true,
    ['doc.type.string'] = true,
    ['doc.type.integer'] = true,
    ['doc.type.boolean'] = true,
    ['doc.cast.name']  = true,
    ['doc.type.function'] = true,
}

--- `---@return string result`: the name follows its type, outside the range of the type node (and so out of reach of the
--- general search)
---@param doc      parser.object
---@param position integer
---@return parser.object?
local function returnNameAt(doc, position)
    if doc.type ~= 'doc.return' then
        return nil
    end
    for _, returned in ipairs(doc.returns or {}) do
        local returnName = returned.name
        if returnName and position >= returnName.start and position <= returnName.finish then
            return returnName
        end
    end
    return nil
end

--- The tags plugins register (`---@secret`) and the attributes in parentheses. A marker tag node
--- has no width (it sits at the end of the tag), a name list tag starts at the tag name: the word
--- itself is what is hovered.
---@param state    parser.state
---@param position integer
---@return parser.object?
local function findPluginDoc(state, position)
    for _, doc in ipairs(state.ast.docs) do
        -- `---@class (exact) A`: the attributes lie before the start of the node, out of reach
        -- of the general search
        for _, name in ipairs(doc.docAttr and doc.docAttr.names or {}) do
            if position >= name.start and position <= name.finish then
                return name
            end
        end
        local returnName = returnNameAt(doc, position)
        if returnName then
            return returnName
        end
        local name = docTags.getTagInfo(doc.type)
        if name then
            if docTags.isArgumentTag(doc.type) then
                -- the tag word and the arguments after it: all of them show the tag's help
                if position >= doc.start and position <= doc.finish then
                    return doc
                end
            else
                local from = doc.finish - #name
                if position >= from and position <= from + #name then
                    return doc
                end
            end
        end
    end
end

--- The parameter a `---@param name T` tag is bound to: what the name in the tag stands for. (A tag naming no parameter of the
--- function is bound to nothing.)
---@param name parser.object a `doc.param.name`
---@return parser.object?
local function paramOfDocName(name)
    return name.parent and name.parent.bindSource
end

---@async
---@param uri uri
---@param position integer
---@param level integer
---@return markdown?
---@return parser.object?
---@return integer?
local function getHoverByUri(uri, position, level)
    local ast = files.getState(uri)
    if not ast then
        return nil
    end
    local source = findSource(ast, position, accept) or findPluginDoc(ast, position)
    if source and source.type == 'doc.diagnostic' then
        -- (only the mode word answers: the names after the colon have their own hover, the colon and the blanks none)
        local mode = source.mode
        if not (mode and position >= source.start and position < source.start + #mode) then
            source = nil
        end
    end
    if source and source.type == 'doc.field.name' then
        -- `---@field name T`: hover the field as a whole
        source = source.parent
    end
    if source and source.type == 'doc.cast.name' then
        -- `---@cast value string`: hover the variable that is cast
        source = guide.getLocal(source, source[1], source.start)
    end
    if source and source.type == 'doc.type.function' and not (source.parent and source.parent.type == 'doc.overload') then
        -- (only the signature of an `---@overload` answers: a function type inside another type has its own parts)
        source = nil
    end
    if source and source.type == 'doc.param.name' then
        -- `---@param value string`: hover the parameter itself (nothing for a name the function has no parameter of)
        source = paramOfDocName(source)
    end
    if not source then
        return nil
    end
    local hover, maxLevel = getHover(source, level)
    if SHOWSOURCE then
        hover:splitLine()
        hover:add('md', 'Source Info')
        hover:add('lua', util.dump(source, {
            deep = 1,
        }))
    end
    if SHOWNODE then
        hover:splitLine()
        hover:add('md', 'Node Info')
        hover:add('lua', util.dump(vm.compileNode(source), {
            deep = 1,
        }))
    end
    return hover, source, maxLevel
end

return {
    get   = getHover,
    byUri = getHoverByUri,
}
