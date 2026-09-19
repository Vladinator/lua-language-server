local files           = require 'files'
local guide           = require 'parser.guide'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local ONLY_SPACE_MESSAGE = 'Line with spaces only.'
local POST_SPACE_MESSAGE = 'Line with trailing space.'

protoDiagnostic.register {
    'trailing-space',
} {
    group    = 'unused',
    severity = 'Hint',
    status   = 'Opened',
    description = 'Enable trailing space diagnostics.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    local text  = files.getText(uri)
    if not state or not text then
        return
    end
    local delayer = await.newThrottledDelayer(5000)
    local lines = state.lines
    for i = 0, #lines do
        delayer:delay()
        local startOffset  = lines[i]
        local finishOffset = text:find('[\r\n]', startOffset) or (#text + 1)
        local lastOffset   = finishOffset - 1
        local lastChar     = text:sub(lastOffset, lastOffset)
        if lastChar ~= ' ' and lastChar ~= '\t' then
            goto NEXT_LINE
        end
        local lastPos = guide.offsetToPosition(state, lastOffset)
        if guide.isInString(state.ast, lastPos)
        or guide.isInComment(state.ast, lastPos) then
            goto NEXT_LINE
        end
        local firstOffset = startOffset
        for n = lastOffset - 1, startOffset, -1 do
            local char = text:sub(n, n)
            if char ~= ' ' and char ~= '\t' then
                firstOffset = n + 1
                break
            end
        end
        local firstPos = guide.offsetToPosition(state, firstOffset) - 1
        if firstOffset == startOffset then
            callback {
                start   = firstPos,
                finish  = lastPos,
                message = ONLY_SPACE_MESSAGE,
            }
        else
            callback {
                start   = firstPos,
                finish  = lastPos,
                message = POST_SPACE_MESSAGE,
            }
        end
        ::NEXT_LINE::
    end
end
