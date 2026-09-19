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

local diagnosticModes = {
    'disable-next-line',
    'disable-line',
    'disable',
    'enable',
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

local stackID = 0
---@type table<integer, async fun(): vm.completion.resolved?>
local stacks = {}

---@param oldSource parser.object
---@param callback async fun(newSource: parser.object): vm.completion.resolved
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

    for _, field in ipairs(source --[[@as parser.object[] ]]) do
        if field.start <= position and (field.range or field.finish) >= position then
            if field.type == 'tableexp' then
                if field.value.type == 'getlocal'
                or field.value.type == 'getglobal' then
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
---@return string
local function buildDetail(source)
    local types = vm.getInfer(source):view(guide.getUri(source))
    local literals = vm.getInfer(source):viewLiterals()
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
        source = source.parent --[[@as parser.object]]
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
            args[#args+1] = arg.name[1] --[[@as string]]
        else
            args[#args+1] = arg[1] --[[@as string]]
        end
    end
    if oop and args[1] ~= '...' then
        table.remove(args, 1)
    end
    return '(' .. table.concat(args, ', ') .. ')'
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
        if vm.getInfer(source):hasFunction(state.uri) then
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
                        id         = stack(source, function (newSource) ---@async
                            return {
                                detail      = buildDetail(newSource),
                                description = buildDesc(newSource),
                            }
                        end),
                    })
                end
            end
        else
            results[#results+1] = {
                label  = name,
                kind   = define.CompletionItemKind.Variable,
                id     = stack(source, function (newSource) ---@async
                    return {
                        detail      = buildDetail(newSource),
                        description = buildDesc(newSource),
                    }
                end),
            }
        end
        ::CONTINUE::
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
        local str2 = str[2] --[[@as string]]
        textEdit = {
            start   = str.start + #str2,
            finish  = position,
            newText = name:sub(#str2 + 1, - #str2 - 1),
        }
    else
        textEdit, additionalTextEdits = checkFieldFromFieldToIndex(state, name, parent, word, position)
    end
    results[#results+1] = {
        label      = name,
        kind       = kind,
        deprecated = vm.getDeprecated(src) and true or nil,
        textEdit   = textEdit,
        id         = stack(src, function (newSrc) ---@async
            return {
                detail      = buildDetail(newSrc),
                description = buildDesc(newSrc),
            }
        end),

        additionalTextEdits = additionalTextEdits,
    }
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
        local score1 = scoreMap[a] --[[@as integer]]
        local score2 = scoreMap[b] --[[@as integer]]
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
        used[result.label:match '^[^(]*' --[[@as string]]] = true
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
        if firstParam and matchKey(word, firstParam.param[1] --[[@as string]]) then
            ---@type string[]
            local label = {}
            for _, param in ipairs(params) do
                label[#label+1] = param.param[1] --[[@as string]]
            end
            results[#results+1] = {
                label = table.concat(label, ', '),
                match = firstParam.param[1] --[[@as string]],
                kind  = define.CompletionItemKind.Snippet,
            }
        end
    end
    for _, doc in ipairs(params) do
        if matchKey(word, doc.param[1] --[[@as string]]) then
            results[#results+1] = {
                label = doc.param[1] --[[@as string]],
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
    if not matchKey(source[1] --[[@as string]], state.ast[1] --[[@as string]]) then
        return nil
    end
    return util.viewString(state.ast[1] --[[@as string]], source[2] --[[@as string?]])
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
                parentName = loc[1] --[[@as string]]
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
        args[i] = ('${%d:%s}'):format(i, arg.name[1] --[[@as string]])
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
    local markTbl = mark or {} --[[@as table<vm.node.object, boolean>]]
    if markTbl[src] then
        return
    end
    markTbl[src] = true
    if src.type == 'doc.type.string'
    or src.type == 'doc.type.integer'
    or src.type == 'doc.type.boolean' then
        ---@cast src parser.object
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
        ---@cast src parser.object
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
        ---@cast src parser.object
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
    cleanEnums(enums --[[@as vm.completion.result[] ]], str)
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
    end) --[[@as parser.object?]]
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
        source = source.parent --[[@as parser.object]]
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
        checkEqualEnumLeft(state, position, parent[1] --[[@as parser.object]], results)
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
---@param results completion.results
local function tryIndex(state, position, results)
    local parent, oop = findParentInStringIndex(state, position)
    if not parent then
        return
    end
    local word = parent.next and parent.next.index and parent.next.index[1] --[[@as string?]]
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
            checkField(state, word, startPos, position, parent, oop, results)
        elseif isFuncArg(state, position) then
            checkProvideLocal(state, word, startPos, results)
            checkFunctionArgByDocParam(state, word, startPos, results)
        else
            local afterLocal = isAfterLocal(state, text, startPos)
            local stop = checkKeyWord(state, startPos, position, word, hasSpace, afterLocal, results)
            if stop then
                return
            end
            if not hasSpace then
                if afterLocal then
                    checkProvideLocal(state, word, startPos, results)
                else
                    checkLocal(state, word, startPos, results)
                    checkTableField(state, word, startPos, results)
                    local env = guide.getENV(state.ast, startPos)
                    if env then
                        checkGlobal(state, word, startPos, position, env, false, results)
                        checkModule(state, word, startPos, results)
                    end
                end
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
    ---@diagnostic disable-next-line: missing-fields
    local node = vm.compileCallArg({ type = 'dummyarg', uri = state.uri }, call, argIndex)
    if not node then
        return
    end

    ---@type table[]
    local enums = {}
    for src in node:eachObject() do
        insertEnum(state, position, src, enums, arg and arg.type == 'table')
    end
    cleanEnums(enums, arg)
    for _, enum in ipairs(enums) do
        results[#results+1] = enum
    end
end

---@param state    parser.state
---@param position integer
---@param results completion.results
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
        tbl = source.parent --[[@as parser.object]]
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
            range = (position - src.start) --[[@as number]]
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
        if  (err.finish --[[@as integer]]) <= position
        and (err.start --[[@as integer]]) >= start  then
            if not text:sub((err.finish --[[@as integer]]) + 1, position):find '%S' then
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

---@async
---@param state    parser.state
---@param position integer
---@param source   parser.object
---@param results completion.results
local function tryluaDocBySource(state, position, source, results)
    if     source.type == 'doc.extends.name' then
        if source.parent and source.parent.type == 'doc.class' then
            ---@type table<string, boolean>
            local used = {}
            for _, doc in ipairs(vm.getDocSets(state.uri)) do
                local name = doc.type == 'doc.class' and doc.class[1] --[[@as string?]]
                if  name
                and name ~= source.parent.class[1] --[[@as string]]
                and not used[name]
                and matchKey(source[1] --[[@as string]], name) then
                    used[name] = true
                    results[#results+1] = {
                        label       = name,
                        kind        = define.CompletionItemKind.Class,
                        textEdit    = name:find '[^%w_]' and {
                            start   = source.start,
                            finish  = position,
                            newText = name,
                        },
                    }
                end
            end
        end
        return true
    elseif source.type == 'doc.type.name' then
        ---@type table<string, boolean>
        local used = {}
        for _, doc in ipairs(vm.getDocSets(state.uri)) do
            local name = ((doc.type == 'doc.class' and doc.class[1])
                    or   (doc.type == 'doc.alias' and doc.alias[1])
                    or   (doc.type == 'doc.enum'  and doc.enum[1])) --[[@as string?]]
            if  name
            and not used[name]
            and matchKey(source[1] --[[@as string]], name) then
                used[name] = true
                results[#results+1] = {
                    label       = name,
                    kind        = define.CompletionItemKind.Class,
                    textEdit    = name:find '[^%w_]' and {
                        start   = source.start,
                        finish  = position,
                        newText = name,
                    },
                }
            end
        end
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
        local sourceName = source[1] --[[@as string]]
        for name in util.sortPairs(define.DiagnosticDefaultSeverity) do
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
    elseif source.type == 'doc.module' then
        collectRequireNames('require', state.uri, source.module or '', source, source.smark, position, results)
        return true
    elseif source.type == 'doc.cast.name' then
        local locals = guide.getVisibleLocals(state.ast, position)
        for name, loc in util.sortPairs(locals) do
            if matchKey(source[1] --[[@as string]], name) then
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

---@async
---@param state    parser.state
---@param position integer
---@param err      parser.state.err
---@param docState parser.object?
---@param results completion.results
local function tryluaDocByErr(state, position, err, docState, results)
    if     err.type == 'LUADOC_MISS_CLASS_EXTENDS_NAME' then
        ---@type table<string, boolean>
        local used = {}
        for _, doc in ipairs(vm.getDocSets(state.uri)) do
            local className = doc.type == 'doc.class' and doc.class[1] --[[@as string?]]
            if  className
            and not used[className]
            and docState and className ~= docState.class[1] then
                used[className] = true
                results[#results+1] = {
                    label       = className,
                    kind        = define.CompletionItemKind.Class,
                }
            end
        end
    elseif err.type == 'LUADOC_MISS_TYPE_NAME' then
        ---@type table<string, boolean>
        local used = {}
        for _, doc in ipairs(vm.getDocSets(state.uri)) do
            local className = doc.type == 'doc.class' and doc.class[1] --[[@as string?]]
            if  className
            and not used[className] then
                used[className] = true
                results[#results+1] = {
                    label       = className,
                    kind        = define.CompletionItemKind.Class,
                }
            end
            local aliasName = doc.type == 'doc.alias' and doc.alias[1] --[[@as string?]]
            if  aliasName
            and not used[aliasName] then
                used[aliasName] = true
                results[#results+1] = {
                    label       = aliasName,
                    kind        = define.CompletionItemKind.Class,
                }
            end
            local enumName = doc.type == 'doc.enum' and doc.enum[1] --[[@as string?]]
            if  enumName
            and not used[enumName] then
                used[enumName] = true
                results[#results+1] = {
                    label       = enumName,
                    kind        = define.CompletionItemKind.Enum,
                }
            end
        end
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
            local argName = arg[1] --[[@as string?]]
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
            local argName = arg[1] --[[@as string?]]
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
        local funcArgName = funcArg[1] --[[@as string?]]
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
              or nil --[[@as parser.object?]]
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

---@async
---@param state    parser.state
---@param position integer
---@param results completion.results
local function tryLuaDoc(state, position, results)
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
        local cate = line:match('^-+%s*@(%a*)$')
        if cate then
            tryluaDocCate(cate, results)
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
    tryWord(state, position, triggerCharacter, results)
    tryIndex(state, position, results)
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
