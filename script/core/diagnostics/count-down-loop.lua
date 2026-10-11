local files           = require "files"
local guide           = require "parser.guide"
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Do you mean `%s` ?'
local ZERO_STEP = 'The step of this loop is `0`: it never ends, and Lua raises an error.'
local WRONG_WAY = 'The step is negative but the loop counts up: it never runs. Do you mean `%s, %s, %s`?'

--- The value of a step written as a number (`2`, `-1`), nil for anything else.
---@param step parser.object?
---@return number?
local function literalStep(step)
    if not step then
        return nil
    end
    if step.type == 'unary' and step.op and step.op.type == '-' and step[1] and step[1].type ~= 'unary' then
        local inner = tonumber(step[1][1])
        return inner and -inner or nil
    end
    return tonumber(step[1])
end

protoDiagnostic.register {
    'count-down-loop',
} {
    group    = 'ambiguity',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for `for` loops which will never reach their max/limit because the loop is incrementing instead of decrementing.',
}

return function (uri, callback)
    local state = files.getState(uri)
    local text  = files.getText(uri)
    if not state or not text then
        return
    end

    guide.eachSourceType(state.ast, 'loop', function (source)
        local literal = literalStep(source.step)
        if literal == 0 and source.step then
            callback {
                start   = source.step.start,
                finish  = source.step.finish,
                message = ZERO_STEP,
            }
            return
        end
        if literal and literal < 0 and source.init and source.max then
            local from, to = tonumber(source.init[1]), tonumber(source.max[1])
            if from and to and from < to then
                callback {
                    start   = source.init.start,
                    finish  = source.step.finish,
                    message = WRONG_WAY:format(source.max[1], source.init[1], literal),
                }
                return
            end
        end
        ---@type number?
        local maxNumber = source.max and tonumber(source.max[1]) or nil
        if not maxNumber then
            return
        end
        ---@type number?
        local minNumber = source.init and tonumber(source.init[1]) or nil
        if minNumber and maxNumber and minNumber <= maxNumber then
            return
        end
        if not minNumber and maxNumber ~= 1 then
            return
        end
        if not source.step then
            callback {
                start   = source.init.start,
                finish  = source.max.finish,
                message = MESSAGE:format(
                    ('%s, %s'):format(text:sub(
                        guide.positionToOffset(state, source.init.start + 1),
                        guide.positionToOffset(state, source.max.finish)
                    ), '-1')
                )
            }
        else
            local stepNumber = tonumber(source.step[1])
            if stepNumber and stepNumber > 0 then
                callback {
                    start   = source.init.start,
                    finish  = source.step.finish,
                    message = MESSAGE:format(
                        ('%s, -%s'):format(text:sub(
                            guide.positionToOffset(state, source.init.start + 1),
                            guide.positionToOffset(state, source.max.finish)
                        ), source.step[1])
                    )
                }
            end
        end
    end)
end
