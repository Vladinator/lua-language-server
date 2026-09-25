local error        = error
local type         = type

---@class (incremental) parser.object
---@field bindDocs?              parser.object[]
---@field bindGroup?             parser.object[]
---@field bindSource?            parser.object
---@field value?                 parser.object
---@field parent                parser.object
---@field type                  string
---@field special?               string|parser.object -- almost always the name of a recognized builtin (e.g. 'pcall', 'setmetatable', '_G'); luadoc.lua's buildAndBindDoc is the one place that stores a parser.object here instead (looks like it should be .bindSource -- see spawned follow-up task)
---@field tag?                   string
---@field args                  { [integer]: parser.object, start: integer, finish: integer, type: string }
---@field locals?                parser.object[]
---@field globals?              parser.object[]
---@field gotos?                parser.object[]
---@field returns?              parser.object[]
---@field breaks?               parser.object[]
---@field exps                  parser.object[]
---@field keys                  parser.object
---@field uri                   uri
---@field start                 integer
---@field finish                integer
---@field range                 integer
---@field effect                integer
---@field bstart                integer
---@field bfinish               integer
---@field vstart?               integer
---@field attrs?                parser.object -- a 'localattrs' node; its array part holds 'localattr' nodes
---@field specials              parser.object[]
---@field labels                parser.object[]
---@field node                  parser.object
---@field field?                 parser.object
---@field method?                parser.object
---@field index?                 parser.object
---@field extends?              parser.object[]|parser.object
---@field defaultType?          parser.object -- `doc.generic.object`: `---@generic T = string`, the type used when nothing infers `T` (`default` is taken: a boolean on 'doc.resume' nodes)
---@field types                 parser.object[]
---@field fields                parser.object[]
---@field tkey                  parser.object
---@field tvalue                parser.object
---@field tindex                integer
---@field op                    parser.object
---@field next                  parser.object
---@field docParam              parser.object
---@field sindex                integer
---@field name                  parser.object
---@field call                  parser.object
---@field closure               parser.object
---@field proto                 parser.object
---@field exp                   parser.object
---@field alias                 parser.object
---@field class                 parser.object
---@field enum                  parser.object
---@field vararg                parser.object
---@field param                 parser.object
---@field negated?               true -- `doc.guard` / `doc.asserts`: the tag says `x is not T`
---@field overload              parser.object
---@field docParamMap           table<string, integer>
---@field upvalues              table<string, string[]>
---@field ref                   parser.object[]
---@field returnIndex           integer
---@field assignIndex           integer
---@field docIndex              integer
---@field docs                  parser.object
---@field state                 parser.state
---@field comment               string|parser.state.comm|parser.object -- a plain string on 'doc.resume' enum-default/additional nodes; otherwise an object carrying `.text` (a 'doc.tailcomment' node or the raw parser.state.comm)
---@field optional              boolean
---@field max                   parser.object
---@field init                  parser.object
---@field step                  parser.object
---@field redundant             { max: integer, passed: integer }
---@field filter                parser.object
---@field loc                   parser.object
---@field keyword               integer[]
---@field casts                 parser.object[]
---@field locPos?              integer
---@field mode?                 '+' | '-' | 'disable-next-line' | 'disable-line' | 'disable' | 'enable' | 'expect-next-line' | 'expect-line' -- '+'/'-' on some doc-type nodes, the rest on 'doc.diagnostic' nodes
---@field public _hits?          table<string, boolean> -- on an 'expect-*' doc.diagnostic: diagnostic names it suppressed (see vm/doc.lua)
---@field hasGoTo?              true
---@field hasReturn?            true
---@field hasBreak?             true
---@field hasExit?              true
---@field virtual?              boolean
---@field keyStart?             integer -- only set on a 'goto' action, the start of its label name
---@field [integer]             parser.object|any
---@field dot                   { type: string, start: integer, finish: integer }
---@field colon                 { type: string, start: integer, finish: integer }
---@field declare?              boolean
---@field varargRef?            boolean|parser.object -- compile.lua sets this to the vararg node itself; only ever read for truthiness
---@field const?                boolean
---@field groups?               parser.object[]
---@field asyncPos?             integer -- set by luadoc.lua on '@async' doc nodes
---@field specialBindGroup?     table -- set by luadoc.lua's buildAndBindDoc, passed straight through from its own `group` param
---@field escs?                 table<integer, integer|string> -- escape spans of a short string, flattened as (start, finish, kind) triples; read by semantic-tokens.lua
---@field package _root         parser.object
---@field package _eachCache?   parser.object[]
---@field package _isGlobal?    boolean
---@field package _typeCache?   table<string, parser.object[]>

---@class guide
---@field debugMode boolean
local m = {}

m.ANY = {"<ANY>"}

m.notNamePattern  = '[^%w_\x80-\xff]'
m.namePattern     = '[%a_\x80-\xff][%w_\x80-\xff]*'
m.namePatternFull = '^' .. m.namePattern .. '$'

local blockTypes = {
    ['while']       = true,
    ['in']          = true,
    ['loop']        = true,
    ['repeat']      = true,
    ['do']          = true,
    ['function']    = true,
    ['if']          = true,
    ['ifblock']     = true,
    ['elseblock']   = true,
    ['elseifblock'] = true,
    ['main']        = true,
}

m.blockTypes = blockTypes

local topBlockTypes = {
    ['while']       = true,
    ['function']    = true,
    ['if']          = true,
    ['ifblock']     = true,
    ['elseblock']   = true,
    ['elseifblock'] = true,
    ['main']        = true,
}

local breakBlockTypes = {
    ['while']       = true,
    ['in']          = true,
    ['loop']        = true,
    ['repeat']      = true,
    ['for']         = true,
}

local childMap = {
    ['main']        = {'#', 'docs'},
    ['repeat']      = {'#', 'filter'},
    ['while']       = {'filter', '#'},
    ['in']          = {'keys', 'exps', '#'},
    ['loop']        = {'loc', 'init', 'max', 'step', '#'},
    ['do']          = {'#'},
    ['if']          = {'#'},
    ['ifblock']     = {'filter', '#'},
    ['elseifblock'] = {'filter', '#'},
    ['elseblock']   = {'#'},
    ['setfield']    = {'node', 'field', 'value'},
    ['getfield']    = {'node', 'field'},
    ['setmethod']   = {'node', 'method', 'value'},
    ['getmethod']   = {'node', 'method'},
    ['setindex']    = {'node', 'index', 'value'},
    ['getindex']    = {'node', 'index'},
    ['tableindex']  = {'index', 'value'},
    ['tablefield']  = {'field', 'value'},
    ['tableexp']    = {'value'},
    ['setglobal']   = {'value'},
    ['local']       = {'attrs', 'value'},
    ['setlocal']    = {'value'},
    ['return']      = {'#'},
    ['select']      = {'vararg'},
    ['table']       = {'#'},
    ['function']    = {'args', '#'},
    ['funcargs']    = {'#'},
    ['paren']       = {'exp'},
    ['call']        = {'node', 'args'},
    ['callargs']    = {'#'},
    ['list']        = {'#'},
    ['binary']      = {1, 2},
    ['unary']       = {1},
    ['ternary']     = {1, 2, 3},
    ['...']         = {'name'},

    ['doc']                = {'#'},
    ['doc.class']          = {'class', '#extends', '#signs', 'docAttr', 'comment'},
    ['doc.type']           = {'#types', 'name', 'comment'},
    ['doc.alias']          = {'alias', 'docAttr', 'extends', 'comment'},
    ['doc.enum']           = {'enum', 'extends', 'comment', 'docAttr'},
    ['doc.param']          = {'param', 'extends', 'comment'},
    ['doc.return']         = {'#returns', 'comment'},
    ['doc.field']          = {'field', 'extends', 'comment'},
    ['doc.generic']        = {'#generics', 'comment'},
    ['doc.generic.object'] = {'generic', 'extends', 'defaultType', 'comment'},
    ['doc.vararg']         = {'vararg', 'comment'},
    ['doc.type.array']     = {'node'},
    ['doc.type.function']  = {'#args', '#returns', '#signs', 'comment'},
    ['doc.type.table']     = {'#fields', 'comment'},
    ['doc.type.literal']   = {'node'},
    ['doc.type.arg']       = {'name', 'extends'},
    ['doc.type.field']     = {'name', 'extends'},
    ['doc.type.sign']      = {'node', '#signs'},
    ['doc.overload']       = {'overload', 'comment'},
    ['doc.see']            = {'name', 'comment'},
    ['doc.version']        = {'#versions'},
    ['doc.diagnostic']     = {'#names'},
    ['doc.as']             = {'as'},
    ['doc.cast']           = {'name', '#casts'},
    ['doc.cast.block']     = {'extends'},
    ['doc.operator']       = {'op', 'exp', 'extends'},
    ['doc.meta']           = {'name'},
    ['doc.attr']           = {'#names'},
}

---@type table<string, fun(obj: parser.object, list: parser.object[])|false>
local compiledChildMap = setmetatable({}, {__index = function (self, name)
    ---@cast self table<string, fun(obj: parser.object, list: parser.object[])|false>
    ---@cast name string
    local defs = childMap[name]
    if not defs then
        self[name] = false
        return false
    end
    ---@type string[]
    local text = {}
    text[#text+1] = 'local obj, list = ...'
    for _, def in ipairs(defs) do
        if def == '#' then
            text[#text+1] = [[
for i = 1, #obj do
    list[#list+1] = obj[i]
end
]]
        elseif type(def) == 'string' and def:sub(1, 1) == '#' then
            local key = def:sub(2)
            text[#text+1] = ([[
local childs = obj.%s
if childs then
    for i = 1, #childs do
        list[#list+1] = childs[i]
    end
end
]]):format(key)
        elseif type(def) == 'string' then
            text[#text+1] = ('list[#list+1] = obj.%s'):format(def)
        else
            text[#text+1] = ('list[#list+1] = obj[%q]'):format(def)
        end
    end
    local buf = table.concat(text, '\n')
    local f = load(buf, buf, 't') --[[@as fun(obj: parser.object, list: parser.object[])]]
    self[name] = f
    return f
end})

---@type table<string, fun(obj: parser.object, callback: fun(child: parser.object))|false>
local eachChildMap = setmetatable({}, {__index = function (self, name)
    ---@cast self table<string, fun(obj: parser.object, callback: fun(child: parser.object))|false>
    ---@cast name string
    local defs = childMap[name]
    if not defs then
        self[name] = false
        return false
    end
    ---@type string[]
    local text = {}
    text[#text+1] = 'local obj, callback = ...'
    for _, def in ipairs(defs) do
        if def == '#' then
            text[#text+1] = [[
for i = 1, #obj do
    callback(obj[i])
end
]]
        elseif type(def) == 'string' and def:sub(1, 1) == '#' then
            local key = def:sub(2)
            text[#text+1] = ([[
local childs = obj.%s
if childs then
    for i = 1, #childs do
        callback(childs[i])
    end
end
]]):format(key)
        elseif type(def) == 'string' then
            text[#text+1] = ('callback(obj.%s)'):format(def)
        else
            text[#text+1] = ('callback(obj[%q])'):format(def)
        end
    end
    local buf = table.concat(text, '\n')
    local f = load(buf, buf, 't') --[[@as fun(obj: parser.object, callback: fun(child: parser.object))]]
    self[name] = f
    return f
end})

--- Tell the tree walkers (`eachChild`, `getChildren`, so `eachSource`, hover, completion,
--- ...) where a node type keeps its children, for a node type a plugin adds
--- (see `parser.docTags`). `defs` uses the same syntax as the built-in map: `'#names'` walks
--- the array `obj.names`, `'name'` the single child `obj.name`.
---@param nodeType string
---@param defs     string[]
function m.registerChildren(nodeType, defs)
    childMap[nodeType]         = defs
    compiledChildMap[nodeType] = nil
    eachChildMap[nodeType]     = nil
end

m.actionMap = {
    ['main']        = {'#'},
    ['repeat']      = {'#'},
    ['while']       = {'#'},
    ['in']          = {'#'},
    ['loop']        = {'#'},
    ['if']          = {'#'},
    ['ifblock']     = {'#'},
    ['elseifblock'] = {'#'},
    ['elseblock']   = {'#'},
    ['do']          = {'#'},
    ['function']    = {'#'},
    ['funcargs']    = {'#'},
}

--- 是否是字面量
---@param obj table
---@return boolean
function m.isLiteral(obj)
    ---@type string?
    local tp = obj.type
    return tp == 'nil'
        or tp == 'boolean'
        or tp == 'string'
        or tp == 'number'
        or tp == 'integer'
        or tp == 'table'
        or tp == 'function'
        or tp == 'doc.type.function'
        or tp == 'doc.type.table'
        or tp == 'doc.type.string'
        or tp == 'doc.type.integer'
        or tp == 'doc.type.boolean'
        or tp == 'doc.type.code'
        or tp == 'doc.type.array'
end

--- 获取字面量
---@param obj table
---@return any
function m.getLiteral(obj)
    if m.isLiteral(obj) then
        return obj[1]
    end
    return nil
end

--- 寻找父函数
---@param obj parser.object
---@return parser.object?
function m.getParentFunction(obj)
    for _ = 1, 10000 do
        obj = obj.parent
        if not obj then
            break
        end
        ---@type string
        local tp = obj.type
        if tp == 'function' or tp == 'main' then
            return obj
        end
    end
    return nil
end

--- 寻找所在区块
---@param obj parser.object
---@return parser.object?
function m.getBlock(obj)
    for _ = 1, 10000 do
        if not obj then
            return nil
        end
        local tp = obj.type
        if blockTypes[tp] then
            return obj
        end
        if obj == obj.parent then
            error('obj == obj.parent?' .. obj.type)
        end
        obj = obj.parent
    end
    -- make stack
    ---@type string[]
    local stack = {}
    for _ = 1, 10 do
        stack[#stack+1] = ('%s:%s'):format(obj.type, obj.finish)
        obj = obj.parent
        if not obj then
            break
        end
    end
    error('guide.getBlock overstack:' .. table.concat(stack, ' -> '))
end

--- 寻找所在父区块
---@param obj parser.object
---@return parser.object?
function m.getParentBlock(obj)
    for _ = 1, 10000 do
        obj = obj.parent
        if not obj then
            return nil
        end
        ---@type string
        local tp = obj.type
        if blockTypes[tp] then
            return obj
        end
    end
    error('guide.getParentBlock overstack')
end

--- 寻找所在可break的父区块
---@param obj parser.object
---@return parser.object?
function m.getBreakBlock(obj)
    for _ = 1, 10000 do
        obj = obj.parent
        if not obj then
            return nil
        end
        ---@type string
        local tp = obj.type
        if breakBlockTypes[tp] then
            return obj
        end
        if tp == 'function' then
            return nil
        end
    end
    error('guide.getBreakBlock overstack')
end

--- 寻找doc的主体
---@param obj parser.object
---@return parser.object
function m.getDocState(obj)
    for _ = 1, 10000 do
        local parent = obj.parent
        if not parent then
            return obj
        end
        if parent.type == 'doc' then
            return obj
        end
        obj = parent
    end
    error('guide.getDocState overstack')
end

--- 寻找所在父类型
---@param obj parser.object
---@param want string
---@return parser.object?
function m.getParentType(obj, want)
    for _ = 1, 10000 do
        obj = obj.parent
        if not obj then
            return nil
        end
        if want == obj.type then
            return obj
        end
    end
    error('guide.getParentType overstack')
end

--- 寻找所在父类型
---@param obj parser.object
---@param wants table<string, boolean>
---@return parser.object?
function m.getParentTypes(obj, wants)
    for _ = 1, 10000 do
        obj = obj.parent
        if not obj then
            return nil
        end
        if wants[obj.type] then
            return obj
        end
    end
    error('guide.getParentTypes overstack')
end

--- 寻找根区块
---@param obj parser.object
---@return parser.object
function m.getRoot(obj)
    local source = obj
    if source._root then
        return source._root
    end
    for _ = 1, 10000 do
        if obj.type == 'main' then
            source._root = obj
            return obj
        end
        if obj._root then
            source._root = obj._root
            return source._root
        end
        local parent = obj.parent
        if not parent then
            error('Can not find out root:' .. tostring(obj.type))
        end
        obj = parent
    end
    error('guide.getRoot overstack')
end

---@param obj parser.object | { uri: uri }
---@return uri
function m.getUri(obj)
    if obj.uri then
        return obj.uri
    end
    local root = m.getRoot(obj)
    if root then
        return root.uri or ''
    end
    return ''
end

---@param source parser.object
---@param start integer?
---@return parser.object?
function m.getENV(source, start)
    if not start then
        start = 1
    end
    return m.getLocal(source, '_ENV', start)
        or m.getLocal(source, '@fenv', start)
end

--- 获取指定区块中可见的局部变量
---@param source parser.object
---@param name string # 变量名
---@param pos integer # 可见位置
---@return parser.object?
function m.getLocal(source, name, pos)
    local block = source
    -- find nearest source
    for _ = 1, 10000 do
        if not block then
            return nil
        end
        if block.type == 'main' then
            break
        end
        if  block.start <= pos
        and block.finish >= pos
        and blockTypes[block.type] then
            break
        end
        block = block.parent
    end

    m.eachSourceContain(block, pos, function (src)
        if  blockTypes[src.type]
        and (src.finish - src.start) < (block.finish - src.start) then
            block = src
        end
    end)

    for _ = 1, 10000 do
        if not block then
            break
        end
        ---@type parser.object?
        local res
        ---@type parser.object[]?
        local blockLocals = block.locals
        if blockLocals then
            for _, loc in ipairs(blockLocals) do
                if  loc[1] == name
                and loc.effect <= pos then
                    if not res or res.effect < loc.effect then
                        res = loc --[[@as parser.object]]
                    end
                end
            end
        end
        if res then
            return res
        end
        block = block.parent --[[@as parser.object]]
    end
    return nil
end

--- 获取指定区块中所有的可见局部变量名称
---@param block parser.object
---@param pos integer
---@return table<string, parser.object>
function m.getVisibleLocals(block, pos)
    ---@type table<string, parser.object>
    local result = {}
    m.eachSourceContain(m.getRoot(block), pos, function (source)
        local locals = source.locals
        if locals then
            for i = 1, #locals do
                local loc = locals[i]
                local name = loc[1] --[[@as string]]
                if loc.effect <= pos then
                    result[name] = loc
                end
            end
        end
    end)
    return result
end

--- 获取指定区块中可见的标签
---@param block parser.object
---@param name string
---@return parser.object?
function m.getLabel(block, name)
    local current = m.getBlock(block)
    for _ = 1, 10000 do
        if not current then
            return nil
        end
        local labels = current.labels
        if labels then
            local label = labels[name]
            if label then
                return label
            end
        end
        if current.type == 'function' then
            return nil
        end
        current = m.getParentBlock(current)
    end
    error('guide.getLocal overstack')
end

---@param source parser.object
---@return integer? start
---@return integer? finish
function m.getStartFinish(source)
    local start  = source.start
    local finish = source.finish
    if source.bfinish and source.bfinish > finish then
        finish = source.bfinish
    end
    if not start then
        local first = source[1]
        if not first then
            return nil, nil
        end
        local last  = source[#source]
        start  = first.start
        finish = last.finish
    end
    return start, finish
end

---@param source parser.object
---@return integer? start
---@return integer? finish
function m.getRange(source)
    local start  = source.vstart or source.start
    local finish = source.range  or source.finish
    if source.bfinish and source.bfinish > finish then
        finish = source.bfinish
    end
    if not start then
        local first = source[1]
        if not first then
            return nil, nil
        end
        local last  = source[#source]
        start  = first.vstart or first.start
        finish = last.range   or last.finish
    end
    return start, finish
end

--- 判断source是否包含position
function m.isContain(source, position)
    local start, finish = m.getStartFinish(source)
    if not start or not finish then
        return false
    end
    return start <= position and finish >= position
end

--- 判断position在source的影响范围内
---
--- 主要针对赋值等语句时，key包含value
function m.isInRange(source, position)
    local start, finish = m.getRange(source)
    if not start or not finish then
        return false
    end
    return start <= position and finish >= position
end

function m.isBetween(source, tStart, tFinish)
    local start, finish = m.getStartFinish(source)
    if not start or not finish then
        return false
    end
    return start <= tFinish and finish >= tStart
end

function m.isBetweenRange(source, tStart, tFinish)
    local start, finish = m.getRange(source)
    if not start or not finish then
        return false
    end
    return start <= tFinish and finish >= tStart
end

--- 添加child
---@param list parser.object[]
---@param obj parser.object
local function addChilds(list, obj)
    local tp = obj.type
    if not tp then
        return
    end
    local f = compiledChildMap[tp]
    if not f then
        return
    end
    f(obj, list)
end

--- 遍历所有包含position的source
---@param ast parser.object
---@param position integer
---@param callback fun(src: parser.object): any
---@return any
function m.eachSourceContain(ast, position, callback)
    ---@type parser.object[]
    local list = { ast }
    ---@type table<parser.object, boolean>
    local mark = {}
    while true do
        local len = #list
        if len == 0 then
            return
        end
        local obj = list[len]
        list[len] = nil
        if not mark[obj] then
            mark[obj] = true
            if m.isInRange(obj, position) then
                if m.isContain(obj, position) then
                    local res = callback(obj)
                    if res ~= nil then
                        return res
                    end
                end
                addChilds(list, obj)
            end
        end
    end
end

--- 遍历所有在某个范围内的source
---@param ast parser.object
---@param start number
---@param finish number
---@param callback fun(src: parser.object): any
---@return any
function m.eachSourceBetween(ast, start, finish, callback)
    ---@type parser.object[]
    local list = { ast }
    ---@type table<parser.object, boolean>
    local mark = {}
    while true do
        local len = #list
        if len == 0 then
            return
        end
        local obj = list[len]
        list[len] = nil
        if not mark[obj] then
            mark[obj] = true
            if m.isBetweenRange(obj, start, finish) then
                if m.isBetween(obj, start, finish) then
                    local res = callback(obj)
                    if res ~= nil then
                        return res
                    end
                end
                addChilds(list, obj)
            end
        end
    end
end

---@param ast parser.object
---@return table<string, parser.object[]>
local function getSourceTypeCache(ast)
    local cache = ast._typeCache
    if not cache then
        cache = {}
        ast._typeCache = cache
        m.eachSource(ast, function (source)
            local tp = source.type
            if not tp then
                return
            end
            local myCache = cache[tp]
            if not myCache then
                myCache = {}
                cache[tp] = myCache
            end
            myCache[#myCache+1] = source
        end)
    end
    return cache
end

--- 遍历所有指定类型的source
---@param ast parser.object
---@param ty string
---@param callback fun(src: parser.object): any
---@return any
function m.eachSourceType(ast, ty, callback)
    local cache = getSourceTypeCache(ast)
    local myCache = cache[ty]
    if not myCache then
        return
    end
    for i = 1, #myCache do
        local res = callback(myCache[i])
        if res ~= nil then
            return res
        end
    end
end

---@param ast parser.object
---@param tps string[]
---@param callback fun(src: parser.object)
function m.eachSourceTypes(ast, tps, callback)
    local cache = getSourceTypeCache(ast)
    for x = 1, #tps do
        local tpCache = cache[tps[x]]
        if tpCache then
            for i = 1, #tpCache do
                callback(tpCache[i])
            end
        end
    end
end

--- 遍历所有的source
---@param ast parser.object
---@param callback fun(src: parser.object): boolean?
function m.eachSource(ast, callback)
    local cache = ast._eachCache
    if not cache then
        cache = { ast }
        ast._eachCache = cache
        ---@type table<parser.object, boolean>
        local mark = {}
        local index = 1
        while true do
            local obj = cache[index]
            if not obj then
                break
            end
            index = index + 1
            if not mark[obj] then
                mark[obj] = true
                addChilds(cache, obj)
            end
        end
    end
    for i = 1, #cache do
        local res = callback(cache[i])
        if res == false then
            return
        end
    end
end

---@param source   parser.object
---@param callback fun(src: parser.object)
function m.eachChild(source, callback)
    local f = eachChildMap[source.type]
    if not f then
        return
    end
    f(source, callback)
end

--- 获取指定的 special
---@param ast parser.object
---@param name string
---@param callback fun(src: parser.object)
function m.eachSpecialOf(ast, name, callback)
    local root = m.getRoot(ast)
    local state = root.state
    if not state.specials then
        return
    end
    local specials = state.specials[name]
    if not specials then
        return
    end
    for i = 1, #specials do
        callback(specials[i])
    end
end

--- 将 position 拆分成行号与列号
---
--- 第一行是0
---@param position integer
---@return integer row
---@return integer col
function m.rowColOf(position)
    return position // 10000, position % 10000
end

--- 将行列合并为 position
---
--- 第一行是0
---@param row integer
---@param col integer
---@return integer
function m.positionOf(row, col)
    return row * 10000 + math.min(col, 10000 - 1)
end

---@alias parser.guide.lines { [integer]: integer, size: integer }

---@param lines    parser.guide.lines
---@param position integer
---@return integer
function m.positionToOffsetByLines(lines, position)
    local row, col = m.rowColOf(position)
    if row < 0 then
        return 0
    end
    if row > #lines then
        return lines.size
    end
    local offset = lines[row] + col - 1
    if lines[row + 1] and offset >= lines[row + 1] then
        return lines[row + 1] - 1
    elseif offset > lines.size then
        return lines.size
    end
    return offset
end

--- 返回全文光标位置
---@param state    parser.state
---@param position integer
---@return integer
function m.positionToOffset(state, position)
    return m.positionToOffsetByLines(state.lines, position)
end

---@param lines  parser.guide.lines
---@param offset integer
---@return integer
function m.offsetToPositionByLines(lines, offset)
    local left  = 0
    local right = #lines
    local row   = 0
    while true do
        row = (left + right) // 2
        if row == left then
            if right ~= left then
                if lines[right] - 1 <= offset then
                    row = right
                end
            end
            break
        end
        local start = lines[row] - 1
        if start > offset then
            right = row --[[@as integer]]
        else
            left  = row --[[@as integer]]
        end
    end
    local col = offset - lines[row] + 1
    return m.positionOf(row, col)
end

---@param state  parser.state
---@param offset integer
---@return integer
function m.offsetToPosition(state, offset)
    return m.offsetToPositionByLines(state.lines, offset)
end

---@param state parser.state
---@param row integer
---@return integer
function m.getLineRange(state, row)
    if not state.lines[row] then
        return 0
    end
    local lua = state.lua or ''
    local nextLineStart = state.lines[row + 1] or #lua
    for i = nextLineStart - 1, state.lines[row], -1 do
        local w = lua:sub(i, i)
        if w ~= '\r' and w ~= '\n' then
            return i - state.lines[row] + 1
        end
    end
    return 0
end

local assignTypeMap = {
    ['setglobal']         = true,
    ['local']             = true,
    ['self']              = true,
    ['setlocal']          = true,
    ['setfield']          = true,
    ['setmethod']         = true,
    ['setindex']          = true,
    ['tablefield']        = true,
    ['tableindex']        = true,
    ['tableexp']          = true,
    ['label']             = true,
    ['doc.class']         = true,
    ['doc.alias']         = true,
    ['doc.enum']          = true,
    ['doc.field']         = true,
    ['doc.class.name']    = true,
    ['doc.alias.name']    = true,
    ['doc.enum.name']     = true,
    ['doc.field.name']    = true,
    ['doc.type.field']    = true,
    ['doc.type.array']    = true,
}
---@param source parser.object
---@return boolean
function m.isAssign(source)
    local tp = source.type
    if assignTypeMap[tp] then
        return true
    end
    if tp == 'call' then
        local special = m.getSpecial(source.node)
        if special == 'rawset' then
            return true
        end
    end
    return false
end

local getTypeMap = {
    ['getglobal'] = true,
    ['getlocal']  = true,
    ['getfield']  = true,
    ['getmethod'] = true,
    ['getindex']  = true,
}
---@param source parser.object
---@return boolean
function m.isGet(source)
    local tp = source.type
    if getTypeMap[tp] then
        return true
    end
    if tp == 'call' then
        local special = m.getSpecial(source.node)
        if special == 'rawget' then
            return true
        end
    end
    return false
end

function m.getSpecial(source)
    if not source then
        return nil
    end
    return source.special
end

---@param obj parser.object?
---@return string|integer?
function m.getKeyNameOfLiteral(obj)
    if not obj then
        return nil
    end
    ---@type string
    local tp = obj.type
    if tp == 'field'
    or     tp == 'method' then
        return obj[1]
    elseif tp == 'string'
    or     tp == 'number'
    or     tp == 'integer'
    or     tp == 'boolean'
    or     tp == 'doc.type.integer'
    or     tp == 'doc.type.string'
    or     tp == 'doc.type.boolean' then
        return obj[1]
    end
end

---@param obj parser.object?
---@return string?
function m.getKeyName(obj)
    if not obj then
        return nil
    end
    ---@type string
    local tp = obj.type
    if tp == 'getglobal'
    or tp == 'setglobal' then
        return obj[1]
    elseif tp == 'local'
    or     tp == 'self'
    or     tp == 'getlocal'
    or     tp == 'setlocal' then
        return obj[1]
    elseif tp == 'getfield'
    or     tp == 'setfield'
    or     tp == 'tablefield' then
        if obj.field then
            return obj.field[1]
        end
    elseif tp == 'getmethod'
    or     tp == 'setmethod' then
        if obj.method then
            return obj.method[1]
        end
    elseif tp == 'getindex'
    or     tp == 'setindex'
    or     tp == 'tableindex' then
        -- may transitively return the raw tableexp integer described below
        ---@diagnostic expect-next-line: return-type-mismatch
        return m.getKeyNameOfLiteral(obj.index)
    elseif tp == 'tableexp' then
        -- Genuinely returns the raw integer here (not a string) -- callers
        -- that key a table by position (e.g. vm/compiler.lua's field
        -- lookups) rely on getting the same integer back that indexed the
        -- table literal in the first place; stringifying it here broke
        -- those lookups (`t["1"]` is not `t[1]`) when tried.
        ---@diagnostic expect-next-line: return-type-mismatch
        return obj.tindex
    elseif tp == 'field'
    or     tp == 'method' then
        return obj[1]
    elseif tp == 'doc.class' then
        return obj.class[1]
    elseif tp == 'doc.alias' then
        return obj.alias[1]
    elseif tp == 'doc.enum' then
        return obj.enum[1]
    elseif tp == 'doc.field' then
        return obj.field and obj.field[1]
    elseif tp == 'doc.field.name'
    or     tp == 'doc.type.name'
    or     tp == 'doc.class.name'
    or     tp == 'doc.alias.name'
    or     tp == 'doc.enum.name'
    or     tp == 'doc.extends.name' then
        return obj[1]
    elseif tp == 'doc.type.field' then
        return m.getKeyName(obj.name)
    end
    -- may return the raw tableexp integer described above
    ---@diagnostic expect-next-line: return-type-mismatch
    return m.getKeyNameOfLiteral(obj)
end

---@param obj parser.object?
---@return string?
function m.getKeyTypeOfLiteral(obj)
    if not obj then
        return nil
    end
    ---@type string
    local tp = obj.type
    if tp == 'field'
    or     tp == 'method' then
        return 'string'
    elseif tp == 'string' then
        return 'string'
    elseif tp == 'number' then
        return 'number'
    elseif tp == 'integer' then
        return 'integer'
    elseif tp == 'boolean' then
        return 'boolean'
    end
end

---@param obj parser.object?
---@return string?
function m.getKeyType(obj)
    if not obj then
        return nil
    end
    ---@type string
    local tp = obj.type
    if tp == 'getglobal'
    or tp == 'setglobal' then
        return 'string'
    elseif tp == 'local'
    or     tp == 'self'
    or     tp == 'getlocal'
    or     tp == 'setlocal' then
        return 'local'
    elseif tp == 'getfield'
    or     tp == 'setfield'
    or     tp == 'tablefield' then
        return 'string'
    elseif tp == 'getmethod'
    or     tp == 'setmethod' then
        return 'string'
    elseif tp == 'getindex'
    or     tp == 'setindex'
    or     tp == 'tableindex' then
        return m.getKeyTypeOfLiteral(obj.index)
    elseif tp == 'tableexp' then
        return 'integer'
    elseif tp == 'field'
    or     tp == 'method' then
        return 'string'
    elseif tp == 'doc.class' then
        return 'string'
    elseif tp == 'doc.alias' then
        return 'string'
    elseif tp == 'doc.enum' then
        return 'string'
    elseif tp == 'doc.field' then
        return obj.field and type(obj.field[1]) or nil
    elseif tp == 'doc.type.field' then
        return type(obj.name[1])
    end
    if tp == 'doc.field.name' then
        return type(obj[1])
    end
    return m.getKeyTypeOfLiteral(obj)
end

---是否是全局变量（包括 _G.XXX 形式）
---@param source parser.object
---@return boolean
function m.isGlobal(source)
    if source._isGlobal ~= nil then
        return source._isGlobal
    end
    if source.tag == '_ENV' then
        source._isGlobal = true
        return false
    end
    if source.special == '_G' then
        source._isGlobal = true
        return true
    end
    if source.type == 'setglobal'
    or source.type == 'getglobal' then
        if source.node and source.node.tag == '_ENV' then
            source._isGlobal = true
            return true
        end
    end
    if source.type == 'setfield'
    or source.type == 'getfield'
    or source.type == 'setindex'
    or source.type == 'getindex' then
        local current = source
        while current do
            local node = current.node
            if not node then
                break
            end
            if node.special == '_G' then
                source._isGlobal = true
                return true
            end
            if m.getKeyName(node) ~= '_G' then
                break
            end
            current = node
        end
    end
    if source.type == 'call' then
        local node = source.node
        if node.special == 'rawget'
        or node.special == 'rawset' then
            if source.args and source.args[1] then
                local isGlobal = source.args[1].special == '_G'
                source._isGlobal = isGlobal
                return isGlobal
            end
        end
    end
    source._isGlobal = false
    return false
end

---@param ast      parser.object
---@param position integer
---@return boolean? # true if in range, nil (not false) otherwise -- matches eachSourceContain's callback-return-passthrough
function m.isInString(ast, position)
    return m.eachSourceContain(ast, position, function (source)
        if  source.type == 'string'
        and source.start < position then
            return true
        end
    end)
end

---@param ast    parser.object
---@param offset integer
---@return boolean
function m.isInComment(ast, offset)
    for _, com in ipairs(ast.state.comms) do
        if offset >= com.start and offset <= com.finish then
            return true
        end
    end
    return false
end

function m.isOOP(source)
    if source.type == 'setmethod'
    or source.type == 'getmethod' then
        return true
    end
    if source.type == 'method'
    or source.type == 'field'
    or source.type == 'function' then
        return m.isOOP(source.parent)
    end
    return false
end

local basicTypeMap = {
    ['unknown']  = true,
    ['any']      = true,
    ['true']     = true,
    ['false']    = true,
    ['nil']      = true,
    ['boolean']  = true,
    ['integer']  = true,
    ['number']   = true,
    ['string']   = true,
    ['table']    = true,
    ['function'] = true,
    ['thread']   = true,
    ['userdata'] = true,
}

---@param str string
---@return boolean
function m.isBasicType(str)
    return basicTypeMap[str] == true
end

---@param source parser.object
---@return boolean
function m.isBlockType(source)
    return blockTypes[source.type] == true
end

---@param source parser.object
---@return parser.object?
function m.getSelfNode(source)
    if source.type == 'getlocal'
    or source.type == 'setlocal' then
        source = source.node
    end
    if source.type ~= 'self' then
        return nil
    end
    local args = source.parent
    if args.type == 'callargs' then
        local call = args.parent
        if call.type ~= 'call' then
            return nil
        end
        local getmethod = call.node
        if getmethod.type ~= 'getmethod' then
            return nil
        end
        return getmethod.node
    end
    if args.type == 'funcargs' then
        return m.getFunctionSelfNode(args.parent)
    end
    return nil
end

---@param func parser.object
---@return parser.object?
function m.getFunctionSelfNode(func)
    if func.type ~= 'function' then
        return nil
    end
    local parent = func.parent
    if parent.type == 'setmethod'
    or parent.type == 'setfield' then
        return parent.node
    end
    return nil
end

---@param source parser.object
---@return parser.object?
function m.getTopBlock(source)
    for _ = 1, 1000 do
        local block = source.parent
        if not block then
            return nil
        end
        if topBlockTypes[block.type] then
            return block
        end
        source = block
    end
    return nil
end

---@param source parser.object
---@return boolean
function m.isParam(source)
    if  source.type ~= 'local'
    and source.type ~= 'self' then
        return false
    end
    if source.parent.type ~= 'funcargs' then
        return false
    end
    return true
end

---@param source parser.object
---@return parser.object[]?
function m.getParams(source)
    if source.type == 'call' then
        local args = source.args
        if not args then
            return
        end
        assert(args.type == 'callargs', 'call.args type is\'t callargs')
        return args
    elseif source.type == 'callargs' then
        return source
    elseif source.type == 'function' then
        local args = source.args
        if not args then
            return
        end
        assert(args.type == 'funcargs', 'function.args type is\'t callargs')
        return args
    end
    return nil
end

---@param source parser.object
---@param index integer
---@return parser.object?
function m.getParam(source, index)
    local args = m.getParams(source)
    return args and args[index] or nil
end

return m
