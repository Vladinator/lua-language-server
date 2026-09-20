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
        local desc = owner and docTags.getAttributeDescription(owner.type, source[1] --[[@as string]])
        if desc then
            md:add('md', ('`%s`'):format(source[1]))
            md:add('md', desc)
            return md, 0
        end
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
    ['doc.class.name'] = true,
    ['doc.enum.name']  = true,
    ['function']       = true,
    ['doc.module']     = true,
    ['doc.see.name']   = true,
}

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
        local name = docTags.getTagInfo(doc.type)
        if name then
            local from = docTags.isNameListTag(doc.type) and doc.start or doc.finish - #name
            if position >= from and position <= from + #name then
                return doc
            end
        end
    end
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
