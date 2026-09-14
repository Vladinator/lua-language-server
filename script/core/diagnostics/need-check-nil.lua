local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Need check nil.'

protoDiagnostic.register {
    'need-check-nil',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
}

-- Binary/unary operators that raise a runtime error when given a nil
-- operand (unlike `and`/`or`/`==`/`~=`/`not`, which all handle nil without
-- erroring, so are deliberately excluded).
local UNSAFE_BINARY_OPS = {
    ['+']  = true, ['-']  = true, ['*']  = true, ['/']  = true,
    ['%']  = true, ['//'] = true, ['^']  = true, ['..'] = true,
    ['<']  = true, ['>']  = true, ['<='] = true, ['>='] = true,
    ['&']  = true, ['|']  = true, ['~']  = true, ['<<'] = true, ['>>'] = true,
}
local UNSAFE_UNARY_OPS = {
    ['-'] = true, ['#'] = true, ['~'] = true,
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    ---@async
    guide.eachSourceType(state.ast, 'getlocal', function (src)
        delayer:delay()
        local checkNil
        local nxt = src.next
        if nxt then
            if nxt.type == 'getfield'
            or nxt.type == 'getmethod'
            or nxt.type == 'getindex'
            or nxt.type == 'call' then
                -- 安全导航（?. / ?.( / ?.[ 等）：访问本身已判空，无需再次检查
                if not nxt.safe then
                    checkNil = true
                end
            end
        end
        local parent = src.parent
        if parent then
            if parent.type == 'call' and parent.node == src then
                -- 安全导航调用（f?.()）：已判空，无需再次检查
                if not parent.safe then
                    checkNil = true
                end
            elseif parent.type == 'setindex' and parent.index == src then
                checkNil = true
            elseif parent.type == 'binary'
            and parent.op and UNSAFE_BINARY_OPS[parent.op.type]
            and (parent[1] == src or parent[2] == src) then
                -- 二元运算符（算术/比较/拼接/位运算）对 nil 操作数会直接报错
                checkNil = true
            elseif parent.type == 'unary'
            and parent.op and UNSAFE_UNARY_OPS[parent.op.type] then
                -- 一元运算符（取负/取长度/按位取反）对 nil 操作数会直接报错
                checkNil = true
            else
                -- 数值 for 循环的初值/终值/步长节点的 parent 是内部的
                -- expList，而非 loop 本身（见 parser/compile.lua 里
                -- `value.parent = expList` / `expList.parent = action`），
                -- 所以要看祖父节点
                local loop = parent.parent
                if loop and loop.type == 'loop'
                and (loop.init == src or loop.max == src or loop.step == src) then
                    checkNil = true
                end
            end
        end
        if not checkNil then
            return
        end
        local node = vm.compileNode(src)
        if node:hasFalsy() and not vm.getInfer(src):hasType(uri, 'any') then
            callback {
                start   = src.start,
                finish  = src.finish,
                message = MESSAGE,
            }
        end
    end)
end
