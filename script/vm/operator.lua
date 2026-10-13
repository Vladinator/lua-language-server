---@class vm
local vm     = require 'vm.vm'
local util   = require 'utility'
local guide  = require 'parser.guide'
local config = require 'config'

vm.UNARY_OP  = {
    'unm',
    'bnot',
    'len',
}
vm.BINARY_OP = {
    'add',
    'sub',
    'mul',
    'div',
    'mod',
    'pow',
    'idiv',
    'band',
    'bor',
    'bxor',
    'shl',
    'shr',
    'concat',
}
vm.OTHER_OP = {
    'call',
}

local unaryMap = {
    ['-'] = 'unm',
    ['~'] = 'bnot',
    ['#'] = 'len',
}

local binaryMap = {
    ['+']  = 'add',
    ['-']  = 'sub',
    ['*']  = 'mul',
    ['/']  = 'div',
    ['%']  = 'mod',
    ['^']  = 'pow',
    ['//'] = 'idiv',
    ['&']  = 'band',
    ['|']  = 'bor',
    ['~']  = 'bxor',
    ['<<'] = 'shl',
    ['>>'] = 'shr',
    ['~>>'] = 'sar', -- LuaJIT 算术右移
    ['..'] = 'concat',
}

local otherMap = {
    ['()'] = 'call',
}

vm.OP_UNARY_MAP  = util.revertMap(unaryMap)
vm.OP_BINARY_MAP = util.revertMap(binaryMap)
vm.OP_OTHER_MAP  = util.revertMap(otherMap)

---@param source parser.object
---@return uri, vm.infer, vm.infer
local function getOperandInfers(source)
    return guide.getUri(source), vm.getInfer(source[1]), vm.getInfer(source[2])
end

---@param operators parser.object[]
---@param op string
---@param value? parser.object
---@param result? vm.node
---@param uri? uri
---@param classGlobal? vm.global
---@param signs? parser.object[]
---@return vm.node?
local function checkOperators(operators, op, value, result, uri, classGlobal, signs)
    -- For operators declared on a generic class and reached through an
    -- instantiated type (`Box<string>`), substitute the class type
    -- parameters in the operand and return annotations.
    ---@type table<string, vm.node>?
    local genericMap
    if uri and classGlobal and signs then
        genericMap = vm.getClassGenericMap(uri, classGlobal, signs)
    end
    for _, operator in ipairs(operators) do
        if operator.op[1] ~= op
        or not operator.extends then
            goto CONTINUE
        end
        -- 泛型类上声明的 @operator：按实例化类型替换类泛型参数。
        -- @operator 的 exp/extends 运行时均为单个类型节点（extends 字段的数组
        -- 类型注解仅供 doc.class 等使用），克隆结果可能是 vm.generic，故声明联合类型。
        ---@type parser.object|vm.generic
        local exp     = operator.exp
        ---@type parser.object|vm.generic
        local extends = operator.extends
        if genericMap then
            if exp and vm.containsGenericName(exp) then
                exp = vm.cloneObject(exp, genericMap) or exp --[[@as parser.object|vm.generic]]
            end
            if vm.containsGenericName(extends) then
                extends = vm.cloneObject(extends, genericMap) or extends --[[@as parser.object|vm.generic]]
            end
        end
        if value and exp then
            local valueNode = vm.compileNode(value)
            local expNode   = vm.compileNode(exp)
            local opUri     = guide.getUri(operator)
            for vo in valueNode:eachObject() do
                local child = vo
                -- `vm.isSubType` has no notion of `doc.type.sign`; match an
                -- instantiated type (`Box<string>`) by its base class.
                if child.type == 'doc.type.sign' and child.node and child.node[1] then
                    child = vm.getGlobal('type', child.node[1]) or child
                end
                if vm.isSubType(opUri, child, expNode) then
                    if not result then
                        result = vm.createNode()
                    end
                    result:merge(vm.compileNode(extends))
                    return result
                end
            end
        else
            if not result then
                result = vm.createNode()
            end
            result:merge(vm.compileNode(extends))
            return result
        end
        ::CONTINUE::
    end
    return result
end

--- The metatables `setmetatable` gave to a table constructor, so that what a metatable does to the table (`__call`, `__len`, the
--- arithmetic and `..` metamethods) can be read from the table later. Keyed by the constructor, weakly: it lives as long as the tree.
---@type table<parser.object, parser.object[]>
local metatableLinks = setmetatable({}, { __mode = 'k' })

---@param tbl parser.object a table constructor
---@param mt  parser.object the second argument of `setmetatable`
function vm.linkMetatable(tbl, mt)
    local links = metatableLinks[tbl]
    if not links then
        links = {}
        metatableLinks[tbl] = links
    end
    for _, linked in ipairs(links) do
        if linked == mt then
            return
        end
    end
    links[#links+1] = mt
end

---@class parser.object
---@field package _metatableScanned? boolean

--- `local M = {}` ... `setmetatable(M, meta)` as a statement: nobody compiles the result of that call, so the link is made from the
--- table when its metamethods are asked for.
---@param tbl parser.object a table constructor
local function linkStatementMetatables(tbl)
    if tbl._metatableScanned then
        return
    end
    tbl._metatableScanned = true
    local var = tbl.parent
    if not var or var.type ~= 'local' or var.value ~= tbl then
        return
    end
    for _, ref in ipairs(var.ref or {}) do
        local args = ref.parent
        local call = args and args.type == 'callargs' and args.parent
        if call and call.type == 'call' and call.node and call.node.special == 'setmetatable' and args[1] == ref then
            vm.compileNode(call)
        end
    end
end

--- The functions the metatables linked to `obj` give to the metamethod `__<name>`: the ones written in the metatable, else the ones its
--- class declares. (The field also has the type of the standard `metatable` class, `fun(t1, t2): any`, which says nothing about this one.)
---@param name string
---@param obj  parser.object a table constructor
---@return parser.object[]
function vm.getMetamethodFunctions(name, obj)
    ---@type parser.object[]
    local found = {}
    linkStatementMetatables(obj)
    local links = metatableLinks[obj]
    if not links then
        return found
    end
    for _, mt in ipairs(links) do
        vm.compileByParentNodeAll(mt, '__' .. name, function (src)
            -- the declaration of the standard `metatable` class (`__len: fun(t): integer`) is not what this metatable does
            if vm.isMetaFile(guide.getUri(src)) then
                return
            end
            ---@type parser.object[]
            local written = {}
            ---@type parser.object[]
            local declared = {}
            for func in vm.compileNode(src):eachObject() do
                if func.type == 'function' then
                    written[#written+1] = func
                elseif func.type == 'doc.type.function' then
                    declared[#declared+1] = func
                end
            end
            for _, func in ipairs(#written > 0 and written or declared) do
                found[#found+1] = func
            end
        end)
    end
    return found
end

--- The first result of the metamethod `__<op>` of the metatables linked to `obj`.
---@param op  string
---@param obj parser.object
---@return vm.node?
local function runMetamethod(op, obj)
    ---@type vm.node?
    local result
    for _, func in ipairs(vm.getMetamethodFunctions(op, obj)) do
        local rtn = vm.getReturnOfFunction(func, 1)
        if rtn then
            for ret in vm.compileNode(rtn):eachObject() do
                -- an `unknown` says nothing about the result (it stands for a return not worked out yet)
                if not (ret.type == 'global' and ret.cate == 'type' and ret.name == 'unknown') then
                    result = result or vm.createNode()
                    result:merge(ret)
                end
            end
        end
    end
    return result
end

--- What reading a key the table does not have gives when its metatable's `__index` is a function: that function's first result.
---@param receiver parser.object
---@return vm.node?
function vm.getIndexMetamethodResult(receiver)
    ---@type vm.node?
    local result
    for obj in vm.compileNode(receiver):eachObject() do
        if obj.type == 'table' then
            local viaIndex = runMetamethod('index', obj)
            if viaIndex then
                result = result and result:merge(viaIndex) or viaIndex
            end
        end
    end
    return result
end

---@param op string
---@param exp parser.object
---@param value? parser.object
---@return vm.node?
function vm.runOperator(op, exp, value)
    local uri = guide.getUri(exp)
    local node = vm.compileNode(exp)
    ---@type vm.node?
    local result
    for cVal in node:eachObject() do
        local c = cVal
        if c.type == 'table' then
            local viaMetatable = runMetamethod(op, c)
            if viaMetatable then
                result = result and result:merge(viaMetatable) or viaMetatable
            end
        end
        if c.type == 'string'
        or c.type == 'doc.type.string' then
            c = vm.declareGlobal('type', 'string')
        end
        if c.type == 'global' and c.cate == 'type' then
            for _, set in ipairs(c:getSets(uri)) do
                if set.operators and #set.operators > 0 then
                    result = checkOperators(set.operators, op, value, result)
                end
            end
        end
        if c.type == 'doc.type.sign' and c.node and c.node[1] then
            local classGlobal = vm.getGlobal('type', c.node[1])
            if classGlobal then
                for _, set in ipairs(classGlobal:getSets(uri)) do
                    if set.operators and #set.operators > 0 then
                        result = checkOperators(set.operators, op, value, result,
                            uri, classGlobal, c.signs)
                    end
                end
            end
        end
    end
    return result
end

vm.unarySwich = util.switch()
    : case 'not'
    ---@param source parser.object
    : call(function (source)
        local result = vm.testCondition(source[1])
        if result == nil then
            vm.setNode(source, vm.declareGlobal('type', 'boolean'))
        else
            vm.setNode(source, {
                type   = 'boolean',
                start  = source.start,
                finish = source.finish,
                parent = source,
                [1]    = not result,
            })
        end
    end)
    : case '#'
    ---@param source parser.object
    : call(function (source)
        local node = vm.runOperator('len', source[1])
        vm.setNode(source, node or vm.declareGlobal('type', 'integer'))
    end)
    : case '-'
    ---@param source parser.object
    : call(function (source)
        local v = vm.getNumber(source[1])
        if v == nil then
            local uri = guide.getUri(source)
            local infer = vm.getInfer(source[1])
            if infer:hasType(uri, 'integer') then
                vm.setNode(source, vm.declareGlobal('type', 'integer'))
            elseif infer:hasType(uri, 'number') then
                vm.setNode(source, vm.declareGlobal('type', 'number'))
            else
                local node = vm.runOperator('unm', source[1])
                vm.setNode(source, node or vm.declareGlobal('type', 'number'))
            end
        else
            vm.setNode(source, {
                type   = 'number',
                start  = source.start,
                finish = source.finish,
                parent = source,
                [1]    = -v,
            })
        end
    end)
    : case '~'
    ---@param source parser.object
    : call(function (source)
        local v = vm.getInteger(source[1])
        if v == nil then
            local node = vm.runOperator('bnot', source[1])
            vm.setNode(source, node or vm.declareGlobal('type', 'integer'))
        else
            vm.setNode(source, {
                type   = 'integer',
                start  = source.start,
                finish = source.finish,
                parent = source,
                [1]    = ~v,
            })
        end
    end)

vm.binarySwitch = util.switch()
    : case 'and'
    ---@param source parser.object
    : call(function (source)
        local node1 = vm.compileNode(source[1])
        local node2 = vm.compileNode(source[2])
        local r1    = vm.testCondition(source[1])
        if r1 == true then
            vm.setNode(source, node2)
        elseif r1 == false then
            vm.setNode(source, node1)
        else
            local node = node1:copy():setFalsy():merge(node2)
            vm.setNode(source, node)
        end
    end)
    : case 'or'
    ---@param source parser.object
    : call(function (source)
        local node1 = vm.compileNode(source[1])
        local node2 = vm.compileNode(source[2])
        local r1 = vm.testCondition(source[1])
        if r1 == true then
            vm.setNode(source, node1)
        elseif r1 == false then
            vm.setNode(source, node2)
        else
            local node = node1:copy():setTruthy()
            if not vm.isNeverExpr(source[2]) then
                node:merge(node2)
            end
            vm.setNode(source, node)
        end
    end)
    : case '??' -- LuaJIT 空值合并：仅当左侧为 nil 时取右侧（false 仍返回左侧）
    ---@param source parser.object
    : call(function (source)
        local node1 = vm.compileNode(source[1])
        local node2 = vm.compileNode(source[2])
        -- 统计具体类型：variable/local 是引用元信息，无具体类型时视为未知（可能为 nil）
        local count   = 0
        local hasNil  = false
        for c in node1:eachObject() do
            if c.type == 'nil'
            or (c.type == 'global' and c.cate == 'type' and c.name == 'nil') then
                hasNil = true
            elseif c.type ~= 'variable' and c.type ~= 'local' then
                count = count + 1
                if c.type == 'unknown'
                or (c.type == 'global' and c.cate == 'type' and c.name == 'unknown') then
                    -- 未初始化变量可能为 nil
                    hasNil = true
                end
            end
        end
        -- a `T?` operand carries its nil as the optional flag, not as an object
        if node1:isOptional() then
            hasNil = true
        end
        if count == 0 then
            -- 无具体类型（仅元信息或空）：未知，视为可能为 nil，取右侧
            vm.setNode(source, node2)
        elseif hasNil then
            -- a 可能为 nil → (a 去 nil) | b
            local node = node1:copy():removeOptional()
            if not vm.isNeverExpr(source[2]) then
                node:merge(node2)
            end
            vm.setNode(source, node)
        else
            -- a 必非 nil → a
            vm.setNode(source, node1)
        end
    end)
    : case '=='
    : case '~='
    ---@param source parser.object
    : call(function (source)
        local result = vm.equal(source[1], source[2])
        if result == nil then
            vm.setNode(source, vm.declareGlobal('type', 'boolean'))
        else
            if source.op.type == '~=' then
                result = not result
            end
            vm.setNode(source, {
                type   = 'boolean',
                start  = source.start,
                finish = source.finish,
                parent = source,
                [1]    = result,
            })
        end
    end)
    : case '<<'
    : case '>>'
    : case '~>>'
    : case '&'
    : case '|'
    : case '~'
    ---@param source parser.object
    : call(function (source)
        local a = vm.getInteger(source[1])
        local b = vm.getInteger(source[2])
        local op = source.op.type
        if a and b then
            local result = op == '<<' and a << b
                        or op == '>>' and a >> b
                        -- LuaJIT 算术右移：Lua 5.3+ 的 >> 即算术右移
                        or op == '~>>' and a >> b
                        or op == '&'  and a &  b
                        or op == '|'  and a |  b
                        or op == '~'  and a ~  b
            vm.setNode(source, {
                type   = 'integer',
                start  = source.start,
                finish = source.finish,
                parent = source,
                [1]    = result,
            })
        else
            local node = vm.runOperator(binaryMap[op], source[1], source[2])
            if not node then
                node = vm.runOperator(binaryMap[op], source[2], source[1])
            end
            if node then
                vm.setNode(source, node)
                return
            end
            -- Bitwise ops on integers always produce integer
            local uri, infer1, infer2 = getOperandInfers(source)
            if  infer1:hasType(uri, 'integer')
            and infer2:hasType(uri, 'integer') then
                vm.setNode(source, vm.declareGlobal('type', 'integer'))
            end
        end
    end)
    : case '+'
    : case '-'
    : case '*'
    : case '/'
    : case '%'
    : case '//'
    : case '^'
    ---@param source parser.object
    : call(function (source)
        local a = vm.getNumber(source[1])
        local b = vm.getNumber(source[2])
        local op = source.op.type
        local zero = b == 0
                and (  op == '%'
                    or op == '/'
                    or op == '//'
                )
        if a and b and not zero then
            local result = op == '+'  and a +  b
                        or op == '-'  and a -  b
                        or op == '*'  and a *  b
                        or op == '/'  and a /  b
                        or op == '%'  and a %  b
                        or op == '//' and a // b
                        or op == '^'  and a ^  b
            vm.setNode(source, {
                type   = (op == '//' or math.type(result) == 'integer') and 'integer' or 'number',
                start  = source.start,
                finish = source.finish,
                parent = source,
                [1]    = result,
            })
        else
            local node = vm.runOperator(binaryMap[op], source[1], source[2])
            if not node then
                node = vm.runOperator(binaryMap[op], source[2], source[1])
            end
            if node then
                vm.setNode(source, node)
                return
            end
            if op == '+'
            or op == '-'
            or op == '*'
            or op == '%' then
                local uri = guide.getUri(source)
                local infer1 = vm.getInfer(source[1])
                local infer2 = vm.getInfer(source[2])
                if  infer1:hasType(uri, 'integer')
                and infer2:hasType(uri, 'integer') then
                    vm.setNode(source, vm.declareGlobal('type', 'integer'))
                    return
                end
                if  (infer1:hasType(uri, 'number') or infer1:hasType(uri, 'integer'))
                and (infer2:hasType(uri, 'number') or infer2:hasType(uri, 'integer')) then
                    vm.setNode(source, vm.declareGlobal('type', 'number'))
                    return
                end
            end
            if op == '/'
            or op == '^' then
                local uri = guide.getUri(source)
                local infer1 = vm.getInfer(source[1])
                local infer2 = vm.getInfer(source[2])
                if  (infer1:hasType(uri, 'integer') or infer1:hasType(uri, 'number'))
                and (infer2:hasType(uri, 'integer') or infer2:hasType(uri, 'number')) then
                    vm.setNode(source, vm.declareGlobal('type', 'number'))
                    return
                end
            end
            if op == '//' then
                local uri = guide.getUri(source)
                local infer1 = vm.getInfer(source[1])
                local infer2 = vm.getInfer(source[2])
                if  (infer1:hasType(uri, 'integer') or infer1:hasType(uri, 'number'))
                and (infer2:hasType(uri, 'integer') or infer2:hasType(uri, 'number')) then
                    vm.setNode(source, vm.declareGlobal('type', 'integer'))
                    return
                end
            end
        end
    end)
    : case '..'
    ---@param source parser.object
    : call(function (source)
        local a =  vm.getString(source[1])
                or vm.getNumber(source[1])
        local b =  vm.getString(source[2])
                or vm.getNumber(source[2])
        if a and b then
            if type(a) == 'number' or type(b) == 'number' then
                local uri     = guide.getUri(source)
                local version = config.get(uri, 'Lua.runtime.version')
                if math.tointeger(a) and math.type(a) == 'float' then
                    if version == 'Lua 5.3' or version == 'Lua 5.4' or version == 'Lua 5.5' then
                        a = ('%.1f'):format(a)
                    else
                        a = ('%.0f'):format(a)
                    end
                end
                if math.tointeger(b) and math.type(b) == 'float' then
                    if version == 'Lua 5.3' or version == 'Lua 5.4' or version == 'Lua 5.5' then
                        b = ('%.1f'):format(b)
                    else
                        b = ('%.0f'):format(b)
                    end
                end
            end
            vm.setNode(source, {
                type   = 'string',
                start  = source.start,
                finish = source.finish,
                parent = source,
                [1]    = a .. b,
            })
        else
            local uri, infer1, infer2 = getOperandInfers(source)
            if  (
                infer1:hasType(uri, 'integer')
            or  infer1:hasType(uri, 'number')
            or  infer1:hasType(uri, 'string')
            )
            and (
                infer2:hasType(uri, 'integer')
            or  infer2:hasType(uri, 'number')
            or  infer2:hasType(uri, 'string')
            ) then
                vm.setNode(source, vm.declareGlobal('type', 'string'))
                return
            end
            local node = vm.runOperator(binaryMap[source.op.type], source[1], source[2])
            if not node then
                node = vm.runOperator(binaryMap[source.op.type], source[2], source[1])
            end
            if node then
                vm.setNode(source, node)
            end
        end
    end)
    : case '>'
    : case '<'
    : case '>='
    : case '<='
    ---@param source parser.object
    : call(function (source)
        local a = vm.getNumber(source[1])
        local b = vm.getNumber(source[2])
        if a and b then
            local op = source.op.type
            local result = op == '>'  and a >  b
                        or op == '<'  and a <  b
                        or op == '>=' and a >= b
                        or op == '<=' and a <= b
            vm.setNode(source, {
                type   = 'boolean',
                start  = source.start,
                finish = source.finish,
                parent = source,
                [1]    =result,
            })
        else
            vm.setNode(source, vm.declareGlobal('type', 'boolean'))
        end
    end)
