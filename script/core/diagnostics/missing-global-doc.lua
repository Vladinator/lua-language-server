local files           = require 'files'
local guide           = require "parser.guide"
local await           = require 'await'
local helper          = require 'core.diagnostics.helper.missing-doc-helper'
local protoDiagnostic = require 'proto.diagnostic'

local COMMENT_MESSAGE = 'Missing comment for global function `%s`.'
local PARAM_MESSAGE   = 'Missing @param annotation for parameter `%s` in global function `%s`.'
local RETURN_MESSAGE  = 'Missing @return annotation at index `%d` in global function `%s`.'

protoDiagnostic.register {
    'missing-global-doc',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'None',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    if not state.ast then
        return
    end

    ---@async
    guide.eachSourceType(state.ast, 'function', function (source)
        await.delay()

        if source.parent.type ~= 'setglobal' then
            return
        end

        helper.CheckFunction(source, callback, COMMENT_MESSAGE, PARAM_MESSAGE, RETURN_MESSAGE)
    end)
end
