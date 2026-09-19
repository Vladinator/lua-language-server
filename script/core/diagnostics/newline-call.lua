local files           = require 'files'
local guide           = require 'parser.guide'
local await           = require 'await'
local sub             = require 'core.substring'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Will be interpreted as `%s%s`. It may be necessary to add a `,`.'

protoDiagnostic.register {
    'newline-call',
} {
    group    = 'ambiguity',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable newline call diagnostics. It\'s raised when a line starting with `(` is encountered, which is syntactically parsed as a function call on the previous line.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    local text  = files.getText(uri)
    if not state or not text then
        return
    end

    ---@async
    guide.eachSourceType(state.ast, 'call', function (source)
        local node = source.node
        local args = source.args
        if not args then
            return
        end

        -- 必须有其他人在继续使用当前对象
        if not source.next then
            return
        end

        await.delay()

        local startOffset  = guide.positionToOffset(state, args.start) + 1
        local finishOffset = guide.positionToOffset(state, args.finish)
        if text:sub(startOffset,  startOffset)  ~= '('
        or text:sub(finishOffset, finishOffset) ~= ')' then
            return
        end

        local nodeRow = guide.rowColOf(node.finish)
        local argRow  = guide.rowColOf(args.start)
        if nodeRow == argRow then
            return
        end

        if #args == 1 then
            callback {
                start   = node.start,
                finish  = args.finish,
                message = MESSAGE:format(
                    sub(state)(node.start + 1, node.finish),
                    sub(state)(args.start + 1, args.finish)
                ),
            }
        end
    end)
end
