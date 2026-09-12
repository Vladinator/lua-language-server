local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'
local lang  = require 'language'
local await = require 'await'

local ALLOWED_BINARY_OPS = {
    ['..']  = true,
    ['and'] = true,
    ['or']  = true,
}

local function isIndexNode(t)
    return t == 'getfield' or t == 'getmethod' or t == 'getindex'
        or t == 'setfield' or t == 'setmethod' or t == 'setindex'
end

local function isBooleanNode(node)
    for c in node:eachObject() do
        if c.type == 'boolean'
        or c.type == 'doc.type.boolean'
        or (c.type == 'global' and c.cate == 'type'
            and (c.name == 'boolean' or c.name == 'true' or c.name == 'false')) then
            return true
        end
    end
    return false
end

local function isDirectCondition(parent, src)
    if parent.filter == src then
        return true
    end
    if parent.type == 'unary' and parent.op and parent.op.type == 'not' then
        return true
    end
    if parent.type == 'binary' and parent.op
    and (parent.op.type == 'and' or parent.op.type == 'or')
    and (parent[1] == src or parent[2] == src) then
        return true
    end
    return false
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)

    ---@async
    guide.eachSourceTypes(state.ast, {'getlocal', 'getglobal', 'getfield', 'getindex', 'getmethod'}, function (src)
        delayer:delay()

        local parent = src.parent
        if not parent then
            return
        end

        local node = vm.compileNode(src)
        if not node:hasSecret() then
            return
        end

        if isDirectCondition(parent, src) then
            if isBooleanNode(node) then
                callback {
                    start   = src.start,
                    finish  = src.finish,
                    message = lang.script('DIAG_NEED_CHECK_SECRET'),
                }
            end
            return
        end

        if isIndexNode(parent.type) and parent.node == src then
            callback {
                start   = src.start,
                finish  = src.finish,
                message = lang.script('DIAG_NEED_CHECK_SECRET'),
            }
            return
        end

        if (parent.type == 'getindex' or parent.type == 'setindex' or parent.type == 'tableindex')
        and parent.index == src then
            callback {
                start   = src.start,
                finish  = src.finish,
                message = lang.script('DIAG_NEED_CHECK_SECRET'),
            }
            return
        end

        if parent.type == 'call' and parent.node == src then
            callback {
                start   = src.start,
                finish  = src.finish,
                message = lang.script('DIAG_NEED_CHECK_SECRET'),
            }
            return
        end

        if parent.type == 'callargs' and parent[1] == src
        and parent.parent and parent.parent.type == 'call'
        and (parent.parent.node.special == 'pairs'
            or parent.parent.node.special == 'ipairs'
            or parent.parent.node.special == 'next') then
            callback {
                start   = src.start,
                finish  = src.finish,
                message = lang.script('DIAG_NEED_CHECK_SECRET'),
            }
            return
        end

        if parent.type == 'unary' and parent.op and parent.op.type ~= 'not' then
            callback {
                start   = src.start,
                finish  = src.finish,
                message = lang.script('DIAG_NEED_CHECK_SECRET'),
            }
            return
        end

        if parent.type == 'binary' then
            local op = parent.op and parent.op.type
            if not ALLOWED_BINARY_OPS[op] then
                callback {
                    start   = src.start,
                    finish  = src.finish,
                    message = lang.script('DIAG_NEED_CHECK_SECRET'),
                }
            end
        end
    end)
end
