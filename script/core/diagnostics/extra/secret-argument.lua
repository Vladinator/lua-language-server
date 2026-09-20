-- Companion of need-check-secret.lua (which owns the flag that says a value is secret).
-- `---@param str nosecret string` says a function cannot take a secret value in that parameter
-- (an API of the game that raises an error for one): a call that passes a value known to be
-- secret there is reported on the argument. A value that was checked with a
-- `---@secret-check` function is not secret any more, and a parameter without the keyword
-- takes anything, as before. The keyword is registered here, so this file is all of it.

local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'
local docTags         = require 'parser.docTags'

--- Extends parser.object (defined in parser/luadoc.lua) with the field this file's `nosecret`
--- type keyword sets on the `doc.type` of a parameter.
---@class parser.object
---@field ["nosecret"]? boolean

local MESSAGE = 'Parameter `%s` cannot take a secret value.'

protoDiagnostic.register {
    'secret-argument',
} {
    group    = 'secret',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for passing a secret value to a parameter that is declared `nosecret` (`---@param str nosecret string`).',
}

-- `nosecret` in front of a type item: `---@param str nosecret string`, `fun(str: nosecret string)`.
docTags.registerTypeKeyword('nosecret', 'nosecret',
    'This parameter cannot take a secret value: `---@param str nosecret string`. Passing one is reported by `secret-argument`.')

--- The name of a parameter that is declared `nosecret`, or nil.
---@param param parser.object a function parameter (`local`) or the argument of a `fun(...)` type
---@return string?
local function getNoSecretName(param)
    if param.type == 'doc.type.arg' then
        local extends = param.extends
        if extends and extends.nosecret then
            return param.name and param.name[1] --[[@as string?]]
        end
        return nil
    end
    local docs = param.bindDocs
    if not docs then
        return nil
    end
    for i = 1, #docs do
        local doc = docs[i]
        if  doc.type == 'doc.param'
        and doc.param
        and doc.param[1] == param[1]
        and doc.extends
        and doc.extends.nosecret then
            return param[1] --[[@as string?]]
        end
    end
    return nil
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@async
    guide.eachSourceType(state.ast, 'call', function (source)
        if not source.args or not source.node then
            return
        end
        await.delay()
        local funcNode = vm.compileNode(source.node)
        for i, arg in ipairs(source.args) do
            -- every function the callee can be (a definition and its overloads) has to refuse
            -- the secret: a call that one of them takes is fine
            ---@type string?
            local name
            local refuses = false
            local takes   = false
            for def in funcNode:eachObject() do
                if def.type == 'function' or def.type == 'doc.type.function' then
                    local param = def.args and def.args[i]
                    if param then
                        local refused = getNoSecretName(param)
                        if refused then
                            refuses = true
                            name = name or refused
                        else
                            takes = true
                        end
                    end
                end
            end
            if refuses and not takes and vm.compileNode(arg):hasFlag('secret') then
                callback {
                    start   = arg.start,
                    finish  = arg.finish,
                    message = MESSAGE:format(name or '?'),
                }
            end
        end
    end)
end
