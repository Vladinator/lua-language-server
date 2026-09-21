local files           = require 'files'
local vm              = require 'vm'
local guide           = require 'parser.guide'
local protoDiagnostic = require 'proto.diagnostic'

local requireLike = {
    ['include'] = true,
    ['import']  = true,
    ['require'] = true,
    ['load']    = true,
}

local UNDEF_GLOBAL_MESSAGE = 'Undefined global `%s`.'
local REQUIRE_LIKE_MESSAGE = 'You can treat `%s` as `require` by setting.'

protoDiagnostic.register {
    'undefined-global',
} {
    group    = 'global',
    narrowSettings = { 'Lua.diagnostics.globals', 'Lua.diagnostics.globalsRegex' },
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable undefined global variable diagnostics.',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    -- 遍历全局变量，检查所有没有 set 模式的全局变量
    guide.eachSourceType(state.ast, 'getglobal', function (src) ---@async
        if vm.isUndefinedGlobal(src) then
            local key = src[1]
            local message = UNDEF_GLOBAL_MESSAGE:format(key)
            if requireLike[key:lower()] then
                message = ('%s(%s)'):format(message, REQUIRE_LIKE_MESSAGE:format(key))
            end

            callback {
                start   = src.start,
                finish  = src.finish,
                message = message,
                undefinedGlobal = src[1]
            }
        end
    end)
end
