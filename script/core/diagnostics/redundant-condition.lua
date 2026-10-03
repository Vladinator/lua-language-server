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

-- the kind of a literal operand: what `x == <literal>` is compared against
local LITERAL_KIND = {
    ['string']  = 'string',
    ['number']  = 'number',
    ['integer'] = 'number',
    ['boolean'] = 'boolean',
    ['nil']     = 'nil',
}

--- Whether a value of type `node` can be equal to the literal `lit`, and whether it always is.
--- Nothing is judged (nil, nil) for a type that is not fully known (`any`, `unknown`, empty).
---@param node vm.node
---@param lit  parser.object
---@return boolean? canEqual
---@return boolean? mustEqual
local function judgeLiteral(node, lit)
    local litKind = LITERAL_KIND[lit.type]
    if not litKind or #node == 0 then
        return nil, nil
    end
    local litValue = lit[1]
    local can = false
    local only = nil       -- the one literal the node consists of, if it does
    local count = 0
    if node.optional then
        can = can or litKind == 'nil'
        count = count + 1
    end
    for _, c in ipairs(node) do
        -- (a node also lists the variables it came from: they are not types)
        if c.type == 'variable' or c.type == 'local' or (c.type == 'global' and c.cate ~= 'type') then
            goto CONTINUE
        end
        count = count + 1
        ---@type string?
        local kind
        ---@type (string|number|boolean)?
        local value
        if c.type == 'global' and c.cate == 'type' then
            local name = c.name
            if name == 'any' or name == 'unknown' then
                return nil, nil
            elseif name == 'nil' then
                kind = 'nil'
            elseif name == 'string' or name == 'boolean' then
                kind = name
                can = can or litKind == name
            elseif name == 'number' or name == 'integer' then
                kind = 'number'
                can = can or litKind == 'number'
            end
            -- (any other class, table or function type: never equal to a primitive literal)
        elseif c.type == 'doc.type.string' or c.type == 'string' then
            kind, value = 'string', c[1]
        elseif c.type == 'doc.type.integer' or c.type == 'integer' or c.type == 'number' then
            kind, value = 'number', c[1]
        elseif c.type == 'doc.type.boolean' or c.type == 'boolean' then
            kind, value = 'boolean', c[1]
        elseif c.type == 'nil' then
            kind = 'nil'
        end
        if kind == 'nil' and litKind == 'nil' then
            can = true
        elseif value ~= nil then
            if kind == litKind and value == litValue then
                can = true
                only = c
            end
        end
        ::CONTINUE::
    end
    if count == 0 then
        return nil, nil   -- no type at all (an unknown global): nothing to judge
    end
    -- always equal: the node is exactly one literal, and it is the literal compared with
    local must = can and count == 1 and only ~= nil
    return can, must
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
        -- so is a comparison of two literals (`if 1 == 2 then`)
        if filter.type == 'binary' and filter[1] and filter[2]
        and LITERAL_KIND[filter[1].type] and LITERAL_KIND[filter[2].type] then
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
        if filter.type == 'binary' and filter.op and (filter.op.type == '==' or filter.op.type == '~=')
        and filter[1] and filter[2] then
            local left, right = filter[1], filter[2]
            local litSide = LITERAL_KIND[right.type] and right or (LITERAL_KIND[left.type] and left) or nil
            local other = litSide == right and left or right
            if litSide and not LITERAL_KIND[other.type] then
                local can, must = judgeLiteral(vm.compileNode(other), litSide)
                if can ~= nil then
                    local equal = filter.op.type == '=='
                    if not can then
                        callback {
                            start   = filter.start,
                            finish  = filter.finish,
                            message = equal and 'This comparison is always false: the value can never equal this.'
                                            or  'This comparison is always true: the value can never equal this.',
                        }
                        return
                    elseif must then
                        callback {
                            start   = filter.start,
                            finish  = filter.finish,
                            message = equal and 'This comparison is always true: the value is always this.'
                                            or  'This comparison is always false: the value is always this.',
                        }
                        return
                    end
                end
            end
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
