local m          = require 'lpeglabel'
local re         = require 'parser.relabel'
local guide      = require 'parser.guide'
local compile    = require 'parser.compile'
local util       = require 'utility'
local docTags    = require 'parser.docTags'

---@type table<integer, string>
local TokenTypes
---@type table<integer, integer>
local TokenStarts
---@type table<integer, integer>
local TokenFinishs
---@type table<integer, string|integer>
local TokenContents
---@type table<integer, string>
local TokenMarks
---@type integer
local Ci
---@type integer
local Offset
---@type fun(err: parser.state.err): parser.state.err?
local pushWarning
---@type fun(offset?: integer, peek?: boolean): parser.state.comm?
local NextComment
---@type { [integer]: integer, size: integer }
local Lines
---@type fun(parent?: parser.object): parser.object?
local parseType
---@type fun(parent: parser.object): parser.object?
local parseTypeUnit
---@type any
local Parser = re.compile([[
Main                <-  (Token / Sp)*
Sp                  <-  %s+
X16                 <-  [a-fA-F0-9]
Token               <-  Integer / Name / String / Code / Symbol
Name                <-  ({} {%name} {})
                    ->  Name
Integer             <-  ({} {'-'? [0-9]+} !'.' {})
                    ->  Integer
Code                <-  ({} '`' { (!'`' .)*} '`' {})
                    ->  Code
String              <-  ({} StringDef {})
                    ->  String
StringDef           <-  {'"'}
                        {~(Esc / !'"' .)*~} -> 1
                        ('"'?)
                    /   {"'"}
                        {~(Esc / !"'" .)*~} -> 1
                        ("'"?)
                    /   '[' {:eq: '='* :} '['
                        =eq -> LongStringMark
                        {(!StringClose .)*} -> 1
                        StringClose?
StringClose         <-  ']' =eq ']'
Esc                 <-  '\' -> ''
                        EChar
EChar               <-  'a' -> ea
                    /   'b' -> eb
                    /   'f' -> ef
                    /   'n' -> en
                    /   'r' -> er
                    /   't' -> et
                    /   'v' -> ev
                    /   '\'
                    /   '"'
                    /   "'"
                    /   %nl
                    /   ('z' (%nl / %s)*)     -> ''
                    /   ('x' {X16 X16})       -> Char16
                    /   ([0-9] [0-9]? [0-9]?) -> Char10
                    /   ('u{' {X16*} '}')    -> CharUtf8
Symbol              <-  ({} {
                            [:|,;<>()?+#{}*=&!]
                        /   '[]'
                        /   '...'
                        /   '['
                        /   ']'
                        /   '-' !'-'
                        /   '.' !'..'
                        } {})
                    ->  Symbol
]], {
    s  = m.S' \t\v\f',
    ea = '\a',
    eb = '\b',
    ef = '\f',
    en = '\n',
    er = '\r',
    et = '\t',
    ev = '\v',
    name = ((m.R('az', 'AZ', '09', '\x80\xff') + m.S('_')) * (m.R('az', 'AZ', '09', '\x80\xff') + m.S('_.*-'))^0),
    Char10 = function (char)
        ---@type integer?
        char = tonumber(char)
        if not char or char < 0 or char > 255 then
            return ''
        end
        return string.char(char)
    end,
    Char16 = function (char)
        return string.char(tonumber(char, 16))
    end,
    CharUtf8 = function (char)
        if #char == 0 then
            return ''
        end
        local v = tonumber(char, 16)
        if not v then
            return ''
        end
        if v >= 0 and v <= 0x10FFFF then
            return utf8.char(v)
        end
        return ''
    end,
    LongStringMark = function (back)
        return '[' .. back .. '['
    end,
    Name = function (start, content, finish)
        Ci = Ci + 1
        TokenTypes[Ci]    = 'name'
        TokenStarts[Ci]   = start
        TokenFinishs[Ci]  = finish - 1
        TokenContents[Ci] = content
    end,
    String = function (start, mark, content, finish)
        Ci = Ci + 1
        TokenTypes[Ci]    = 'string'
        TokenStarts[Ci]   = start
        TokenFinishs[Ci]  = finish - 1
        TokenContents[Ci] = content
        TokenMarks[Ci]    = mark
    end,
    Integer = function (start, content, finish)
        Ci = Ci + 1
        TokenTypes[Ci]    = 'integer'
        TokenStarts[Ci]   = start
        TokenFinishs[Ci]  = finish - 1
        TokenContents[Ci] = math.tointeger(content)
    end,
    Code = function (start, content, finish)
        Ci = Ci + 1
        TokenTypes[Ci]    = 'code'
        TokenStarts[Ci]   = start
        TokenFinishs[Ci]  = finish - 1
        TokenContents[Ci] = content
    end,
    Symbol = function (start, content, finish)
        Ci = Ci + 1
        TokenTypes[Ci]    = 'symbol'
        TokenStarts[Ci]   = start
        TokenFinishs[Ci]  = finish - 1
        TokenContents[Ci] = content
    end,
})

---@alias parser.visibleType 'public' | 'protected' | 'private' | 'package'

---@class parser.object
---@field literal           boolean
---@field signs             parser.object[]
---@field originalComment   parser.state.comm
---@field as?               parser.object
---@field touch?            integer
---@field module?           string
---@field async?            boolean
---@field versions?         table[]
---@field names?            parser.object[]
---@field path?             string
---@field line?             integer -- only set on a 'doc.source' node
---@field char?             integer -- only set on a 'doc.source' node
---@field source?           parser.object -- set on 'doc.class'/'doc.field' nodes; points at their bound 'doc.source' node
---@field bindComments?     parser.object[]
---@field visible?          parser.visibleType
---@field operators?        parser.object[]
---@field calls?            parser.object[]
---@field cases?            parser.object[][] -- on a tuple-union 'doc.return' (`(A, B) | (C, D)`): each case's per-slot 'doc.type's, detached from the tree
---@field generics?         parser.object[]
---@field generic?          parser.object
---@field docAttr?          parser.object
---@field pattern?          string
---@field package _bindedDocType? boolean
---@field default?          boolean -- set on 'doc.resume'-shaped nodes for `>`
---@field additional?       boolean -- set on 'doc.resume'-shaped nodes for `+`
---@field firstFinish?      integer -- end of the first extends entry on 'doc.class', used to pick a tailcomment split point
---@field smark?            string
---@field ge?               boolean -- set on 'doc.version.unit' nodes for a leading `>`
---@field le?               boolean -- set on 'doc.version.unit' nodes for a leading `<`
---@field version?          number|string -- set on 'doc.version.unit' nodes

---@param text string
---@param offset integer
local function parseTokens(text, offset)
    Ci = 0
    Offset = offset
    TokenTypes    = {}
    TokenStarts   = {}
    TokenFinishs  = {}
    TokenContents = {}
    TokenMarks    = {}
    Parser:match(text)
    Ci = 0
end

local function peekToken(offset)
    offset = offset or 1
    return TokenTypes[Ci + offset], TokenContents[Ci + offset]
end

---@return string? tokenType
---@return (string|integer)? tokenContent
--- The marks of the type syntax the editor colours as operators (as TypeScript does): the parser records each one it takes as
--- syntax, so a word of a tail comment (`---@param a string: the name`) that never passes through `nextToken` is not one.
---@type table<string, true>
local SyntaxMarks = {
    [':'] = true, [','] = true, ['?'] = true, ['!'] = true, ['&'] = true, ['|'] = true, ['='] = true,
    ['{'] = true, ['}'] = true, ['('] = true, [')'] = true, ['[]'] = true, ['['] = true, [']'] = true,
    ['<'] = true, ['>'] = true,
}

--- The marks taken as syntax of the doc line being parsed, by start offset (a backtracking parser may take one twice).
---@type table<integer, parser.position>
local TakenMarks = {}

local function nextToken()
    Ci = Ci + 1
    if not TokenTypes[Ci] then
        Ci = Ci - 1
        return nil, nil
    end
    if TokenTypes[Ci] == 'symbol' and SyntaxMarks[TokenContents[Ci]] then
        TakenMarks[TokenStarts[Ci] + Offset] = TokenFinishs[Ci] + Offset + 1
    end
    return TokenTypes[Ci], TokenContents[Ci]
end

local function checkToken(tp, content, offset)
    offset = offset or 0
    return  TokenTypes[Ci + offset] == tp
        and TokenContents[Ci + offset] == content
end

local function getStart()
    if Ci == 0 then
        return Offset
    end
    return TokenStarts[Ci] + Offset
end

---@return integer
local function getFinish()
    if Ci == 0 then
        return Offset
    end
    return TokenFinishs[Ci] + Offset + 1
end

--- After a param / field name that ends at `nameFinish`: is the `?` that follows the `?T` prefix form (a space
--- before it, none after it: `---@param a ?string`) rather than the optional marker (`a? string`, `a?: string`)?
---@param nameFinish integer
---@return boolean
local function isPrefixOptionalAfterName(nameFinish)
    local questionStart, questionFinish = TokenStarts[Ci + 1], TokenFinishs[Ci + 1]
    local typeStart = TokenStarts[Ci + 2]
    if not questionStart or not questionFinish or not typeStart then
        return false
    end
    return questionStart + Offset > nameFinish
       and typeStart == questionFinish + 1
end

local function getMark()
    return TokenMarks[Ci]
end

---@param callback fun(): any
---@return any
local function try(callback)
    local savePoint = Ci
    -- rollback
    local suc = callback()
    if not suc then
        Ci = savePoint
    end
    return suc
end

---@param tp string
---@param parent parser.object?
---@return parser.object?
local function parseName(tp, parent)
    local nameTp, nameText = peekToken()
    if nameTp ~= 'name' then
        return nil
    end
    nextToken()
    ---@type parser.object
    local name = {
        type   = tp,
        start  = getStart(),
        finish = getFinish(),
        ---@diagnostic expect-next-line: assign-type-mismatch
        parent = parent,
        [1]    = nameText,
    }
    return name
end

local function nextSymbolOrError(symbol)
    if checkToken('symbol', symbol, 1) then
        nextToken()
        return true
    end
    pushWarning {
        type   = 'LUADOC_MISS_SYMBOL',
        start  = getFinish(),
        finish = getFinish(),
        info   = {
            symbol = symbol,
        }
    }
    return false
end

---@param parent parser.object?
---@return parser.object?
local function parseDocAttr(parent)
    if not checkToken('symbol', '(', 1) then
        return nil
    end
    nextToken()

    ---@type parser.object
    local attrs = {
        type   = 'doc.attr',
        ---@diagnostic expect-next-line: assign-type-mismatch
        parent = parent,
        start  = getStart(),
        finish = getStart(),
        names  = {},
    }
    local names = attrs.names --[[@as parser.object[] ]]

    while true do
        if checkToken('symbol', ',', 1) then
            nextToken()
            goto continue
        end
        local name = parseName('doc.attr.name', attrs)
        if not name then
            break
        end
        names[#names+1] = name
        attrs.finish = name.finish
        ::continue::
    end

    nextSymbolOrError(')')
    attrs.finish = getFinish()

    return attrs
end

---@param parent parser.object
---@return parser.object?
local function parseIndexField(parent)
    if not checkToken('symbol', '[', 1) then
        return nil
    end
    nextToken()
    local field = parseType(parent)
    nextSymbolOrError ']'
    return field
end

local function slideToNextLine()
    if peekToken() then
        return
    end
    local nextComment = NextComment(0, true)
    if not nextComment then
        return
    end
    local currentComment = NextComment(-1, true)
    if not currentComment then
        return
    end
    local currentLine = guide.rowColOf(currentComment.start)
    local nextLine = guide.rowColOf(nextComment.start)
    if currentLine + 1 ~= nextLine then
        return
    end
    if nextComment.text:sub(1, 1) ~= '-' then
        return
    end
    if nextComment.text:match '^%-%s*%@' then
        return
    end
    NextComment()
    parseTokens(nextComment.text:sub(2), nextComment.start + 2)
end

---@param parent parser.object
---@return parser.object?
local function parseTable(parent)
    if not checkToken('symbol', '{', 1) then
        return nil
    end
    nextToken()
    ---@type parser.object
    local typeUnit = {
        type    = 'doc.type.table',
        start   = getStart(),
        parent  = parent,
        fields  = {},
    }

    while true do
        slideToNextLine()
        if checkToken('symbol', '}', 1) then
            nextToken()
            break
        end
        ---@type parser.object
        local field = {
            type   = 'doc.type.field',
            parent = typeUnit,
        }

        do
            ---@type boolean?
            local needCloseParen
            if checkToken('symbol', '(', 1) then
                nextToken()
                needCloseParen = true
            end
            local nameNode = parseName('doc.field.name', field)
                    or   parseIndexField(field)
            if not nameNode then
                pushWarning {
                    type   = 'LUADOC_MISS_FIELD_NAME',
                    start  = getFinish(),
                    finish = getFinish(),
                }
                break
            end
            field.name = nameNode
            if not field.start then
                field.start = field.name.start
            end
            if checkToken('symbol', '?', 1) then
                nextToken()
                field.optional = true
            end
            field.finish = getFinish()
            if not nextSymbolOrError(':') then
                break
            end
            field.extends = parseType(field)
            if not field.extends then
                break
            end
            field.finish = getFinish()
            if needCloseParen then
                nextSymbolOrError ')'
            end
        end

        typeUnit.fields[#typeUnit.fields+1] = field
        if checkToken('symbol', ',', 1)
        or checkToken('symbol', ';', 1) then
            nextToken()
        else
            nextSymbolOrError('}')
            break
        end
    end
    typeUnit.finish = getFinish()
    return typeUnit
end

---@param parent parser.object
---@return parser.object?
local function parseTuple(parent)
    if not checkToken('symbol', '[', 1) then
        return nil
    end
    nextToken()
    ---@type parser.object
    local typeUnit = {
        type    = 'doc.type.table',
        start   = getStart(),
        parent  = parent,
        fields  = {},
        isTuple = true,
    }

    local index = 1
    while true do
        slideToNextLine()
        if checkToken('symbol', ']', 1) then
            nextToken()
            break
        end
        ---@type parser.object
        local field = {
            type   = 'doc.type.field',
            parent = typeUnit,
        }

        do
            ---@type boolean?
            local needCloseParen
            if checkToken('symbol', '(', 1) then
                nextToken()
                needCloseParen = true
            end
            field.name = {
                type        = 'doc.type',
                start       = getFinish(),
                firstFinish = getFinish(),
                finish      = getFinish(),
                parent      = field,
            }
            field.name.types = {
                [1] = {
                    type   = 'doc.type.integer',
                    start  = getFinish(),
                    finish = getFinish(),
                    parent = field.name,
                    [1]    = index,
                }
            }
            index          = index + 1
            field.extends  = parseType(field)
            if not field.extends then
                break
            end
            field.optional = field.extends.optional
            field.start    = field.extends.start
            field.finish   = field.extends.finish
            if needCloseParen then
                nextSymbolOrError ')'
            end
        end

        typeUnit.fields[#typeUnit.fields+1] = field
        if checkToken('symbol', ',', 1)
        or checkToken('symbol', ';', 1) then
            nextToken()
        else
            nextSymbolOrError(']')
            break
        end
    end
    typeUnit.finish = getFinish()
    return typeUnit
end

---@param parent parser.object
---@return parser.object[]?
local function parseSigns(parent)
    if not checkToken('symbol', '<', 1) then
        return nil
    end
    nextToken()
    ---@type parser.object[]
    local signs = {}
    while true do
        local sign = parseName('doc.generic.name', parent)
        if not sign then
            pushWarning {
                type   = 'LUADOC_MISS_SIGN_NAME',
                start  = getFinish(),
                finish = getFinish(),
            }
            break
        end
        signs[#signs+1] = sign
        if checkToken('symbol', ',', 1) then
            nextToken()
        else
            break
        end
    end
    nextSymbolOrError '>'
    return signs
end

---@param tp string
---@param parent parser.object
---@return parser.object?
local function parseDots(tp, parent)
    if not checkToken('symbol', '...', 1) then
        return
    end
    nextToken()
    ---@type parser.object
    local dots = {
        type   = tp,
        start  = getStart(),
        finish = getFinish(),
        parent = parent,
        [1]    = '...',
    }
    return dots
end

---@param parent parser.object
---@return parser.object?
local function  parseTypeUnitFunction(parent)
    if not checkToken('name', 'fun', 1) then
        return nil
    end
    nextToken()
    ---@type parser.object
    local typeUnit = {
        type    = 'doc.type.function',
        parent  = parent,
        start   = getStart(),
        args    = {},
        returns = {},
    }
    -- Parse optional generic params: fun<T, V>(...)
    ---@diagnostic expect-next-line: assign-type-mismatch
    typeUnit.signs = parseSigns(typeUnit)
    if not nextSymbolOrError('(') then
        return nil
    end
    while true do
        slideToNextLine()
        if checkToken('symbol', ')', 1) then
            nextToken()
            break
        end
        ---@type parser.object
        local arg = {
            type   = 'doc.type.arg',
            parent = typeUnit,
        }
        local nameNode = parseName('doc.type.arg.name', arg)
                or parseDots('doc.type.arg.name', arg)
        if not nameNode then
            pushWarning {
                type   = 'LUADOC_MISS_ARG_NAME',
                start  = getFinish(),
                finish = getFinish(),
            }
            break
        end
        arg.name = nameNode
        if not arg.start then
            arg.start = arg.name.start
        end
        if checkToken('symbol', '?', 1) then
            nextToken()
            arg.optional = true
        end
        arg.finish = getFinish()
        if checkToken('symbol', ':', 1) then
            nextToken()
            arg.extends = parseType(arg)
        end
        arg.finish = getFinish()
        typeUnit.args[#typeUnit.args+1] = arg
        if checkToken('symbol', ',', 1) then
            nextToken()
        else
            nextSymbolOrError(')')
            break
        end
    end
    slideToNextLine()
    if checkToken('symbol', ':', 1) then
        nextToken()
        slideToNextLine()
        ---@type boolean?
        local needCloseParen
        if checkToken('symbol', '(', 1) then
            nextToken()
            needCloseParen = true
        end
        while true do
            slideToNextLine()
            ---@type parser.object?
            local name
            try(function ()
                local returnName = parseName('doc.return.name', typeUnit)
                                or parseDots('doc.return.name', typeUnit)
                if not returnName then
                    return false
                end
                if checkToken('symbol', ':', 1) then
                    nextToken()
                    name = returnName
                    return true
                end
                if returnName[1] == '...' then
                    name = returnName
                    return false
                end
                return false
            end)
            local rtn = parseType(typeUnit)
            if not rtn then
                break
            end
            ---@diagnostic expect-next-line: assign-type-mismatch
            rtn.name = name
            if checkToken('symbol', '?', 1) then
                nextToken()
                rtn.optional = true
            end
            ---@diagnostic expect-next-line: need-check-nil
            typeUnit.returns[#typeUnit.returns+1] = rtn
            if checkToken('symbol', ',', 1) then
                nextToken()
            else
                break
            end
        end
        if needCloseParen then
            nextSymbolOrError ')'
        end
    end
    typeUnit.finish = getFinish()
    -- Bind local generics from fun<T, V> to type names within this function
    if typeUnit.signs then
        local signs = typeUnit.signs
        ---@type table<string|integer, parser.object>
        local generics = {}
        for _, sign in ipairs(signs) do
            generics[sign[1] --[[@as string|integer]]] = sign
        end
        ---@param obj parser.object?
        local function bindTypeNames(obj)
            if not obj then return end
            if obj.type == 'doc.type.name' and generics[obj[1]] then
                obj.type = 'doc.generic.name'
                obj.generic = generics[obj[1]]
            elseif obj.type == 'doc.type' and obj.types then
                for _, t in ipairs(obj.types) do
                    bindTypeNames(t)
                end
            elseif obj.type == 'doc.type.array' then
                bindTypeNames(obj.node)
            elseif obj.type == 'doc.type.table' and obj.fields then
                for _, field in ipairs(obj.fields) do
                    bindTypeNames(field.name)
                    bindTypeNames(field.extends)
                end
            elseif obj.type == 'doc.type.sign' then
                bindTypeNames(obj.node)
                if obj.signs then
                    for _, s in ipairs(obj.signs) do
                        bindTypeNames(s)
                    end
                end
            elseif obj.type == 'doc.type.function' then
                for _, arg in ipairs(obj.args) do
                    bindTypeNames(arg.extends)
                end
                for _, ret in ipairs(obj.returns) do
                    bindTypeNames(ret)
                end
            end
        end
        for _, arg in ipairs(typeUnit.args) do
            bindTypeNames(arg.extends)
        end
        for _, ret in ipairs(typeUnit.returns) do
            bindTypeNames(ret)
        end
    end
    return typeUnit
end

---@param parent parser.object
---@return parser.object?
local function parseFunction(parent)
    local _, content = peekToken()
    if content == 'async' then
        nextToken()
        local pos = getStart()
        local tp, cont = peekToken()
        if tp == 'name' then
            if cont == 'fun' then
                local func = parseTypeUnit(parent)
                if func then
                    func.async = true
                    func.asyncPos = pos
                    return func
                end
            end
        end
    end
    if content == 'fun' then
        return parseTypeUnitFunction(parent)
    end
end

--- A plugin type keyword used as a one-argument generic (`secret<string>`) that is not the whole
--- type (an array element, one alternative of a union) becomes a nested `doc.type` of its own, the
--- same shape `(secret string)` gives, so the keyword field sits on a `doc.type` here too.
---@param unit parser.object
---@return parser.object
local function wrapKeywordSign(unit)
    if unit.type ~= 'doc.type.sign' or not unit.node or unit.node.type ~= 'doc.type.name'
    or not unit.signs or #unit.signs ~= 1 then
        return unit
    end
    local wrapperField = docTags.getTypeKeyword(unit.node[1])
    if not wrapperField then
        return unit
    end
    local inner = unit.signs[1]
    ---@type parser.object
    local wrapped = {
        type   = 'doc.type',
        start  = unit.start,
        finish = unit.finish,
        parent = unit.parent,
        types  = { inner },
        kwStart  = unit.node.start,
        kwFinish = unit.node.finish,
        [wrapperField] = true,
    }
    inner.parent = wrapped
    return wrapped
end

---@param parent parser.object
---@param node parser.object
---@return parser.object?
local function parseTypeUnitArray(parent, node)
    if not checkToken('symbol', '[]', 1) then
        return nil
    end
    nextToken()
    node = wrapKeywordSign(node)
    ---@type parser.object
    local result = {
        type   = 'doc.type.array',
        start  = node.start,
        finish = getFinish(),
        node   = node,
        parent = parent,
    }
    node.parent = result
    return result
end

---@param parent parser.object
---@param node parser.object
---@return parser.object?
local function parseTypeUnitIndexedAccess(parent, node)
    if not checkToken('symbol', '[', 1) then
        return nil
    end
    nextToken()
    local key = parseType(parent)
    if not key then
        pushWarning {
            type   = 'LUADOC_MISS_TYPE_NAME',
            start  = getFinish(),
            finish = getFinish(),
        }
        return nil
    end
    nextSymbolOrError ']'
    ---@type parser.object
    local result = {
        type   = 'doc.type.indexed',
        start  = node.start,
        finish = getFinish(),
        node   = node,
        key    = key,
        parent = parent,
    }
    node.parent = result
    key.parent  = result
    return result
end

---@param parent parser.object
---@param node parser.object
---@return parser.object?
local function parseTypeUnitSign(parent, node)
    if not checkToken('symbol', '<', 1) then
        return nil
    end
    nextToken()
    ---@type parser.object
    local result = {
        type   = 'doc.type.sign',
        start  = node.start,
        finish = getFinish(),
        node   = node,
        parent = parent,
        signs  = {},
    }
    node.parent = result
    while true do
        local sign = parseType(result)
        if not sign then
            pushWarning {
                type   = 'LUA_DOC_MISS_SIGN',
                start  = getFinish(),
                finish = getFinish(),
            }
            break
        end
        result.signs[#result.signs+1] = sign
        if checkToken('symbol', ',', 1) then
            nextToken()
        else
            break
        end
    end
    nextSymbolOrError '>'
    result.finish = getFinish()
    return result
end

---@param parent parser.object
---@return parser.object?
local function parseString(parent)
    local tp, content = peekToken()
    if not tp or tp ~= 'string' then
        return nil
    end

    nextToken()
    local mark = getMark()
    -- compatibility
    if content:sub(1, 1) == '"'
    or content:sub(1, 1) == "'" then
        if #content > 1 and content:sub(1, 1) == content:sub(-1, -1) then
            mark = content:sub(1, 1)
            content = content:sub(2, -2)
        end
    end
    ---@type parser.object
    local str = {
        type   = 'doc.type.string',
        start  = getStart(),
        finish = getFinish(),
        parent = parent,
        [1]    = content,
        [2]    = mark,
    }
    return str
end

---@param parent parser.object
---@return parser.object?
local function parseCodePattern(parent)
    local tp, pattern = peekToken()
    if not tp or (tp ~= 'name' and tp ~= 'code') then
        return nil
    end
    ---@type integer?
    local codeOffset
    ---@type string|integer?
    local content
    local i = 1
    if tp == 'code' then
        codeOffset = i
        content = pattern
        pattern = '%s'
    end
    while true do
        i = i+1
        local nextTp, nextContent = peekToken(i)
        if not nextTp or TokenFinishs[Ci+i-1] + 1 ~= TokenStarts[Ci+i] then
            ---不连续的name，无效的
            break
        end
        if nextTp == 'name' then
            pattern = pattern .. nextContent
        elseif nextTp == 'code' then
            if codeOffset then
                -- 暂时不支持多generic
                break
            end
            codeOffset = i
            pattern = pattern .. '%s'
            content = nextContent
        elseif codeOffset then
            -- should be match with Parser "name" mask
            if nextTp == 'integer' then
                pattern = pattern .. nextContent
            elseif nextTp == 'symbol' and (nextContent == '.' or nextContent == '*' or nextContent == '-') then
                pattern = pattern .. nextContent
            else
                break
            end
        else
            break
        end
    end
    if not codeOffset then
        return nil
    end
    nextToken()
    local start = getStart()
    local finishOffset = i-1
    if finishOffset == 1 then
        -- code only, no pattern
        ---@diagnostic expect-next-line: cast-local-type -- pattern's later use (as code.pattern) is optional
        pattern = nil
    else
        for _ = 2, finishOffset do
            nextToken()
        end
    end
    ---@type parser.object
    local code = {
        type   = 'doc.type.code',
        start  = start,
        finish = getFinish(),
        parent = parent,
        pattern = pattern --[[@as string?]],
        [1]    = content,
    }
    return code
end

---@param parent parser.object
---@return parser.object?
local function parseInteger(parent)
    local tp, content = peekToken()
    if not tp or tp ~= 'integer' then
        return nil
    end

    nextToken()
    ---@type parser.object
    local integer = {
        type   = 'doc.type.integer',
        start  = getStart(),
        finish = getFinish(),
        parent = parent,
        [1]    = content,
    }
    return integer
end

---@param parent parser.object
---@return parser.object?
local function parseBoolean(parent)
    local tp, content = peekToken()
    if not tp
    or tp ~= 'name'
    or (content ~= 'true' and content ~= 'false') then
        return nil
    end

    nextToken()
    ---@type parser.object
    local boolean = {
        type   = 'doc.type.boolean',
        start  = getStart(),
        finish = getFinish(),
        parent = parent,
        [1]    = content == 'true' and true or false,
    }
    return boolean
end

---@param parent parser.object
---@return parser.object?
local function parseParen(parent)
    if not checkToken('symbol', '(', 1) then
        return
    end
    nextToken()
    local tp = parseType(parent)
    -- `(T extends U ? X : Y)` (TypeScript's conditional types): checked here, inside the parens
    -- and before they close, rather than as a general postfix on any type -- a bare `extends`
    -- straight after a type, with no parens, is indistinguishable from the start of an ordinary
    -- English tail comment (`---@param x string extends the base config`), and `parseType` runs
    -- on the same token stream a tail comment's words come from. Requiring parens keeps the
    -- grammar unambiguous: nothing containing a bare `extends` at the top level of a type was
    -- ever valid syntax, but a tail comment starting with the word right after a plain type is
    -- exactly the shape that would have silently misparsed without this restriction.
    if tp and checkToken('name', 'extends', 1) then
        nextToken()
        local kwStart, kwFinish = getStart(), getFinish()
        local extendsType = parseType(tp)
        if not extendsType then
            pushWarning {
                type   = 'LUADOC_MISS_TYPE_NAME',
                start  = getFinish(),
                finish = getFinish(),
            }
        end
        -- `parseType`'s own trailing `?` (optional-suffix) check already consumed the ternary `?`
        -- right after `U` as if it meant `U?` -- undo that reading and treat it as having
        -- satisfied the `?` this needs, instead of requiring a second one.
        local hadQuestion = extendsType and extendsType.optional
        if extendsType then
            extendsType.optional = nil
        end
        if not hadQuestion then
            nextSymbolOrError '?'
        end
        local trueType = parseType(tp)
        nextSymbolOrError ':'
        local falseType = parseType(tp)
        ---@type parser.object
        local condResult = {
            type      = 'doc.type.conditional',
            kwStart   = kwStart,
            kwFinish  = kwFinish,
            start     = tp.start,
            finish    = getFinish(),
            parent    = parent,
            check     = tp,
            extends   = extendsType,
            trueType  = trueType,
            falseType = falseType,
        }
        tp.parent = condResult
        if extendsType then
            extendsType.parent = condResult
        end
        if trueType then
            trueType.parent = condResult
        end
        if falseType then
            falseType.parent = condResult
        end
        nextSymbolOrError(')')
        condResult.finish = getFinish()
        return condResult
    end
    nextSymbolOrError(')')
    return tp
end

---@param parent parser.object
---@return parser.object?
local function parseTypeUnitKeyof(parent)
    if not checkToken('name', 'keyof', 1) then
        return nil
    end
    nextToken()
    local kwStart = getStart()
    local kwFinish = getFinish()
    local node = parseTypeUnit(parent)
    if not node then
        pushWarning {
            type   = 'LUADOC_MISS_TYPE_NAME',
            start  = getFinish(),
            finish = getFinish(),
        }
        return nil
    end
    ---@type parser.object
    local result = {
        type   = 'doc.type.keyof',
        start  = kwStart,
        finish = node.finish,
        node   = node,
        parent = parent,
        kwStart  = kwStart,
        kwFinish = kwFinish,
    }
    node.parent = result
    return result
end

function parseTypeUnit(parent)
    local result = parseTypeUnitKeyof(parent)
                or parseFunction(parent)
                or parseTable(parent)
                or parseTuple(parent)
                or parseString(parent)
                or parseInteger(parent)
                or parseBoolean(parent)
                or parseParen(parent)
                or parseCodePattern(parent)
    if not result then
        result = parseName('doc.type.name', parent)
              or parseDots('doc.type.name', parent)
        if not result then
            return nil
        end
        if result[1] == '...' then
            result[1] = 'unknown'
        end
    end
    while true do
        local newResult = parseTypeUnitSign(parent, result)
        if not newResult then
            break
        end
        result = newResult
    end
    while true do
        local newResult = parseTypeUnitArray(parent, result)
        if not newResult then
            break
        end
        result = newResult
    end
    while true do
        local newResult = parseTypeUnitIndexedAccess(parent, result)
        if not newResult then
            break
        end
        result = newResult
    end
    return result
end

--- `A & B` (TypeScript's intersection types): binds tighter than `|` (parsed one level above
--- `parseTypeUnit`, one level below `parseType`'s own `|`-loop), so `A & B | C` is `(A & B) | C`.
--- A single unit with no `&` after it returns unwrapped -- no `doc.type.intersection` node for the
--- common case of a plain type with no `&` at all.
---@param parent parser.object
---@return parser.object?
local function parseTypeIntersection(parent)
    local first = parseTypeUnit(parent)
    if not first then
        return nil
    end
    if not checkToken('symbol', '&', 1) then
        return first
    end
    ---@type parser.object
    local result = {
        type   = 'doc.type.intersection',
        start  = first.start,
        parent = parent,
        types  = { first },
    }
    first.parent = result
    while checkToken('symbol', '&', 1) do
        nextToken()
        local unit = parseTypeUnit(result)
        if not unit then
            pushWarning {
                type   = 'LUADOC_MISS_TYPE_NAME',
                start  = getFinish(),
                finish = getFinish(),
            }
            break
        end
        result.types[#result.types+1] = unit
    end
    result.finish = getFinish()
    return result
end

---@param parent parser.object
---@return parser.object?
local function parseResume(parent)
    ---@type boolean?, boolean?
    local default, additional
    if checkToken('symbol', '>', 1) then
        nextToken()
        default = true
    end

    if checkToken('symbol', '+', 1) then
        nextToken()
        additional = true
    end

    local result = parseTypeUnit(parent)
    if result then
        result.default    = default
        result.additional = additional
    end

    return result
end

local lockResume = false

function parseType(parent)
    ---@type parser.object
    local result = {
        type    = 'doc.type',
        parent  = parent,
        types   = {},
    }
    -- a plugin type keyword (`secret string`): only when a type follows it
    ---@type string?
    local keywordField
    ---@type integer?
    local keywordStart
    ---@type integer?
    local keywordFinish
    local keywordTp, keyword = peekToken()
    if keywordTp == 'name' and keyword then
        ---@cast keyword string -- a 'name' token always carries its text
        keywordField = docTags.getTypeKeyword(keyword)
        if keywordField then
            local nextTp, nextContent = peekToken(2)
            if not (nextTp == 'name'
                or  nextTp == 'string'
                or (nextTp == 'symbol' and (nextContent == '(' or nextContent == '{' or nextContent == '['))) then
                keywordField = nil
            else
                nextToken()
                keywordStart, keywordFinish = getStart(), getFinish()
            end
        end
    end
    -- `?T` (wowlua-ls): the same as `T?`, only when a type follows the `?`
    local prefixOptional = false
    if keywordTp == 'symbol' and keyword == '?' then
        local nextTp, nextContent = peekToken(2)
        if nextTp == 'name'
        or nextTp == 'string'
        or (nextTp == 'symbol' and (nextContent == '(' or nextContent == '{' or nextContent == '[')) then
            nextToken()
            prefixOptional = true
        end
    end
    result.kwStart, result.kwFinish = keywordStart, keywordFinish
    while true do
        local typeUnit = parseTypeIntersection(result)
        if not typeUnit then
            break
        end

        result.types[#result.types+1] = typeUnit
        if not result.start then
            result.start = typeUnit.start
        end

        if not checkToken('symbol', '|', 1) then
            break
        end
        nextToken()
    end
    -- A plugin type keyword wrapped as a one-argument generic instead of a bare prefix
    -- (`secret<string>` for `secret string`) is pure sugar: unwrap it into the same shape the
    -- prefix form produces (the inner type promoted to this `doc.type`'s own sole member, the
    -- keyword field set here instead of on a `doc.type.sign`), so every consumer of the prefix
    -- form (vm.node flag genesis rules, or a plain field read directly off a `doc.type` like
    -- `nosecret` -- see secret-access.lua) sees an identical result either way. Only when it
    -- is the type's sole member (matching the prefix form, which always covers the whole `doc.type`,
    -- never just one union alternative) and not already using the prefix form.
    if not keywordField and #result.types > 1 then
        for i, member in ipairs(result.types) do
            result.types[i] = wrapKeywordSign(member)
        end
    end
    if not keywordField and #result.types == 1 then
        local sole = result.types[1]
        if sole.type == 'doc.type.sign' and sole.node and sole.node.type == 'doc.type.name'
        and sole.signs and #sole.signs == 1 then
            local wrapperField = docTags.getTypeKeyword(sole.node[1])
            if wrapperField then
                local inner = sole.signs[1]
                inner.parent = result
                result.types[1] = inner
                result[wrapperField] = true
                result.kwStart, result.kwFinish = sole.node.start, sole.node.finish
            end
        end
    end
    if not result.start then
        result.start = getFinish()
    end
    if checkToken('symbol', '?', 1) then
        nextToken()
        result.optional = true
    elseif checkToken('symbol', '!', 1) then
        -- lateinit (`T!`, wowlua-ls interop): conceptually non-nil, but may be nil mid-lifecycle
        -- (object pools, a separate `:Init()`). A core type-system marker, like `.optional` --
        -- `need-check-nil`/`field-type-mismatch` read `.lateinit` to exempt it from their usual
        -- nil-guard / nil-assignment checks (not owned by any `extra/` plugin).
        nextToken()
        result.lateinit = true
    end
    if prefixOptional then
        result.optional = true
        result.prefixOptional = true
    end
    if keywordField then
        -- plugin-supplied field name, not known statically
        result[keywordField] = true
    end
    result.finish = getFinish()
    result.firstFinish = result.finish

    local row = guide.rowColOf(result.finish)

    local function pushResume()
        ---@type string[]?
        local comments
        for i = 0, 100 do
            local nextComm = NextComment(i, true)
            if not nextComm then
                return false
            end
            local nextCommRow = guide.rowColOf(nextComm.start)
            local currentRow = row + i + 1
            if currentRow < nextCommRow then
                return false
            end
            if nextComm.text:match '^%-%s*%@' then
                return false
            else
                local resumeHead = nextComm.text:match '^%-%s*%|'
                if resumeHead then
                    NextComment(i)
                    row = row + i + 1
                    local finishPos = nextComm.text:find('#', #resumeHead + 1) or #nextComm.text
                    parseTokens(nextComm.text:sub(#resumeHead + 1, finishPos), nextComm.start + #resumeHead + 1)
                    local resume = parseResume(result)
                    if resume then
                        -- doc.resume nodes store a plain string here, unlike the usual
                        -- table-shaped { type = 'doc.tailcomment', ... } comment node
                        if comments then
                            resume.comment = table.concat(comments, '\n')
                        else
                            resume.comment = nextComm.text:match('%s*#?%s*(.+)', resume.finish - nextComm.start)
                        end
                        result.types[#result.types+1] = resume
                        result.finish = resume.finish
                    end
                    comments = nil
                    return true
                else
                    if not comments then
                        comments = {}
                    end
                    comments[#comments+1] = nextComm.text:sub(2)
                end
            end
        end
        return false
    end

    if not lockResume then
        lockResume = true
        while pushResume() do end
        lockResume = false
    end

    if #result.types == 0 then
        pushWarning {
            type   = 'LUADOC_MISS_TYPE_NAME',
            start  = getFinish(),
            finish = getFinish(),
        }
        return nil
    end
    return result
end

local docSwitch = util.switch()
    : case 'class'
    : call(function ()
        ---@type parser.object
        local result = {
            type      = 'doc.class',
            fields    = {},
            operators = {},
            calls     = {},
        }
        result.docAttr = parseDocAttr(result)
        local classNode = parseName('doc.class.name', result)
        if not classNode then
            pushWarning {
                type   = 'LUADOC_MISS_CLASS_NAME',
                start  = getFinish(),
                finish = getFinish(),
            }
            return nil
        end
        result.class = classNode
        result.start  = getStart()
        result.finish = getFinish()
        ---@diagnostic expect-next-line: assign-type-mismatch
        result.signs  = parseSigns(result)
        if not checkToken('symbol', ':', 1) then
            return result
        end
        nextToken()

        result.extends = {}

        while true do
            local extend = parseName('doc.extends.name', result)
                        or parseTable(result)
                        or parseTuple(result)
            if not extend then
                pushWarning {
                    type   = 'LUADOC_MISS_CLASS_EXTENDS_NAME',
                    start  = getFinish(),
                    finish = getFinish(),
                }
                return result
            end
            if extend.type == 'doc.extends.name' then
                local signResult = parseTypeUnitSign(result, extend)
                if signResult then
                    extend = signResult
                end
            end
            result.extends[#result.extends+1] = extend
            result.finish = getFinish()
            -- `&` is accepted as an alternate separator alongside `,` -- `@class X : A & B` reads
            -- naturally when the parents are mixins, and both spellings already mean the same thing
            -- here (multiple parents to inherit from), same as the general `A & B` intersection
            -- type elsewhere just lists several types together.
            if not checkToken('symbol', ',', 1) and not checkToken('symbol', '&', 1) then
                break
            end
            nextToken()
        end
        return result
    end)
    : case 'type'
    : call(function ()
        local first = parseType()
        if not first then
            return nil
        end
        ---@type parser.object[]?
        local rests
        while checkToken('symbol', ',', 1) do
            nextToken()
            local rest = parseType()
            if not rests then
                rests = {}
            end
            rests[#rests+1] = rest
        end
        return first, rests
    end)
    : case 'alias'
    : call(function ()
        ---@type parser.object
        local result = {
            type   = 'doc.alias',
        }
        result.docAttr = parseDocAttr(result)
        local aliasNode = parseName('doc.alias.name', result)
        if not aliasNode then
            pushWarning {
                type   = 'LUADOC_MISS_ALIAS_NAME',
                start  = getFinish(),
                finish = getFinish(),
            }
            return nil
        end
        result.alias = aliasNode
        result.start  = getStart()
        ---@diagnostic expect-next-line: assign-type-mismatch
        result.signs  = parseSigns(result)
        result.extends = parseType(result)
        if not result.extends then
            pushWarning {
                type   = 'LUADOC_MISS_ALIAS_EXTENDS',
                start  = getFinish(),
                finish = getFinish(),
            }
            return nil
        end
        result.finish = getFinish()
        return result
    end)
    : case 'param'
    : call(function ()
        ---@type parser.object
        local result = {
            type   = 'doc.param',
        }
        local paramNode = parseName('doc.param.name', result)
                    or parseDots('doc.param.name', result)
        if not paramNode then
            pushWarning {
                type   = 'LUADOC_MISS_PARAM_NAME',
                start  = getFinish(),
                finish = getFinish(),
            }
            return nil
        end
        result.param = paramNode
        if checkToken('symbol', '?', 1) then
            result.prefixOptional = isPrefixOptionalAfterName(paramNode.finish) or nil
            nextToken()
            result.optional = true
        end
        result.start  = result.param.start
        result.finish = getFinish()
        result.extends = parseType(result)
        if not result.extends then
            pushWarning {
                type   = 'LUADOC_MISS_PARAM_EXTENDS',
                start  = getFinish(),
                finish = getFinish(),
            }
            return result
        end
        result.finish = getFinish()
        result.firstFinish = result.extends.firstFinish
        return result
    end)
    : case 'return'
    : call(function ()
        ---@type parser.object
        local result = {
            type    = 'doc.return',
            returns = {},
        }
        -- Tuple-union (wowlua-ls interop): `---@return (A, B) | (C, D)` -- the function returns one
        -- of the listed tuples, all of the same width. Each slot's type is the union of that slot
        -- across the cases (so ordinary typing needs nothing new: `result.returns` is the usual
        -- per-slot list), and the cases themselves are kept as `result.cases` (each a list of the
        -- per-slot `doc.type`s, detached from the tree -- read only for their nil-ness) so the flow
        -- analysis can tell which slots are always nil/non-nil together (vm/flow.lua,
        -- `casesCorrelation`). Tried speculatively and rolled back unless there are at least two
        -- cases of equal width, so the labeled shorthand below and a plain grouped type still parse
        -- the way they always did.
        if checkToken('symbol', '(', 1) then
            try(function ()
                ---@type parser.object[][]
                local cases = {}
                while true do
                    if not checkToken('symbol', '(', 1) then
                        return false
                    end
                    nextToken()
                    ---@type parser.object[]
                    local caseTypes = {}
                    while true do
                        local docType = parseType(result)
                        if not docType then
                            return false
                        end
                        caseTypes[#caseTypes+1] = docType
                        if not checkToken('symbol', ',', 1) then
                            break
                        end
                        nextToken()
                    end
                    if not checkToken('symbol', ')', 1) then
                        return false
                    end
                    nextToken()
                    cases[#cases+1] = caseTypes
                    if not checkToken('symbol', '|', 1) then
                        break
                    end
                    nextToken()
                end
                if #cases < 2 then
                    return false
                end
                local width = #cases[1]
                for k = 2, #cases do
                    if #cases[k] ~= width then
                        return false
                    end
                end
                ---@type parser.object[]
                local slots = {}
                for i = 1, width do
                    ---@type parser.object
                    local union = {
                        type   = 'doc.type',
                        parent = result,
                        types  = {},
                        start  = cases[1][i].start,
                        finish = cases[#cases][i].finish,
                    }
                    ---@type parser.object[]
                    local nilUnits = {}
                    for k = 1, #cases do
                        local caseSlot = cases[k][i]
                        for _, unit in ipairs(caseSlot.types) do
                            unit.parent = union
                            if unit.type == 'doc.type.name' and unit[1] == 'nil' then
                                nilUnits[#nilUnits+1] = unit
                            else
                                union.types[#union.types+1] = unit
                            end
                        end
                        if caseSlot.optional then
                            union.optional = true
                        end
                    end
                    -- `string | nil` is `string?` everywhere else in the engine (the `.optional`
                    -- flag, not a `nil` member): normalize to that, so a tuple-union slot types and
                    -- narrows exactly like the plain `---@return string?` it is equivalent to. A
                    -- slot that is only ever `nil` stays a plain `nil` type.
                    if #nilUnits > 0 then
                        if #union.types > 0 then
                            union.optional = true
                        else
                            union.types[1] = nilUnits[1]
                        end
                    end
                    union.firstFinish = union.finish
                    slots[i] = union
                end
                result.start   = slots[1].start
                result.returns = slots
                result.cases   = cases
                result.finish  = getFinish()
                return true
            end)
            ---@diagnostic expect-next-line: need-check-nil
            if #result.returns > 0 then
                return result
            end
        end
        -- Labeled tuple shorthand: `---@return (A name, B name2)` is sugar for the equivalent
        -- comma-separated `---@return A name` / `---@return B name2` lines below -- same AST, same
        -- `result.returns` list, just written compactly in one pair of parens (wowlua-ls interop).
        -- Tried speculatively (`try`, rolled back on failure) because a single parenthesized type
        -- with no name, `---@return (SomeType)`, is already valid syntax elsewhere (an ordinary
        -- grouped/cast type) and must keep parsing the normal way below.
        if checkToken('symbol', '(', 1) then
            try(function ()
                local savePoint = Ci
                nextToken()
                ---@type parser.object[]
                local tupleReturns = {}
                while true do
                    local docType = parseType(result)
                    if not docType then
                        Ci = savePoint
                        return false
                    end
                    if checkToken('symbol', '?', 1) then
                        nextToken()
                        docType.optional = true
                    end
                    ---@diagnostic expect-next-line: assign-type-mismatch
                    docType.name = parseName('doc.return.name', docType)
                                or parseDots('doc.return.name', docType)
                    if not docType.name then
                        -- no label: not the tuple-shorthand shape (could be a plain grouped type,
                        -- or a tuple-union case `(A, B) | (C, D)` -- neither is this feature)
                        Ci = savePoint
                        return false
                    end
                    tupleReturns[#tupleReturns+1] = docType
                    if not checkToken('symbol', ',', 1) then
                        break
                    end
                    nextToken()
                end
                if not checkToken('symbol', ')', 1) then
                    Ci = savePoint
                    return false
                end
                nextToken()
                if checkToken('symbol', '|', 1) then
                    -- a tuple-union case (`(A, B) | (C, D)`), not this shorthand -- not supported
                    -- here, let the caller's own type parsing (or a future feature) handle it
                    Ci = savePoint
                    return false
                end
                result.start   = tupleReturns[1].start
                result.returns = tupleReturns
                result.finish  = getFinish()
                return true
            end)
            -- `result.returns` is set to `{}` above, unconditionally, outside this closure; the
            -- closure only ever reassigns it to a non-empty list on success, never clears it --
            -- correlated invariant the checker can't see through a closure's own reassignment.
            ---@diagnostic expect-next-line: need-check-nil
            if #result.returns > 0 then
                return result
            end
        end
        while true do
            local dots = parseDots('doc.return.name', result)
            if dots then
                -- `...T` written together (wowlua-ls): the type of the remaining returns, so the type is parsed
                -- from here; a lone `...` (or `... words`) stays the unknown vararg it always was
                local nextStart = TokenStarts[Ci + 1]
                if not (TokenTypes[Ci + 1] == 'name' and nextStart and nextStart == TokenFinishs[Ci] + 1) then
                    Ci = Ci - 1
                end
            end
            local docType = parseType(result)
            if not docType then
                break
            end
            if not result.start then
                result.start = docType.start
            end
            if checkToken('symbol', '?', 1) then
                nextToken()
                docType.optional = true
            end
            if dots then
                docType.name = dots
                dots.parent  = docType
            else
                ---@diagnostic expect-next-line: assign-type-mismatch
                docType.name = parseName('doc.return.name', docType)
                            or parseDots('doc.return.name', docType)
            end
            ---@diagnostic expect-next-line: need-check-nil
            result.returns[#result.returns+1] = docType
            if not checkToken('symbol', ',', 1) then
                break
            end
            nextToken()
        end
        ---@diagnostic expect-next-line: need-check-nil
        if #result.returns == 0 then
            return nil
        end
        result.finish = getFinish()
        return result
    end)
    : case 'field'
    : call(function ()
        ---@type parser.object
        local result = {
            type = 'doc.field',
        }
        try(function ()
            local tp, value = nextToken()
            if tp == 'name' then
                assert(value)
                ---@cast value string -- tp == 'name' always pairs with string content
                if value == 'public'
                or value == 'protected'
                or value == 'private'
                or value == 'package' then
                    local tp2 = peekToken(1)
                    local tp3 = peekToken(2)
                    if tp2 == 'name' and not tp3 then
                        return false
                    end
                    result.visible = value
                    result.start = getStart()
                    return true
                end
                local fieldResultKey = docTags.getFieldKeyword(value)
                if fieldResultKey then
                    local tp2 = peekToken(1)
                    local tp3 = peekToken(2)
                    if tp2 == 'name' and not tp3 then
                        return false
                    end
                    -- fieldResultKey is a plugin-supplied string (see
                    -- docTags.registerFieldKeyword), so its actual name
                    -- can't be known statically here
                    result[fieldResultKey] = true
                    result.start = getStart()
                    return true
                end
            end
            return false
        end)
        result.field = parseName('doc.field.name', result)
                    or parseIndexField(result)
        if not result.field then
            pushWarning {
                type   = 'LUADOC_MISS_FIELD_NAME',
                start  = getFinish(),
                finish = getFinish(),
            }
            return nil
        end
        if not result.start then
            result.start = result.field.start
        end
        if checkToken('symbol', '?', 1) then
            nextToken()
            result.optional = true
        end
        result.extends = parseType(result)
        if not result.extends then
            pushWarning {
                type   = 'LUADOC_MISS_FIELD_EXTENDS',
                start  = getFinish(),
                finish = getFinish(),
            }
            return nil
        end
        result.finish = getFinish()
        return result
    end)
    : case 'generic'
    : call(function ()
        ---@type parser.object
        local result = {
            type = 'doc.generic',
            generics = {},
        }
        while true do
            ---@type parser.object
            local object = {
                type = 'doc.generic.object',
                parent = result,
            }
            object.generic = parseName('doc.generic.name', object)
            if not object.generic then
                pushWarning {
                    type   = 'LUADOC_MISS_GENERIC_NAME',
                    start  = getFinish(),
                    finish = getFinish(),
                }
                return nil
            end
            object.start = object.generic.start
            if not result.start then
                result.start = object.start
            end
            -- `T: Base`, or TypeScript's `T extends Base`
            local isExtendsWord = checkToken('name', 'extends', 1)
            if checkToken('symbol', ':', 1) or isExtendsWord then
                nextToken()
                if isExtendsWord then
                    -- (the word is a keyword to colour; the colon is a symbol)
                    object.kwStart, object.kwFinish = getStart(), getFinish()
                end
                object.extends = parseType(object)
            end
            -- `---@generic T = string` (TypeScript's default type parameter): the type `resolve()`
            -- falls back to when nothing infers `T` (an argument typed `T` was not given, or was `nil`).
            -- Named `defaultType`, not `default`: that name is already a boolean on 'doc.resume' nodes.
            if checkToken('symbol', '=', 1) then
                nextToken()
                object.defaultType = parseType(object)
            end
            object.finish = getFinish()
            ---@diagnostic expect-next-line: need-check-nil
            result.generics[#result.generics+1] = object
            if not checkToken('symbol', ',', 1) then
                break
            end
            nextToken()
        end
        result.finish = getFinish()
        return result
    end)
    : case 'vararg'
    : call(function ()
        ---@type parser.object
        local result = {
            type = 'doc.vararg',
        }
        local varargNode = parseType(result)
        if not varargNode then
            pushWarning {
                type   = 'LUADOC_MISS_VARARG_TYPE',
                start  = getFinish(),
                finish = getFinish(),
            }
            return
        end
        result.vararg = varargNode
        result.start = result.vararg.start
        result.finish = result.vararg.finish
        return result
    end)
    : case 'overload'
    : call(function ()
        local tp, name = peekToken()
        if tp ~= 'name'
        or (name ~= 'fun' and name ~= 'async') then
            pushWarning {
                type   = 'LUADOC_MISS_FUN_AFTER_OVERLOAD',
                start  = getFinish(),
                finish = getFinish(),
            }
            return nil
        end
        ---@type parser.object
        local result = {
            type = 'doc.overload',
        }
        local overloadNode = parseFunction(result)
        if not overloadNode then
            return nil
        end
        result.overload = overloadNode
        result.overload.parent = result
        result.start = result.overload.start
        result.finish = result.overload.finish
        return result
    end)
    : case 'meta'
    : call(function ()
        ---@type parser.object
        local meta = {
            type   = 'doc.meta',
            start  = getFinish(),
            finish = getFinish(),
        }
        ---@diagnostic expect-next-line: assign-type-mismatch
        meta.name = parseName('doc.meta.name', meta)
        return meta
    end)
    : case 'version'
    : call(function ()
        ---@type parser.object
        local result = {
            type     = 'doc.version',
            versions = {},
        }
        while true do
            local tp, text = nextToken()
            if not tp then
                pushWarning {
                    type  = 'LUADOC_MISS_VERSION',
                    start  = getFinish(),
                    finish = getFinish(),
                }
                break
            end
            if not result.start then
                result.start = getStart()
            end
            ---@type parser.object
            local version = {
                type   = 'doc.version.unit',
                parent = result,
                start  = getStart(),
            }
            if tp == 'symbol' then
                if text == '>' then
                    version.ge = true
                elseif text == '<' then
                    version.le = true
                end
                tp, text = nextToken()
            end
            if tp ~= 'name' then
                pushWarning {
                    type  = 'LUADOC_MISS_VERSION',
                    start  = getStart(),
                    finish = getFinish(),
                }
                break
            end
            version.version = tonumber(text) or text
            version.finish = getFinish()
            ---@diagnostic expect-next-line: need-check-nil
            result.versions[#result.versions+1] = version
            if not checkToken('symbol', ',', 1) then
                break
            end
            nextToken()
        end
        ---@diagnostic expect-next-line: need-check-nil
        if #result.versions == 0 then
            return nil
        end
        result.finish = getFinish()
        return result
    end)
    : case 'see'
    : call(function ()
        ---@type parser.object
        local result = {
            type     = 'doc.see',
        }
        local nameNode = parseName('doc.see.name', result)
        if not nameNode then
            pushWarning {
                type  = 'LUADOC_MISS_SEE_NAME',
                start  = getFinish(),
                finish = getFinish(),
            }
            return nil
        end
        result.name = nameNode
        result.start  = result.name.start
        result.finish = result.name.finish
        return result
    end)
    : case 'diagnostic'
    : call(function ()
        ---@type parser.object
        local result = {
            type = 'doc.diagnostic',
        }
        local nextTP, mode = nextToken()
        if nextTP ~= 'name' then
            pushWarning {
                type   = 'LUADOC_MISS_DIAG_MODE',
                start  = getFinish(),
                finish = getFinish(),
            }
            return nil
        end
        result.mode   = mode --[[@as '+'|'-'|'disable-next-line'|'disable-line'|'disable'|'enable'|'expect-next-line'|'expect-line']]
        result.start  = getStart()
        result.finish = getFinish()
        if  mode ~= 'disable-next-line'
        and mode ~= 'disable-line'
        and mode ~= 'disable'
        and mode ~= 'enable'
        and mode ~= 'expect-next-line'
        and mode ~= 'expect-line' then
            pushWarning {
                type   = 'LUADOC_ERROR_DIAG_MODE',
                start  = result.start,
                finish = result.finish,
            }
        end

        if checkToken('symbol', ':', 1) then
            nextToken()
            result.names = {}
            while true do
                local name = parseName('doc.diagnostic.name', result)
                if not name then
                    pushWarning {
                        type   = 'LUADOC_MISS_DIAG_NAME',
                        start  = getFinish(),
                        finish = getFinish(),
                    }
                    return result
                end
                result.names[#result.names+1] = name
                if not checkToken('symbol', ',', 1) then
                    break
                end
                nextToken()
            end
        end

        result.finish = getFinish()

        return result
    end)
    : case 'module'
    : call(function ()
        ---@type parser.object
        local result = {
            type     = 'doc.module',
            start    = getFinish(),
            finish   = getFinish(),
        }
        local tp, content = peekToken()
        if tp == 'string' then
            result.module = content --[[@as string]]
            nextToken()
            result.start  = getStart()
            result.finish = getFinish()
            result.smark  = getMark()
        else
            pushWarning {
                type   = 'LUADOC_MISS_MODULE_NAME',
                start  = getFinish(),
                finish = getFinish(),
            }
        end
        return result
    end)
    : case 'async'
    : call(function ()
        return {
            type   = 'doc.async',
            start  = getFinish(),
            finish = getFinish(),
        }
    end)
    : case 'nodiscard'
    : call(function ()
        return {
            type   = 'doc.nodiscard',
            start  = getFinish(),
            finish = getFinish(),
        }
    end)
    : case 'as'
    : call(function ()
        ---@type parser.object
        local result = {
            type   = 'doc.as',
            start  = getFinish(),
            finish = getFinish(),
        }
        result.as     = parseType(result)
        result.finish = getFinish()
        return result
    end)
    : case 'cast'
    : call(function ()
        ---@type parser.object
        local result = {
            type   = 'doc.cast',
            start  = getFinish(),
            finish = getFinish(),
            casts  = {},
        }

        local loc = parseName('doc.cast.name', result)
        if not loc then
            pushWarning {
                type   = 'LUADOC_MISS_LOCAL_NAME',
                start  = getFinish(),
                finish = getFinish(),
            }
            return result
        end

        result.name   = loc
        result.finish = loc.finish

        while true do
            ---@type parser.object
            local block = {
                type   = 'doc.cast.block',
                parent = result,
                start  = getFinish(),
                finish = getFinish(),
            }
            if     checkToken('symbol', '+', 1) then
                block.mode = '+'
                nextToken()
                block.start  = getStart()
                block.finish = getFinish()
            elseif checkToken('symbol', '-', 1) then
                block.mode = '-'
                nextToken()
                block.start  = getStart()
                block.finish = getFinish()
            end

            if checkToken('symbol', '?', 1) then
                block.optional = true
                nextToken()
                block.finish = getFinish()
            else
                block.extends = parseType(block)
                if block.extends then
                    block.start  = block.start or block.extends.start
                    block.finish = block.extends.finish
                end
            end

            if block.optional or block.extends then
                result.casts[#result.casts+1] = block
            end
            result.finish = block.finish

            if checkToken('symbol', ',', 1) then
                nextToken()
            else
                break
            end
        end

        return result
    end)
    : case 'operator'
    : call(function ()
        ---@type parser.object
        local result = {
            type   = 'doc.operator',
            start  = getFinish(),
            finish = getFinish(),
        }

        local op = parseName('doc.operator.name', result)
        if not op then
            pushWarning {
                type   = 'LUADOC_MISS_OPERATOR_NAME',
                start  = getFinish(),
                finish = getFinish(),
            }
            return nil
        end
        result.op = op
        result.finish = op.finish

        if checkToken('symbol', '(', 1) then
            nextToken()
            if checkToken('symbol', ')', 1) then
                nextToken()
            else
                local exp = parseType(result)
                if exp then
                    result.exp = exp
                    result.finish = exp.finish
                end
                nextSymbolOrError ')'
            end
        end

        nextSymbolOrError ':'

        local ret = parseType(result)
        if ret then
            result.extends = ret
            result.finish  = ret.finish
        end

        return result
    end)
    : case 'source'
    ---@param doc string
    ---@return parser.object?
    : call(function (doc)
        local fullSource = doc:sub(#'source' + 1)
        if not fullSource or fullSource == '' then
            return
        end
        fullSource = util.trim(fullSource)
        if fullSource == '' then
            return
        end
        local source, line, char = fullSource:match('^(.-):?(%d*):?(%d*)$')
        source = source or fullSource
        line   = tonumber(line) or 1
        char   = tonumber(char) or 0
        ---@type parser.object
        local result = {
            type   = 'doc.source',
            start  = getStart(),
            finish = getFinish(),
            path   = source,
            line   = line --[[@as integer]],
            char   = char --[[@as integer]],
        }
        return result
    end)
    : case 'enum'
    : call(function ()
        local attr = parseDocAttr()
        local name = parseName('doc.enum.name')
        if not name then
            return nil
        end
        ---@type parser.object
        local result = {
            type    = 'doc.enum',
            start   = name.start,
            finish  = name.finish,
            enum    = name,
            docAttr = attr,
        }
        name.parent = result
        if attr then
            attr.parent = result
        end
        return result
    end)
    : case 'private'
    : call(function ()
        return {
            type   = 'doc.private',
            start  = getFinish(),
            finish = getFinish(),
        }
    end)
    : case 'protected'
    : call(function ()
        return {
            type   = 'doc.protected',
            start  = getFinish(),
            finish = getFinish(),
        }
    end)
    : case 'public'
    : call(function ()
        return {
            type   = 'doc.public',
            start  = getFinish(),
            finish = getFinish(),
        }
    end)
    : case 'package'
    : call(function ()
        return {
            type   = 'doc.package',
            start  = getFinish(),
            finish = getFinish(),
        }
    end)

---@param doc string
---@return parser.object? result
---@return parser.object[]? rests
local function convertTokens(doc)
    local tp, text = nextToken()
    if not tp then
        return
    end
    if tp ~= 'name' then
        pushWarning {
            type   = 'LUADOC_MISS_CATE_NAME',
            start  = getStart(),
            finish = getFinish(),
        }
        return nil
    end
    assert(text)
    ---@cast text string -- tp == 'name' (checked above) always pairs with string content
    if not docSwitch:has(text) then
        local docType = docTags.getMarkerTagType(text)
        if docType then
            ---@type parser.object
            local result = {
                type   = docType,
                start  = getFinish(),
                finish = getFinish(),
            }
            if docTags.isNameListTag(docType) then
                -- cover the tag name itself (a zero-width range is useless for a diagnostic)
                result.start = getStart()
                local savePoint = Ci
                ---@type parser.object[]
                local names = {}
                while true do
                    local name = parseName(docType .. '.name', result)
                    if not name then
                        names = {}
                        break
                    end
                    names[#names+1] = name
                    if not checkToken('symbol', ',', 1) then
                        break
                    end
                    nextToken()
                end
                if #names > 0 and not peekToken() then
                    result.names  = names
                    result.finish = getFinish()
                else
                    -- not a clean list (a description, a trailing comma): stay bare
                    Ci = savePoint
                end
            elseif docTags.getParamKinds(docType) then
                -- `---@secret-guard x accessible`: a parameter (or `...`) and one word of the tag's list
                result.start = getStart()
                local savePoint = Ci
                local param = parseName(docType .. '.name', result)
                if not param and checkToken('symbol', '...', 1) then
                    nextToken()
                    ---@type parser.object
                    param = {
                        type   = docType .. '.name',
                        start  = getStart(),
                        finish = getFinish(),
                        parent = result,
                        [1]    = '...',
                    }
                end
                if param then
                    -- the word may contain hyphens (`is-secret`): name and `-` tokens joined
                    ---@type string[]
                    local parts = {}
                    ---@type integer?
                    local kindStart
                    ---@type integer?
                    local kindFinish
                    while true do
                        local tp, content = peekToken()
                        if tp == 'name' or (tp == 'symbol' and content == '-' and #parts > 0) then
                            parts[#parts+1] = tostring(content)
                            nextToken()
                            kindStart  = kindStart or getStart()
                            kindFinish = getFinish()
                        else
                            break
                        end
                    end
                    local kind = table.concat(parts)
                    local kinds = docTags.getParamKinds(docType)
                    if kinds and kinds[kind] and not peekToken() then
                        result.param  = param
                        result.kind   = kind
                        result.kindStart  = kindStart
                        result.kindFinish = kindFinish
                        result.finish = getFinish()
                    else
                        Ci = savePoint
                    end
                else
                    Ci = savePoint
                end
            elseif docTags.getKindParams(docType) then
                -- `---@secret-args none a b`: one word of the tag's list, then names (or `...`) separated by spaces
                result.start = getStart()
                local savePoint = Ci
                -- (the kind is one name token, a hyphenated word such as `kind-one` included; the next name starts the list)
                local kindTp, kindText = peekToken()
                -- (a first token that is no name is not consumed below, so the names loop leaves the tag bare)
                local kind = tostring(kindText)
                ---@type integer?
                local kindStart
                ---@type integer?
                local kindFinish
                if kindTp == 'name' then
                    nextToken()
                    kindStart, kindFinish = getStart(), getFinish()
                end
                local kinds = docTags.getKindParams(docType)
                ---@type parser.object[]
                local names = {}
                local clean = kinds ~= nil and kinds[kind] == true
                while clean and peekToken() do
                    local name = parseName(docType .. '.name', result)
                    if not name and checkToken('symbol', '...', 1) then
                        nextToken()
                        ---@type parser.object
                        name = {
                            type   = docType .. '.name',
                            start  = getStart(),
                            finish = getFinish(),
                            parent = result,
                            [1]    = '...',
                        }
                    end
                    if name then
                        names[#names+1] = name
                    else
                        clean = false
                    end
                end
                if clean then
                    result.kind   = kind
                    result.kindStart  = kindStart
                    result.kindFinish = kindFinish
                    result.names  = #names > 0 and names or nil
                    result.finish = getFinish()
                else
                    Ci = savePoint
                end
            elseif docTags.isGuardTag(docType) then
                -- `---@guard x is T` / `---@guard x is not T`
                result.start = getStart()
                local savePoint = Ci
                local param = parseName(docType .. '.name', result)
                if param and checkToken('name', 'is', 1) then
                    nextToken()
                    local negated = false
                    if checkToken('name', 'not', 1) then
                        nextToken()
                        negated = true
                    end
                    local extends = parseType(result)
                    if extends then
                        result.param   = param
                        result.negated = negated or nil
                        result.extends = extends
                        result.finish  = getFinish()
                    else
                        Ci = savePoint
                    end
                else
                    Ci = savePoint
                end
            end
            return result
        end
    end
    return docSwitch(text, doc)
end

---@param text string
---@return string
local function trimTailComment(text)
    local comment = text
    if text:sub(1, 1) == '@' then
        comment = util.trim(text:sub(2))
    end
    if text:sub(1, 1) == '#' then
        comment = util.trim(text:sub(2))
    end
    if text:sub(1, 2) == '--' then
        comment = util.trim(text:sub(3))
    end
    if  comment:find '^%s*[\'"[]'
    and comment:find '[\'"%]]%s*$' then
        local state = compile(comment:gsub('^%s+', ''), 'String')
        if state and state.ast then
            comment = state.ast[1] --[[@as string]]
        end
    end
    return util.trim(comment)
end

---@param comment parser.state.comm
---@return parser.object? result
---@return parser.object[]? rests
local function buildLuaDoc(comment)
    local headPos = (comment.type == 'comment.short' and comment.text:match '^%-%s*@()')
                 or (comment.type == 'comment.long'  and comment.text:match '^%s*@()')
    if not headPos then
        return {
            type    = 'doc.comment',
            start   = comment.start,
            finish  = comment.finish,
            range   = comment.finish,
            comment = comment,
        }
    end
    -- absolute position of `@` symbol
    local startOffset = comment.start + (headPos --[[@as integer]])
    if comment.type == 'comment.long' then
        ---@diagnostic expect-next-line: need-check-nil -- .mark is always set for 'comment.long'
        startOffset = comment.start + (headPos --[[@as integer]]) + #comment.mark - 2
    end

    local doc = comment.text:sub(headPos)

    parseTokens(doc, startOffset)
    TakenMarks = {}
    local result, rests = convertTokens(doc)
    if result then
        for markStart, markFinish in pairs(TakenMarks) do
            docTags.addMark(result, markStart, markFinish)
        end
        result.range = math.max(comment.finish, result.finish)
        local finish = result.firstFinish or result.finish
        if rests then
            for _, rest in ipairs(rests) do
                rest.range = math.max(comment.finish, rest.finish)
                finish = rest.firstFinish or rest.finish
            end
        end

        -- `result` can be a multiline annotation or an alias, while `doc` is the first line, so we can't parse comment
        if finish >= comment.finish then
            return result, rests
        end

        local cstart = doc:find('%S', finish - startOffset)
        if cstart then
            result.comment = {
                type   = 'doc.tailcomment',
                start  = startOffset + cstart,
                finish = comment.finish,
                parent = result,
                text   = trimTailComment(doc:sub(cstart)),
            }
            if rests then
                for _, rest in ipairs(rests) do
                    rest.comment = result.comment
                end
            end
        end

        return result, rests
    end

    return {
        type    = 'doc.comment',
        start   = comment.start,
        finish  = comment.finish,
        range   = comment.finish,
        comment = comment,
    }
end

---@param text string?
---@param doc parser.object?
---@return boolean|integer|nil
local function isTailComment(text, doc)
    if not doc or not text then
        return false
    end
    local left          = doc.originalComment.start
    local row, col      = guide.rowColOf(left)
    local lineStart     = Lines[row] or 0
    local hasCodeBefore = text:sub(lineStart, lineStart + col):find '[%w_]'
    return hasCodeBefore
end

---@param lastDoc parser.object
---@param nextDoc parser.object?
---@return boolean
local function isContinuedDoc(lastDoc, nextDoc)
    if not nextDoc then
        return false
    end
    if nextDoc.type == 'doc.diagnostic' then
        return true
    end
    if lastDoc.type == 'doc.type'
    or lastDoc.type == 'doc.module'
    or lastDoc.type == 'doc.enum' then
        if nextDoc.type ~= 'doc.comment' then
            return false
        end
    end
    if lastDoc.type == 'doc.class'
    or lastDoc.type == 'doc.field'
    or lastDoc.type == 'doc.operator' then
        if  nextDoc.type ~= 'doc.field'
        and nextDoc.type ~= 'doc.operator'
        and nextDoc.type ~= 'doc.comment'
        and nextDoc.type ~= 'doc.overload'
        and nextDoc.type ~= 'doc.source'
        and not docTags.continuesAfterClassGroup(nextDoc.type) then
            return false
        end
    end
    if nextDoc.type == 'doc.cast' then
        return false
    end
    return true
end

---@param lastDoc parser.object
---@param nextDoc parser.object?
---@return boolean
local function isNextLine(lastDoc, nextDoc)
    if not nextDoc then
        return false
    end
    local lastRow = guide.rowColOf(lastDoc.finish)
    local newRow  = guide.rowColOf(nextDoc.start)
    return newRow - lastRow == 1
end

---@param binded parser.object[]
local function bindGeneric(binded)
    ---@type table<string|integer, parser.object>
    local generics = {}
    for _, doc in ipairs(binded) do
        if doc.type == 'doc.generic' then
            for _, obj in ipairs(doc.generics) do
                ---@diagnostic expect-next-line: need-check-nil -- .generic is always set on a 'doc.generic' element
                local name = obj.generic[1] --[[@as string|integer]]
                generics[name] = obj
            end
            -- a constraint or a default may name the other type parameters of the same line (`K: keyof T`), in any order
            for _, obj in ipairs(doc.generics) do
                for _, part in pairs { extends = obj.extends, default = obj.defaultType } do
                    -- (`eachSource`, not `eachSourceType`: that one caches the types of the walked tree, which are changed here)
                    guide.eachSource(part, function (src)
                        if src.type == 'doc.type.name' and generics[src[1]] then
                            src.type = 'doc.generic.name'
                            src.generic = generics[src[1]]
                        end
                    end)
                end
            end
        end
        if doc.type == 'doc.class'
        or doc.type == 'doc.alias' then
            if doc.signs then
                for _, sign in ipairs(doc.signs) do
                    local name = sign[1] --[[@as string|integer]]
                    generics[name] = sign
                end
            end
        end
        if doc.type == 'doc.param'
        or doc.type == 'doc.vararg'
        or doc.type == 'doc.return'
        or doc.type == 'doc.type'
        or doc.type == 'doc.class'
        or doc.type == 'doc.alias'
        or doc.type == 'doc.field'
        or doc.type == 'doc.operator'
        or doc.type == 'doc.overload' then
            guide.eachSourceType(doc, 'doc.type.name', function (src)
                local name = src[1]
                if generics[name] then
                    src.type = 'doc.generic.name'
                    src.generic = generics[name]
                end
            end)
            guide.eachSourceType(doc, 'doc.type.code', function (src)
                local name = src[1]
                if generics[name] then
                    src.type = 'doc.generic.name'
                    src.literal = true
                end
            end)
        end
    end
end

---@param doc parser.object
---@param source parser.object
local function bindDocWithSource(doc, source)
    if not source.bindDocs then
        source.bindDocs = {}
    end
    if source.bindDocs[#source.bindDocs] ~= doc then
        source.bindDocs[#source.bindDocs+1] = doc
    end
    doc.bindSource = source
end

---@param source parser.object
---@param binded parser.object[]
---@return boolean
local function bindDoc(source, binded)
    local isParam = source.type == 'self'
                or  source.type == 'local'
                and (source.parent.type == 'funcargs'
                        or (    source.parent.type == 'in'
                            and source.finish <= source.parent.keys.finish
                        )
                    )
    local ok = false
    for _, doc in ipairs(binded) do
        if doc.bindSource
        -- a name-list tag (`---@secret b, c`) binds to *every* local of the statement
        -- it precedes; the tag itself picks the names it applies to
        and not (docTags.isNameListTag(doc.type)
             and source.type == 'local'
             and doc.bindSource.type == 'local'
             and not isParam) then
            goto CONTINUE
        end
        if doc.type == 'doc.class'
        or doc.type == 'doc.version'
        or doc.type == 'doc.module'
        or doc.type == 'doc.source'
        or doc.type == 'doc.private'
        or doc.type == 'doc.protected'
        or doc.type == 'doc.public'
        or doc.type == 'doc.package'
        or doc.type == 'doc.see' then
            if source.type == 'function'
            or isParam then
                goto CONTINUE
            end
            bindDocWithSource(doc, source)
            ok = true
        elseif doc.type == 'doc.type' then
            if source.type == 'function'
            or isParam
            or source._bindedDocType then
                goto CONTINUE
            end
            source._bindedDocType = true
            bindDocWithSource(doc, source)
            ok = true
        elseif doc.type == 'doc.overload' then
            if not source.bindDocs then
                source.bindDocs = {}
            end
            source.bindDocs[#source.bindDocs+1] = doc
            if source.type == 'function' then
                bindDocWithSource(doc, source)
            end
            ok = true
        elseif doc.type == 'doc.param' then
            if  isParam
            and doc.param[1] == source[1] then
                bindDocWithSource(doc, source)
                ok = true
            elseif source.type == '...'
            and    doc.param[1] == '...' then
                bindDocWithSource(doc, source)
                ok = true
            elseif source.type == 'self'
            and    doc.param[1] == 'self' then
                bindDocWithSource(doc, source)
                ok = true
            elseif source.type == 'function' then
                if not source.bindDocs then
                    source.bindDocs = {}
                end
                source.bindDocs[#source.bindDocs + 1] = doc
                if source.args then
                    for _, arg in ipairs(source.args) do
                        if arg[1] == doc.param[1] then
                            bindDocWithSource(doc, arg)
                            break
                        end
                    end
                end
            end
        elseif doc.type == 'doc.vararg' then
            if source.type == '...' then
                bindDocWithSource(doc, source)
                ok = true
            end
        elseif doc.type == 'doc.return'
        or     doc.type == 'doc.generic'
        or     doc.type == 'doc.async'
        or     doc.type == 'doc.nodiscard' then
            if source.type == 'function' then
                bindDocWithSource(doc, source)
                ok = true
            end
        elseif doc.type == 'doc.enum' then
            if source.type == 'table' then
                bindDocWithSource(doc, source)
                ok = true
            end
            if source.value and source.value.type == 'table' then
                bindDocWithSource(doc, source.value)
                goto CONTINUE
            end
        elseif doc.type == 'doc.comment' then
            bindDocWithSource(doc, source)
            ok = true
        else
            local rule = docTags.getBindRule(doc.type)
            if rule then
                if rule(doc, source, isParam) then
                    bindDocWithSource(doc, source)
                    ok = true
                else
                    goto CONTINUE
                end
            end
        end
        ::CONTINUE::
    end
    return ok
end

---@param sources parser.object[]
---@param binded parser.object[]
---@param start integer
---@param finish integer
---@return boolean
local function bindDocsBetween(sources, binded, start, finish)
    -- 用二分法找到第一个
    local max = #sources
    ---@type integer
    local index
    local left  = 1
    local right = max
    for _ = 1, 1000 do
        index = left + (right - left) // 2
        if index <= left then
            index = left
            break
        elseif index >= right then
            index = right
            break
        end
        local src = sources[index]
        if src.start < start then
            left = index + 1
        else
            right = index
        end
    end

    local ok = false
    -- 从前往后进行绑定
    for i = index, max do
        local src = sources[i]
        if src and src.start >= start then
            if src.start >= finish then
                break
            end
            if src.start >= start then
                if src.type == 'local'
                or src.type == 'self'
                or src.type == 'setlocal'
                or src.type == 'setglobal'
                or src.type == 'tablefield'
                or src.type == 'tableindex'
                or src.type == 'setfield'
                or src.type == 'setindex'
                or src.type == 'setmethod'
                or src.type == 'function'
                or src.type == 'return'
                or src.type == '...'
                or src.type == 'call'   -- for `rawset`
                then
                    if bindDoc(src, binded) then
                        ok = true
                    end
                end
            end
        end
    end

    return ok
end

---@param binded parser.object[]
local function bindReturnIndex(binded)
    local returnIndex = 0
    for _, doc in ipairs(binded) do
        if doc.type == 'doc.return' then
            for _, rtn in ipairs(doc.returns) do
                returnIndex = returnIndex + 1
                rtn.returnIndex = returnIndex
            end
        end
    end
end

---@param doc parser.object
---@param comments parser.object[]
local function bindCommentsToDoc(doc, comments)
    doc.bindComments = comments
    for _, comment in ipairs(comments) do
        comment.bindSource = doc
    end
end

---@param binded parser.object[]
local function bindCommentsAndFields(binded)
    ---@type parser.object?
    local class
    ---@type parser.object[]
    local comments = {}
    ---@type parser.object?
    local source
    ---@type parser.object?
    local classInGroup
    for _, doc in ipairs(binded) do
        if doc.type == 'doc.class' then
            classInGroup = doc
        end
    end
    for _, doc in ipairs(binded) do
        if docTags.isClassGroupDoc(doc.type) then
            if classInGroup then
                bindDocWithSource(doc, classInGroup)
            end
        elseif doc.type == 'doc.class' then
            -- 多个class连续写在一起，只有最后一个class可以绑定source
            if class then
                class.bindSource = nil
            end
            if source then
                doc.source = source
                source.bindSource = doc
            end
            class = doc
            bindCommentsToDoc(doc, comments)
            comments = {}
        elseif doc.type == 'doc.field' then
            if class then
                class.fields[#class.fields+1] = doc
                doc.class = class
            end
            if source then
                doc.source = source
                source.bindSource = doc
            end
            bindCommentsToDoc(doc, comments)
            comments = {}
        elseif doc.type == 'doc.operator' then
            if class then
                ---@diagnostic expect-next-line: need-check-nil -- .operators is always set on a constructed 'doc.class' node
                class.operators[#class.operators+1] = doc
                doc.class = class
            end
            bindCommentsToDoc(doc, comments)
            comments = {}
        elseif doc.type == 'doc.overload' then
            if class then
                ---@diagnostic expect-next-line: need-check-nil -- .calls is always set on a constructed 'doc.class' node
                class.calls[#class.calls+1] = doc
                doc.class = class
            end
        elseif doc.type == 'doc.alias'
        or     doc.type == 'doc.enum' then
            bindCommentsToDoc(doc, comments)
            comments = {}
        elseif doc.type == 'doc.comment' then
            comments[#comments+1] = doc
        elseif doc.type == 'doc.source' then
            source = doc
            goto CONTINUE
        end
        source = nil
        ::CONTINUE::
    end
end

--- The functions of this file that declare type parameters (`---@generic T`), in file order, with the `doc.generic` that declares them: the
--- docs inside their body can name those type parameters. Filled while the docs are bound (a function's own comment block comes before its body).
---@type {func: parser.object, doc: parser.object}[]
local genericFuncs = {}

--- The type parameters of the functions around a group of docs are in scope for it: `---@type T` above a local in the body of
--- `---@generic T` is the type parameter, not an undefined name. The nearest function wins (later entries are inner ones).
--- What the group's own `---@generic` binds was done before and stays.
---@param binded parser.object[]
local function bindEnclosingGenerics(binded)
    if #genericFuncs == 0 then
        return
    end
    local pos = binded[1].start
    ---@type table<string|integer, parser.object>?
    local generics
    for _, entry in ipairs(genericFuncs) do
        local func = entry.func
        if func.start < pos and pos < func.finish then
            generics = generics or {}
            for _, obj in ipairs(entry.doc.generics) do
                ---@diagnostic expect-next-line: need-check-nil -- .generic is always set on a 'doc.generic.object'
                local name = obj.generic[1] --[[@as string|integer]]
                generics[name] = obj
            end
        end
    end
    if not generics then
        return
    end
    for _, doc in ipairs(binded) do
        if doc.type ~= 'doc.generic' then
            -- (`eachSource`, not `eachSourceType`: that one caches the types of the walked tree, which are changed here)
            guide.eachSource(doc, function (src)
                if src.type == 'doc.type.name' and generics[src[1]] then
                    src.type = 'doc.generic.name'
                    src.generic = generics[src[1]]
                end
            end)
        end
    end
end

---@param sources parser.object[]
---@param binded parser.object[]?
local function bindDocWithSourcesBase(sources, binded)
    if not binded then
        return
    end
    local lastDoc = binded[#binded]
    if not lastDoc then
        return
    end
    for _, doc in ipairs(binded) do
        doc.bindGroup = binded
    end
    bindGeneric(binded)
    bindEnclosingGenerics(binded)
    bindCommentsAndFields(binded)
    bindReturnIndex(binded)

    -- doc is special node
    -- NOTE: .special is declared string|parser.object; this is the one read site
    -- that expects the parser.object half (see spawned follow-up task on
    -- luadoc.lua's buildAndBindDoc setting doc.special to a parser.object)
    if lastDoc.special then
        if bindDoc(lastDoc.special --[[@as parser.object]], binded) then
            return
        end
    end

    local row = guide.rowColOf(lastDoc.finish)
    local suc = bindDocsBetween(sources, binded, guide.positionOf(row, 0), lastDoc.start)
    if not suc then
        bindDocsBetween(sources, binded, guide.positionOf(row + 1, 0), guide.positionOf(row + 2, 0))
    end
end

---@param sources parser.object[]
---@param binded parser.object[]?
local function bindDocWithSources(sources, binded)
    bindDocWithSourcesBase(sources, binded)
    -- a function that declares type parameters: its body's docs can name them (see `bindEnclosingGenerics`)
    for _, doc in ipairs(binded or {}) do
        if doc.type == 'doc.generic' and doc.bindSource and doc.bindSource.type == 'function' then
            genericFuncs[#genericFuncs+1] = { func = doc.bindSource, doc = doc }
        end
    end
end

---@param sources parser.object[]
local docsDedupe = function (sources)
    ---@param bindDocs parser.object[]
    ---@param value parser.object
    local removeByValue = function(bindDocs, value)
        for i = #bindDocs, 1, -1 do
            if bindDocs[i] == value then
                table.remove(bindDocs, i)
                break
            end
        end
    end
    for _, source in ipairs(sources) do
        if source.bindDocs then
            ---@type table<string, parser.object>
            local docs = {}
            for i = #source.bindDocs, 1, -1 do
                local doc = source.bindDocs[i]
                if doc.type == 'doc.param' and doc.param[1] then
                    local param1 = doc.param[1] --[[@as string]]
                    if docs[param1] then
                        local old = docs[param1]
                        if old.virtual and not doc.virtual then
                            removeByValue(source.bindDocs, old)
                        elseif not old.virtual and doc.virtual then
                            removeByValue(source.bindDocs, doc)
                            doc = old --[[@as parser.object]]
                        end
                    end
                    docs[param1] = doc
                end
            end
        end
    end
end

local bindDocAccept = {
    'local'     , 'setlocal'  , 'setglobal',
    'setfield'  , 'setmethod' , 'setindex' ,
    'tablefield', 'tableindex', 'self'     ,
    'function'  , 'return'     , '...'      ,
    'call',
}

---@param state parser.state
local function bindDocs(state)
    genericFuncs = {}
    local text = state.lua
    ---@type parser.object[]
    local sources = {}
    guide.eachSourceTypes(state.ast, bindDocAccept, function (src)
        -- allow binding docs with rawset(_G, "key", value)
        if src.type == 'call' then
            if src.node.special ~= 'rawset' or not src.args then
                return
            end
            local g, key = src.args[1], src.args[2]
            if not g or not key or g.special ~= '_G' then
                return
            end
        end
        sources[#sources+1] = src
    end)
    table.sort(sources, function (a, b)
        return a.start < b.start
    end)
    ---@type parser.object[]?
    local binded
    for i, doc in ipairs(state.ast.docs) do
        if not binded then
            binded = {}
            ---@diagnostic expect-next-line: need-check-nil -- .groups is always set by luadoc() before bindDocs runs
            state.ast.docs.groups[#state.ast.docs.groups+1] = binded
        end
        binded[#binded+1] = doc
        if doc.specialBindGroup then
            bindDocWithSources(sources, doc.specialBindGroup)
            binded = nil
        elseif isTailComment(text, doc) and doc.type ~= "doc.field" then
            bindDocWithSources(sources, binded)
            binded = nil
        else
            local nextDoc = state.ast.docs[i+1]
            if nextDoc and nextDoc.special
            or not isNextLine(doc, nextDoc) then
                bindDocWithSources(sources, binded)
                binded = nil
            end
            if  not isContinuedDoc(doc, nextDoc)
            and not isTailComment(text, nextDoc) then
                bindDocWithSources(sources, binded)
                binded = nil
            end
        end
    end
    docsDedupe(sources)
end

---@param state parser.state
---@param doc parser.object
local function findTouch(state, doc)
    local text = state.lua or ''
    local pos  = guide.positionToOffset(state, doc.originalComment.start)
    for i = pos - 2, 1, -1 do
        local c = text:sub(i, i)
        if c == '\r'
        or c == '\n' then
            break
        elseif c ~= ' '
        and    c ~= '\t' then
            doc.touch = guide.offsetToPosition(state, i)
            break
        end
    end
end

---@param state parser.state
local function luadoc(state)
    local ast = state.ast
    local comments = state.comms
    table.sort(comments, function (a, b)
        return a.start < b.start
    end)
    ast.docs = {
        type   = 'doc',
        parent = ast,
        groups = {},
    }

    pushWarning = function (err)
        local errs = state.errs
        if err.start and err.finish and err.finish < err.start then
            err.finish = err.start
        end
        local last = errs[#errs]
        if last and last.start and last.finish and err.start and err.finish then
            if last.start <= err.start and last.finish >= err.finish then
                return
            end
        end
        err.level = err.level or 'Warning'
        errs[#errs+1] = err
        return err
    end
    Lines       = state.lines

    local ci = 1
    NextComment = function (offset, peek)
        local comment = comments[ci + (offset or 0)]
        if not peek then
            ci = ci + 1 + (offset or 0)
        end
        return comment
    end

    ---@param doc parser.object
    ---@param comment parser.state.comm
    local function insertDoc(doc, comment)
        ast.docs[#ast.docs+1] = doc
        doc.parent = ast.docs
        if ast.start > doc.start then
            ast.start = doc.start
        end
        if ast.finish < doc.finish then
            ast.finish = doc.finish
        end
        doc.originalComment = comment
        if comment.type == 'comment.long' then
            findTouch(state, doc)
        end
    end

    while true do
        local comment = NextComment()
        if not comment then
            break
        end
        lockResume = false
        local doc, rests = buildLuaDoc(comment)
        if doc then
            insertDoc(doc, comment)
            if rests then
                for _, rest in ipairs(rests) do
                    insertDoc(rest, comment)
                end
            end
        end
    end

    if ast.state.pluginDocs then
        for _, doc in ipairs(ast.state.pluginDocs) do
            insertDoc(doc, doc.originalComment)
        end
        ---@param a parser.object
        ---@param b parser.object
        ---@return boolean
        table.sort(ast.docs, function (a, b)
            return a.start < b.start
        end)
        ast.state.pluginDocs = nil
    end

    ast.docs.start  = ast.start
    ast.docs.finish = ast.finish

    if #ast.docs == 0 then
        return
    end

    bindDocs(state)
end

---@param node parser.object?
local function markVirtual(node)
    if not node then
        return
    end
    node.virtual = true
    guide.eachChild(node, markVirtual)
end

---@param ast parser.object
---@param src parser.object
---@param comment {type: string, start: integer, finish: integer, text: string, virtual: boolean}
---@param group? table
---@return parser.object?
local function buildAndBindDoc(ast, src, comment, group)
    ---@type parser.object?
    local doc = buildLuaDoc(comment)
    if doc then
        local pluginDocs = ast.state.pluginDocs or {}
        pluginDocs[#pluginDocs+1] = doc
        doc.special = src
        doc.originalComment = comment
        markVirtual(doc)
        doc.specialBindGroup = group
        ast.state.pluginDocs = pluginDocs
        return doc
    end
    return nil
end

return {
    buildAndBindDoc = buildAndBindDoc,
    luadoc = luadoc
}
