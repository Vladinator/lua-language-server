local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

protoDiagnostic.register {
    'redundant-condition',
} {
    group    = 'redundant',
    severity = 'Hint',
    status   = 'None',
    description = 'Enable diagnostics for an `if` / `elseif` / `while` condition that is provably constant: always truthy or always falsy by its type, or a value compared with itself.',
}

local LITERALS = {
    ['boolean'] = true,
    ['nil']     = true,
    ['number']  = true,
    ['integer'] = true,
    ['string']  = true,
}

--- Whether two expressions name the same variable or the same field path (no calls, no indexing by
--- expressions, so evaluating either has no side effect and gives the same value).
---@param a parser.object
---@param b parser.object
---@return boolean
local function sameRef(a, b)
    if a.type ~= b.type then
        return false
    end
    if a.type == 'getlocal' then
        return a.node == b.node
    end
    if a.type == 'getglobal' then
        return a[1] ~= nil and a[1] == b[1]
    end
    if a.type == 'getfield' then
        local ka, kb = a.field and a.field[1], b.field and b.field[1]
        return ka ~= nil and ka == kb and a.node ~= nil and b.node ~= nil and sameRef(a.node, b.node)
    end
    return false
end

local SELF_TRUE  = { ['=='] = true, ['<='] = true, ['>='] = true }
local SELF_FALSE = { ['<']  = true, ['>']  = true, ['~='] = true }

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    ---@async
    guide.eachSourceTypes(state.ast, { 'ifblock', 'elseifblock', 'while' }, function (src)
        local filter = src.filter
        if not filter then
            return
        end
        -- a literal condition is deliberate (`while true do`, `if false then` to switch code off)
        if LITERALS[filter.type] then
            return
        end
        delayer:delay()
        if filter.type == 'binary' and filter.op and (SELF_TRUE[filter.op.type] or SELF_FALSE[filter.op.type])
        and filter[1] and filter[2] and sameRef(filter[1], filter[2]) then
            -- `x ~= x` / `x == x` is also how NaN is tested: leave numbers alone
            local node = vm.compileNode(filter[1])
            if not (node:hasType('number') or node:hasType('integer') or not node:hasKnownType()) then
                callback {
                    start   = filter.start,
                    finish  = filter.finish,
                    message = SELF_TRUE[filter.op.type]
                        and 'A value compared with itself: this is always true.'
                        or  'A value compared with itself: this is always false.',
                }
            end
            return
        end
        local node = vm.compileNode(filter)
        if node:alwaysTruthy() then
            callback {
                start   = filter.start,
                finish  = filter.finish,
                message = 'This condition is always true.',
            }
        elseif node:alwaysFalsy() then
            callback {
                start   = filter.start,
                finish  = filter.finish,
                message = 'This condition is always false.',
            }
        end
    end)
end
