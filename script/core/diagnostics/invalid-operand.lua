local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'
local config          = require 'config'

protoDiagnostic.register {
    'invalid-operand',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for an operator applied to an operand that always fails at run time: the length of a number, arithmetic or `..` on a boolean or a function, a number compared with a string. Only primitives are judged: a table or a class may carry a metatable with the metamethod, so it never is.',
}

-- the kinds of a primitive operand
local NUMBER, STRING, BOOLEAN, FUNCTION = 'number', 'string', 'boolean', 'function'

local KIND_OF_TYPE = {
    ['number']   = NUMBER,
    ['integer']  = NUMBER,
    ['string']   = STRING,
    ['boolean']  = BOOLEAN,
    ['function'] = FUNCTION,
}

local KIND_OF_SOURCE = {
    ['number']             = NUMBER,
    ['integer']            = NUMBER,
    ['doc.type.integer']   = NUMBER,
    ['string']             = STRING,
    ['doc.type.string']    = STRING,
    ['boolean']            = BOOLEAN,
    ['doc.type.boolean']   = BOOLEAN,
    ['function']           = FUNCTION,
    ['doc.type.function']  = FUNCTION,
}

-- operators that take numbers (strings coerce); strings and numbers both work for `..`
local ARITHMETIC = {
    ['+'] = true, ['-'] = true, ['*'] = true, ['/'] = true, ['%'] = true, ['//'] = true, ['^'] = true,
    ['&'] = true, ['|'] = true, ['~'] = true, ['<<'] = true, ['>>'] = true,
    ['..'] = true,
}
-- the bitwise operators: strings are NOT converted to numbers by them in Lua 5.4 and 5.5 (only by the arithmetic ones; 5.3 converted them)
local BITWISE = { ['&'] = true, ['|'] = true, ['~'] = true, ['<<'] = true, ['>>'] = true }
local ORDERING = { ['<'] = true, ['>'] = true, ['<='] = true, ['>='] = true }

--- The set of primitive kinds of a value, or nil when it can be anything else (a table, a class, `any`, an unresolved type: they may have a metatable).
--- `nil` members are left out (an optional value is `need-check-nil`'s business); a value that is only `nil` says nothing.
---@param uri  uri
---@param node vm.node
---@return table<string, true>?
local function primitiveKinds(uri, node)
    ---@type table<string, true>
    local kinds = {}
    local any = false
    for _, c in ipairs(node) do
        ---@type string?
        local kind
        if c.type == 'global' and c.cate == 'type' then
            if c.name == 'nil' then
                goto continue
            end
            kind = KIND_OF_TYPE[c.name]
        elseif c.type == 'variable' or c.type == 'local' or c.type == 'global' then
            -- (the variables a node came from: not types)
            goto continue
        else
            kind = KIND_OF_SOURCE[c.type]
        end
        if not kind then
            return nil
        end
        kinds[kind] = true
        any = true
        ::continue::
    end
    if not any then
        return nil
    end
    return kinds
end

---@param kinds table<string, true>
---@param bad   table<string, true>
---@return boolean
local function allIn(kinds, bad)
    for kind in pairs(kinds) do
        if not bad[kind] then
            return false
        end
    end
    return true
end

local NO_ARITHMETIC = { [BOOLEAN] = true, [FUNCTION] = true }
local NO_BITWISE    = { [BOOLEAN] = true, [FUNCTION] = true, [STRING] = true }
local NO_LENGTH     = { [NUMBER] = true, [BOOLEAN] = true, [FUNCTION] = true }

---@param kinds table<string, true>
---@return string
local function viewKinds(kinds)
    ---@type string[]
    local names = {}
    for kind in pairs(kinds) do
        names[#names+1] = kind
    end
    table.sort(names)
    return table.concat(names, '|')
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    local version = config.get(uri, 'Lua.runtime.version')
    local stringsInBitwise = version == 'Lua 5.4' or version == 'Lua 5.5'

    --- The kinds an operand of the operator cannot be.
    ---@param op string
    ---@return table<string, true>
    local function invalidFor(op)
        if BITWISE[op] and stringsInBitwise then
            return NO_BITWISE
        end
        return NO_ARITHMETIC
    end

    ---@async
    ---@param operand parser.object
    ---@return table<string, true>?
    local function kindsOf(operand)
        delayer:delay()
        return primitiveKinds(uri, vm.compileNode(operand))
    end

    ---@param operand parser.object
    ---@param kinds   table<string, true>
    ---@param op      string
    local function report(operand, kinds, op)
        callback {
            start   = operand.start,
            finish  = operand.finish,
            message = ('The operator `%s` cannot be applied to a value of type `%s`.'):format(op, viewKinds(kinds)),
        }
    end

    ---@async
    guide.eachSourceType(state.ast, 'unary', function (src)
        local op = src.op and src.op.type
        local operand = src[1]
        if not op or not operand then
            return
        end
        if op == '#' then
            local kinds = kindsOf(operand)
            if kinds and allIn(kinds, NO_LENGTH) then
                report(operand, kinds, op)
            end
        elseif op == '-' or op == '~' then
            local kinds = kindsOf(operand)
            if kinds and allIn(kinds, invalidFor(op)) then
                report(operand, kinds, op)
            end
        end
    end)

    ---@async
    guide.eachSourceType(state.ast, 'binary', function (src)
        local op = src.op and src.op.type
        local left, right = src[1], src[2]
        if not op or not left or not right then
            return
        end
        -- (a metamethod of EITHER operand is used: `pattern / function` is the other operand's `__div`; the operator is judged only
        -- when both sides are known primitives)
        if ARITHMETIC[op] then
            local lk, rk = kindsOf(left), kindsOf(right)
            if not lk or not rk then
                return
            end
            local invalid = invalidFor(op)
            if allIn(lk, invalid) then
                report(left, lk, op)
            end
            if allIn(rk, invalid) then
                report(right, rk, op)
            end
        elseif ORDERING[op] then
            local lk, rk = kindsOf(left), kindsOf(right)
            if not lk or not rk then
                return
            end
            if allIn(lk, NO_ARITHMETIC) then
                report(left, lk, op)
            elseif allIn(rk, NO_ARITHMETIC) then
                report(right, rk, op)
            elseif ((allIn(lk, { [NUMBER] = true }) and allIn(rk, { [STRING] = true }))
              or (allIn(lk, { [STRING] = true }) and allIn(rk, { [NUMBER] = true }))) then
                report(right, rk, op)
            end
        end
    end)
end
