-- Companion of need-check-secret.lua (which owns the flag that says a value is secret).
-- `---@type nosecret string` and `---@nosecret` (all the locals of the statement, or `---@nosecret a, b`)
-- say that a local cannot hold a secret value: `local x = value` and `x = value` with a value that is
-- known to be secret are reported on the value. A value that was checked with a `---@secret-check`
-- function is not secret any more, and the coder unwraps a call result with `---@secret-unwrap` where
-- it becomes plain (the tag is on the local that receives it, so it does not fit a local that is also
-- `nosecret`: unwrap in an intermediate local).
--
-- A local that is declared both secret and `nosecret` is a contradiction: it is reported on the
-- `nosecret` tag (or type) and its values are not checked.
-- The `nosecret` keyword and tag belong to the secret vocabulary (need-check-secret.lua); this file
-- only reads them.

local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Variable `%s` cannot hold a secret value.'
local CONTRADICTION = '`secret` and `nosecret` contradict each other on this variable; keep one.'

protoDiagnostic.register {
    'secret-variable',
} {
    group    = 'secret',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for assigning a secret value to a local declared `nosecret` (`---@type nosecret string`, `---@nosecret`), and for a local declared both secret and `nosecret`.',
}

--- Does a name list tag concern this local?
---@param doc   parser.object
---@param value parser.object
---@return boolean
local function appliesTo(doc, value)
    local names = doc.names
    if not names then
        return true
    end
    for i = 1, #names do
        if names[i][1] == value[1] then
            return true
        end
    end
    return false
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@type table<parser.object, true>
    local reported = {}

    ---@async
    guide.eachSourceType(state.ast, 'local', function (source)
        local docs = source.bindDocs
        if not docs then
            return
        end
        -- `---@nosecret` above `local f = function` is a tag of the function (secret-return)
        if source.value and source.value.type == 'function' then
            return
        end
        ---@type parser.object?
        local nosecret
        local secret = false
        for i = 1, #docs do
            ---@type parser.object
            local doc = docs[i]
            if doc.type == 'doc.nosecret' and appliesTo(doc, source) then
                nosecret = nosecret or doc
            elseif doc.type == 'doc.secret' and appliesTo(doc, source) then
                secret = true
            elseif doc.type == 'doc.type' then
                if doc.nosecret then
                    nosecret = nosecret or doc
                elseif doc.secret then
                    secret = true
                end
            end
        end
        if not nosecret then
            return
        end
        if secret then
            if not reported[nosecret] then
                reported[nosecret] = true
                callback {
                    start   = nosecret.start,
                    finish  = nosecret.finish,
                    message = CONTRADICTION,
                }
            end
            return
        end

        ---@type parser.object[]
        local values = {}
        if source.value then
            values[#values+1] = source.value
        end
        local refs = source.ref
        if refs then
            for i = 1, #refs do
                ---@type parser.object
                local ref = refs[i]
                if ref.type == 'setlocal' and ref.value then
                    values[#values+1] = ref.value
                end
            end
        end
        for i = 1, #values do
            local value = values[i]
            await.delay()
            if vm.compileNode(value):hasFlag('secret') then
                callback {
                    start   = value.start,
                    finish  = value.finish,
                    message = MESSAGE:format(source[1]),
                }
            end
        end
    end)
end
