local define       = require 'proto.define'
local files        = require 'files'
local matchKey     = require 'core.matchkey'
local vm           = require 'vm'
local getName      = require 'core.hover.name'
local getArgs      = require 'core.hover.args'
local getHover     = require 'core.hover'
local config       = require 'config'
local util         = require 'utility'
local markdown     = require 'provider.markdown'
local parser       = require 'parser'
local keyWordMap   = require 'core.completion.keyword'
local workspace    = require 'workspace'
local furi         = require 'file-uri'
local rpath        = require 'workspace.require-path'
local lang         = require 'language'
local lookBackward = require 'core.look-backward'
local guide        = require 'parser.guide'
local await        = require 'await'
local postfix      = require 'core.completion.postfix'
local diag         = require 'proto.diagnostic'
local wssymbol     = require 'core.workspace-symbol'
local findSource   = require 'core.find-source'
local diagnostic   = require 'provider.diagnostic'
local autoRequire  = require 'core.completion.auto-require'
local docTags      = require 'parser.docTags'

local diagnosticModes = {
    'disable-next-line',
    'disable-line',
    'disable',
    'enable',
    'expect-next-line',
    'expect-line',
}

---@class vm.completion.edit
---@field start integer
---@field finish integer
---@field newText string

--- One entry of the `results` array threaded through this whole file.
--- Fields beyond `label` are populated selectively by whichever
--- completion source produced this entry; see provider.lua's
--- 'textDocument/completion' handler for which of these actually cross
--- the wire to the client (the rest, like `match`, are used only
--- internally within this file for filtering/sorting).
---@class vm.completion.result
---@field label string
---@field kind? integer
---@field id? integer
---@field detail? string
---@field description? string|table
---@field deprecated? boolean
---@field sortText? string
---@field preselect? boolean
---@field filterText? string
---@field insertText? string
---@field insertTextFormat? integer
---@field commitCharacters? string[]
---@field command? table
---@field textEdit? vm.completion.edit
---@field additionalTextEdits? vm.completion.edit[]
---@field match? string
---@field isMethod? boolean

---@alias completion.results { [integer]: vm.completion.result, incomplete?: boolean, enableCommon?: boolean }

---@class vm.completion.resolved
---@field detail? string
---@field description? string|markdown
---@field additionalTextEdits? vm.completion.edit[]

--- The local, global or field a variable result was made from, to rank it by the type the place asks for (see `boostExpectedType`).
---@type table<vm.completion.result, parser.object>
local resultSources = setmetatable({}, { __mode = 'k' })

local stackID = 0
---@type table<integer, async fun(): vm.completion.resolved?>
local stacks = {}

---@param oldSource parser.object
---@param callback async fun(newSource: parser.object): vm.completion.resolved
---@return integer
local function stack(oldSource, callback)
    stackID = stackID + 1
    local uri = guide.getUri(oldSource)
    local pos = oldSource.start
    local tp  = oldSource.type
    ---@async
    stacks[stackID] = function ()
        local state = files.getState(uri)
        if not state then
            return
        end
        local newSource = findSource(state, pos, { [tp] = true })
        if not newSource and oldSource.synthetic then
            -- (a field of `A & B` or `Partial<A>` has no text of its own to find again: it is the source itself)
            newSource = oldSource
        end
        if not newSource then
            return
        end
        return callback(newSource)
    end
    return stackID
end

local function clearStack()
    stacks = {}
end

---@async
---@param id integer
---@return vm.completion.resolved?
local function resolveStack(id)
    local callback = stacks[id]
    if not callback then
        log.warn('Unknown resolved id', id)
        return nil
    end

    return callback()
end

---@param str string
---@return string?
local function trim(str)
    return str:match '^%s*(%S+)%s*$'
end

---@param state parser.state
---@param position integer
---@return parser.object?
local function findNearestSource(state, position)
    ---@type parser.object
    local source
    guide.eachSourceContain(state.ast, position, function (src)
        if not source or source.start <= src.start then
            source = src
        end
    end)
    return source
end

---@param state parser.state
---@param position integer
---@return parser.object?
local function findNearestTable(state, position)
    local uri  = state.uri
    local text = files.getText(uri)
    if not text then
        return nil
    end
    local offset  = guide.positionToOffset(state, position)
    local soffset = lookBackward.findAnyOffset(text, offset)
    if not soffset then
        return nil
    end
    local symbol = text:sub(soffset, soffset)
    if symbol == '}' then
        return nil
    end
    local sposition = guide.offsetToPosition(state, soffset)
    ---@type parser.object?
    local source
    guide.eachSourceContain(state.ast, sposition, function (src)
        if src.type == 'table' then
            source = src
        end
    end)

    if not source then
        return nil
    end

    for _, field in ipairs(source) do
        if field.start <= position and (field.range or field.finish) >= position then
            if field.type == 'tableexp' then
                local value = field.value
                if value
                and (value.type == 'getlocal'
                or   value.type == 'getglobal') then
                    if field.finish >= position then
                        return source
                    else
                        return nil
                    end
                end
            end
            if field.type == 'tablefield' then
                if field.finish >= position then
                    return source
                else
                    return nil
                end
            end
            if field.type == 'tableindex' then
                if field.index and field.index.type == 'string' then
                    if field.index.finish >= position then
                        return source
                    else
                        return nil
                    end
                end
            end
            return nil
        end
    end

    return source
end

---@param state parser.state
---@param position integer
---@return parser.object? parent
---@return boolean? oop
local function findParent(state, position)
    local text = state.lua
    if not text then
        return
    end
    local offset = guide.positionToOffset(state, position)
    for i = offset, 1, -1 do
        local char = text:sub(i, i)
        if lookBackward.isSpace(char) then
            goto CONTINUE
        end
        ---@type boolean
        local oop
        if     char == '.' then
            -- `..` 的情况
            if text:sub(i - 1, i - 1) == '.' then
                return nil, nil
            end
            oop = false
        elseif char == ':' then
            oop = true
        else
            return nil, nil
        end
        local anyOffset = lookBackward.findAnyOffset(text, i - 1)
        if not anyOffset then
            return nil, nil
        end
        local anyPos = guide.offsetToPosition(state, anyOffset)
        local parent = guide.eachSourceContain(state.ast, anyPos, function (source)
            if source.finish == anyPos then
                return source
            end
        end)
        if parent then
            return parent, oop
        end
        ::CONTINUE::
    end
    return nil, nil
end

---@param state parser.state
---@param position integer
---@return parser.object? parent
---@return boolean? oop
local function findParentInStringIndex(state, position)
    ---@type parser.object?
    local near
    ---@type integer?
    local nearStart
    guide.eachSourceContain(state.ast, position, function (source)
        local start = guide.getStartFinish(source)
        if not start then
            return
        end
        if not nearStart or nearStart < start then
            near = source
            nearStart = start
        end
    end)
    if not near or near.type ~= 'string' then
        return
    end
    local parent = near.parent
    if not parent or parent.index ~= near then
        return
    end
    -- index不可能是oop模式
    return parent.node, false
end

---@param source parser.object
---@param value  parser.object
---@param oop    boolean?
---@return string
local function buildFunctionSnip(source, value, oop)
    local name = (getName(source) or ''):gsub('^.+[$.:]', '')
    local args = getArgs(value)
    if oop then
        table.remove(args, 1)
    end

    ---@type string[]
    local snipArgs = {}
    for id, arg in ipairs(args) do
        local str, count = arg:gsub('^(%s*)(%.%.%.)(.+)', function (sp, word)
            return ('%s${%d:%s}'):format(sp, id, word)
        end)
        if count == 0 then
            str = arg:gsub('^(%s*)([^:]+)(.+)', function (sp, word)
                return ('%s${%d:%s}'):format(sp, id, word)
            end)
        end
        table.insert(snipArgs, str)
    end
    return ('%s(%s)'):format(name, table.concat(snipArgs, ', '))
end

---@param source parser.object
---@param node?   vm.node the type to show instead of the source's own
---@return string
local function buildDetail(source, node)
    local infer = vm.getInfer(node or source)
    local types = infer:view(guide.getUri(source))
    local literals = infer:viewLiterals()
    if literals then
        return types .. ' = ' .. literals
    else
        return types
    end
end

---@param source parser.object
---@return string?
local function getSnip(source)
    local context = config.get(guide.getUri(source), 'Lua.completion.displayContext')
    if context <= 0 then
        return nil
    end
    local defs = vm.getDefs(source)
    for _, def in ipairs(defs) do
        if def ~= source and def.type == 'function' then
            local uri = guide.getUri(def)
            local text = files.getText(uri)
            local state = files.getState(uri)
            if not state then
                goto CONTINUE
            end
            local lines = state.lines
            if not text then
                goto CONTINUE
            end
            if vm.isMetaFile(uri) then
                goto CONTINUE
            end
            local firstRow   = guide.rowColOf(def.start)
            local lastRow    = math.min(guide.rowColOf(def.finish) + 1, firstRow + context)
            local lastOffset = lines[lastRow] and (lines[lastRow] - 1) or #text
            local snip       = text:sub(lines[firstRow], lastOffset)
            return snip
        end
        ::CONTINUE::
    end
end

---@async
---@param source parser.object
---@return markdown
local function buildDesc(source)
    local desc = markdown()
    local hover = getHover.get(source, 1)
    desc:add('md', hover)
    desc:splitLine()
    desc:add('lua', getSnip(source))
    return desc
end

---@param results completion.results
---@param source  parser.object
---@param value   parser.object
---@param oop     boolean?
---@param data    vm.completion.result
local function buildFunction(results, source, value, oop, data)
    local snipType = config.get(guide.getUri(source), 'Lua.completion.callSnippet')
    local first = #results + 1
    if snipType == 'Disable' or snipType == 'Both' then
        results[#results+1] = data
    end
    if snipType == 'Both' or snipType == 'Replace' then
        local snipData = util.deepCopy(data)

        snipData.kind             = snipType == 'Both'
                                    and define.CompletionItemKind.Snippet
                                    or  data.kind
        snipData.insertText       = buildFunctionSnip(source, value, oop)
        snipData.insertTextFormat = 2
        snipData.command          = {
            title = 'trigger signature',
            command = 'editor.action.triggerParameterHints',
        }
        snipData.id               = stack(source, function (newSource) ---@async
            return {
                detail      = buildDetail(newSource),
                description = buildDesc(newSource),
            }
        end)

        results[#results+1] = snipData
    end
    -- (a function is ranked by the type the place asks for like any other variable)
    for i = first, #results do
        resultSources[results[i]] = source
    end
end

---@param state  parser.state
---@param source parser.object
---@param pos    integer
---@return boolean
local function isSameSource(state, source, pos)
    if guide.getUri(source) ~= guide.getUri(state.ast) then
        return false
    end
    if source.type == 'field'
    or source.type == 'method' then
        source = source.parent
    end
    return source.start <= pos and source.finish >= pos
end

---@param func parser.object
---@param oop  boolean?
---@return string
local function getParams(func, oop)
    if not func.args then
        return '()'
    end
    ---@type string[]
    local args = {}
    for _, arg in ipairs(func.args) do
        if     arg.type == '...' then
            args[#args+1] = '...'
        elseif arg.type == 'doc.type.arg' then
            args[#args+1] = arg.name[1]
        else
            args[#args+1] = arg[1]
        end
    end
    if oop and args[1] ~= '...' then
        table.remove(args, 1)
    end
    return '(' .. table.concat(args, ', ') .. ')'
end

--- A local declared without a type or a value (`local f`, then `f = ...` or `function f() end` later): what the assignments before the
--- cursor give it, which is what a hover on a use says (the declaration itself is `unknown`).
---@param source   parser.object a `local`
---@param position integer
---@return vm.node?
---@return parser.object? lastAssignment the last assignment before the cursor (its hover is the documentation of the item)
local function evolvedNodeOf(source, position)
    if source.type ~= 'local' or source.value then
        return nil
    end
    -- (a comment above the local binds to it as well; only a declared type makes it not evolve)
    for _, doc in ipairs(source.bindDocs or {}) do
        if doc.type == 'doc.type' or doc.type == 'doc.class' then
            return nil
        end
    end
    if source.parent and source.parent.type == 'funcargs' then
        return nil
    end
    ---@type vm.node?
    local node
    ---@type parser.object?
    local last
    for _, ref in ipairs(source.ref or {}) do
        if ref.type == 'setlocal' and ref.value and ref.start < position then
            node = node or vm.createNode()
            node:merge(vm.compileNode(ref))
            if not last or ref.start > last.start then
                last = ref
            end
        end
    end
    return node, last
end

--- The type a local has at the cursor when a use of it earlier in the same block (or one around the cursor) was narrowed: the word being
--- typed is not a reference yet, so the nearest earlier read stands for it. Nothing in between may assign the local, and the read must be
--- in the function the cursor is in. A narrowing made after that read (a condition between the two) is not seen: the node is then wider
--- than the hover will say, never wrong.
---@param source   parser.object a `local`
---@param position integer
---@return vm.node?
---@return parser.object? read the earlier read (its hover is the documentation of the item)
local function narrowedNodeOf(source, position)
    local root = guide.getRoot(source)
    ---@type parser.object
    local func = root
    guide.eachSourceContain(root, position, function (src)
        if src.type == 'function' then
            func = src
        end
    end)
    ---@type parser.object?
    local nearest
    for _, ref in ipairs(source.ref or {}) do
        if ref.start > position then
            goto CONTINUE
        end
        if ref.type == 'setlocal' then
            -- (an assignment between the read and the cursor ends the narrowing: start over after it)
            nearest = nil
        elseif ref.type == 'getlocal'
        and (not nearest or ref.start > nearest.start)
        and guide.getParentFunction(ref) == func then
            local block = guide.getBlock(ref)
            if block and block.start <= position and position <= block.finish then
                nearest = ref
            end
        end
        ::CONTINUE::
    end
    if not nearest then
        return nil
    end
    return vm.compileNode(nearest), nearest
end

--- The type a field has at the cursor when a read of it (`shape.sides`) earlier in the same block, or one around the cursor, was narrowed
--- (`if shape.sides then print(shape.<??>)`): the same earlier-read stand-in as `narrowedNodeOf`, for a field of a local. A call does not
--- end a narrowed field (the flow engine keeps field paths across calls); an assignment to the field or the local does.
---@param receiver parser.object the object before the dot, as completion found it
---@param name     string
---@param position integer
---@return vm.node?
---@return parser.object? read the earlier read of the field
local function narrowedFieldNodeOf(receiver, name, position)
    local source = receiver.type == 'getlocal' and receiver.node
    if not source then
        return nil
    end
    local root = guide.getRoot(source)
    ---@type parser.object
    local func = root
    guide.eachSourceContain(root, position, function (src)
        if src.type == 'function' then
            func = src
        end
    end)
    ---@type parser.object?
    local nearest
    for _, ref in ipairs(source.ref or {}) do
        if ref.start > position then
            goto CONTINUE
        end
        if ref.type == 'setlocal' then
            nearest = nil
        elseif ref.type == 'getlocal' and ref.next and ref.next.field and ref.next.field[1] == name
        and guide.getParentFunction(ref) == func then
            local field = ref.next
            if field.type == 'setfield' then
                nearest = nil
            elseif field.type == 'getfield' and field.finish < position and (not nearest or field.start > nearest.start) then
                local block = guide.getBlock(field)
                if block and block.start <= position and position <= block.finish then
                    nearest = field
                end
            end
        end
        ::CONTINUE::
    end
    if not nearest then
        return nil
    end
    local node = vm.compileNode(nearest)
    -- (the condition itself, `if shape.sides then <here>` / `while shape.sides do <here>`: the body is what its truth gives)
    local parent = nearest.parent
    if parent and parent.filter == nearest then
        node = node:copy():setTruthy()
    end
    return node, nearest
end

---@param state    parser.state
---@param word     string
---@param position integer
---@param results completion.results
local function checkLocal(state, word, position, results)
    local locals = guide.getVisibleLocals(state.ast, position)
    local showParams = config.get(state.uri, 'Lua.completion.showParams')
    for name, source in util.sortPairs(locals) do
        if isSameSource(state, source, position) then
            goto CONTINUE
        end
        if not matchKey(word, name) then
            goto CONTINUE
        end
        if name:sub(1, 1) == '@' then
            goto CONTINUE
        end
        if vm.getInfer(evolvedNodeOf(source, position) or source):hasFunction(state.uri) then
            local defs = vm.getDefs(source)
            -- (a local that is given its function later: the assignment stands for the function, and the documentation is the one
            -- of that assignment -- the hover of the declaration alone says `unknown`)
            ---@type table<parser.object, parser.object>
            local assignedBy = {}
            for i, def in ipairs(defs) do
                if def.type == 'setlocal' and def.value and def.value.type == 'function' then
                    assignedBy[def.value] = def
                    defs[i] = def.value
                end
            end
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
            for _, def in ipairs(defs) do
                if (def.type == 'function' and not vm.isVarargFunctionWithOverloads(def))
                or def.type == 'doc.type.function' then
                    ---@type string
                    local funcLabel
                    if showParams then
                        funcLabel = name .. getParams(def, false)
                    else
                        funcLabel = name
                    end
                    buildFunction(results, source, def, false, {
                        label      = funcLabel,
                        match      = name,
                        insertText = name,
                        kind       = define.CompletionItemKind.Function,
                        id         = stack(assignedBy[def] or source, function (newSource) ---@async
                            return {
                                detail      = buildDetail(newSource),
                                description = buildDesc(newSource),
                            }
                        end),
                    })
                end
            end
        else
            local res = {
                label  = name,
                kind   = define.CompletionItemKind.Variable,
                id     = stack(source, function (newSource) ---@async
                    local evolved, lastAssignment = evolvedNodeOf(newSource, position)
                    ---@type vm.node?
                    local narrowed
                    ---@type parser.object?
                    local read
                    if not evolved then
                        narrowed, read = narrowedNodeOf(newSource, position)
                    end
                    return {
                        detail      = buildDetail(newSource, evolved or narrowed),
                        description = buildDesc(lastAssignment or read or newSource),
                    }
                end),
            }
            resultSources[res] = source
            results[#results+1] = res
        end
        ::CONTINUE::
    end
end

--- The declared type of the parameter the cursor is at in a call `f(a, <??>)`: only when the call resolves to exactly one function
--- (an overloaded callee has no single expectation). A parameter that takes anything fits every variable, so nothing moves.
---@param state    parser.state
---@param position integer start of the word being typed
---@return vm.node?
local function getExpectedArgType(state, position)
    ---@type parser.object?
    local call
    guide.eachSourceContain(state.ast, position, function (src)
        if src.type == 'table' or src.type == 'function' then
            -- (a call inside the table is a new, nearer call: it is met later in this walk)
            call = nil
            return
        end
        if src.type == 'call' and src.node and src.node.finish <= position then
            call = src
        end
    end)
    if not call or not call.node then
        return nil
    end
    local index = 1
    for _, arg in ipairs(call.args or {}) do
        if arg.finish <= position then
            index = index + 1
        end
    end
    -- (the args of a colon call already hold the receiver as their first element)
    ---@type parser.object?
    local callee
    for obj in vm.compileNode(call.node):eachObject() do
        if obj.type == 'function' or obj.type == 'doc.type.function' then
            if callee then
                return nil
            end
            callee = obj
        end
    end
    local param = callee and callee.args and callee.args[index]
    if not param or param.type == '...' then
        return nil
    end
    local expected = vm.compileNode(param)
    if expected:isEmpty() then
        return nil
    end
    return expected
end

--- The declared type of the value the word is: `local x ---@type T = <??>`, `return <??>` in a function with `---@return T`, `x = <??>` of a
--- variable with a declared type, `obj.field = <??>` and `{ field = <??> }` of a declared field.
---@param state    parser.state
---@param position integer start of the word being typed
---@return vm.node?
local function getExpectedValueType(state, position)
    ---@type parser.object?
    local declared
    ---@type vm.node?
    local target
    guide.eachSourceContain(state.ast, position, function (src)
        -- (the word is the whole value: the parent of the name that starts at the cursor)
        local parent = src.start == position and src.parent
        if not parent then
            return
        end
        if parent.type == 'setlocal' and parent.value == src then
            -- `x = <??>` of a variable with a declared type (`---@type`, `---@param`)
            local locNode = vm.compileNode(parent.node)
            if locNode.hasDefined then
                target = locNode
            end
        elseif (parent.type == 'setfield' or parent.type == 'setglobal' or parent.type == 'setindex'
            or parent.type == 'tablefield' or parent.type == 'tableindex')
        and parent.value == src then
            -- `obj.field = <??>` and `{ field = <??> }`: the declared type of the field (a `---@field`, a `---@type` table)
            target = vm.compileNode(parent)
        elseif parent.type == 'local' and parent.value == src then
            for _, doc in ipairs(parent.bindDocs or {}) do
                if doc.type == 'doc.type' then
                    declared = doc
                end
            end
        elseif parent.type == 'return' then
            ---@type integer?
            local index
            for i, value in ipairs(parent) do
                if value == src then
                    index = i
                end
            end
            local func = index and guide.getParentFunction(parent)
            for _, doc in ipairs(func and func.bindDocs or {}) do
                if doc.type == 'doc.return' then
                    for _, rtn in ipairs(doc.returns) do
                        if rtn.returnIndex == index then
                            declared = rtn
                        end
                    end
                end
            end
        end
    end)
    local expected = target
    if not expected then
        if not declared then
            return nil
        end
        expected = vm.compileNode(declared)
    end
    if expected:isEmpty() then
        return nil
    end
    return expected
end

--- Is the node nothing but `unknown` or `any` (or empty)? Such a value is accepted everywhere and tells nothing about the place.
---@param uri  uri
---@param node vm.node
---@return boolean
local function isUnknownNode(uri, node)
    local view = vm.getInfer(node):view(uri)
    return view == 'unknown' or view == 'any'
end

--- Variables whose type fits what the place asks for come first, the rest keep their order (TypeScript preselects by the expected type).
---@param state    parser.state
---@param position integer
---@param results  completion.results
---@param from     integer the first result to rank
local function boostExpectedType(state, position, results, from)
    local expected = getExpectedArgType(state, position) or getExpectedValueType(state, position)
    if not expected then
        return
    end
    ---@type vm.completion.result[]
    local fits = {}
    ---@type vm.completion.result[]
    local others = {}
    for i = from, #results do
        local res = results[i]
        local source = resultSources[res]
        -- (a value of an unknown type fits every place; that says nothing, so it is not ranked as a fit)
        if source and not isUnknownNode(state.uri, vm.compileNode(source))
        and vm.isSubType(state.uri, vm.compileNode(source), expected) == true then
            fits[#fits+1] = res
        else
            others[#others+1] = res
        end
    end
    -- (the best match is the one the editor selects; when everything fits, or nothing does, the place does not tell the items apart)
    if #fits > 0 and #others > 0 then
        fits[1].preselect = true
    end
    local at = from
    for _, res in ipairs(fits) do
        results[at] = res
        at = at + 1
    end
    for _, res in ipairs(others) do
        results[at] = res
        at = at + 1
    end
end

---@param state    parser.state
---@param word     string
---@param position integer
---@param results completion.results
local function checkModule(state, word, position, results)
    if not config.get(state.uri, 'Lua.completion.autoRequire') then
        return
    end
    autoRequire.check(state, word, position, function (uri, stemName, targetSource)
        if not stemName or not targetSource then
            return
        end
        results[#results+1] = {
            label            = stemName,
            kind             = define.CompletionItemKind.Variable,
            commitCharacters = { '.' },
            command          = {
                title     = 'autoRequire',
                command   = 'lua.autoRequire',
                arguments = {
                    {
                        uri    = guide.getUri(state.ast),
                        target = uri,
                        name   = stemName,
                    },
                },
            },
            id               = stack(targetSource, function (newSource) ---@async
                local md = markdown()
                md:add('md', lang.script('COMPLETION_IMPORT_FROM', ('[%s](%s)'):format(
                    workspace.getRelativePath(uri),
                    uri
                )))
                md:add('md', buildDesc(newSource))
                return {
                    detail      = buildDetail(newSource),
                    description = md,
                    --additionalTextEdits = buildInsertRequire(state, originUri, stemName),
                }
            end)
        }
    end)
end

---@param state    parser.state
---@param name     string
---@param parent   parser.object
---@param word     string
---@param position integer
---@return vm.completion.edit? textEdit
---@return vm.completion.edit[]? additionalTextEdits
local function checkFieldFromFieldToIndex(state, name, parent, word, position)
    if name:match(guide.namePatternFull) then
        if not name:match '[\x80-\xff]'
        or config.get(state.uri, 'Lua.runtime.unicodeName') then
            return nil
        end
        name = ('%q'):format(name)
    end
    ---@type vm.completion.edit
    local textEdit
    ---@type vm.completion.edit[]?
    local additionalTextEdits
    local offset      = guide.positionToOffset(state, position)
    local wordStartOffset = offset - #word
    local wordStartPos = guide.offsetToPosition(state, wordStartOffset)
    local newText = ('[%s]'):format(name)
    textEdit = {
        start   = wordStartPos,
        finish  = position,
        newText = newText,
    }
    local nxt = parent.next
    if nxt then
        ---@type integer?, integer?
        local dotStart, dotFinish
        if     nxt.type == 'setfield'
        or     nxt.type == 'getfield'
        or     nxt.type == 'tablefield' then
            dotStart = nxt.dot.start
            dotFinish = nxt.dot.finish
        elseif nxt.type == 'setmethod'
        or     nxt.type == 'getmethod' then
            dotStart = nxt.colon.start
            dotFinish = nxt.colon.finish
        end
        if dotStart then
            additionalTextEdits = {
                {
                    start   = dotStart,
                    finish  = dotFinish --[[@as integer]],
                    newText = '',
                }
            }
        end
    else
        if config.get(state.uri, 'Lua.runtime.version') == 'Lua 5.1'
        or config.get(state.uri, 'Lua.runtime.version') == 'LuaJIT' then
            textEdit.newText = '_G' .. textEdit.newText
        else
            textEdit.newText = '_ENV' .. textEdit.newText
        end
    end
    return textEdit, additionalTextEdits
end

---@param state    parser.state
---@param name     string
---@param src      parser.object
---@param word     string
---@param position integer
---@param parent   parser.object
---@param oop      boolean?
---@param results completion.results
local function checkFieldThen(state, name, src, word, position, parent, oop, results)
    local value = vm.getObjectFunctionValue(src) or src
    local kind = define.CompletionItemKind.Field
    if (value.type == 'function' and not vm.isVarargFunctionWithOverloads(value))
    or value.type == 'doc.type.function' then
        local isMethod = value.parent.type == 'setmethod'
        if isMethod then
            kind = define.CompletionItemKind.Method
        else
            kind = define.CompletionItemKind.Function
        end
        buildFunction(results, src, value, oop, {
            label      = name,
            kind       = kind,
            isMethod   = isMethod,
            match      = name:match '^[^(]+',
            insertText = name:match '^[^(]+',
            deprecated = vm.getDeprecated(src) and true or nil,
            id         = stack(src, function (newSrc) ---@async
                return {
                    detail      = buildDetail(newSrc),
                    description = buildDesc(newSrc),
                }
            end),
        })
        return
    end
    if oop and not vm.getInfer(src):hasFunction(state.uri) then
        return
    end
    local literal = guide.getLiteral(value)
    if literal ~= nil then
        kind = define.CompletionItemKind.Enum
    end
    ---@type vm.completion.edit?
    local textEdit
    ---@type vm.completion.edit[]?
    local additionalTextEdits
    if parent.next and parent.next.index then
        local str = parent.next.index
        local str2 = str[2]
        textEdit = {
            start   = str.start + #str2,
            finish  = position,
            newText = name:sub(#str2 + 1, - #str2 - 1),
        }
    else
        textEdit, additionalTextEdits = checkFieldFromFieldToIndex(state, name, parent, word, position)
    end
    ---@type vm.completion.result
    local res = {
        label      = name,
        kind       = kind,
        deprecated = vm.getDeprecated(src) and true or nil,
        textEdit   = textEdit,
        id         = stack(src, function (newSrc) ---@async
            local narrowed, read = narrowedFieldNodeOf(parent, name, position)
            return {
                detail      = buildDetail(newSrc, narrowed),
                description = buildDesc(read or newSrc),
            }
        end),

        additionalTextEdits = additionalTextEdits,
    }
    resultSources[res] = src
    results[#results+1] = res
end

---@async
---@param refs     parser.object[]
---@param state    parser.state
---@param word     string
---@param startPos integer
---@param position integer
---@param parent   parser.object
---@param oop      boolean?
---@param results completion.results
---@param locals?   table<string, parser.object>
---@param isGlobal? string
local function checkFieldOfRefs(refs, state, word, startPos, position, parent, oop, results, locals, isGlobal)
    ---@type table<string, parser.object>
    local fields = {}
    ---@type table<string, boolean>
    local funcs  = {}
    local count  = 0
    local maxSuggestCount = config.get(state.uri, 'Lua.completion.maxSuggestCount')
    for _, src in ipairs(refs) do
        if count > maxSuggestCount then
            results.incomplete = true
            break
        end
        local _, name = vm.viewKey(src, state.uri)
        if not name then
            goto CONTINUE
        end
        if isSameSource(state, src, startPos) then
            goto CONTINUE
        end
        name = tostring(name)
        if isGlobal and locals and locals[name] then
            goto CONTINUE
        end
        if not matchKey(word, name:gsub([=[^['"]]=], ''), count >= 100) then
            goto CONTINUE
        end
        if not vm.isVisible(parent, src) then
            goto CONTINUE
        end
        ---@type string?
        local funcLabel
        if config.get(state.uri, 'Lua.completion.showParams') then
            --- TODO determine if getlocal should be a function here too
            local value = vm.getObjectFunctionValue(src) or src
            if value.type == 'function'
            or value.type == 'doc.type.function' then
                if not vm.isVarargFunctionWithOverloads(value) then
                    funcLabel = name .. getParams(value, oop)
                    fields[funcLabel] = src
                    count = count + 1
                end
                if value.type == 'function' and value.bindDocs then
                    for _, doc in ipairs(value.bindDocs) do
                        if doc.type == 'doc.overload' then
                            funcLabel = name .. getParams(doc.overload, oop)
                            fields[funcLabel] = doc.overload
                        end
                    end
                end
                funcs[name] = true
                if fields[name] and not guide.isAssign(fields[name]) then
                    fields[name] = nil
                end
                goto CONTINUE
            end
        end
        local last = fields[name]
        if last == nil and not funcs[name] then
            fields[name] = src
            count = count + 1
            goto CONTINUE
        end
        if vm.getDeprecated(src) then
            goto CONTINUE
        end
        if guide.isAssign(src) then
            fields[name] = src
            goto CONTINUE
        end
        ::CONTINUE::
    end

    ---@type completion.results
    local fieldResults = {}
    for name, src in util.sortPairs(fields) do
        if src then
            checkFieldThen(state, name, src, word, position, parent, oop, fieldResults)
            await.delay()
        end
    end

    ---@type table<vm.completion.result, integer>
    local scoreMap = {}
    for i, res in ipairs(fieldResults) do
        scoreMap[res] = i
    end
    table.sort(fieldResults, function (a, b)
        local score1 = scoreMap[a]
        local score2 = scoreMap[b]
        if oop then
            if not a.isMethod then
                score1 = score1 + 10000
            end
            if not b.isMethod then
                score2 = score2 + 10000
            end
        else
            if a.isMethod then
                score1 = score1 + 10000
            end
            if b.isMethod then
                score2 = score2 + 10000
            end
        end
        return score1 < score2
    end)

    for _, res in ipairs(fieldResults) do
        results[#results+1] = res
    end
end

---@async
---@param state    parser.state
---@param word     string
---@param startPos integer
---@param position integer
---@param parent   parser.object
---@param oop      boolean?
---@param results completion.results
local function checkGlobal(state, word, startPos, position, parent, oop, results)
    local locals = guide.getVisibleLocals(state.ast, position)
    local globals = vm.getGlobalSets(state.uri, 'variable')
    checkFieldOfRefs(globals, state, word, startPos, position, parent, oop, results, locals, 'global')
end

---@async
---@param state  parser.state
---@param word   string
---@param start  integer
---@param position integer
---@param parent parser.object
---@param oop    boolean?
---@param results completion.results
local function checkField(state, word, start, position, parent, oop, results)
    if parent.tag == '_ENV' or parent.special == '_G' then
        local globals = vm.getGlobalSets(state.uri, 'variable')
        checkFieldOfRefs(globals, state, word, start, position, parent, oop, results)
    else
        local refs = vm.getFields(parent)
        checkFieldOfRefs(refs, state, word, start, position, parent, oop, results)
    end
end

---@param state parser.state
---@param word  string
---@param start integer
---@param results completion.results
local function checkTableField(state, word, start, results)
    local source = guide.eachSourceContain(state.ast, start, function (source)
        if  source.start == start
        and source.parent
        and source.parent.type == 'table' then
            return source
        end
    end)
    if not source then
        return
    end
    ---@type table<string, boolean>
    local used = {}
    guide.eachSourceType(state.ast, 'tablefield', function (src)
        if not src.field then
            return
        end
        local key = src.field[1] --[[@as string]]
        if  not used[key]
        and matchKey(word, key)
        and src ~= source then
            used[key] = true
            results[#results+1] = {
                label = key,
                kind  = define.CompletionItemKind.Property,
            }
        end
    end)
end

---@param state    parser.state
---@param word     string
---@param position integer
---@param results completion.results
local function checkCommon(state, word, position, results)
    local myUri = state.uri
    local text = state.lua
    if not text then
        return
    end
    local showWord = config.get(state.uri, 'Lua.completion.showWord')
    if showWord == 'Disable' then
        return
    end
    results.enableCommon = true
    if showWord == 'Fallback' and #results ~= 0 then
        return
    end
    ---@type table<string, boolean>
    local used = {}
    for _, result in ipairs(results) do
        used[result.label:match '^[^(]*'] = true
    end
    for _, data in ipairs(keyWordMap) do
        used[data[1]] = true
    end
    if config.get(state.uri, 'Lua.completion.workspaceWord') and #word >= 2 then
        local myHead = word:sub(1, 2)
        for uri in files.eachFile(state.uri) do
            if #results >= 100 then
                results.incomplete = true
                break
            end
            if myUri == uri then
                goto CONTINUE
            end
            local words = files.getWordsOfHead(uri, myHead)
            if not words then
                goto CONTINUE
            end
            for _, str in ipairs(words) do
                if #results >= 100 then
                    break
                end
                if  not used[str]
                and str ~= word then
                    used[str] = true
                    if matchKey(word, str) then
                        results[#results+1] = {
                            label = str,
                            kind  = define.CompletionItemKind.Text,
                        }
                    end
                end
            end
            ::CONTINUE::
        end
        for uri in files.eachDll() do
            if #results >= 100 then
                break
            end
            local words = files.getDllWords(uri) or {}
            for _, str in ipairs(words) do
                if #results >= 100 then
                    break
                end
                if #str >= 3 and not used[str] and str ~= word then
                    used[str] = true
                    if matchKey(word, str) then
                        results[#results+1] = {
                            label = str,
                            kind  = define.CompletionItemKind.Text,
                        }
                    end
                end
            end
        end
    end
    for str, offset in (text:gmatch('(' .. guide.namePattern .. ')()') --[[@as fun(): string, integer]]) do
        if #results >= 100 then
            results.incomplete = true
            break
        end
        if  #str >= 3
        and not used[str]
        and guide.offsetToPosition(state, offset - 1) ~= position then
            used[str] = true
            if matchKey(word, str) then
                results[#results+1] = {
                    label = str,
                    kind  = define.CompletionItemKind.Text,
                }
            end
        end
    end
end

---@param state      parser.state
---@param start      integer
---@param position   integer
---@param word       string
---@param hasSpace   boolean
---@param afterLocal boolean?
---@param results completion.results
---@return boolean?
local function checkKeyWord(state, start, position, word, hasSpace, afterLocal, results)
    local text = state.lua
    assert(text)
    local snipType = config.get(state.uri, 'Lua.completion.keywordSnippet')
    local symbol = lookBackward.findSymbol(text, guide.positionToOffset(state, start))
    local isExp = symbol == '(' or symbol == ',' or symbol == '=' or symbol == '[' or symbol == '{'
    ---@type core.completion.keyword.info
    local info = {
        hasSpace = hasSpace,
        isExp    = isExp,
        text     = text,
        start    = start,
        uri      = guide.getUri(state.ast),
        position = position,
        state    = state,
    }
    for _, data in ipairs(keyWordMap) do
        local key = data[1]
        ---@type boolean?
        local eq
        if hasSpace then
            eq = word == key
        else
            eq = matchKey(word, key)
        end
        if afterLocal and key ~= 'function' then
            eq = false
        end
        if not eq then
            goto CONTINUE
        end
        if isExp then
            if  key ~= 'nil'
            and key ~= 'true'
            and key ~= 'false'
            and key ~= 'function' then
                goto CONTINUE
            end
        end
        ---@type boolean?
        local replaced
        ---@type boolean?
        local extra
        if snipType == 'Both' or snipType == 'Replace' then
            local func = data[2]
            if func then
                replaced = func(info, results)
                extra = true
            end
        end
        if snipType == 'Both' then
            replaced = false
        end
        if not replaced then
            if not hasSpace then
                local item = {
                    label = key,
                    kind  = define.CompletionItemKind.Keyword,
                }
                if #results > 0 and extra then
                    table.insert(results, #results, item)
                else
                    results[#results+1] = item
                end
            end
        end
        local checkStop = data[3]
        if checkStop then
            local stop = checkStop(info)
            if stop then
                return true
            end
        end
        ::CONTINUE::
    end
end

---@param state parser.state
---@param word  string
---@param start integer
---@param results completion.results
local function checkProvideLocal(state, word, start, results)
    ---@type parser.object?
    local block
    guide.eachSourceContain(state.ast, start, function (source)
        if source.type == 'function'
        or source.type == 'main' then
            block = source
        end
    end)
    if not block then
        return
    end
    ---@type table<string, boolean>
    local used = {}
    guide.eachSourceType(block, 'getglobal', function (source)
        local name = source[1] --[[@as string]]
        if source.start > start
        and not used[name]
        and matchKey(word, name) then
            used[name] = true
            results[#results+1] = {
                label = name,
                kind  = define.CompletionItemKind.Variable,
            }
        end
    end)
    guide.eachSourceType(block, 'getlocal', function (source)
        local name = source[1] --[[@as string]]
        if source.start > start
        and not used[name]
        and matchKey(word, name) then
            used[name] = true
            results[#results+1] = {
                label = name,
                kind  = define.CompletionItemKind.Variable,
            }
        end
    end)
end

---@param state    parser.state
---@param word     string
---@param startPos integer
---@param results completion.results
local function checkFunctionArgByDocParam(state, word, startPos, results)
    local func = guide.eachSourceContain(state.ast, startPos, function (source)
        if source.type == 'function' then
            return source
        end
    end) --[[@as parser.object?]]
    if not func then
        return
    end
    local docs = func.bindDocs
    if not docs then
        return
    end
    ---@type parser.object[]
    local params = {}
    for _, doc in ipairs(docs) do
        if doc.type == 'doc.param' then
            params[#params+1] = doc
        end
    end
    local firstArg = func.args and func.args[1]
    if not firstArg
    or firstArg.start <= startPos and firstArg.finish >= startPos then
        local firstParam = params[1]
        if firstParam and matchKey(word, firstParam.param[1]) then
            ---@type string[]
            local label = {}
            for _, param in ipairs(params) do
                label[#label+1] = param.param[1]
            end
            results[#results+1] = {
                label = table.concat(label, ', '),
                match = firstParam.param[1],
                kind  = define.CompletionItemKind.Snippet,
            }
        end
    end
    for _, doc in ipairs(params) do
        if matchKey(word, doc.param[1]) then
            results[#results+1] = {
                label = doc.param[1],
                kind  = define.CompletionItemKind.Interface,
            }
        end
    end
end

---@param state    parser.state
---@param text     string
---@param startPos integer
---@return boolean
local function isAfterLocal(state, text, startPos)
    local offset = guide.positionToOffset(state, startPos)
    local pos    = lookBackward.skipSpace(text, offset)
    local word   = lookBackward.findWord(text, pos)
    return word == 'local'
end

---@class core.completion.collectRequire.entry
---@field textEdit vm.completion.edit
---@field path? string
---@field [integer] string

---@param mode     'require'|'dofile'|'loadfile'
---@param myUri    uri
---@param literal  string
---@param source   parser.object?
---@param smark    string?
---@param position integer
---@param results completion.results
local function collectRequireNames(mode, myUri, literal, source, smark, position, results)
    ---@type table<string, core.completion.collectRequire.entry>
    local collect = {}
    local source_start   = source and smark and (source.start + #smark) or position
    local source_finish  = source and smark and (source.finish - #smark) or position
    if mode == 'require' then
        for uri in files.eachFile(myUri) do
            if myUri == uri then
                goto CONTINUE
            end
            local path = furi.decode(uri)
            local infos = rpath.getVisiblePath(myUri, path)
            local relative = workspace.getRelativePath(path)
            for _, info in ipairs(infos) do
                if matchKey(literal, info.name) then
                    if not collect[info.name] then
                        collect[info.name] = {
                            textEdit = {
                                start   = source_start,
                                finish  = source_finish,
                                newText = smark and info.name or util.viewString(info.name),
                            },
                            path = relative,
                        }
                    end
                    if vm.isMetaFile(uri) then
                        collect[info.name][#collect[info.name]+1] = ('* [[meta]](%s)'):format(uri)
                    else
                        collect[info.name][#collect[info.name]+1] = ([=[* [%s](%s) %s]=]):format(
                            relative,
                            uri,
                            lang.script('HOVER_USE_LUA_PATH', info.searcher)
                        )
                    end
                end
            end
            ::CONTINUE::
        end
        for uri in files.eachDll() do
            local opens = files.getDllOpens(uri) or {}
            local path = workspace.getRelativePath(uri)
            for _, open in ipairs(opens) do
                if matchKey(literal, open) then
                    if not collect[open] then
                        collect[open] = {
                            textEdit = {
                                start   = source_start,
                                finish  = source_finish,
                                newText = smark and open or util.viewString(open),
                            },
                            path = path,
                        }
                    end
                    collect[open][#collect[open]+1] = ([=[* [%s](%s)]=]):format(
                        path,
                        uri
                    )
                end
            end
        end
    else
        for uri in files.eachFile(myUri) do
            if myUri == uri then
                goto CONTINUE
            end
            if vm.isMetaFile(uri) then
                goto CONTINUE
            end
            local path = workspace.getRelativePath(uri)
            path = path:gsub('\\', '/')
            if matchKey(literal, path) then
                if not collect[path] then
                    collect[path] = {
                        textEdit = {
                            start   = source_start,
                            finish  = source_finish,
                            newText = smark and path or util.viewString(path),
                        }
                    }
                end
                collect[path][#collect[path]+1] = ([=[[%s](%s)]=]):format(
                    path,
                    uri
                )
            end
            ::CONTINUE::
        end
    end
    for label, infos in util.sortPairs(collect) do
        ---@type table<string, boolean>
        local mark = {}
        ---@type string[]
        local des  = {}
        for _, info in ipairs(infos) do
            if not mark[info] then
                mark[info] = true
                des[#des+1] = info
            end
        end
        results[#results+1] = {
            label       = label,
            detail      = infos.path,
            kind        = define.CompletionItemKind.File,
            description = table.concat(des, '\n'),
            textEdit    = infos.textEdit,
        }
    end
end

---@param state    parser.state
---@param position integer
---@param results completion.results
local function checkUri(state, position, results)
    local myUri = guide.getUri(state.ast)
    guide.eachSourceContain(state.ast, position, function (source)
        if source.type ~= 'string' then
            return
        end
        local callargs = source.parent
        if not callargs or callargs.type ~= 'callargs' then
            return
        end
        if callargs[1] ~= source then
            return
        end
        local call = callargs.parent
        if not call then
            return
        end
        local func = call.node
        local literal = guide.getLiteral(source)
        local libName = vm.getLibraryName(func)
        if not libName then
            return
        end
        if libName == 'require'
        or libName == 'dofile'
        or libName == 'loadfile' then
            collectRequireNames(libName, myUri, literal, source, source[2] --[[@as string?]], position, results)
        end
    end)
end

---@param state    parser.state
---@param position integer
---@param results completion.results
local function checkLenPlusOne(state, position, results)
    local text = state.lua
    if not text then
        return
    end
    guide.eachSourceContain(state.ast, position, function (source)
        if source.type == 'getindex'
        or source.type == 'setindex' then
            local finish = guide.positionToOffset(state, source.node.finish)
            local _, offset = text:find('%s*%[%s*%#', finish)
            if not offset then
                return
            end
            local start = guide.positionToOffset(state, source.node.start) + 1
            local nodeText = text:sub(start, finish)
            local writingText = trim(text:sub(offset + 1, guide.positionToOffset(state, position))) or ''
            if not matchKey(writingText, nodeText) then
                return
            end
            local offsetPos = guide.offsetToPosition(state, offset) - 1
            if source.parent == guide.getParentBlock(source) then
                local sourceFinish = guide.positionToOffset(state, source.finish)
                -- state
                local label = (text:match('%#[ \t]*', offset) --[[@as string]]) .. nodeText .. '+1'
                local eq = text:find('^%s*%]?%s*%=', sourceFinish)
                local newText = label .. ']'
                if not eq then
                    newText = (newText .. ' = ') --[[@as string]]
                end
                results[#results+1] = {
                    label    = label,
                    match    = nodeText,
                    kind     = define.CompletionItemKind.Snippet,
                    textEdit = {
                        start   = offsetPos,
                        finish  = source.finish,
                        newText = newText,
                    },
                }
            else
                -- exp
                local label = (text:match('%#[ \t]*', offset) --[[@as string]]) .. nodeText
                local newText = label .. ']'
                results[#results+1] = {
                    label    = label,
                    kind     = define.CompletionItemKind.Snippet,
                    textEdit = {
                        start   = offsetPos,
                        finish  = source.finish,
                        newText = newText,
                    },
                }
            end
        end
    end)
end

---@param label  string
---@param source parser.object?
---@return string?
local function tryLabelInString(label, source)
    if not source or source.type ~= 'string' then
        return label
    end
    local state = parser.compile(label, 'String')
    if not state or not state.ast then
        return label
    end
    if not matchKey(source[1], state.ast[1]) then
        return nil
    end
    return util.viewString(state.ast[1], source[2])
end

---@param enums vm.completion.result[]
---@param source parser.object?
---@return vm.completion.result[]
local function cleanEnums(enums, source)
    for i = #enums, 1, -1 do
        local enum = enums[i]
        local label = tryLabelInString(enum.label, source)
        if label then
            enum.label    = label
            enum.textEdit = source and {
                start   = source.start,
                finish  = source.finish,
                newText = enum.insertText or label,
            }
        end
    end
    return enums
end

---@param state     parser.state
---@param pos       integer
---@param doc       vm.node.object
---@param enums     table[]
---@return table[]?
local function insertDocEnum(state, pos, doc, enums)
    local tbl = doc.bindSource
    if not tbl then
        return nil
    end
    local parent = tbl.parent
    ---@type string?
    local parentName
    if vm.getGlobalNode(parent) then
        parentName = vm.getGlobalNode(parent):getCodeName()
    else
        local locals = guide.getVisibleLocals(state.ast, pos)
        for _, loc in pairs(locals) do
            if util.arrayHas(vm.getDefs(loc), tbl) then
                parentName = loc[1]
                break
            end
        end
    end
    ---@type table[]
    local valueEnums = {}
    for _, field in ipairs(tbl) do
        if field.type == 'tablefield'
        or field.type == 'tableindex' then
            if not field.value then
                goto CONTINUE
            end
            local key = guide.getKeyName(field)
            if not key then
                goto CONTINUE
            end
            if parentName then
                enums[#enums+1] = {
                    label  = parentName .. '.' .. key,
                    kind   = define.CompletionItemKind.EnumMember,
                    id     = stack(field, function (newField) ---@async
                        return {
                            detail      = buildDetail(newField),
                            description = buildDesc(newField),
                        }
                    end),
                }
            end
            for nd in vm.compileNode(field.value):eachObject() do
                if nd.type == 'boolean'
                or nd.type == 'number'
                or nd.type == 'integer'
                or nd.type == 'string' then
                    valueEnums[#valueEnums+1] = {
                        label  = util.viewLiteral(nd[1]),
                        kind   = define.CompletionItemKind.EnumMember,
                        id     = stack(field, function (newField) ---@async
                            return {
                                detail      = buildDetail(newField),
                                description = buildDesc(newField),
                            }
                        end),
                    }
                end
            end
            ::CONTINUE::
        end
    end
    for _, enum in ipairs(valueEnums) do
        enums[#enums+1] = enum
    end
    return enums
end

---@param doc       vm.node.object
---@param enums     table[]
---@return table[]?
local function insertDocEnumKey(doc, enums)
    local tbl = doc.bindSource
    if not tbl then
        return nil
    end
    ---@type table[]
    local keyEnums = {}
    for _, field in ipairs(tbl) do
        if field.type == 'tablefield'
        or field.type == 'tableindex' then
            if not field.value then
                goto CONTINUE
            end
            local key = guide.getKeyName(field)
            if not key then
                goto CONTINUE
            end
            enums[#enums+1] = {
                label  = ('%q'):format(key),
                kind   = define.CompletionItemKind.EnumMember,
                id     = stack(field, function (newField) ---@async
                    return {
                        detail      = buildDetail(newField),
                        description = buildDesc(newField),
                    }
                end),
            }
            ::CONTINUE::
        end
    end
    for _, enum in ipairs(keyEnums) do
        enums[#enums+1] = enum
    end
    return enums
end

---@param doc parser.object
---@return string
local function buildInsertDocFunction(doc)
    ---@type string[]
    local args = {}
    for i, arg in ipairs(doc.args) do
        args[i] = ('${%d:%s}'):format(i, arg.name[1])
    end
    return ("\z
function (%s)\
\t$0\
end"):format(table.concat(args, ', '))
end

---@param state     parser.state
---@param pos       integer
---@param src       vm.node.object
---@param enums     table[]
---@param isInArray boolean?
---@param mark      table<vm.node.object, boolean>?
local function insertEnum(state, pos, src, enums, isInArray, mark)
    local markTbl = mark or {}
    if markTbl[src] then
        return
    end
    markTbl[src] = true
    if src.type == 'doc.type.string'
    or src.type == 'doc.type.integer'
    or src.type == 'doc.type.boolean' then
        enums[#enums+1] = {
            label       = vm.getInfer(src):view(state.uri),
            description = src.comment,
            kind        = define.CompletionItemKind.EnumMember,
        }
    elseif src.type == 'doc.type.code' then
        enums[#enums+1] = {
            label       = src[1],
            description = src.comment,
            kind        = define.CompletionItemKind.EnumMember,
        }
    elseif src.type == 'doc.type.function' then
        local insertText = buildInsertDocFunction(src)
        ---@type string|parser.state.comm|parser.object
        local description
        if src.comment then
            description = src.comment
        else
            local descText = insertText:gsub('%$%{%d+:([^}]+)%}', function (val)
                return val
            end):gsub('%$%{?%d+%}?', '')
            description = markdown()
                : add('lua', descText)
                : string()
        end
        enums[#enums+1] = {
            label       = vm.getInfer(src):view(state.uri),
            description = description,
            kind        = define.CompletionItemKind.Function,
            insertText  = insertText,
            insertTextFormat = 2,
        }
    elseif src.type == 'doc.enum' then
        if vm.docHasAttr(src, 'key') then
            insertDocEnumKey(src, enums)
        else
            insertDocEnum(state, pos, src, enums)
        end
    elseif isInArray and src.type == 'doc.type.array' then
        for _, d in ipairs(vm.getDefs(src.node)) do
            insertEnum(state, pos, d, enums, isInArray, markTbl)
        end
    elseif src.type == 'global' and src.cate == 'type' then
        for _, set in ipairs(src:getSets(state.uri)) do
            if set.type == 'doc.enum' then
                insertEnum(state, pos, set, enums, isInArray, markTbl)
            end
        end
    end
end

---@param state      parser.state
---@param position   integer
---@param defs       parser.object[]
---@param str        parser.object?
---@param results completion.results
---@param isInArray? boolean
local function checkTypingEnum(state, position, defs, str, results, isInArray)
    ---@type table[]
    local enums = {}
    for _, def in ipairs(defs) do
        insertEnum(state, position, def, enums, isInArray)
    end
    cleanEnums(enums, str)
    for _, res in ipairs(enums) do
        results[#results+1] = res
    end
end

---@param state      parser.state
---@param position   integer
---@param source     parser.object?
---@param results completion.results
---@param isInArray? boolean
local function checkEqualEnumLeft(state, position, source, results, isInArray)
    if not source then
        return
    end
    local str = guide.eachSourceContain(state.ast, position, function (src)
        if src.type == 'string' then
            return src
        end
    end)
    local defs = vm.getDefs(source)
    checkTypingEnum(state, position, defs, str, results, isInArray)
end

---@param state    parser.state
---@param position integer
---@param results completion.results
local function checkEqualEnum(state, position, results)
    local text  = state.lua
    if not text then
        return
    end
    local start = lookBackward.findTargetSymbol(text, guide.positionToOffset(state, position), '=')
    if not start then
        return
    end
    ---@type boolean?
    local eqOrNeq
    if text:sub(start - 1, start - 1) == '='
    or text:sub(start - 1, start - 1) == '~' then
        start = start - 1
        eqOrNeq = true
    end
    start = lookBackward.skipSpace(text, start - 1)
    local source = findNearestSource(state, guide.offsetToPosition(state, start))
    if not source then
        return
    end
    if source.type == 'callargs' then
        source = source.parent
    end
    if source.type == 'call' and not eqOrNeq then
        return
    end
    checkEqualEnumLeft(state, position, source, results)
end

---@param state    parser.state
---@param position integer
---@param results completion.results
local function checkEqualEnumInString(state, position, results)
    local source = findNearestSource(state, position)
    local parent = source and source.parent
    if not parent then
        return
    end
    if parent.type == 'binary' then
        if source ~= parent[2] then
            return
        end
        if not parent.op then
            return
        end
        if parent.op.type ~= '==' and parent.op.type ~= '~=' then
            return
        end
        checkEqualEnumLeft(state, position, parent[1], results)
    end
    if (parent.type == 'tableexp') then
        checkEqualEnumLeft(state, position, parent.parent and parent.parent.parent, results, true)
        return
    end
    if parent.type == 'local' then
        checkEqualEnumLeft(state, position, parent, results)
    end

    if parent.type == 'setlocal'
    or parent.type == 'setglobal'
    or parent.type == 'setfield'
    or parent.type == 'setindex' then
        checkEqualEnumLeft(state, position, parent.node, results)
    end
    if parent.type == 'tablefield'
    or parent.type == 'tableindex' then
        checkEqualEnumLeft(state, position, parent, results)
    end
end

---@param state    parser.state
---@param position integer
---@return boolean?
local function isFuncArg(state, position)
    return guide.eachSourceContain(state.ast, position, function (source)
        if source.type == 'funcargs' then
            return true
        end
    end)
end

---@param state    parser.state
---@param position integer
---@param results completion.results
local function trySpecial(state, position, results)
    if guide.isInString(state.ast, position) then
        checkUri(state, position, results)
        checkEqualEnumInString(state, position, results)
        return
    end
    -- x[#x+1]
    checkLenPlusOne(state, position, results)
    -- type(o) ==
    checkEqualEnum(state, position, results)
end

---@async
---@param state parser.state
---@param position integer
---@param results completion.results
local function tryIndex(state, position, results)
    local parent, oop = findParentInStringIndex(state, position)
    if not parent then
        return
    end
    local nextIndex = parent.next and parent.next.index
    ---@type string?
    local word = nextIndex and nextIndex[1]
    if not word then
        return
    end
    checkField(state, word, position, position, parent, oop, results)
end

---@async
---@param state            parser.state
---@param position         integer
---@param triggerCharacter string?
---@param results completion.results
local function tryWord(state, position, triggerCharacter, results)
    if triggerCharacter == '('
    or triggerCharacter == '#'
    or triggerCharacter == ','
    or triggerCharacter == '{' then
        return
    end
    local text = state.lua
    if not text then
        return
    end
    local offset = guide.positionToOffset(state, position)
    local finish = lookBackward.skipSpace(text, offset)
    local word, start = lookBackward.findWord(text, offset)
    ---@type integer
    local startPos
    if not word then
        word = ''
        startPos = position
    else
        assert(start)
        startPos = guide.offsetToPosition(state, start - 1)
    end
    local hasSpace = triggerCharacter ~= nil and finish ~= offset
    if guide.isInString(state.ast, position) then
        if not hasSpace then
            if #results == 0 then
                checkCommon(state, word, position, results)
            end
        end
    else
        local parent, oop = findParent(state, startPos)
        if     parent then
            local firstField = #results + 1
            checkField(state, word, startPos, position, parent, oop, results)
            boostExpectedType(state, startPos, results, firstField)
        elseif isFuncArg(state, position) then
            checkProvideLocal(state, word, startPos, results)
            checkFunctionArgByDocParam(state, word, startPos, results)
        else
            local afterLocal = isAfterLocal(state, text, startPos)
            -- the keywords go after the variables and types of the scope (TypeScript's order), unless they stop the search
            ---@type completion.results
            local keywordResults = {}
            local stop = checkKeyWord(state, startPos, position, word, hasSpace, afterLocal, keywordResults)
            if stop then
                for _, res in ipairs(keywordResults) do
                    results[#results+1] = res
                end
                return
            end
            if not hasSpace then
                if afterLocal then
                    checkProvideLocal(state, word, startPos, results)
                else
                    local firstLocal = #results + 1
                    checkLocal(state, word, startPos, results)
                    checkTableField(state, word, startPos, results)
                    local env = guide.getENV(state.ast, startPos)
                    if env then
                        checkGlobal(state, word, startPos, position, env, false, results)
                        checkModule(state, word, startPos, results)
                    end
                    -- (the variables of the scope together: a global that fits goes before a local that does not)
                    boostExpectedType(state, startPos, results, firstLocal)
                end
            end
            for _, res in ipairs(keywordResults) do
                results[#results+1] = res
            end
        end
        if not hasSpace and (#results == 0 or word ~= '') then
            checkCommon(state, word, position, results)
        end
    end
end

---@async
---@param state    parser.state
---@param position integer
---@param results completion.results
---@return nil
local function trySymbol(state, position, results)
    local text = state.lua
    assert(text)
    local symbol, start = lookBackward.findSymbol(text, guide.positionToOffset(state, position))
    if not symbol then
        return nil
    end
    assert(start)
    if guide.isInString(state.ast, position) then
        return nil
    end
    local startPos = guide.offsetToPosition(state, start)
    --if symbol == '.'
    --or symbol == ':' then
    --    local parent, oop = findParent(state, startPos)
    --    if parent then
    --        tracy.ZoneBeginN 'completion.trySymbol'
    --        checkField(state, '', startPos, position, parent, oop, results)
    --        tracy.ZoneEnd()
    --    end
    --end
    if symbol == '(' then
        checkFunctionArgByDocParam(state, '', startPos, results)
    end
end

---@param state    parser.state
---@param position integer
---@return parser.object?
local function findCall(state, position)
    ---@type parser.object?
    local call
    guide.eachSourceContain(state.ast, position, function (src)
        if src.type == 'call' and src.node.finish <= position then
            if not call or call.start < src.start  then
                call = src
            end
        end
    end)
    return call
end

---@param call     parser.object
---@param position integer
---@return integer index
---@return parser.object? arg
local function getCallArgInfo(call, position)
    if not call.args then
        return 1, nil
    end
    for index, arg in ipairs(call.args) do
        if arg.start <= position and arg.finish >= position then
            return index, arg
        end
    end
    return #call.args + 1, nil
end

---@param state   parser.state
---@param position integer
---@param tbl     parser.object
---@param fields  parser.object[]
---@param results completion.results
---@return boolean?
local function checkTableLiteralField(state, position, tbl, fields, results)
    local text = state.lua
    if not text then
        return
    end
    ---@type table<string, boolean>
    local mark = {}
    for _, field in ipairs(tbl) do
        if field.type == 'tablefield'
        or field.type == 'tableindex'
        or field.type == 'tableexp' then
            local name = guide.getKeyName(field)
            if name then
                mark[name] = true
            end
        end
    end
    table.sort(fields, function (a, b)
        return tostring(guide.getKeyName(a)) < tostring(guide.getKeyName(b))
    end)
    -- {$}
    local left = lookBackward.findWord(text, guide.positionToOffset(state, position))
    if not left then
        local pos = lookBackward.findAnyOffset(text, guide.positionToOffset(state, position))
        if pos then
            local char = text:sub(pos, pos)
            if char == '{' or char == ',' or char == ';' then
                left = ''
            end
        end
    end
    if left then
        ---@type completion.results
        local fieldResults = {}
        for _, field in ipairs(fields) do
            local name = guide.getKeyName(field)
            if  name
            and not mark[name]
            and matchKey(left, tostring(name)) then
                local res = {
                    label      = name,
                    kind       = define.CompletionItemKind.Property,
                    id         = stack(field, function (newField) ---@async
                        return {
                            detail      = buildDetail(newField),
                            description = buildDesc(newField),
                        }
                    end),
                }
                if field.optional
                or vm.compileNode(field):isNullable() then
                    res.insertText = res.label
                    res.label      = res.label.. '?'
                end
                fieldResults[#fieldResults+1] = res
            end
        end
        util.sortByScore(fieldResults, {
            function (r) return r.insertText and 0 or 1 end,
            util.sortCallbackOfIndex(fieldResults),
        })
        util.arrayMerge(results, fieldResults)
        return #fieldResults > 0
    end
end

--- What an argument of a generic function can be once the type parameters are bound by the arguments before it: a parameter typed
--- `keyof T` (`---@param key keyof T`, `---@param ... keyof T` for every extra argument), or a type parameter constrained by
--- a type that names others (`---@generic T, K: keyof T`; a constraint alone completes as well, `T: "a"|"b"`).
---@param state    parser.state
---@param call     parser.object
---@param argIndex integer
---@return vm.node?
local function keyofArgNode(state, call, argIndex)
    -- the one function the call can be
    ---@type parser.object?
    local func
    for obj in vm.compileNode(call.node):eachObject() do
        if obj.type == 'function' then
            func = obj
        end
    end
    local sign = func and vm.getSign(func)
    if not func or not sign then
        return nil
    end
    local params = func.args or {}
    local param  = params[argIndex]
    local last   = params[#params]
    if not param and last and last.type == '...' then
        param = last
    end
    if not param then
        return nil
    end
    ---@type parser.object?
    local typeDoc
    for _, doc in ipairs(func.bindDocs or {}) do
        if doc.type == 'doc.param' and doc.param and doc.param[1] == param[1] then
            typeDoc = doc.extends
            break
        end
    end
    if not typeDoc then
        return nil
    end
    -- a type parameter alone (`key: K`): complete by its constraint
    ---@type parser.object
    local target = typeDoc
    local unit = typeDoc.types and #typeDoc.types == 1 and typeDoc.types[1]
    if unit and unit.type == 'doc.generic.name' then
        for _, genericDoc in ipairs(sign.docGeneric) do
            for _, object in ipairs(genericDoc.generics) do
                if object.generic and object.generic[1] == unit[1] and object.extends then
                    target = object.extends
                end
            end
        end
    end
    ---@type parser.object[]
    local before = {}
    for i = 1, argIndex - 1 do
        before[i] = call.args and call.args[i]
    end
    ---@type table<string, vm.node>
    local resolved = {}
    for name, node in pairs(sign:resolve(state.uri, before) or {}) do
        resolved[name] = node
    end
    -- (`keyof self` is the receiver of this call, not the class that declares the method)
    if call.node.type == 'getmethod' and call.node.node then
        resolved.self = vm.compileNode(call.node.node)
    end
    return vm.compileNode(vm.cloneObject(target, resolved) --[[@as parser.object]])
end

---@param state    parser.state
---@param position integer
---@param results completion.results
local function tryCallArg(state, position, results)
    local call = findCall(state, position)
    if not call then
        return
    end
    local argIndex, arg = getCallArgInfo(call, position)
    if arg and arg.type == 'function' then
        return
    end
    local node = vm.compileCallArg({ type = 'dummyarg', uri = state.uri }, call, argIndex)

    ---@type table[]
    local enums = {}
    for src in (node and node:eachObject() or function () end) do
        insertEnum(state, position, src, enums, arg and arg.type == 'table')
    end
    if #enums == 0 then
        local keys = keyofArgNode(state, call, argIndex)
        for src in (keys and keys:eachObject() or function () end) do
            insertEnum(state, position, src, enums, false)
        end
    end
    cleanEnums(enums, arg)
    for _, enum in ipairs(enums) do
        results[#results+1] = enum
    end
end

---@param state    parser.state
---@param position integer
---@param results completion.results
---@return boolean?
local function tryTable(state, position, results)
    local tbl = findNearestTable(state, position)
    if not tbl then
        return false
    end
    if  tbl.type ~= 'table' then
        return
    end
    ---@type table<string, boolean>
    local mark = {}
    ---@type parser.object[]
    local fields = {}

    local defs = vm.getFields(tbl)
    for _, field in ipairs(defs) do
        local name = guide.getKeyName(field)
        if name and not mark[name] then
            mark[name] = true
            fields[#fields+1] = field
        end
    end
    if checkTableLiteralField(state, position, tbl, fields, results) then
        return true
    end
    return false
end

---@param state    parser.state
---@param position integer
---@param results completion.results
local function tryArray(state, position, results)
    local source = findNearestSource(state, position)
    if not source then
        return
    end
    if source.type ~= 'table' and (not source.parent or source.parent.type ~= 'table') then
        return
    end
    local tbl = source
    if source.type ~= 'table' then
        tbl = source.parent
    end
    if source.parent
    and source.parent.type == 'callargs'
    and source.parent.parent
    and source.parent.parent.type == 'call' then
        return
    end
    -- {  } inside when enum
    checkEqualEnumLeft(state, position, tbl, results, true)
end

---@param state    parser.state
---@param position integer
---@return parser.state.comm?
local function getComment(state, position)
    local text = state.lua
    if not text then
        return
    end
    local offset = guide.positionToOffset(state, position)
    local symbolOffset = lookBackward.findAnyOffset(text, offset, true)
    if not symbolOffset then
        return
    end
    local symbolPosition = guide.offsetToPosition(state, symbolOffset)
    for _, comm in ipairs(state.comms) do
        if symbolPosition > comm.start and symbolPosition <= comm.finish then
            return comm
        end
    end
    return nil
end

---@param state    parser.state
---@param position integer
---@return parser.object?
local function getLuaDoc(state, position)
    local text = state.lua
    if not text then
        return
    end
    local offset = guide.positionToOffset(state, position)
    local symbolOffset = lookBackward.findAnyOffset(text, offset, true)
    if not symbolOffset then
        return
    end
    local symbolPosition = guide.offsetToPosition(state, symbolOffset)
    for _, doc in ipairs(state.ast.docs) do
        if symbolPosition >= doc.start and symbolPosition <= doc.range then
            return doc
        end
        -- `---@class (exact) A`: the attributes come before what starts the node
        local attr = doc.docAttr
        if attr and symbolPosition >= attr.start and symbolPosition <= attr.finish then
            return doc
        end
    end
    return nil
end

---@param word string
---@param results completion.results
local function tryluaDocCate(word, results)
    for _, docType in ipairs {
        'class',
        'type',
        'alias',
        'param',
        'return',
        'field',
        'generic',
        'vararg',
        'overload',
        'deprecated',
        'meta',
        'version',
        'see',
        'diagnostic',
        'module',
        'async',
        'nodiscard',
        'cast',
        'operator',
        'source',
        'enum',
        'package',
        'private',
        'protected'
    } do
        if matchKey(word, docType) then
            results[#results+1] = {
                label       = docType,
                kind        = define.CompletionItemKind.Event,
                description = lang.script('LUADOC_DESC_' .. docType:upper())
            }
        end
    end
    -- tags taught by plugins (parser.docTags)
    for name, description in docTags.eachTag() do
        if matchKey(word, name) then
            results[#results+1] = {
                label       = name,
                kind        = define.CompletionItemKind.Event,
                description = description,
            }
        end
    end
end

---@param state    parser.state
---@param position integer
---@return parser.object?
local function getluaDocByContain(state, position)
    ---@type parser.object?
    local result
    ---@type number
    local range = math.huge
    guide.eachSourceContain(state.ast.docs, position, function (src)
        if not src.start then
            return
        end
        if  range >= position - src.start
        and position <= src.finish then
            range = (position - src.start)
            result = src
        end
    end)
    return result
end

---@param state    parser.state
---@param start    integer
---@param position integer
---@return parser.state.err?, parser.object?
local function getluaDocByErr(state, start, position)
    local text = state.lua
    if not text then
        return nil
    end
    ---@type parser.state.err?
    local targetError
    for _, err in ipairs(state.errs) do
        -- every parser.state.err the parser actually pushes sets both start and finish together
        -- (parser/compile.lua's pushError callers); the field-level `?` is conservative, not a
        -- real independent-nilability case
        ---@diagnostic expect-next-line: need-check-nil
        if  err.finish <= position
        ---@diagnostic expect-next-line: need-check-nil
        and err.start >= start  then
            ---@diagnostic expect-next-line: need-check-nil
            if not text:sub(err.finish + 1, position):find '%S' then
                targetError = err
                break
            end
        end
    end
    if not targetError then
        return nil
    end
    ---@type parser.object?
    local targetDoc
    for i = #state.ast.docs, 1, -1 do
        local doc = state.ast.docs[i]
        if doc.finish <= (targetError.start --[[@as integer]]) then
            targetDoc = doc
            break
        end
    end
    return targetError, targetDoc
end

--- What may stand in front of a `---@field` name (the parser reads these itself).
---@type [string, string][]
local visibilityKeywords = {
    { 'public',    'Visible everywhere, the default.' },
    { 'protected', 'Visible in the class and in the classes that inherit from it.' },
    { 'private',   'Visible only inside the class.' },
    { 'package',   'Visible only in the file that declares the class.' },
}

--- The type whose keys a string inside a type position names: `T` of `Pick<T, "...">` / `Omit<T, "...">` (in the second argument) and of
--- `T["..."]`.
---@param source parser.object a `doc.type.string`
---@return parser.object?
local function stringKeyBase(source)
    local holder = source.parent
    while holder and holder.type == 'doc.type' do
        holder = holder.parent
    end
    if not holder then
        return nil
    end
    ---@param part parser.object?
    ---@return boolean
    local function within(part)
        return part ~= nil and source.start >= part.start and source.finish <= part.finish
    end
    if holder.type == 'doc.type.sign' and holder.node and holder.signs then
        local name = holder.node[1]
        if (name == 'Pick' or name == 'Omit') and within(holder.signs[2]) then
            return holder.signs[1]
        end
    elseif holder.type == 'doc.type.indexed' and holder.node and within(holder.key) then
        return holder.node
    end
    return nil
end

---@class completion.typeNamesOptions
---@field inReturn?    boolean the type is in a `---@return` (`self` is offered)
---@field classesOnly? boolean only classes (the parent of `---@class A : <here>`): no keywords, operators, aliases or enums
---@field exclude?     string a class that is not offered (the class that is being declared)

--- The names a type can be written with, for the word typed so far (`''` right after `---@type `): the type keywords (`secret`, `nosecret`, ...),
--- `self` in a `---@return`, the built-in type operators (`Partial`, `keyof`, `returns`, ...) and the classes, aliases and enums of the project.
--- THE one place that decides what is offered where a type is written and in which order, for the position with a word and the one without
--- (the client keeps filtering the first list it got while the word is typed, so a name missing from the list of the empty word never shows up).
---@param state     parser.state
---@param word      string
---@param start     integer where the name starts (a name with a character that is no word character replaces the text from here)
---@param position  integer
---@param options   completion.typeNamesOptions
---@param results   completion.results
local function addTypeNames(state, word, start, position, options, results)
    ---@type table<string, boolean>
    local used = {}
    if not options.classesOnly then
        for name, description in docTags.eachTypeKeyword() do
            if matchKey(word, name) then
                used[name] = true
                results[#results+1] = {
                    label       = name,
                    kind        = define.CompletionItemKind.Keyword,
                    description = description,
                }
            end
        end
        -- `---@return self`: the object the method was called on
        if options.inReturn and matchKey(word, 'self') and not used['self'] then
            used['self'] = true
            results[#results+1] = {
                label       = 'self',
                kind        = define.CompletionItemKind.Keyword,
                description = 'The object the method was called on.',
            }
        end
        -- the built-in type operators (`Partial<T>`, `keyof T`, `returns<F>`, ...) are not declared
        -- anywhere, so the resolvers' own name list is offered as type names
        ---@type string[]
        local operators = { 'keyof', 'returns', 'params' }
        for name in pairs(vm.utilityTypeNames) do
            operators[#operators+1] = name
        end
        table.sort(operators)
        for _, name in ipairs(operators) do
            if not used[name] and matchKey(word, name) then
                used[name] = true
                local operator = vm.getTypeOperatorDoc(state.uri, name)
                results[#results+1] = {
                    label       = name,
                    kind        = define.CompletionItemKind.Class,
                    detail      = operator and operator.signature,
                    description = operator and operator.text,
                }
            end
        end
    end
    for _, doc in ipairs(vm.getDocSets(state.uri)) do
        local name = ((doc.type == 'doc.class' and doc.class[1])
                or   (not options.classesOnly and doc.type == 'doc.alias' and doc.alias[1])
                or   (not options.classesOnly and doc.type == 'doc.enum'  and doc.enum[1])) --[[@as string?]]
        if  name
        and name ~= options.exclude
        and not used[name]
        and matchKey(word, name) then
            used[name] = true
            results[#results+1] = {
                label       = name,
                kind        = doc.type == 'doc.enum' and define.CompletionItemKind.Enum or define.CompletionItemKind.Class,
                textEdit    = name:find '[^%w_]' and {
                    start   = start,
                    finish  = position,
                    newText = name,
                },
            }
        end
    end
end

---@async
---@param state    parser.state
---@param position integer
---@param source   parser.object
---@param results completion.results
---@return boolean?
local function tryluaDocBySource(state, position, source, results)
    if     source.type == 'doc.type.string' then
        -- the key of `Pick<T, "...">` / `Omit<T, "...">` or of `T["..."]`: the keys of `T`
        local base = stringKeyBase(source)
        if not base then
            return false
        end
        ---@type parser.object
        local keyOf = {
            type   = 'doc.type.keyof',
            start  = source.start,
            finish = source.finish,
            parent = source.parent,
            node   = base,
        }
        for key in vm.compileNode(keyOf):eachObject() do
            if key.type == 'doc.type.string' and matchKey(source[1] --[[@as string]], key[1] --[[@as string]]) then
                local label = vm.getInfer(key):view(state.uri)
                results[#results+1] = {
                    label    = label,
                    kind     = define.CompletionItemKind.EnumMember,
                    textEdit = {
                        start   = source.start,
                        finish  = source.finish,
                        newText = label,
                    },
                }
            end
        end
        return #results > 0
    elseif source.type == 'doc.extends.name' then
        if source.parent and source.parent.type == 'doc.class' then
            addTypeNames(state, source[1] --[[@as string]], source.start, position,
                { classesOnly = true, exclude = source.parent.class[1] --[[@as string]] }, results)
        end
        return true
    elseif source.type == 'doc.type.name' then
        ---@type parser.object?
        local doc = source
        while doc and doc.type ~= 'doc.return' do
            doc = doc.parent
        end
        addTypeNames(state, source[1] --[[@as string]], source.start, position, { inReturn = doc ~= nil }, results)
        return true
    elseif source.type == 'doc.param.name' then
        ---@type parser.object[]
        local funcs = {}
        guide.eachSourceBetween(state.ast, position, math.huge, function (src)
            if src.type == 'function' and src.start > position then
                funcs[#funcs+1] = src
            end
        end)
        table.sort(funcs, function (a, b)
            return a.start < b.start
        end)
        local func = funcs[1]
        if not func or not func.args then
            return
        end
        for _, arg in ipairs(func.args) do
            local argName = arg[1] --[[@as string?]]
            if argName and matchKey(source[1] --[[@as string]], argName) then
                results[#results+1] = {
                    label  = argName,
                    kind   = define.CompletionItemKind.Interface,
                }
            end
        end
        return true
    elseif source.type == 'doc.diagnostic' then
        local sourceMode = source.mode --[[@as string]]
        for _, mode in ipairs(diagnosticModes) do
            if matchKey(sourceMode, mode) then
                results[#results+1] = {
                    label    = mode,
                    kind     = define.CompletionItemKind.Enum,
                    textEdit = {
                        start   = source.start,
                        finish  = source.start + #sourceMode,
                        newText = mode,
                    },
                }
            end
        end
        return true
    elseif source.type == 'doc.diagnostic.name' then
        local sourceName = source[1]
        -- the live registry: `define.DiagnosticDefaultSeverity` is a snapshot taken when
        -- proto.define loads, before the diagnostics have registered themselves
        for name in util.sortPairs(diag.getDiagAndErrNameMap()) do
            if matchKey(sourceName, name) then
                results[#results+1] = {
                    label    = name,
                    kind     = define.CompletionItemKind.Value,
                    textEdit = {
                        start   = source.start,
                        finish  = source.start + #sourceName,
                        newText = name,
                    },
                }
            end
        end
        return true
    elseif source.type == 'doc.attr.name' or source.type == 'doc.attr' then
        -- `---@class (ex<??>)`: the attributes registered for the tag the parentheses belong to
        local attr  = source.type == 'doc.attr' and source or source.parent
        local owner = attr and attr.parent
        if owner then
            local word = source.type == 'doc.attr.name' and source[1] or ''
            for name, description in docTags.eachAttribute(owner.type) do
                if matchKey(word, name) then
                    results[#results+1] = {
                        label       = name,
                        kind        = define.CompletionItemKind.Keyword,
                        description = description,
                    }
                end
            end
        end
        return true
    elseif source.type == 'doc.field.name' then
        -- the field name position also takes the visibility keywords and the ones plugins put in
        -- front of it
        for _, keyword in ipairs(visibilityKeywords) do
            if matchKey(source[1] --[[@as string]], keyword[1]) then
                results[#results+1] = {
                    label       = keyword[1],
                    kind        = define.CompletionItemKind.Keyword,
                    description = keyword[2],
                }
            end
        end
        for name, description in docTags.eachFieldKeyword() do
            if matchKey(source[1] --[[@as string]], name) then
                results[#results+1] = {
                    label       = name,
                    kind        = define.CompletionItemKind.Keyword,
                    description = description,
                }
            end
        end
    elseif source.parent and docTags.isNameListTag(source.parent.type) then
        -- `---@secret a, b`: the names are the locals of the statement the tag is bound to
        local tag = source.parent
        ---@type table<string, parser.object>
        local locals = {}
        guide.eachSourceType(state.ast, 'local', function (loc)
            for _, bound in ipairs(loc.bindDocs or {}) do
                if bound == tag then
                    locals[loc[1] --[[@as string]]] = loc
                end
            end
        end)
        for name, loc in util.sortPairs(locals) do
            if matchKey(source[1], name) then
                results[#results+1] = {
                    label = name,
                    kind  = define.CompletionItemKind.Variable,
                    id    = stack(loc, function (newLoc) ---@async
                        return {
                            detail      = buildDetail(newLoc),
                            description = buildDesc(newLoc),
                        }
                    end),
                }
            end
        end
        return true
    elseif source.type == 'doc.module' then
        collectRequireNames('require', state.uri, source.module or '', source, source.smark, position, results)
        return true
    elseif source.type == 'doc.cast.name' then
        local locals = guide.getVisibleLocals(state.ast, position)
        for name, loc in util.sortPairs(locals) do
            if matchKey(source[1], name) then
                results[#results+1] = {
                    label = name,
                    kind  = define.CompletionItemKind.Variable,
                    id    = stack(loc, function (newLoc) ---@async
                        return {
                            detail      = buildDetail(newLoc),
                            description = buildDesc(newLoc),
                        }
                    end),
                }
            end
        end
        return true
    elseif source.type == 'doc.operator.name' then
        local sourceName = source[1] --[[@as string]]
        for _, name in ipairs(vm.UNARY_OP) do
            if matchKey(sourceName, name) then
                results[#results+1] = {
                    label       = name,
                    kind        = define.CompletionItemKind.Operator,
                    description = ('```lua\n%s\n```'):format(vm.OP_UNARY_MAP[name]),
                }
            end
        end
        for _, name in ipairs(vm.BINARY_OP) do
            if matchKey(sourceName, name) then
                results[#results+1] = {
                    label       = name,
                    kind        = define.CompletionItemKind.Operator,
                    description = ('```lua\n%s\n```'):format(vm.OP_BINARY_MAP[name]),
                }
            end
        end
        for _, name in ipairs(vm.OTHER_OP) do
            if matchKey(sourceName, name) then
                results[#results+1] = {
                    label       = name,
                    kind        = define.CompletionItemKind.Operator,
                    description = ('```lua\n%s\n```'):format(vm.OP_OTHER_MAP[name]),
                }
            end
        end
        return true
    elseif source.type == 'doc.see.name' then
        local symbolds = wssymbol(source[1] --[[@as string]], state.uri)
        table.sort(symbolds, function (a, b)
            return a.name < b.name
        end)
        for _, symbol in ipairs(symbolds) do
            local symbolName = symbol.name --[[@as string]]
            results[#results+1] = {
                label = symbolName,
                kind  = symbol.ckind,
                id    = stack(symbol.source, function (newSource) ---@async
                    return {
                        detail      = buildDetail(newSource),
                        description = buildDesc(newSource),
                    }
                end),
                textEdit = {
                    start   = source.start,
                    finish  = source.finish,
                    newText = symbolName,
                },
            }
        end
    end
    return false
end

--- Is the cursor on a line that starts a `---@return` tag? (A tag that is still being written has no node yet to ask.)
---@param state    parser.state
---@param position integer
---@return boolean
local function isInReturnTag(state, position)
    local before = (state.lua or ''):sub(1, position):match('([^\r\n]*)$')
    return before ~= nil and before:find('^%s*%-%-+%s*@return%s') ~= nil
end

---@async
---@param state    parser.state
---@param position integer
---@param err      parser.state.err
---@param docState parser.object?
---@param results completion.results
local function tryluaDocByErr(state, position, err, docState, results)
    if     err.type == 'LUADOC_MISS_CLASS_EXTENDS_NAME' then
        -- (a class is needed, and there is no class being declared when the tag is broken off before its name)
        if docState then
            addTypeNames(state, '', position, position, { classesOnly = true, exclude = docState.class[1] --[[@as string]] }, results)
        end
    elseif err.type == 'LUADOC_MISS_TYPE_NAME' then
        -- (no word yet: everything a type can be written with, as with a word)
        addTypeNames(state, '', position, position, { inReturn = isInReturnTag(state, position) }, results)
    elseif err.type == 'LUADOC_MISS_PARAM_NAME' then
        ---@type parser.object[]
        local funcs = {}
        guide.eachSourceBetween(state.ast, position, math.huge, function (src)
            if src.type == 'function' and src.start > position then
                funcs[#funcs+1] = src
            end
        end)
        table.sort(funcs, function (a, b)
            return a.start < b.start
        end)
        local func = funcs[1]
        if not func or not func.args then
            return
        end
        ---@type string[]
        local label = {}
        ---@type string[]
        local insertText = {}
        for _, arg in ipairs(func.args) do
            local argName = arg[1]
            if argName and arg.type ~= 'self' then
                label[#label+1] = argName
                if #label == 1 then
                    insertText[#insertText+1] = ('%s ${%d:any}'):format(argName, #label)
                else
                    insertText[#insertText+1] = ('---@param %s ${%d:any}'):format(argName, #label)
                end
            end
        end
        results[#results+1] = {
            label            = table.concat(label, ', '),
            kind             = define.CompletionItemKind.Snippet,
            insertTextFormat = 2,
            insertText       = table.concat(insertText, '\n'),
        }
        for _, arg in ipairs(func.args) do
            local argName = arg[1]
            if argName then
                results[#results+1] = {
                    label  = argName,
                    kind   = define.CompletionItemKind.Interface,
                }
            end
        end
    elseif err.type == 'LUADOC_MISS_DIAG_MODE' then
        for _, mode in ipairs(diagnosticModes) do
            results[#results+1] = {
                label = mode,
                kind  = define.CompletionItemKind.Enum,
            }
        end
    elseif err.type == 'LUADOC_MISS_DIAG_NAME' then
        for name in util.sortPairs(diag.getDiagAndErrNameMap()) do
            results[#results+1] = {
                label = name,
                kind  = define.CompletionItemKind.Value,
            }
        end
    elseif err.type == 'LUADOC_MISS_MODULE_NAME' then
        collectRequireNames('require', state.uri, '', docState, nil, position, results)
    elseif err.type == 'LUADOC_MISS_LOCAL_NAME' then
        local locals = guide.getVisibleLocals(state.ast, position)
        for name, loc in util.sortPairs(locals) do
            if name ~= '_ENV' then
                results[#results+1] = {
                    label = name,
                    kind   = define.CompletionItemKind.Variable,
                    id     = stack(loc, function (newLoc) ---@async
                        return {
                            detail      = buildDetail(newLoc),
                            description = buildDesc(newLoc),
                        }
                    end),
                }
            end
        end
    elseif err.type == 'LUADOC_MISS_OPERATOR_NAME' then
        for _, name in ipairs(vm.UNARY_OP) do
            results[#results+1] = {
                label       = name,
                kind        = define.CompletionItemKind.Operator,
                description = ('```lua\n%s\n```'):format(vm.OP_UNARY_MAP[name]),
            }
        end
        for _, name in ipairs(vm.BINARY_OP) do
            results[#results+1] = {
                label       = name,
                kind        = define.CompletionItemKind.Operator,
                description = ('```lua\n%s\n```'):format(vm.OP_BINARY_MAP[name]),
            }
        end
        for _, name in ipairs(vm.OTHER_OP) do
            results[#results+1] = {
                label       = name,
                kind        = define.CompletionItemKind.Operator,
                description = ('```lua\n%s\n```'):format(vm.OP_OTHER_MAP[name]),
            }
        end
    elseif err.type == 'LUADOC_MISS_SEE_NAME' then
        local symbolds = wssymbol('', state.uri)
        table.sort(symbolds, function (a, b)
            return a.name < b.name
        end)
        for _, symbol in ipairs(symbolds) do
            results[#results+1] = {
                label = symbol.name --[[@as string]],
                kind  = symbol.ckind,
                id    = stack(symbol.source, function (newSource) ---@async
                    return {
                        detail      = buildDetail(newSource),
                        description = buildDesc(newSource),
                    }
                end),
            }
        end
    end
end

---@param func parser.object
---@param pad  boolean?
---@return string
local function buildluaDocOfFunction(func, pad)
    local index = 1
    ---@type string[]
    local buf = {}
    buf[#buf+1] = '${1:comment}'
    ---@type string[]
    local args = {}
    ---@type string[]
    local returns = {}
    if func.args then
        for _, arg in ipairs(func.args) do
            args[#args+1] = vm.getInfer(arg):view(guide.getUri(func))
        end
    end
    if func.returns then
        for _, rtns in ipairs(func.returns) do
            for n = 1, #rtns do
                if not returns[n] then
                    returns[n] = vm.getInfer(rtns[n]):view(guide.getUri(func))
                end
            end
        end
    end
    for n, arg in ipairs(args) do
        local funcArg = func.args[n]
        local funcArgName = funcArg[1]
        if funcArgName and funcArg.type ~= 'self' then
            index = index + 1
            buf[#buf+1] = ('---%s@param %s ${%d:%s}'):format(
                pad and ' ' or '',
                funcArgName,
                index,
                arg
            )
        end
    end
    for _, rtn in ipairs(returns) do
        index = index + 1
        buf[#buf+1] = ('---%s@return ${%d:%s}'):format(
            pad and ' ' or '',
            index,
            rtn
        )
    end
    local insertText = table.concat(buf, '\n')
    return insertText
end

---@param doc     parser.object
---@param results completion.results
---@param pad     boolean?
local function tryluaDocOfFunction(doc, results, pad)
    if not doc.bindSource then
        return
    end
    local func = (doc.bindSource.type == 'function' and doc.bindSource)
              or (doc.bindSource.value and doc.bindSource.value.type == 'function' and doc.bindSource.value)
              or nil
    if not func then
        return
    end
    for _, otherDoc in ipairs(doc.bindGroup) do
        if otherDoc.type == 'doc.return' then
            return
        end
    end
    if func.args then
        for _, param in ipairs(func.args) do
            if param.bindDocs then
                return
            end
        end
    end
    local insertText = buildluaDocOfFunction(func, pad)
    results[#results+1] = {
        label            = '@param;@return',
        kind             = define.CompletionItemKind.Snippet,
        insertTextFormat = 2,
        filterText       = '---',
        insertText       = insertText
    }
end

---Checks for a lua symbol reference in comment
---@async
---@param state    parser.state
---@param position integer
---@param results completion.results
local function trySymbolReference(state, position, results)
    local doc = getLuaDoc(state, position)
    if not doc then
        return
    end

    local line = doc.originalComment.text ---@type string
    local col = select(2, guide.rowColOf(position)) - 2 ---@type integer

    -- User will ask for completion at end of symbol name so we need to perform a reverse match to see if they are in a symbol reference
    -- Matching in reverse allows the symbol to be of any length and we can still match all the way back to `](lua://` from right to left
    local symbol = string.match(string.reverse(line), "%)?([%w%s-_.*]*)//:aul%(%]", #line - col)

    if symbol then
        -- flip it back the right way around
        symbol = string.reverse(symbol)

        for _, match in ipairs(wssymbol(symbol)) do
            results[#results+1] = {
                label = match.name --[[@as string]],
                kind = define.CompletionItemKind.Class,
                insertText = match.name --[[@as string]]
            }
        end
    end
end

--- The name of the attribute list `(a, b)` at the position, or the list itself between them.
---@param attr     parser.object
---@param position integer
---@return parser.object
local function getAttrSource(attr, position)
    for _, name in ipairs(attr.names or {}) do
        if position >= name.start and position <= name.finish then
            return name
        end
    end
    return attr
end

--- The parts after the tag word of the tag shapes a plugin registers, by the position of the word under the cursor:
--- `---@mytag <param> <kind>` (parameter name, then a kind word), `---@mytag <kind> <name>...` (a kind word, then parameter
--- names not named yet). The names are the parameters of the function the tag is bound to, the kinds the tag's list. The tag
--- is read from the text of the line, as what is typed so far does not parse into a clean tag yet.
---@param state    parser.state
---@param position integer
---@param results  completion.results
---@return boolean
---@async
local function tryTagArguments(state, position, results)
    -- the text of the short comment the cursor is in, up to the cursor (`text` starts after the two dashes that open the comment)
    ---@type string?
    local before
    for _, comm in ipairs(state.comms) do
        if comm.type == 'comment.short' and position >= comm.start and position <= comm.finish then
            before = comm.text:sub(1, position - comm.start - 2)
            break
        end
    end
    if not before then
        return false
    end
    local tag, rest = before:match('^%-+%s*@([%w_%-]+)(.*)$')
    if not tag or not rest or not rest:find('^%s') then
        return false
    end
    local docType = docTags.getMarkerTagType(tag)
    local paramFirst = docType and docTags.getParamKinds(docType)
    local kindFirst  = docType and docTags.getKindParams(docType)
    -- `---@mytag x is T`: a parameter, then a type (which completes as any type does)
    local guardFirst = docType and docTags.isGuardTag(docType)
    -- `---@mytag T: Type`: a type parameter of the class of the method, then a type
    local nameTypeFirst = docType and docTags.isNameTypeTag(docType)
    -- a marker tag whose text a plugin reads itself offers what the plugin says
    local tailCompleter = docType and docTags.getTailCompletion(docType)
    local kinds = paramFirst or kindFirst
    if not docType or not (kinds or guardFirst or nameTypeFirst or tailCompleter) then
        return false
    end
    ---@type string[]
    local words = {}
    for word in (rest:gmatch('%S+') --[[@as fun(): string]]) do
        words[#words+1] = word
    end
    local partial = ''
    if not rest:find('%s$') then
        partial = table.remove(words)
    end
    local index = #words + 1
    -- the function the tag is bound to
    local row = guide.rowColOf(position)
    ---@type parser.object?
    local func
    for _, doc in ipairs(state.ast.docs) do
        if doc.type == docType and guide.rowColOf(doc.start) == row then
            func = doc.bindSource
            break
        end
    end
    if (guardFirst or nameTypeFirst) and index > 1 then
        return false
    end
    if tailCompleter then
        local roleKinds = {
            parameter     = define.CompletionItemKind.Variable,
            typeParameter = define.CompletionItemKind.TypeParameter,
            enumMember    = define.CompletionItemKind.EnumMember,
        }
        local candidates, typed = tailCompleter { words = words, partial = partial, func = func }
        typed = typed or partial
        for _, candidate in ipairs(candidates) do
            if matchKey(typed, candidate.label) then
                results[#results+1] = {
                    label    = candidate.label,
                    kind     = roleKinds[candidate.role] or define.CompletionItemKind.Text,
                    textEdit = {
                        start   = position - #typed,
                        finish  = position,
                        newText = candidate.label,
                    },
                }
            end
        end
        return true
    end
    local wantParams = (paramFirst and index == 1) or (kindFirst and index >= 2) or guardFirst
    local wantKinds  = (paramFirst and index == 2) or (kindFirst and index == 1)
    ---@param label string
    ---@param kind   integer
    local function offer(label, kind)
        if matchKey(partial, label) then
            results[#results+1] = {
                label    = label,
                kind     = kind,
                textEdit = {
                    start   = position - #partial,
                    finish  = position,
                    newText = label,
                },
            }
        end
    end
    if wantParams and func then
        ---@type table<string, true>
        local used = {}
        for i = 2, #words do
            used[words[i]] = true
        end
        for _, arg in ipairs(func.args or {}) do
            local name = arg[1]
            if type(name) == 'string' and not (kindFirst and used[name]) then
                offer(name, define.CompletionItemKind.Variable)
            end
        end
    end
    if wantKinds then
        for kind in util.sortPairs(kinds or {}) do
            offer(kind, define.CompletionItemKind.EnumMember)
        end
    end
    if nameTypeFirst and func then
        -- (`function Box:get()`: the type parameters of the class `Box` is typed with)
        local holder = func.parent and (func.parent.type == 'setmethod' or func.parent.type == 'setfield') and func.parent.node
        for obj in vm.compileNode(holder or func):eachObject() do
            if obj.type == 'global' and obj.cate == 'type' then
                for _, set in ipairs(obj:getSets(guide.getUri(func))) do
                    for _, sign in ipairs(set.type == 'doc.class' and set.signs or {}) do
                        offer(sign[1], define.CompletionItemKind.TypeParameter)
                    end
                end
            end
        end
    end
    return true
end

---@async
---@param state    parser.state
---@param position integer
---@param results completion.results
local function tryLuaDoc(state, position, results)
    if tryTagArguments(state, position, results) then
        return
    end
    local doc = getLuaDoc(state, position)
    if not doc then
        return
    end
    if doc.type == 'doc.comment' then
        local line = doc.originalComment.text
        -- 尝试 '---$' or '--- $'
        if line == '-' or line == '- ' then
            tryluaDocOfFunction(doc, results, line == '- ')
            return
        end
        -- 尝试 ---@$
        local cate = line:match('^-+%s*@([%a%-]*)$')
        if cate then
            tryluaDocCate(cate, results)
            return
        end
    end
    -- `---@class (exact) A`: the attributes lie before the start of the node, so the search
    -- below would not go down to them
    local attr = doc.docAttr
    if attr and position >= attr.start and position <= attr.finish then
        if tryluaDocBySource(state, position, getAttrSource(attr, position), results) then
            return
        end
    end
    -- 根据输入中的source来补全
    local source = getluaDocByContain(state, position)
    if source then
        local suc = tryluaDocBySource(state, position, source, results)
        if suc then
            return
        end
    end
    -- 根据附近的错误消息来补全
    local err, expectDoc = getluaDocByErr(state, doc.start, position)
    if err then
        tryluaDocByErr(state, position, err, expectDoc, results)
        return
    end
end

---@param state    parser.state
---@param position integer
---@param results completion.results
local function tryComment(state, position, results)
    if #results > 0 then
        return
    end
    local text = state.lua
    if not text then
        return
    end
    local word = lookBackward.findWord(text, guide.positionToOffset(state, position))
    local doc  = getLuaDoc(state, position)
    if not word then
        local comment = getComment(state, position)
        if not comment then
            return
        end
        if comment.type == 'comment.short'
        or comment.type == 'comment.cshort' then
            if comment.text == '' then
                results[#results+1] = {
                    label = '#region',
                    kind  = define.CompletionItemKind.Snippet,
                }
                results[#results+1] = {
                    label = '#endregion',
                    kind  = define.CompletionItemKind.Snippet,
                }
            end
        end
        return
    end
    if doc and doc.type ~= 'doc.comment' then
        return
    end
    checkCommon(state, word, position, results)
end

---@async
---@param state            parser.state
---@param position         integer
---@param triggerCharacter string?
---@param results completion.results
local function tryCompletions(state, position, triggerCharacter, results)
    if getComment(state, position) then
        trySymbolReference(state, position, results)
        tryLuaDoc(state, position, results)
        tryComment(state, position, results)
        return
    end
    if postfix(state, position, results) then
        return
    end
    if tryTable(state, position, results) then
        return
    end
    trySpecial(state, position, results)
    tryCallArg(state, position, results)
    tryArray(state, position, results)
    -- (the keys of a string index come first: `showWord = Fallback` offers plain words only while nothing better was found)
    tryIndex(state, position, results)
    tryWord(state, position, triggerCharacter, results)
    trySymbol(state, position, results)
end

---@async
---@param uri              uri
---@param position         integer
---@param triggerCharacter string?
---@return completion.results?
local function completion(uri, position, triggerCharacter)
    local state = files.getLastState(uri) or files.getState(uri)
    if not state then
        return nil
    end
    clearStack()
    diagnostic.pause()
    local _ <close> = diagnostic.resume
    ---@type completion.results
    local results = {}
    tracy.ZoneBeginN 'completion #2'
    tryCompletions(state, position, triggerCharacter, results)
    tracy.ZoneEnd()

    if #results == 0 then
        return nil
    end

    return results
end

---@async
---@param id integer
---@return vm.completion.resolved?
local function resolve(id)
    local item = resolveStack(id)
    return item
end

---@class core.completion
---@field completion async fun(uri: uri, position: integer, triggerCharacter: string?): completion.results?
---@field resolve async fun(id: integer): vm.completion.resolved?

---@type core.completion
return {
    completion   = completion,
    resolve      = resolve,
}
