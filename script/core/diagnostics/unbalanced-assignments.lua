local files           = require 'files'
local guide           = require 'parser.guide'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'
local vm              = require 'vm'

local MESSAGE = 'The value is assigned as `nil` because the number of values is not enough. In Lua, `x, y = 1 ` is equivalent to `x, y = 1, nil` .'
local CALL_MESSAGE = 'The function returns at most %d value(s): this variable is assigned `nil`.'

protoDiagnostic.register {
    'unbalanced-assignments',
} {
    group    = 'unbalanced',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics on multiple assignments if not all variables obtain a value (e.g., `local x,y = 1`), also when the last value is a call of a function of the project that returns fewer values than there are variables.',
}

local types = {
    'local',
    'setlocal',
    'setglobal',
    'setfield',
    'setindex' ,
}

---@async
return function (uri, callback)
    local ast = files.getState(uri)
    if not ast then
        return
    end

    ---@type parser.object?
    local last

    ---@param source parser.object
    local function checkSet(source)
        if source.value then
            last = source
        else
            if not last then
                return
            end
            local lastValue = last.value
            if  lastValue
            and last.start      <= source.start
            and lastValue.start >= source.finish then
                callback {
                    start   = source.start,
                    finish  = source.finish,
                    message = MESSAGE
                }
            else
                last = nil
            end
        end
    end

    --- `local a, b, c = f()`: `b` and `c` are the 2nd and 3rd value of the call. A function that returns fewer values (annotated or
    --- read from its body; one with a `...` return or an unknown arity has no maximum) leaves them `nil`. A function that returns
    --- nothing at all is left alone: that is most often a call whose results are not described.
    ---@async
    ---@param source parser.object
    local function checkCall(source)
        local value = source.value
        if not value or value.type ~= 'select' or not value.vararg or value.vararg.type ~= 'call' then
            return
        end
        local position = value.sindex
        if not position or position < 2 then
            return
        end
        -- a variable called `_` is the placeholder for a value nobody wants
        local name = source.type == 'local' and source[1] or (source.type == 'setlocal' and source.node and source.node[1])
        if name == '_' then
            return
        end
        local call = value.vararg
        -- only a function the project defines: the return lists of a library (the annotations of an API, the standard library) are
        -- often incomplete, and a variable that "gets nil" there is not a mistake of the code that is checked
        local funcs = vm.getMatchedFunctions(call.node, call.args)
        if not funcs or #funcs == 0 then
            return
        end
        for _, func in ipairs(funcs) do
            local funcUri = guide.getUri(func)
            if files.isLibrary(funcUri) or vm.isMetaFile(funcUri) then
                return
            end
        end
        local _, max = vm.countReturnsOfCall(call.node, call.args)
        if max >= 1 and max < position then
            -- a last value that is `any` or unknown may stand for several (`fun(): any` for a function nobody described)
            for _, func in ipairs(funcs) do
                local last = vm.getReturnOfFunction(func, math.floor(max))
                if last then
                    local lastNode = vm.compileNode(last)
                    if lastNode:hasType('any') or lastNode:hasType('unknown') or not lastNode:hasKnownType() then
                        return
                    end
                end
            end
            callback {
                start   = source.start,
                finish  = source.finish,
                message = CALL_MESSAGE:format(max)
            }
        end
    end

    local delayer = await.newThrottledDelayer(1000)
    ---@async
    guide.eachSourceTypes(ast.ast, types, function (source)
        delayer:delay()
        checkSet(source)
        checkCall(source)
    end)
end
