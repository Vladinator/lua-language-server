local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm.vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local PRIVATE_MESSAGE   = 'Field `%s` is private, it can only be accessed in class `%s`.'
local PROTECTED_MESSAGE = 'Field `%s` is protected, it can only be accessed in class `%s` and its subclasses.'
local PACKAGE_MESSAGE   = 'Field `%s` can only be accessed in same file `%s`.'

protoDiagnostic.register {
    'invisible',
} {
    group    = 'strict',
    severity = 'Warning',
    status   = 'Any',
    description = 'Enable diagnostics for accesses to fields which are invisible.',
}

local checkTypes = {'getfield', 'setfield', 'getmethod', 'setmethod', 'getindex', 'setindex'}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@async
    guide.eachSourceTypes(state.ast, checkTypes, function (src)
        local child = src.field or src.method or src.index
        if not child then
            return
        end
        local key = guide.getKeyName(src)
        if not key then
            return
        end
        await.delay()
        local defs = vm.getDefs(src)
        for _, def in ipairs(defs) do
            if not vm.isVisible(src.node, def) then
                if vm.getVisibleType(def) == 'private' then
                    callback {
                        start   = child.start,
                        finish  = child.finish,
                        uri     = uri,
                        message = PRIVATE_MESSAGE:format(key, vm.getParentClass(def):getName()),
                    }
                elseif vm.getVisibleType(def) == 'protected' then
                    callback {
                        start   = child.start,
                        finish  = child.finish,
                        uri     = uri,
                        message = PROTECTED_MESSAGE:format(key, vm.getParentClass(def):getName()),
                    }
                elseif vm.getVisibleType(def) == 'package' then
                    callback {
                        start   = child.start,
                        finish  = child.finish,
                        uri     = uri,
                        message = PACKAGE_MESSAGE:format(key, guide.getUri(def)),
                    }
                else
                    error('Unknown visible type: ' .. vm.getVisibleType(def))
                end
                break
            end
        end
    end)
end
