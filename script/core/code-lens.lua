local files  = require 'files'
local guide  = require 'parser.guide'
local await  = require 'await'
local conv   = require 'proto.converter'
local getRef = require 'core.reference'
local vm     = require 'vm'
local hierarchy = require 'core.type-hierarchy'
local lang   = require 'language'
local client = require 'client'

---@class parser.state
---@field package _codeLens? codeLens

---@class codeLens.resolving
---@field mode    'reference'|'implementations'|'overrides'
---@field source? parser.object
---@field name?   string the class (implementations) or the class that defines the overridden method (overrides)

---@class codeLens.result
---@field position integer
---@field id       integer

---@class codeLens
local mt = {}
mt.__index = mt
mt.type = 'codeLens'
mt.id = 0

---@param uri uri
---@return boolean
function mt:init(uri)
    self.state     = files.getState(uri)
    if not self.state then
        return false
    end
    ---@type uri
    self.uri       = uri
    ---@type codeLens.result[]
    self.results   = {}
    ---@type table<integer, codeLens.resolving>
    self.resolving = {}
    return true
end

---@param pos integer
---@param resolving codeLens.resolving
function mt:addResult(pos, resolving)
    self.id = self.id + 1
    self.results[#self.results+1] = {
        position = pos,
        id       = self.id,
    }
    self.resolving[self.id] = resolving
end

---@async
---@param id integer
---@return proto.command?
function mt:resolve(id)
    local resolving = self.resolving[id]
    if not resolving then
        return nil
    end
    if resolving.mode == 'reference' then
        return self:resolveReference(resolving.source)
    end
    if resolving.mode == 'implementations' then
        return self:resolveImplementations(resolving.name, resolving.source)
    end
    if resolving.mode == 'overrides' then
        return conv.command(lang.script('COMMAND_OVERRIDES', resolving.name), '', {})
    end
end

--- The class that defines the method `key` nearest above `class` in the `---@class A : B` chain, when there is one.
---@param uri   uri
---@param class vm.global the class of the method being defined
---@param key   string
---@return string?
local function overriddenClass(uri, class, key)
    ---@type string?
    local owner
    for _, set in ipairs(class:getSets(uri)) do
        if set.type == 'doc.class' then
            for _, ext in ipairs(set.extends or {}) do
                local parent = ext.type == 'doc.extends.name' and vm.getGlobal('type', ext[1])
                if parent then
                    vm.getClassFields(uri, parent, key, function (field)
                        if owner then
                            return
                        end
                        local fieldClass = vm.getParentClass(field --[[@as parser.object]])
                        owner = fieldClass and fieldClass.name
                    end)
                    if owner then
                        return owner
                    end
                end
            end
        end
    end
    return owner
end

---@async
function mt:collectHierarchy()
    await.delay()
    assert(self.state)
    guide.eachSourceType(self.state.ast, 'doc.class', function (doc)
        self:addResult(doc.start, {
            mode   = 'implementations',
            name   = doc.class[1],
            source = doc,
        })
    end)
    ---@param src parser.object
    local function check(src)
        local value = src.value
        if not value or value.type ~= 'function' then
            return
        end
        local key = guide.getKeyName(src)
        local class = vm.getParentClass(src)
        if type(key) ~= 'string' or not class then
            return
        end
        local owner = overriddenClass(self.uri, class, key)
        if owner then
            self:addResult(src.start, {
                mode = 'overrides',
                name = owner,
            })
        end
    end
    guide.eachSourceType(self.state.ast, 'setmethod', check)
    guide.eachSourceType(self.state.ast, 'setfield', check)
end

---@async
---@param name   string
---@param source parser.object the `---@class` line
---@return proto.command?
function mt:resolveImplementations(name, source)
    local subclasses = hierarchy.subtypes(self.uri, name)
    local count = #subclasses
    local title = lang.script(count == 1 and 'COMMAND_IMPLEMENTATION_COUNT_ONE' or 'COMMAND_IMPLEMENTATION_COUNT', count)
    if client.getOption('codeLensViewReferences') and source then
        ---@type location[]
        local locations = {}
        for _, item in ipairs(subclasses) do
            local state = files.getState(item.uri)
            if state then
                locations[#locations+1] = conv.location(
                    item.uri,
                    conv.packRange(state, item.nameStart, item.nameFinish)
                )
            end
        end
        return conv.command(title, 'lua.showReferences', {
            self.uri,
            conv.packPosition(self.state, source.start),
            locations,
        })
    end
    return conv.command(title, '', {})
end

---@async
function mt:collectReferences()
    await.delay()
    -- only called after a successful init(), which guarantees self.state
    assert(self.state)
    ---@async
    guide.eachSourceType(self.state.ast, 'function', function (src)
        local parent = src.parent
        if guide.isAssign(parent) then
            src = parent
        elseif parent.type == 'return' then
        else
            return
        end
        await.delay()
        self:addResult(src.start, {
            mode   = 'reference',
            source = src,
        })
    end)
end

---@async
---@param source parser.object
---@return proto.command?
function mt:resolveReference(source)
    local refs = getRef(self.uri, source.finish, false)
    local count = refs and #refs or 0
    if client.getOption('codeLensViewReferences') then
        ---@type location[]
        local locations = {}
        for _, ref in ipairs(refs or {}) do
            local state = files.getState(ref.uri)
            if state then
                locations[#locations+1] = conv.location(
                    ref.uri,
                    conv.packRange(state, ref.target.start, ref.target.finish)
                )
            end
        end
        local command = conv.command(
            lang.script('COMMAND_REFERENCE_COUNT', count),
            'lua.showReferences',
            {
                self.uri,
                conv.packPosition(self.state, source.start),
                locations,
            }
        )
        return command
    else
        local command = conv.command(
            lang.script('COMMAND_REFERENCE_COUNT', count),
            '',
            {}
        )
        return command
    end
end

---@async
---@param uri uri
---@return codeLens.result[]?
local function getCodeLens(uri)
    local state = files.getState(uri)
    if not state then
        return nil
    end
    local codeLens = setmetatable({}, mt)
    local suc = codeLens:init(uri)
    if not suc then
        return nil
    end
    state._codeLens = codeLens

    codeLens:collectReferences()
    codeLens:collectHierarchy()

    if #codeLens.results == 0 then
        return nil
    end

    return codeLens.results
end

---@async
---@param uri uri
---@param id integer
---@return proto.command?
local function resolve(uri, id)
    local state = files.getState(uri)
    if not state then
        return nil
    end
    local codeLens = state._codeLens
    if not codeLens then
        return nil
    end
    local command = codeLens:resolve(id)
    return command
end

return {
    codeLens = getCodeLens,
    resolve  = resolve,
}
