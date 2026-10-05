local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Cannot call a value of type `%s`.'

protoDiagnostic.register {
    'cannot-call',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for calling a local variable or a literal whose every known type is one that cannot be called (a number, a string, a boolean). Anything that could be callable (a function, a table, a class, `any`, an unknown value, a union with one of those) is left alone, and so are field and method accesses, whose type is not certain; a value that may be `nil` is `need-check-nil`.',
}

--- The types of a value that is never callable.
---@type table<string, true>
local PRIMITIVE_TYPES = {
    ['string']  = true,
    ['number']  = true,
    ['integer'] = true,
    ['boolean'] = true,
}

--- Is `view` (one member of an inferred type) a primitive that cannot be called: a primitive name, or a literal of one
--- (`"text"`, `1`, `true`).
---@param view string
---@return boolean
local function isPrimitiveView(view)
    return PRIMITIVE_TYPES[view] == true
        or view == 'true' or view == 'false'
        or view:sub(1, 1) == '"' or view:sub(1, 1) == "'"
        or tonumber(view) ~= nil
end

--- The callees whose type is trusted (see the check below).
---@type table<string, true>
local CERTAIN_CALLEES = {
    ['getlocal'] = true,
    ['paren']    = true,
    ['integer']  = true,
    ['number']   = true,
    ['string']   = true,
    ['boolean']  = true,
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    ---@async
    guide.eachSourceType(state.ast, 'call', function (call)
        local callee = call.node
        if not callee then
            return
        end
        -- Only a value whose type is certain: a local variable, a literal, a parenthesised one. The type of a field or a method
        -- access (`Lib:Method`, `t.f`) can come out wrong when the table is built across files (the `LibStub` pattern of every addon),
        -- and a wrong type would be a false report on a call that works.
        if not CERTAIN_CALLEES[callee.type] then
            return
        end
        delayer:delay()
        local node = vm.compileNode(callee)
        if node:isOptional() then
            return
        end
        local infer = vm.getInfer(node)
        local views = infer:getSubViews(uri) or { infer:view(uri) }
        if #views == 0 then
            return
        end
        for _, view in ipairs(views) do
            if not isPrimitiveView(view) then
                return
            end
        end
        callback {
            start   = callee.start,
            finish  = callee.finish,
            message = MESSAGE:format(infer:view(uri)),
        }
    end)
end
